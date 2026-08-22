import Foundation
import HealthKit
import CoreLocation
import SwiftData

/// 苹果健康集成：Workout 摘要与 Workout Route 独立入库，不与后台 FootprintPoint 混合。
@MainActor
enum HealthKitService {

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 授权并导入全部锻炼路线
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
        let existing = Set(((try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? [])
            .map(\.healthKitUUID))
        var addedRoutes = 0
        for (i, workout) in workouts.enumerated() {
            let workoutID = workout.uuid.uuidString
            guard !existing.contains(workoutID) else { continue }
            let label = workoutLabel(workout)
            progress("正在读取路线 \(i + 1)/\(count)（\(label)）")
            let locations = await fetchRoute(workout: workout, store: store)
            if !locations.isEmpty {
                appLog.info("[Health] \(label)：\(locations.count) 个轨迹点")
            }
            var elevationGain = 0.0
            for pair in zip(locations, locations.dropFirst()) {
                elevationGain += max(0, pair.1.altitude - pair.0.altitude)
            }
            let record = WorkoutRecord(
                healthKitUUID: workoutID,
                workoutType: workoutTypeName(workout),
                startDate: workout.startDate, endDate: workout.endDate,
                duration: workout.duration,
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                caloriesKCal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                elevationGain: elevationGain, routeAvailable: !locations.isEmpty)
            context.insert(record)
            for loc in locations {
                context.insert(WorkoutRoutePoint(
                    workoutID: workoutID, latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude, altitude: loc.altitude,
                    timestamp: loc.timestamp))
            }
            if !locations.isEmpty { addedRoutes += 1 }
        }
        try? context.save()
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

    /// 锻炼路线：先取路线样本，再逐块累积定位点
    private static func fetchRoute(workout: HKWorkout, store: HKHealthStore) async -> [CLLocation] {
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
        guard let route = routes.first else { return [] }

        return await withCheckedContinuation { continuation in
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
