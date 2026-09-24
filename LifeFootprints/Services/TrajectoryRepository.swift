import Foundation
import SwiftData

enum TrajectoryCachePublicationPolicy {
    enum Action { case discard, exact, refreshSeed }

    static func action(readRevision: Int, currentRevision: Int,
                       readSafety: Int, currentSafety: Int) -> Action {
        guard readSafety == currentSafety, currentRevision >= readRevision else { return .discard }
        return currentRevision == readRevision ? .exact : .refreshSeed
    }
}

enum TrajectoryReadPagingPolicy {
    /// WorkoutRoutePoint 包含多个 String/Optional 字段；真机 170 万行冷读时，
    /// 5k 批次把 SwiftData 的瞬时模型图控制在更低峰值。Apple 的 enumerate
    /// 默认同样为 5k；这里只影响 I/O 分批，不影响排序或结果。
    static let batchSize = 5_000

    static func batchCount(forRowCount rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return (rowCount + batchSize - 1) / batchSize
    }

    static func maximumMaterializedModels(forRowCount rowCount: Int) -> Int {
        min(max(0, rowCount), batchSize)
    }
}

/// SwiftData 只负责提供原始记录；轨迹会话、分段和质量全部由领域 Builder 生成。
struct TrajectoryRepository {
    let container: ModelContainer
    let persistentCache: PersistentTrajectoryCache

    init(container: ModelContainer,
         persistentCache: PersistentTrajectoryCache = .shared) {
        self.container = container
        self.persistentCache = persistentCache
    }

    func load() throws -> [Trajectory] {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        #if DEBUG
        if PerformanceDiagnostics.isEnabled {
            let footprintCount = PerformanceDiagnostics.measure(
                "SwiftData.trajectoryFootprint.count") {
                    (try? context.fetchCount(FetchDescriptor<FootprintPoint>(
                        predicate: #Predicate {
                            $0.sourceRaw == "gps" || $0.sourceRaw == "csv"
                        }))) ?? 0
                }
            let routePointCount = PerformanceDiagnostics.measure(
                "SwiftData.workoutRoutePoint.count") {
                    (try? context.fetchCount(FetchDescriptor<WorkoutRoutePoint>())) ?? 0
                }
            let workoutCount = PerformanceDiagnostics.measure("SwiftData.workout.count") {
                (try? context.fetchCount(FetchDescriptor<WorkoutRecord>())) ?? 0
            }
            let workoutRouteCount = PerformanceDiagnostics.measure(
                "SwiftData.workoutRoute.count") {
                    (try? context.fetchCount(FetchDescriptor<WorkoutRouteRecord>())) ?? 0
                }
            let routeStartCount = PerformanceDiagnostics.measure(
                "SwiftData.workoutRoutePoint.routeStart.count") {
                    (try? context.fetchCount(FetchDescriptor<WorkoutRoutePoint>(
                        predicate: #Predicate { $0.pointIndex == 0 }))) ?? 0
                }
            let unorderedRoutePointCount = PerformanceDiagnostics.measure(
                "SwiftData.workoutRoutePoint.unordered.count") {
                    (try? context.fetchCount(FetchDescriptor<WorkoutRoutePoint>(
                        predicate: #Predicate { $0.pointIndex == nil }))) ?? 0
                }
            PerformanceDiagnostics.count("Dataset.trajectoryFootprintRows", by: footprintCount)
            PerformanceDiagnostics.count("Dataset.workoutRoutePointRows", by: routePointCount)
            PerformanceDiagnostics.count("Dataset.workoutRows", by: workoutCount)
            PerformanceDiagnostics.count("Dataset.workoutRoutes", by: workoutRouteCount)
            PerformanceDiagnostics.count("Dataset.workoutRouteStarts", by: routeStartCount)
            PerformanceDiagnostics.count(
                "Dataset.workoutRoutePointsUnordered", by: unorderedRoutePointCount)
            PerformanceDiagnostics.count(
                "Dataset.rawTrajectoryPointRows",
                by: footprintCount + routePointCount)
            PerformanceDiagnostics.flush()
        }
        #endif

        #if DEBUG
        let footprintRows = try PerformanceDiagnostics.measure("SwiftData.trajectoryFootprint.fetch") {
            try context.fetch(FetchDescriptor<FootprintPoint>(
                predicate: #Predicate { $0.sourceRaw == "gps" || $0.sourceRaw == "csv" },
                sortBy: [SortDescriptor(\.timestamp)]))
        }
        let workouts = try PerformanceDiagnostics.measure("SwiftData.workout.fetch") {
            try context.fetch(FetchDescriptor<WorkoutRecord>())
        }
        #else
        let footprintRows = try context.fetch(FetchDescriptor<FootprintPoint>(
            predicate: #Predicate { $0.sourceRaw == "gps" || $0.sourceRaw == "csv" },
            sortBy: [SortDescriptor(\.timestamp)]))
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        #endif
        let activityByWorkout = Dictionary(uniqueKeysWithValues: workouts.map {
            ($0.healthKitUUID, $0.workoutType)
        })

        let footprintSamples = footprintRows.map { row in
            TrajectorySample(
                id: TrajectorySampleIdentity.footprint(
                    source: row.sourceRaw, latitude: row.latitude,
                    longitude: row.longitude, timestamp: row.timestamp),
                source: row.sourceRaw == FootprintSource.gps.rawValue ? .coreLocation : .imported,
                sourceIdentifier: row.sourceRaw,
                sessionID: row.sessionID, segmentID: row.segmentID,
                latitude: row.latitude, longitude: row.longitude, timestamp: row.timestamp,
                altitude: row.altitude, horizontalAccuracy: row.horizontalAccuracy,
                speed: row.speed, course: row.course)
        }
        let autoSamples = footprintSamples.filter { $0.source == .coreLocation }
        let importedRaw = footprintSamples.filter { $0.source == .imported }
        let importedSessions = ImportedTrajectoryClassifier.sessions(for: importedRaw)
        let importedSamples = importedRaw.compactMap { sample -> TrajectorySample? in
            guard let sessionID = importedSessions[sample.id] else { return nil }
            return TrajectorySample(
                id: sample.id, source: .imported, sourceIdentifier: "csv",
                sessionID: sessionID, latitude: sample.latitude,
                longitude: sample.longitude, timestamp: sample.timestamp)
        }
        let workoutResult = try loadWorkoutTrajectories(activityByWorkout: activityByWorkout)
        let workoutTrajectories = workoutResult.trajectories
        #if DEBUG
        let footprintTrajectories = PerformanceDiagnostics.measure(
            "TrajectoryBuilder.footprints",
            metadata: "samples=\(autoSamples.count + importedSamples.count)") {
                TrajectoryBuilder.build(samples: autoSamples + importedSamples)
            }
        let trajectories = (footprintTrajectories + workoutTrajectories)
            .sorted { $0.startTime < $1.startTime }
        PerformanceDiagnostics.count("Dataset.trajectorySamples",
                                     by: autoSamples.count + importedSamples.count + workoutResult.rowCount)
        PerformanceDiagnostics.count("Dataset.trajectories", by: trajectories.count)
        return trajectories
        #else
        return (TrajectoryBuilder.build(samples: autoSamples + importedSamples)
                + workoutTrajectories).sorted { $0.startTime < $1.startTime }
        #endif
    }

    /// Reuses unchanged HealthKit trajectories from the previous content-addressed
    /// generation. Footprint-backed trajectories are small enough to rebuild exactly.
    /// A point-count reconciliation is the correctness gate; uncertainty falls back to
    /// the existing full rebuild without publishing a partial cache.
    func loadIncremental(
        from stale: StaleTrajectoryCacheSnapshot
    ) throws -> TrajectoryResolution? {
        let inventory = ModelContext(container)
        inventory.autosaveEnabled = false
        let routeRecords = try inventory.fetch(FetchDescriptor<WorkoutRouteRecord>())
        let workouts = try inventory.fetch(FetchDescriptor<WorkoutRecord>())
        let unorderedCount = try inventory.fetchCount(FetchDescriptor<WorkoutRoutePoint>(
            predicate: #Predicate { $0.routeID == nil }))
        guard unorderedCount == 0 else {
            #if DEBUG
            PerformanceDiagnostics.event(
                "TrajectoryIncrementalRefresh.rejected",
                metadata: "reason=legacyRows count=\(unorderedCount)")
            PerformanceDiagnostics.count(
                "TrajectoryIncrementalRefresh.rejected.legacyRows")
            #endif
            return nil
        }

        let activityByWorkout = Dictionary(uniqueKeysWithValues: workouts.map {
            ($0.healthKitUUID, $0.workoutType)
        })
        let cachedHealth = stale.trajectories.filter { $0.source == .healthWorkout }
        let cachedByWorkout = Dictionary(uniqueKeysWithValues: cachedHealth.map {
            ($0.sessionID, $0)
        })
        // Interrupted/legacy imports can have points without a RouteRecord.
        // Use the same route-start inventory as the full reader, otherwise these
        // workouts are excluded and reconciliation needlessly rereads the entire store.
        let routeStarts = try inventory.fetch(FetchDescriptor<WorkoutRoutePoint>(
            predicate: #Predicate { $0.pointIndex == 0 }))
        let recordedRouteIDs = Set(routeRecords.map(\.routeID))
        let unrecordedWorkoutIDs = Set(routeStarts.compactMap { row -> String? in
            guard let routeID = row.routeID, !recordedRouteIDs.contains(routeID) else {
                return nil
            }
            return row.workoutID
        })
        let currentWorkoutIDs = Set(routeRecords.map(\.workoutID))
            .union(routeStarts.map(\.workoutID))
        var changedWorkoutIDs = Set(routeRecords.compactMap {
            $0.createdAt > stale.createdAt ? $0.workoutID : nil
        })
        changedWorkoutIDs.formUnion(currentWorkoutIDs.subtracting(cachedByWorkout.keys))
        // Missing metadata has no trustworthy update timestamp: reload that workout
        // instead of assuming its cached coordinates are current.
        changedWorkoutIDs.formUnion(unrecordedWorkoutIDs)
        for (workoutID, cached) in cachedByWorkout {
            if !currentWorkoutIDs.contains(workoutID)
                || cached.activityType != activityByWorkout[workoutID] {
                changedWorkoutIDs.insert(workoutID)
            }
        }

        let footprintTrajectories = try loadCurrentFootprintTrajectories()
        let rebuiltHealth = try loadWorkoutTrajectories(
            activityByWorkout: activityByWorkout,
            workoutIDs: changedWorkoutIDs).trajectories
        let unchangedHealth = cachedHealth.filter {
            currentWorkoutIDs.contains($0.sessionID)
                && !changedWorkoutIDs.contains($0.sessionID)
        }
        let healthTrajectories = unchangedHealth + rebuiltHealth
        let currentHealthPointCount = try inventory.fetchCount(
            FetchDescriptor<WorkoutRoutePoint>())
        let materializedHealthPointCount = healthTrajectories.reduce(0) { total, trajectory in
            total + trajectory.segments.reduce(0) { $0 + $1.points.count }
        }
        guard currentHealthPointCount == materializedHealthPointCount else {
            #if DEBUG
            PerformanceDiagnostics.event(
                "TrajectoryIncrementalRefresh.rejected",
                metadata: "reason=pointCount database=\(currentHealthPointCount) materialized=\(materializedHealthPointCount)")
            PerformanceDiagnostics.count(
                "TrajectoryIncrementalRefresh.rejected.pointCount")
            #endif
            return nil
        }

        let trajectories = (footprintTrajectories + healthTrajectories)
            .sorted { $0.startTime < $1.startTime }
        #if DEBUG
        PerformanceDiagnostics.count(
            "TrajectoryIncrementalRefresh.workoutsRebuilt", by: changedWorkoutIDs.count)
        PerformanceDiagnostics.count(
            "TrajectoryIncrementalRefresh.workoutsReused", by: unchangedHealth.count)
        PerformanceDiagnostics.count(
            "TrajectoryIncrementalRefresh.healthPointsReused",
            by: unchangedHealth.reduce(0) { total, trajectory in
                total + trajectory.segments.reduce(0) { $0 + $1.points.count }
            })
        return PerformanceDiagnostics.measure(
            "TrajectoryConflictResolver.incremental",
            metadata: "trajectories=\(trajectories.count) changedWorkouts=\(changedWorkoutIDs.count)") {
                TrajectoryConflictResolver.resolve(trajectories)
            }
        #else
        return TrajectoryConflictResolver.resolve(trajectories)
        #endif
    }

    private func loadCurrentFootprintTrajectories() throws -> [Trajectory] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<FootprintPoint>(
            predicate: #Predicate { $0.sourceRaw == "gps" || $0.sourceRaw == "csv" },
            sortBy: [SortDescriptor(\.timestamp)]))
        let samples = rows.map { row in
            TrajectorySample(
                id: TrajectorySampleIdentity.footprint(
                    source: row.sourceRaw, latitude: row.latitude,
                    longitude: row.longitude, timestamp: row.timestamp),
                source: row.sourceRaw == FootprintSource.gps.rawValue
                    ? .coreLocation : .imported,
                sourceIdentifier: row.sourceRaw,
                sessionID: row.sessionID, segmentID: row.segmentID,
                latitude: row.latitude, longitude: row.longitude,
                timestamp: row.timestamp, altitude: row.altitude,
                horizontalAccuracy: row.horizontalAccuracy,
                speed: row.speed, course: row.course)
        }
        let autoSamples = samples.filter { $0.source == .coreLocation }
        let importedRaw = samples.filter { $0.source == .imported }
        let sessions = ImportedTrajectoryClassifier.sessions(for: importedRaw)
        let importedSamples = importedRaw.compactMap { sample -> TrajectorySample? in
            guard let sessionID = sessions[sample.id] else { return nil }
            return TrajectorySample(
                id: sample.id, source: .imported, sourceIdentifier: "csv",
                sessionID: sessionID, latitude: sample.latitude,
                longitude: sample.longitude, timestamp: sample.timestamp)
        }
        #if DEBUG
        return PerformanceDiagnostics.measure(
            "TrajectoryBuilder.footprints.incremental",
            metadata: "samples=\(autoSamples.count + importedSamples.count)") {
                TrajectoryBuilder.build(samples: autoSamples + importedSamples)
            }
        #else
        return TrajectoryBuilder.build(samples: autoSamples + importedSamples)
        #endif
    }

    private func loadWorkoutTrajectories(
        activityByWorkout: [String: String],
        workoutIDs: Set<String>? = nil
    ) throws -> (trajectories: [Trajectory], rowCount: Int) {
        #if DEBUG
        let routeAuditOnly = ProcessInfo.processInfo.environment["FP_ROUTE_AUDIT_ONLY"] == "1"
        #else
        let routeAuditOnly = false
        #endif
        let accumulator = WorkoutTrajectoryAccumulator(
            activityByWorkout: activityByWorkout, collectsPoints: !routeAuditOnly)
        #if DEBUG
        if routeAuditOnly {
            return try auditWorkoutRouteRows(accumulator: accumulator)
        }
        #endif
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        let rowCount = try PerformanceDiagnostics.measure(
            "SwiftData.workoutRoutePoint.enumerateByRoute",
            metadata: "batchSize=\(TrajectoryReadPagingPolicy.batchSize)") {
                try enumerateWorkoutRouteRowsByRoute(
                    accumulator: accumulator, workoutIDs: workoutIDs)
            }
        let batchCount = TrajectoryReadPagingPolicy.batchCount(forRowCount: rowCount)
        PerformanceDiagnostics.recordDuration(
            "SwiftData.workoutRoutePoint.fetch.pagedTotal",
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000)
        PerformanceDiagnostics.count(
            "SwiftData.workoutRoutePoint.fetch.batchCount", by: batchCount)
        PerformanceDiagnostics.count(
            "SwiftData.workoutRoutePoint.fetch.batchModelsMaterialized",
            by: rowCount)
        PerformanceDiagnostics.count("Dataset.workoutRoutePointRows.loaded", by: rowCount)
        PerformanceDiagnostics.count(
            "Dataset.workoutRoutePointSamples.accepted",
            by: accumulator.acceptedSampleCount)
        PerformanceDiagnostics.event(
            "WorkoutTrajectoryAccumulator.finish",
            metadata: "rows=\(rowCount) batches=\(batchCount)")
        PerformanceDiagnostics.flush()
        #else
        let rowCount = try enumerateWorkoutRouteRowsByRoute(
            accumulator: accumulator, workoutIDs: workoutIDs)
        #endif
        return (accumulator.finish(), rowCount)
    }

    /// Route 是 HealthKit 的稳定持久边界。逐 Route 排序与全库 timestamp 排序
    /// 生成相同的 Route 内点序，同时把 SQL sort 峰值从 170 万行降到单条路线。
    private func enumerateWorkoutRouteRowsByRoute(
        accumulator: WorkoutTrajectoryAccumulator,
        workoutIDs: Set<String>? = nil
    ) throws -> Int {
        let inventoryContext = ModelContext(container)
        inventoryContext.autosaveEnabled = false
        let routeRecords = try inventoryContext.fetch(FetchDescriptor<WorkoutRouteRecord>())
        var routeIDSet = Set(routeRecords.compactMap { record in
            workoutIDs == nil || workoutIDs?.contains(record.workoutID) == true
                ? record.routeID : nil
        })
        // HealthKit 写入被中断、旧版本迁移或测试夹具可能只留下 route points。
        // pointIndex == 0 是便宜且稳定的 route inventory，不需要重新对全库做
        // timestamp 排序；与 WorkoutRouteRecord 合并后仍按每条 route 原有时间顺序读取。
        let routeStarts = try inventoryContext.fetch(FetchDescriptor<WorkoutRoutePoint>(
            predicate: #Predicate { $0.pointIndex == 0 }))
        routeIDSet.formUnion(routeStarts.compactMap { row in
            workoutIDs == nil || workoutIDs?.contains(row.workoutID) == true
                ? row.routeID : nil
        })
        let routeIDs = routeIDSet.sorted()
        var rowCount = 0
        for routeID in routeIDs {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let targetRouteID = routeID
                let descriptor = FetchDescriptor<WorkoutRoutePoint>(
                    predicate: #Predicate { $0.routeID == targetRouteID },
                    sortBy: [SortDescriptor(\.timestamp)])
                try context.enumerate(
                    descriptor, batchSize: TrajectoryReadPagingPolicy.batchSize
                ) { row in
                    accumulator.append(Self.value(from: row), globalIndex: rowCount)
                    rowCount += 1
                    #if DEBUG
                    if PerformanceDiagnostics.isEnabled, rowCount.isMultiple(of: 100_000) {
                        PerformanceDiagnostics.count("RouteLoad.rowsProcessed", by: 100_000)
                        PerformanceDiagnostics.flush()
                    }
                    #endif
                }
            }
        }
        // 老数据允许 routeID 为 nil。单独读取这个通常为空的小集合，既保留旧语义，
        // 又避免把 170 万条有 routeID 的记录放进一次全局 SQL sort。
        if workoutIDs == nil {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let descriptor = FetchDescriptor<WorkoutRoutePoint>(
                    predicate: #Predicate { $0.routeID == nil },
                    sortBy: [SortDescriptor(\.timestamp)])
                try context.enumerate(
                    descriptor, batchSize: TrajectoryReadPagingPolicy.batchSize
                ) { row in
                    accumulator.append(Self.value(from: row), globalIndex: rowCount)
                    rowCount += 1
                }
            }
        }
        return rowCount
    }

    #if DEBUG
    /// 诊断专用：逐 Route 排序，避免 170 万行全局 SQL sort 在首个 callback 前
    /// 就耗尽内存。仅输出匿名计数，不构造或返回任何产品路线。
    private func auditWorkoutRouteRows(
        accumulator: WorkoutTrajectoryAccumulator
    ) throws -> (trajectories: [Trajectory], rowCount: Int) {
        let inventoryContext = ModelContext(container)
        inventoryContext.autosaveEnabled = false
        let routeIDs = try inventoryContext.fetch(FetchDescriptor<WorkoutRouteRecord>())
            .map(\.routeID).sorted()
        var rowCount = 0
        PerformanceDiagnosticsRouteAudit.lastAccepted = 0

        try PerformanceDiagnostics.measure(
            "SwiftData.workoutRoutePoint.auditByRoute",
            metadata: "routes=\(routeIDs.count) batchSize=\(TrajectoryReadPagingPolicy.batchSize)"
        ) {
            for routeID in routeIDs {
                try autoreleasepool {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    let targetRouteID = routeID
                    let descriptor = FetchDescriptor<WorkoutRoutePoint>(
                        predicate: #Predicate { $0.routeID == targetRouteID },
                        sortBy: [SortDescriptor(\.timestamp)])
                    try context.enumerate(
                        descriptor, batchSize: TrajectoryReadPagingPolicy.batchSize
                    ) { row in
                        accumulator.append(Self.value(from: row), globalIndex: rowCount)
                        rowCount += 1
                        if rowCount.isMultiple(of: 100_000) {
                            Self.flushRouteAuditProgress(
                                rowCount: rowCount, accumulator: accumulator)
                        }
                    }
                }
            }
        }
        let trailingRows = rowCount % 100_000
        if trailingRows > 0 {
            PerformanceDiagnostics.count("RouteAudit.rowsProcessed", by: trailingRows)
        }
        PerformanceDiagnostics.count(
            "RouteAudit.samplesAccepted",
            by: accumulator.acceptedSampleCount
                - PerformanceDiagnosticsRouteAudit.lastAccepted)
        PerformanceDiagnostics.count("Dataset.workoutRoutePointRows.loaded", by: rowCount)
        PerformanceDiagnostics.flush()
        return ([], rowCount)
    }

    private static func flushRouteAuditProgress(
        rowCount: Int, accumulator: WorkoutTrajectoryAccumulator
    ) {
        PerformanceDiagnostics.count("RouteAudit.rowsProcessed", by: 100_000)
        PerformanceDiagnostics.count(
            "RouteAudit.samplesAccepted",
            by: accumulator.acceptedSampleCount - PerformanceDiagnosticsRouteAudit.lastAccepted)
        PerformanceDiagnosticsRouteAudit.lastAccepted = accumulator.acceptedSampleCount
        PerformanceDiagnostics.flush()
    }
    #endif

    /// Repository 失败时的语义保真 fallback；仍分页，绝不一次物化全库 @Model。
    func loadWorkoutSnapshotsFallback() throws -> [FootprintSnapshot] {
        var result: [FootprintSnapshot] = []
        var metadataPool = FootprintSnapshotMetadataPool()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<WorkoutRoutePoint>(
            sortBy: [SortDescriptor(\.timestamp)])
        try context.enumerate(
            descriptor, batchSize: TrajectoryReadPagingPolicy.batchSize
        ) { row in
            let metadata = metadataPool.metadata(
                source: FootprintSource.health.rawValue,
                trajectoryID: "health:\(row.workoutID)", sessionID: row.workoutID,
                segmentID: "\(row.routeID ?? "legacy:\(row.workoutID)"):\(row.segmentIndex ?? 0)",
                isSuppressedDuplicate: false, suppressedBySource: nil)
            result.append(FootprintSnapshot(
                lat: row.latitude, lon: row.longitude, t: row.timestamp,
                metadata: metadata))
        }
        return result
    }

    private static func value(from row: WorkoutRoutePoint) -> WorkoutRoutePointValue {
        WorkoutRoutePointValue(
            workoutID: row.workoutID, routeID: row.routeID,
            latitude: row.latitude, longitude: row.longitude,
            altitude: row.altitude, timestamp: row.timestamp,
            horizontalAccuracy: row.horizontalAccuracy,
            speed: row.speed, course: row.course)
    }

    func loadResolved() throws -> TrajectoryResolution {
        try DatabaseHeavyWorkGate.withExclusiveAccess("TrajectoryRepository.loadResolved") {
            let revision = DataRevisionStore.snapshot().trajectory
            let safetyRevision = DataRevisionStore.displaySafetyRevision()
            let sourceReadStartedAt = Date()
            let usesSharedPersistentCache = persistentCache === PersistentTrajectoryCache.shared
            if usesSharedPersistentCache,
               let cached = TrajectoryResolutionCache.shared.value(for: revision) {
            #if DEBUG
            PerformanceDiagnostics.event(
                "TrajectoryResolutionCache.hit", metadata: "revision=\(revision)")
            #endif
            return cached
            }
            if let cached = persistentCache.load(dataRevision: revision) {
                if usesSharedPersistentCache {
                    TrajectoryResolutionCache.shared.store(cached, for: revision)
                }
                return cached
            }
            if let stale = persistentCache.loadStaleTrajectories(before: revision) {
                do {
                    if let resolution = try loadIncremental(from: stale) {
                        publishResolution(resolution, readRevision: revision,
                            readSafety: safetyRevision, sourceReadStartedAt: sourceReadStartedAt,
                            usesSharedPersistentCache: usesSharedPersistentCache)
                        #if DEBUG
                        PerformanceDiagnostics.event(
                            "TrajectoryIncrementalRefresh.complete",
                            metadata: "cached=\(stale.dataRevision) current=\(revision)")
                        #endif
                        return resolution
                    }
                } catch {
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "TrajectoryIncrementalRefresh.failed",
                        metadata: error.localizedDescription)
                    #endif
                }
            }
            #if DEBUG
            PerformanceDiagnostics.event(
                "TrajectoryResolutionCache.miss", metadata: "revision=\(revision)")
            let trajectories = try load()
            let resolution = PerformanceDiagnostics.measure(
                "TrajectoryConflictResolver", metadata: "trajectories=\(trajectories.count)") {
                    TrajectoryConflictResolver.resolve(trajectories)
                }
            PerformanceDiagnostics.count("Dataset.trajectoryConflicts",
                                         by: resolution.conflicts.count)
            #else
            let resolution = TrajectoryConflictResolver.resolve(try load())
            #endif
            publishResolution(resolution, readRevision: revision,
                readSafety: safetyRevision, sourceReadStartedAt: sourceReadStartedAt,
                usesSharedPersistentCache: usesSharedPersistentCache)
            return resolution
        }
    }

    private func publishResolution(_ resolution: TrajectoryResolution,
                                   readRevision: Int, readSafety: Int,
                                   sourceReadStartedAt: Date,
                                   usesSharedPersistentCache: Bool) {
        let action = TrajectoryCachePublicationPolicy.action(
            readRevision: readRevision, currentRevision: DataRevisionStore.snapshot().trajectory,
            readSafety: readSafety, currentSafety: DataRevisionStore.displaySafetyRevision())
        guard action != .discard else { return }
        if action == .exact, usesSharedPersistentCache {
            TrajectoryResolutionCache.shared.store(resolution, for: readRevision)
        }
        // GPS may append every minute while a large history is loading. Preserve
        // the work under its OLD revision so the next refresh can reuse Health data.
        // Never label this result as current; destructive changes reject it above.
        let saved = persistentCache.save(resolution, dataRevision: readRevision,
                                         sourceReadStartedAt: sourceReadStartedAt)
        #if DEBUG
        if action == .refreshSeed, saved {
            PerformanceDiagnostics.count("TrajectoryCache.refreshSeed.saved")
        }
        #endif
    }
}

#if DEBUG
private enum PerformanceDiagnosticsRouteAudit {
    nonisolated(unsafe) static var lastAccepted = 0
}
#endif

/// 地图重建期间复用解析结果；任何数据导入/删除通知都会显式失效。
final class TrajectoryResolutionCache: @unchecked Sendable {
    static let shared = TrajectoryResolutionCache()
    private let lock = NSLock()
    private var stored: TrajectoryResolution?
    private var storedRevision: Int?
    private var lastInvalidatedRevision: Int?

    var value: TrajectoryResolution? {
        get {
            #if DEBUG
            return PerformanceDiagnostics.measure("TrajectoryResolutionCache.lock.get") {
                lock.withLock { stored }
            }
            #else
            return lock.withLock { stored }
            #endif
        }
        set {
            let revision = newValue == nil ? nil : DataRevisionStore.snapshot().trajectory
            #if DEBUG
            PerformanceDiagnostics.measure("TrajectoryResolutionCache.lock.set") {
                lock.withLock {
                    stored = newValue
                    storedRevision = revision
                }
            }
            #else
            lock.withLock {
                stored = newValue
                storedRevision = revision
            }
            #endif
        }
    }

    func value(for revision: Int) -> TrajectoryResolution? {
        lock.withLock { storedRevision == revision ? stored : nil }
    }

    func store(_ resolution: TrajectoryResolution, for revision: Int) {
        lock.withLock {
            stored = resolution
            storedRevision = revision
        }
    }

    /// 地图已把解析结果物化成长期显示快照和短期空间索引后，释放体积很大的
    /// trajectories/points 对象图。持久 v2 缓存仍保留，后续确需重载时结果不变。
    /// revision 条件避免旧加载任务误清除较新的内存结果。
    func discardTransientValue(for revision: Int) {
        lock.withLock {
            guard storedRevision == revision else { return }
            stored = nil
            storedRevision = nil
        }
    }

    func invalidate() {
        lock.withLock {
            stored = nil
            storedRevision = nil
            lastInvalidatedRevision = nil
        }
    }

    /// 同一个持久 revision 即使被重复投递，也只执行一次失效。
    func invalidate(for revision: Int) {
        lock.withLock {
            guard lastInvalidatedRevision != revision else { return }
            stored = nil
            storedRevision = nil
            lastInvalidatedRevision = revision
            #if DEBUG
            PerformanceDiagnostics.count("TrajectoryResolutionCache.invalidate")
            #endif
        }
    }
}
