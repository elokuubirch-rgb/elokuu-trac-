import Foundation
import HealthKit
import CoreLocation
import SwiftData

/// 苹果健康集成：Workout 摘要与 Workout Route 独立入库，不与后台 FootprintPoint 混合。
@MainActor
enum HealthKitService {

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 授权并同步全部锻炼。已有 Workout 不再直接跳过：pending/failed 可补取延迟 Route。
    static func requestAndImport(container: ModelContainer,
                                 enableAutomaticSync: Bool,
                                 progress: @escaping @Sendable (String) -> Void) async -> Int {
        guard isAvailable else {
            appLog.error("[Health] 此设备不支持健康数据")
            return 0
        }
        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(toShare: [], read: [
                HKObjectType.workoutType(),
                HKSeriesType.workoutRoute(),
            ])
        } catch {
            appLog.error("[Health] 授权失败: \(error.localizedDescription)")
            HealthKitSyncStatusStore.setEnabled(false)
            HealthKitSyncStatusStore.markFailed(error.localizedDescription)
            return 0
        }
        appLog.info("[Health] 授权成功，读取锻炼记录…")

        HealthKitSyncStatusStore.setEnabled(enableAutomaticSync)
        return await HealthKitSyncCoordinator.shared.synchronizeManually(
            container: container, enableAutomaticSync: enableAutomaticSync,
            progress: progress)
    }

    static func performFullSync(store: HKHealthStore, container: ModelContainer,
                                progress: @escaping @Sendable (String) -> Void) async -> Int {
        do {
            let workouts = try await fetchWorkouts(store: store)
            appLog.info("[Health] 全量锻炼记录 \(workouts.count) 条")
            guard let added = await importChanges(
                workouts: workouts, deletedWorkoutIDs: [], store: store,
                container: container, progress: progress) else {
                HealthKitSyncStatusStore.markFailed("本地健康数据保存失败")
                return 0
            }
            HealthKitSyncStatusStore.markSucceeded()
            return added
        } catch {
            appLog.error("[Health] 全量查询失败: \(error.localizedDescription)")
            HealthKitSyncStatusStore.markFailed(error.localizedDescription)
            return 0
        }
    }

    static func performIncrementalSync(store: HKHealthStore, container: ModelContainer,
                                       forcePendingRetry: Bool,
                                       progress: @escaping @Sendable (String) -> Void) async -> Int {
        let previousAnchor = HealthKitAnchorStore.load()
        do {
            #if DEBUG
            let changes = try await PerformanceDiagnostics.measureAsync(
                "HealthKit.anchoredSync") {
                    try await fetchWorkoutChanges(store: store, anchor: previousAnchor)
                }
            #else
            let changes = try await fetchWorkoutChanges(store: store, anchor: previousAnchor)
            #endif
            let pendingIDs = pendingWorkoutIDs(
                in: container, forceRetry: forcePendingRetry)
            let changedIDs = Set(changes.workouts.map(\.uuid))
            let retryIDs = pendingIDs.subtracting(changedIDs)
            let retries = retryIDs.isEmpty
                ? [] : try await fetchWorkouts(store: store, ids: retryIDs)
            #if DEBUG
            PerformanceDiagnostics.count("HealthKit.routeRetry.workouts", by: retries.count)
            #endif
            let all = Dictionary(uniqueKeysWithValues:
                (changes.workouts + retries).map { ($0.uuid, $0) }).values.sorted {
                    $0.startDate < $1.startDate
                }
            #if DEBUG
            PerformanceDiagnostics.count("HealthKit.changeSet.workouts", by: all.count)
            PerformanceDiagnostics.count("HealthKit.changeSet.deleted",
                                         by: changes.deleted.count)
            if all.isEmpty, changes.deleted.isEmpty {
                PerformanceDiagnostics.count("HealthKit.emptyChangeSet")
                PerformanceDiagnostics.event("HealthKit.emptyChangeSet")
            }
            #endif
            // Anchor/同步状态仍正常推进，但空增量绝不能触碰 SwiftData、迁移或地图缓存。
            if all.isEmpty, changes.deleted.isEmpty {
                if let newAnchor = changes.newAnchor { HealthKitAnchorStore.save(newAnchor) }
                HealthKitSyncStatusStore.markSucceeded()
                appLog.info("[Health] 增量同步完成：无数据变化")
                return 0
            }
            guard let added = await importChanges(
                workouts: all, deletedWorkoutIDs: Set(changes.deleted.map(\.uuid)),
                store: store, container: container, progress: progress) else {
                HealthKitSyncStatusStore.markFailed("本地健康数据保存失败")
                return 0
            }
            if let newAnchor = changes.newAnchor { HealthKitAnchorStore.save(newAnchor) }
            HealthKitSyncStatusStore.markSucceeded()
            appLog.info("[Health] 增量同步：变化 \(changes.workouts.count)，重试 \(retries.count)，删除 \(changes.deleted.count)")
            return added
        } catch {
            appLog.error("[Health] 增量查询失败: \(error.localizedDescription)")
            HealthKitSyncStatusStore.markFailed(error.localizedDescription)
            return 0
        }
    }

    /// 返回 nil 表示 SwiftData 保存失败，此时调用方不得推进 anchor。
    private static func importChanges(workouts: [HKWorkout], deletedWorkoutIDs: Set<UUID>,
                                      store: HKHealthStore, container: ModelContainer,
                                      progress: @escaping @Sendable (String) -> Void) async -> Int? {
        let context = ModelContext(container)
        let deletedStrings = Set(deletedWorkoutIDs.map(\.uuidString))
        var workoutInsertedOrUpdated = false
        var workoutDeleted = false
        var routeInsertedOrUpdated = false
        var routeDeleted = false
        if !deletedStrings.isEmpty {
            for deletedID in deletedStrings {
                let targetID = deletedID
                for row in (try? context.fetch(FetchDescriptor<WorkoutRoutePoint>(
                    predicate: #Predicate { $0.workoutID == targetID }))) ?? [] {
                    context.delete(row)
                    routeDeleted = true
                }
            }
            for deletedID in deletedStrings {
                let targetID = deletedID
                for row in (try? context.fetch(FetchDescriptor<WorkoutRouteRecord>(
                    predicate: #Predicate { $0.workoutID == targetID }))) ?? [] {
                    context.delete(row)
                    routeDeleted = true
                }
                for row in (try? context.fetch(FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate { $0.healthKitUUID == targetID }))) ?? [] {
                    context.delete(row)
                    workoutDeleted = true
                }
            }
        }

        let count = workouts.count
        let existingRecords = (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []
        var recordByID = Dictionary(uniqueKeysWithValues: existingRecords
            .filter { !deletedStrings.contains($0.healthKitUUID) }
            .map { ($0.healthKitUUID, $0) })
        let routeRows = (try? context.fetch(FetchDescriptor<WorkoutRouteRecord>())) ?? []
        var existingRoutes = Set(routeRows.map(\.routeID))
        var workoutsWithRoutes = Set(routeRows.map(\.workoutID))
        var addedRoutes = 0
        for (i, workout) in workouts.enumerated() {
            let workoutID = workout.uuid.uuidString
            let label = workoutLabel(workout)
            let record: WorkoutRecord
            if let existing = recordByID[workoutID] {
                record = existing
                let nextWorkoutType = workoutTypeName(workout)
                let summaryChanged = record.workoutType != nextWorkoutType
                    || record.startDate != workout.startDate
                    || record.endDate != workout.endDate
                    || record.duration != workout.duration
                    || record.distanceMeters != (workout.totalDistance?.doubleValue(for: .meter()) ?? 0)
                    || record.caloriesKCal != (workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0)
                let presentationChanged = record.workoutType != nextWorkoutType
                    && workoutsWithRoutes.contains(workoutID)
                record.workoutType = nextWorkoutType
                record.startDate = workout.startDate
                record.endDate = workout.endDate
                record.duration = workout.duration
                record.distanceMeters = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
                record.caloriesKCal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
                workoutInsertedOrUpdated = workoutInsertedOrUpdated || summaryChanged
                routeInsertedOrUpdated = routeInsertedOrUpdated || presentationChanged
                // 已有可用路线已被 Route 实体覆盖时无需重复下载全部点。
                if existing.routeSyncState == .available { continue }
            } else {
                record = WorkoutRecord(
                    healthKitUUID: workoutID,
                    workoutType: workoutTypeName(workout),
                    startDate: workout.startDate, endDate: workout.endDate,
                    duration: workout.duration,
                    distanceMeters: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                    caloriesKCal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                    elevationGain: 0, routeAvailable: false, routeSyncState: .unknown)
                context.insert(record)
                recordByID[workoutID] = record
                workoutInsertedOrUpdated = true
            }
            progress("正在读取路线 \(i + 1)/\(count)（\(label)）")
            record.routeLastCheckedAt = Date()
            let routes: [RoutePayload]
            do {
                routes = try await fetchRoutes(workout: workout, store: store)
            } catch {
                record.routeSyncState = .failed
                record.routeAvailable = workoutsWithRoutes.contains(workoutID)
                record.routeRetryCount = (record.routeRetryCount ?? 0) + 1
                record.routeLastError = error.localizedDescription
                continue
            }
            var elevationGain = 0.0
            var importedForWorkout = 0
            for route in routes where !existingRoutes.contains(route.routeID) {
                let ordered = route.locations.sorted { $0.timestamp < $1.timestamp }
                guard !ordered.isEmpty else { continue }
                context.insert(WorkoutRouteRecord(
                    routeID: route.routeID, workoutID: workoutID,
                    sourceIdentifier: route.sourceIdentifier,
                    sourceName: route.sourceName,
                    deviceIdentifier: route.deviceIdentifier))
                let raw = ordered.enumerated().map { index, location in
                    WorkoutRouteRawPoint(
                        id: String(index), latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude, timestamp: location.timestamp)
                }
                let orderByID = Dictionary(uniqueKeysWithValues:
                    WorkoutRouteMetadata.assign(raw).map { ($0.id, $0) })
                for (index, location) in ordered.enumerated() {
                    let order = orderByID[String(index)]
                    context.insert(WorkoutRoutePoint(
                        workoutID: workoutID, latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude, altitude: location.altitude,
                        timestamp: location.timestamp, routeID: route.routeID,
                        segmentIndex: order?.segmentIndex, pointIndex: order?.pointIndex,
                        horizontalAccuracy: validMetric(location.horizontalAccuracy),
                        verticalAccuracy: validMetric(location.verticalAccuracy),
                        speed: validMetric(location.speed), course: validMetric(location.course),
                        sourceIdentifier: route.sourceIdentifier))
                }
                for pair in zip(ordered, ordered.dropFirst()) {
                    elevationGain += max(0, pair.1.altitude - pair.0.altitude)
                }
                importedForWorkout += 1
                existingRoutes.insert(route.routeID)
                workoutsWithRoutes.insert(workoutID)
                routeInsertedOrUpdated = true
                appLog.info("[Health] \(label) Route \(route.routeID)：\(ordered.count) 点")
            }
            if workoutsWithRoutes.contains(workoutID) || routes.contains(where: { !$0.locations.isEmpty }) {
                record.routeSyncState = .available
                record.routeAvailable = true
                record.routeRetryCount = 0
                record.routeLastError = nil
                record.elevationGain = max(record.elevationGain, elevationGain)
            } else {
                // Route 可能延迟到达；空结果不是终态，下次同步继续查询。
                record.routeSyncState = .pending
                record.routeAvailable = false
                let retryCount = (record.routeRetryCount ?? 0) + 1
                record.routeRetryCount = retryCount
                record.routeSyncStateRaw = HealthRouteRetryPolicy.stateAfterEmptyResult(
                    retryCount: retryCount, workoutEnd: record.endDate)
                record.routeLastError = nil
            }
            addedRoutes += importedForWorkout
        }
        do {
            try context.save()
        } catch {
            appLog.error("[Health] 保存失败: \(error.localizedDescription)")
            return nil
        }
        let domains = HealthSyncInvalidationPolicy.domains(
            workoutInsertedOrUpdated: workoutInsertedOrUpdated,
            workoutDeleted: workoutDeleted,
            routeInsertedOrUpdated: routeInsertedOrUpdated,
            routeDeleted: routeDeleted)
        DataRevisionStore.commit(domains, reason: "HealthKit.importChanges")
        appLog.info("[Health] 独立 Workout Route 导入：新增 \(addedRoutes) 条")
        return addedRoutes
    }

    // MARK: - HealthKit 查询

    private struct WorkoutChanges {
        let workouts: [HKWorkout]
        let deleted: [HKDeletedObject]
        let newAnchor: HKQueryAnchor?
    }

    private static func fetchWorkoutChanges(store: HKHealthStore,
                                            anchor: HKQueryAnchor?) async throws -> WorkoutChanges {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(), predicate: nil, anchor: anchor,
                limit: HKObjectQueryNoLimit) { _, samples, deleted, newAnchor, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: WorkoutChanges(
                        workouts: (samples as? [HKWorkout]) ?? [],
                        deleted: deleted ?? [], newAnchor: newAnchor))
                }
            store.execute(query)
        }
    }

    private static func fetchWorkouts(store: HKHealthStore,
                                      ids: Set<UUID>? = nil) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = ids.map { HKQuery.predicateForObjects(with: $0) }
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    private static func pendingWorkoutIDs(in container: ModelContainer,
                                          forceRetry: Bool) -> Set<UUID> {
        let context = ModelContext(container)
        let now = Date()
        return Set(((try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []).compactMap { row in
            let eligible = forceRetry || HealthRouteRetryPolicy.shouldRetry(
                stateRaw: row.routeSyncStateRaw, retryCount: row.routeRetryCount,
                lastCheckedAt: row.routeLastCheckedAt, now: now)
            guard eligible, row.routeSyncState != .available else { return nil }
            if row.routeSyncState == .noRoute, !forceRetry { return nil }
            return UUID(uuidString: row.healthKitUUID)
        })
    }

    private struct RoutePayload {
        let routeID: String
        let sourceIdentifier: String?
        let sourceName: String?
        let deviceIdentifier: String?
        let locations: [CLLocation]
    }

    /// 读取一个 Workout 关联的全部 Route；每个 Route 单独累积所有流式 chunk。
    private static func fetchRoutes(workout: HKWorkout,
                                    store: HKHealthStore) async throws -> [RoutePayload] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        var result: [RoutePayload] = []
        for route in routes {
            let locations = try await fetchLocations(route: route, store: store)
            result.append(RoutePayload(
                routeID: route.uuid.uuidString,
                sourceIdentifier: route.sourceRevision.source.bundleIdentifier,
                sourceName: route.sourceRevision.source.name,
                deviceIdentifier: route.device?.localIdentifier,
                locations: locations))
        }
        return result
    }

    private static func fetchLocations(route: HKWorkoutRoute,
                                       store: HKHealthStore) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                var points: [CLLocation] = []
                var resumed = false

                func append(_ locations: [CLLocation], done: Bool,
                            error: Error?) -> Result<[CLLocation], Error>? {
                    lock.lock()
                    defer { lock.unlock() }
                    points.append(contentsOf: locations)
                    guard (done || error != nil), !resumed else { return nil }
                    resumed = true
                    if let error { return .failure(error) }
                    return .success(points)
                }
            }
            let box = Box()
            let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let result = box.append(locations ?? [], done: done, error: error) {
                    continuation.resume(with: result)
                }
            }
            store.execute(routeQuery)
        }
    }

    private static func validMetric(_ value: Double) -> Double? {
        value >= 0 && value.isFinite ? value : nil
    }

    private static func workoutLabel(_ workout: HKWorkout) -> String {
        let name = workoutTypeName(workout)
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        return "\(name) \(df.string(from: workout.startDate))"
    }

    private static func workoutTypeName(_ workout: HKWorkout) -> String {
        let name: String
        switch workout.workoutActivityType {
        case .running: name = "跑步"
        case .walking: name = "步行"
        case .cycling: name = "骑行"
        case .hiking: name = "徒步"
        case .swimming: name = "游泳"
        default: name = "锻炼"
        }
        return name
    }
}

/// HKQueryAnchor 只有在业务数据成功落库后才覆盖，避免“anchor 已前进、数据未保存”的永久丢失。
private enum HealthKitAnchorStore {
    private static let key = "healthKitWorkoutQueryAnchor.v1"

    static func load(defaults: UserDefaults = .standard) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            appLog.error("[Health] Anchor读取失败，将从头增量同步: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ anchor: HKQueryAnchor, defaults: UserDefaults = .standard) {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: anchor, requiringSecureCoding: true)
            defaults.set(data, forKey: key)
        } catch {
            appLog.error("[Health] Anchor保存失败: \(error.localizedDescription)")
        }
    }
}
