import Foundation
import SwiftData

/// 旧 WorkoutRoutePoint 边界的一次性、可恢复迁移。
/// 每个 workout 独立事务，cursor 仅在事务成功后推进；完成后写入 schema version。
enum LegacyRouteMigration {
    static let schemaVersion = 1
    private static let versionKey = "legacyRouteMigration.schemaVersion"
    private static let cursorKey = "legacyRouteMigration.cursor"

    struct Outcome: Equatable {
        let migratedWorkouts: Int
        let migratedPoints: Int
        let alreadyComplete: Bool
    }

    static func runIfNeeded(container: ModelContainer,
                            defaults: UserDefaults = .standard,
                            publishRevision: Bool = true) -> Outcome {
        guard defaults.integer(forKey: versionKey) < schemaVersion else {
            return Outcome(migratedWorkouts: 0, migratedPoints: 0, alreadyComplete: true)
        }
        return DatabaseHeavyWorkGate.withExclusiveAccess("LegacyRouteMigration") {
            migrate(container: container, defaults: defaults,
                    publishRevision: publishRevision)
        }
    }

    private static func migrate(container: ModelContainer,
                                defaults: UserDefaults,
                                publishRevision: Bool) -> Outcome {
        var migratedWorkouts = 0
        var migratedPoints = 0

        while true {
            var batchSucceeded = false
            var migrationComplete = false
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var candidate = FetchDescriptor<WorkoutRoutePoint>(
                    predicate: #Predicate { $0.routeID == nil },
                    sortBy: [SortDescriptor(\.timestamp)])
                candidate.fetchLimit = 1
                guard let workoutID = (try? context.fetch(candidate))?.first?.workoutID else {
                    defaults.set(schemaVersion, forKey: versionKey)
                    defaults.removeObject(forKey: cursorKey)
                    migrationComplete = true
                    return
                }

                let targetWorkoutID = workoutID
                let rows = (try? context.fetch(FetchDescriptor<WorkoutRoutePoint>(
                    predicate: #Predicate {
                        $0.workoutID == targetWorkoutID && $0.routeID == nil
                    }, sortBy: [SortDescriptor(\.timestamp)]))) ?? []
                guard !rows.isEmpty else { return }

                let routeID = "legacy:\(targetWorkoutID)"
                let targetRouteID = routeID
                var routeDescriptor = FetchDescriptor<WorkoutRouteRecord>(
                    predicate: #Predicate { $0.routeID == targetRouteID })
                routeDescriptor.fetchLimit = 1
                if ((try? context.fetch(routeDescriptor)) ?? []).isEmpty {
                    context.insert(WorkoutRouteRecord(routeID: routeID, workoutID: targetWorkoutID))
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

                var workoutDescriptor = FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate { $0.healthKitUUID == targetWorkoutID })
                workoutDescriptor.fetchLimit = 1
                if let workout = try? context.fetch(workoutDescriptor).first {
                    workout.routeSyncState = .available
                    workout.routeAvailable = true
                }
                do {
                    try context.save()
                    defaults.set(targetWorkoutID, forKey: cursorKey)
                    migratedWorkouts += 1
                    migratedPoints += rows.count
                    batchSucceeded = true
                    #if DEBUG
                    PerformanceDiagnostics.event(
                        "LegacyRouteMigration.batch",
                        metadata: "workout=\(targetWorkoutID) points=\(rows.count)")
                    #endif
                } catch {
                    appLog.error("[Migration] Legacy Route 保存失败: \(error.localizedDescription)")
                    return
                }
            }

            // 保存失败时 cursor 不会推进；本轮停止，等待下次启动恢复。
            if migrationComplete || !batchSucceeded { break }
        }

        if migratedWorkouts > 0 {
            DataRevisionStore.commit([.trajectory, .stats],
                                     reason: "LegacyRouteMigration.completed",
                                     defaults: defaults, publish: publishRevision)
        }
        #if DEBUG
        PerformanceDiagnostics.event(
            "LegacyRouteMigration.finish",
            metadata: "workouts=\(migratedWorkouts) points=\(migratedPoints)")
        #endif
        return Outcome(migratedWorkouts: migratedWorkouts,
                       migratedPoints: migratedPoints, alreadyComplete: false)
    }
}
