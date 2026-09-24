import Foundation
import SwiftData

struct HealthKitSyncSnapshot: Equatable {
    let enabled: Bool
    let isSyncing: Bool
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let lastError: String?
    let pendingCount: Int
    let failedCount: Int
    let noRouteCount: Int

    static let empty = HealthKitSyncSnapshot(
        enabled: false, isSyncing: false, lastAttemptAt: nil, lastSuccessAt: nil,
        lastError: nil, pendingCount: 0, failedCount: 0, noRouteCount: 0)
}

extension Notification.Name {
    static let healthKitSyncStatusChanged = Notification.Name("healthKitSyncStatusChanged")
}

@MainActor
enum HealthKitSyncStatusStore {
    private static let lastAttemptKey = "healthKitLastAttemptAt"
    private static let lastSuccessKey = "healthKitLastSuccessAt"
    private static let lastErrorKey = "healthKitLastError"
    private static var syncing = false
    private struct RouteCounts {
        let pending: Int
        let failed: Int
        let noRoute: Int
    }
    private static var cachedRouteCounts: RouteCounts?

    static func snapshot(container: ModelContainer? = nil) -> HealthKitSyncSnapshot {
        var pending = 0, failed = 0, noRoute = 0
        if let container {
            if let cachedRouteCounts {
                pending = cachedRouteCounts.pending
                failed = cachedRouteCounts.failed
                noRoute = cachedRouteCounts.noRoute
                #if DEBUG
                PerformanceDiagnostics.count("HealthKit.statusCounts.cacheHit")
                #endif
            } else {
                let context = ModelContext(container)
                let total = (try? context.fetchCount(FetchDescriptor<WorkoutRecord>())) ?? 0
                func count(_ state: WorkoutRouteSyncState) -> Int {
                    let raw = state.rawValue
                    return (try? context.fetchCount(FetchDescriptor<WorkoutRecord>(
                        predicate: #Predicate { $0.routeSyncStateRaw == raw }))) ?? 0
                }
                let available = count(.available)
                failed = count(.failed)
                noRoute = count(.noRoute)
                // nil/旧版未知值与 WorkoutRecord.routeSyncState 的 fallback 语义一致。
                pending = max(0, total - available - failed - noRoute)
                cachedRouteCounts = RouteCounts(
                    pending: pending, failed: failed, noRoute: noRoute)
                #if DEBUG
                PerformanceDiagnostics.count("HealthKit.statusCounts.cacheMiss")
                #endif
            }
        }
        let defaults = UserDefaults.standard
        return HealthKitSyncSnapshot(
            enabled: defaults.bool(forKey: HealthKitSyncCoordinator.automaticSyncEnabledKey),
            isSyncing: syncing,
            lastAttemptAt: defaults.object(forKey: lastAttemptKey) as? Date,
            lastSuccessAt: defaults.object(forKey: lastSuccessKey) as? Date,
            lastError: defaults.string(forKey: lastErrorKey),
            pendingCount: pending, failedCount: failed, noRouteCount: noRoute)
    }

    static func markStarted() {
        syncing = true
        UserDefaults.standard.set(Date(), forKey: lastAttemptKey)
        notify()
    }

    static func markSucceeded() {
        syncing = false
        cachedRouteCounts = nil
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastSuccessKey)
        defaults.removeObject(forKey: lastErrorKey)
        notify()
    }

    static func markFailed(_ message: String) {
        syncing = false
        cachedRouteCounts = nil
        UserDefaults.standard.set(message, forKey: lastErrorKey)
        notify()
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: HealthKitSyncCoordinator.automaticSyncEnabledKey)
        if !enabled { syncing = false }
        notify()
    }

    static func reset() {
        syncing = false
        cachedRouteCounts = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: HealthKitSyncCoordinator.automaticSyncEnabledKey)
        defaults.removeObject(forKey: lastAttemptKey)
        defaults.removeObject(forKey: lastSuccessKey)
        defaults.removeObject(forKey: lastErrorKey)
        notify()
    }

    private static func notify() {
        #if DEBUG
        PerformanceDiagnostics.event("HealthKit.syncState.publish")
        #endif
        NotificationCenter.default.post(name: .healthKitSyncStatusChanged, object: nil)
    }
}
