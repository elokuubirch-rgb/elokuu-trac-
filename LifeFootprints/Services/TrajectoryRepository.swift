import Foundation
import SwiftData

/// SwiftData 只负责提供原始记录；轨迹会话、分段和质量全部由领域 Builder 生成。
struct TrajectoryRepository {
    let container: ModelContainer

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
        let workoutRows = try PerformanceDiagnostics.measure("SwiftData.workoutRoutePoint.fetch") {
            try context.fetch(FetchDescriptor<WorkoutRoutePoint>(
                sortBy: [SortDescriptor(\.timestamp)]))
        }
        let workouts = try PerformanceDiagnostics.measure("SwiftData.workout.fetch") {
            try context.fetch(FetchDescriptor<WorkoutRecord>())
        }
        #else
        let footprintRows = try context.fetch(FetchDescriptor<FootprintPoint>(
            predicate: #Predicate { $0.sourceRaw == "gps" || $0.sourceRaw == "csv" },
            sortBy: [SortDescriptor(\.timestamp)]))
        let workoutRows = try context.fetch(FetchDescriptor<WorkoutRoutePoint>(
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
        let workoutSamples = workoutRows.enumerated().map { index, row in
            TrajectorySample(
                id: "workout:\(row.workoutID):\(Int64((row.timestamp.timeIntervalSince1970 * 1_000).rounded())):\(index)",
                source: .healthWorkout, sourceIdentifier: row.workoutID,
                sessionID: row.workoutID, routeID: row.routeID,
                activityType: activityByWorkout[row.workoutID],
                latitude: row.latitude, longitude: row.longitude, timestamp: row.timestamp,
                altitude: row.altitude, horizontalAccuracy: row.horizontalAccuracy,
                speed: row.speed, course: row.course)
        }
        #if DEBUG
        let trajectories = PerformanceDiagnostics.measure(
            "TrajectoryBuilder", metadata: "samples=\(autoSamples.count + importedSamples.count + workoutSamples.count)") {
                TrajectoryBuilder.build(samples: autoSamples + importedSamples + workoutSamples)
            }
        PerformanceDiagnostics.count("Dataset.trajectorySamples",
                                     by: autoSamples.count + importedSamples.count + workoutSamples.count)
        PerformanceDiagnostics.count("Dataset.trajectories", by: trajectories.count)
        return trajectories
        #else
        return TrajectoryBuilder.build(samples: autoSamples + importedSamples + workoutSamples)
        #endif
    }

    func loadResolved() throws -> TrajectoryResolution {
        if let cached = TrajectoryResolutionCache.shared.value {
            #if DEBUG
            PerformanceDiagnostics.event("TrajectoryResolutionCache.hit")
            #endif
            return cached
        }
        #if DEBUG
        PerformanceDiagnostics.event("TrajectoryResolutionCache.miss")
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
        TrajectoryResolutionCache.shared.value = resolution
        return resolution
    }
}

/// 地图重建期间复用解析结果；任何数据导入/删除通知都会显式失效。
final class TrajectoryResolutionCache: @unchecked Sendable {
    static let shared = TrajectoryResolutionCache()
    private let lock = NSLock()
    private var stored: TrajectoryResolution?

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
            #if DEBUG
            PerformanceDiagnostics.measure("TrajectoryResolutionCache.lock.set") {
                lock.withLock { stored = newValue }
            }
            #else
            lock.withLock { stored = newValue }
            #endif
        }
    }

    func invalidate() { value = nil }
}
