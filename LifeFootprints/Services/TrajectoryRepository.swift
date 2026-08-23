import Foundation
import SwiftData

/// SwiftData 只负责提供原始记录；轨迹会话、分段和质量全部由领域 Builder 生成。
struct TrajectoryRepository {
    let container: ModelContainer

    func load() throws -> [Trajectory] {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let footprintRows = try context.fetch(FetchDescriptor<FootprintPoint>(
            predicate: #Predicate { $0.sourceRaw == "gps" || $0.sourceRaw == "csv" },
            sortBy: [SortDescriptor(\.timestamp)]))
        let workoutRows = try context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            sortBy: [SortDescriptor(\.timestamp)]))
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
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
        return TrajectoryBuilder.build(samples: autoSamples + importedSamples + workoutSamples)
    }

    func loadResolved() throws -> TrajectoryResolution {
        if let cached = TrajectoryResolutionCache.shared.value { return cached }
        let resolution = TrajectoryConflictResolver.resolve(try load())
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
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func invalidate() { value = nil }
}
