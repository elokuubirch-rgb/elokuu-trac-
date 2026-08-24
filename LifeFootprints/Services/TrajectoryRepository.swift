import Foundation
import SwiftData

/// SwiftData 只负责提供原始记录；轨迹会话、分段和质量全部由领域 Builder 生成。
struct TrajectoryRepository {
    let container: ModelContainer
    let persistentCache: PersistentTrajectoryCache
    private static let routePointBatchSize = 20_000

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
            PerformanceDiagnostics.count("Dataset.trajectoryFootprintRows", by: footprintCount)
            PerformanceDiagnostics.count("Dataset.workoutRoutePointRows", by: routePointCount)
            PerformanceDiagnostics.count("Dataset.workoutRows", by: workoutCount)
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
                latitude: row.latitude, longitude: row.longitude, timestamp: row.timestamp)
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

    private func loadWorkoutTrajectories(
        activityByWorkout: [String: String]
    ) throws -> (trajectories: [Trajectory], rowCount: Int) {
        let accumulator = WorkoutTrajectoryAccumulator(activityByWorkout: activityByWorkout)
        var offset = 0
        var batchCount = 0
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        while true {
            let pageContext = ModelContext(container)
            pageContext.autosaveEnabled = false
            var descriptor = FetchDescriptor<WorkoutRoutePoint>(
                sortBy: [SortDescriptor(\.timestamp)])
            descriptor.fetchLimit = Self.routePointBatchSize
            descriptor.fetchOffset = offset
            #if DEBUG
            let rows = try PerformanceDiagnostics.measure(
                "SwiftData.workoutRoutePoint.fetch.batch",
                metadata: "offset=\(offset) limit=\(Self.routePointBatchSize)") {
                    try pageContext.fetch(descriptor)
                }
            #else
            let rows = try pageContext.fetch(descriptor)
            #endif
            guard !rows.isEmpty else { break }
            autoreleasepool {
                for (localIndex, row) in rows.enumerated() {
                    accumulator.append(WorkoutRoutePointValue(
                        workoutID: row.workoutID, routeID: row.routeID,
                        latitude: row.latitude, longitude: row.longitude,
                        altitude: row.altitude, timestamp: row.timestamp,
                        horizontalAccuracy: row.horizontalAccuracy,
                        speed: row.speed, course: row.course),
                        globalIndex: offset + localIndex)
                }
            }
            offset += rows.count
            batchCount += 1
            #if DEBUG
            PerformanceDiagnostics.count("SwiftData.workoutRoutePoint.fetch.batchCount")
            PerformanceDiagnostics.count("SwiftData.workoutRoutePoint.fetch.batchModelsMaterialized",
                                         by: rows.count)
            #endif
            if rows.count < Self.routePointBatchSize { break }
        }
        #if DEBUG
        PerformanceDiagnostics.recordDuration(
            "SwiftData.workoutRoutePoint.fetch.pagedTotal",
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000)
        PerformanceDiagnostics.count("Dataset.workoutRoutePointRows.loaded", by: offset)
        PerformanceDiagnostics.event("WorkoutTrajectoryAccumulator.finish",
                                     metadata: "rows=\(offset) batches=\(batchCount)")
        #endif
        return (accumulator.finish(), offset)
    }

    /// Repository 失败时的语义保真 fallback；仍分页，绝不一次物化全库 @Model。
    func loadWorkoutSnapshotsFallback() throws -> [FootprintSnapshot] {
        var result: [FootprintSnapshot] = []
        var offset = 0
        while true {
            let pageContext = ModelContext(container)
            var descriptor = FetchDescriptor<WorkoutRoutePoint>(
                sortBy: [SortDescriptor(\.timestamp)])
            descriptor.fetchLimit = Self.routePointBatchSize
            descriptor.fetchOffset = offset
            let rows = try pageContext.fetch(descriptor)
            guard !rows.isEmpty else { break }
            result.reserveCapacity(result.count + rows.count)
            result.append(contentsOf: rows.map {
                FootprintSnapshot(
                    lat: $0.latitude, lon: $0.longitude, t: $0.timestamp,
                    source: FootprintSource.health.rawValue,
                    trajectoryID: "health:\($0.workoutID)", sessionID: $0.workoutID,
                    segmentID: "\($0.routeID ?? "legacy:\($0.workoutID)"):\($0.segmentIndex ?? 0)")
            })
            offset += rows.count
            if rows.count < Self.routePointBatchSize { break }
        }
        return result
    }

    func loadResolved() throws -> TrajectoryResolution {
        try DatabaseHeavyWorkGate.withExclusiveAccess("TrajectoryRepository.loadResolved") {
            let revision = DataRevisionStore.snapshot().trajectory
            if let cached = TrajectoryResolutionCache.shared.value(for: revision) {
            #if DEBUG
            PerformanceDiagnostics.event(
                "TrajectoryResolutionCache.hit", metadata: "revision=\(revision)")
            #endif
            return cached
            }
            if let cached = persistentCache.load(dataRevision: revision) {
                TrajectoryResolutionCache.shared.store(cached, for: revision)
                return cached
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
            // 若构建期间数据发生变化，结果仍可供当前调用返回，但绝不能标记成新 revision 的缓存。
            guard DataRevisionStore.snapshot().trajectory == revision else {
                #if DEBUG
                PerformanceDiagnostics.event(
                    "PersistentTrajectoryCache.skipSave",
                    metadata: "reason=revisionChanged initial=\(revision)")
                #endif
                return resolution
            }
            TrajectoryResolutionCache.shared.store(resolution, for: revision)
            _ = persistentCache.save(resolution, dataRevision: revision)
            return resolution
        }
    }
}

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
