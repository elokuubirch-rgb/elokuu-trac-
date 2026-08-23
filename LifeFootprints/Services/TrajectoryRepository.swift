import Foundation
import SwiftData

/// SwiftData 只负责提供原始记录；轨迹会话、分段和质量全部由领域 Builder 生成。
struct TrajectoryRepository {
    let container: ModelContainer

    func load() throws -> [Trajectory] {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let footprintRows = try context.fetch(FetchDescriptor<FootprintPoint>(
            predicate: #Predicate { $0.sourceRaw == "gps" },
            sortBy: [SortDescriptor(\.timestamp)]))
        let workoutRows = try context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            sortBy: [SortDescriptor(\.timestamp)]))
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let activityByWorkout = Dictionary(uniqueKeysWithValues: workouts.map {
            ($0.healthKitUUID, $0.workoutType)
        })

        let autoSamples = footprintRows.enumerated().map { index, row in
            TrajectorySample(
                id: "footprint:\(Int64((row.timestamp.timeIntervalSince1970 * 1_000).rounded())):\(index)",
                source: .coreLocation,
                latitude: row.latitude, longitude: row.longitude, timestamp: row.timestamp)
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
        return TrajectoryBuilder.build(samples: autoSamples + workoutSamples)
    }

    func loadResolved() throws -> TrajectoryResolution {
        TrajectoryConflictResolver.resolve(try load())
    }
}
