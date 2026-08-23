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
            return 0
        }
        appLog.info("[Health] 授权成功，读取锻炼记录…")

        let workouts = await fetchWorkouts(store: store)
        let count = workouts.count
        appLog.info("[Health] 锻炼记录 \(count) 条")
        let context = ModelContext(container)
        backfillLegacyRouteBoundaries(in: context)
        let existingRecords = (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []
        let recordByID = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.healthKitUUID, $0) })
        let existingRoutes = Set(((try? context.fetch(FetchDescriptor<WorkoutRouteRecord>())) ?? [])
            .map(\.routeID))
        var addedRoutes = 0
        for (i, workout) in workouts.enumerated() {
            let workoutID = workout.uuid.uuidString
            let label = workoutLabel(workout)
            let record: WorkoutRecord
            if let existing = recordByID[workoutID] {
                record = existing
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
            }
            progress("正在读取路线 \(i + 1)/\(count)（\(label)）")
            record.routeLastCheckedAt = Date()
            let routes = await fetchRoutes(workout: workout, store: store)
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
                appLog.info("[Health] \(label) Route \(route.routeID)：\(ordered.count) 点")
            }
            if routes.contains(where: { !$0.locations.isEmpty }) {
                record.routeSyncState = .available
                record.routeAvailable = true
                record.routeRetryCount = 0
                record.routeLastError = nil
                record.elevationGain = max(record.elevationGain, elevationGain)
            } else {
                // Route 可能延迟到达；空结果不是终态，下次同步继续查询。
                record.routeSyncState = .pending
                record.routeAvailable = false
                record.routeRetryCount = (record.routeRetryCount ?? 0) + 1
            }
            addedRoutes += importedForWorkout
        }
        do {
            try context.save()
        } catch {
            appLog.error("[Health] 保存失败: \(error.localizedDescription)")
            return 0
        }
        NotificationCenter.default.post(name: .dataImported, object: nil)
        appLog.info("[Health] 独立 Workout Route 导入：新增 \(addedRoutes) 条")
        return addedRoutes
    }

    // MARK: - HealthKit 查询

    private static func fetchWorkouts(store: HKHealthStore) async -> [HKWorkout] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: nil,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    private struct RoutePayload {
        let routeID: String
        let sourceIdentifier: String?
        let sourceName: String?
        let deviceIdentifier: String?
        let locations: [CLLocation]
    }

    /// 读取一个 Workout 关联的全部 Route；每个 Route 单独累积所有流式 chunk。
    private static func fetchRoutes(workout: HKWorkout, store: HKHealthStore) async -> [RoutePayload] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        var result: [RoutePayload] = []
        for route in routes {
            let locations = await fetchLocations(route: route, store: store)
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
                                       store: HKHealthStore) async -> [CLLocation] {
        await withCheckedContinuation { continuation in
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                var points: [CLLocation] = []
                var resumed = false

                func append(_ locations: [CLLocation], done: Bool, error: Error?) -> [CLLocation]? {
                    lock.lock()
                    defer { lock.unlock() }
                    points.append(contentsOf: locations)
                    guard (done || error != nil), !resumed else { return nil }
                    resumed = true
                    return points
                }
            }
            let box = Box()
            let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let completed = box.append(locations ?? [], done: done, error: error) {
                    continuation.resume(returning: completed)
                }
            }
            store.execute(routeQuery)
        }
    }

    /// 旧库只有 workoutID。将旧点归入稳定的 legacy Route，避免升级后重复导入。
    private static func backfillLegacyRouteBoundaries(in context: ModelContext) {
        let points = (try? context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            sortBy: [SortDescriptor(\.timestamp)]))) ?? []
        let legacy = points.filter { $0.routeID == nil }
        guard !legacy.isEmpty else { return }
        let existingRouteIDs = Set(((try? context.fetch(FetchDescriptor<WorkoutRouteRecord>())) ?? [])
            .map(\.routeID))
        let workouts = Dictionary(uniqueKeysWithValues:
            ((try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? []).map { ($0.healthKitUUID, $0) })
        for (workoutID, rows) in Dictionary(grouping: legacy, by: \.workoutID) {
            let routeID = "legacy:\(workoutID)"
            if !existingRouteIDs.contains(routeID) {
                context.insert(WorkoutRouteRecord(routeID: routeID, workoutID: workoutID))
            }
            let raw = rows.enumerated().map { index, point in
                WorkoutRouteRawPoint(id: String(index), latitude: point.latitude,
                                     longitude: point.longitude, timestamp: point.timestamp)
            }
            let metadata = Dictionary(uniqueKeysWithValues:
                WorkoutRouteMetadata.assign(raw).map { ($0.id, $0) })
            for (index, point) in rows.enumerated() {
                point.routeID = routeID
                point.segmentIndex = metadata[String(index)]?.segmentIndex
                point.pointIndex = metadata[String(index)]?.pointIndex
            }
            if let workout = workouts[workoutID] {
                workout.routeSyncState = .available
                workout.routeAvailable = true
            }
        }
        try? context.save()
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
