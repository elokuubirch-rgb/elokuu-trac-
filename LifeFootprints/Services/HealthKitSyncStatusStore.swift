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

    static func snapshot(container: ModelContainer? = nil) -> HealthKitSyncSnapshot {
        var pending = 0, failed = 0, noRoute = 0
        if let container {
            let context = ModelContext(container)
            for row in (try? context.fetch(FetchDescriptor<WorkoutRecord>())) ?? [] {
                switch row.routeSyncState {
                case .pending, .unknown: pending += 1
                case .failed: failed += 1
                case .noRoute: noRoute += 1
                case .available: break
                }
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
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastSuccessKey)
        defaults.removeObject(forKey: lastErrorKey)
        notify()
    }

    static func markFailed(_ message: String) {
        syncing = false
        UserDefaults.standard.set(message, forKey: lastErrorKey)
        notify()
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: HealthKitSyncCoordinator.automaticSyncEnabledKey)
        if !enabled { syncing = false }
        notify()
    }

    private static func notify() {
        #if DEBUG
        PerformanceDiagnostics.event("HealthKit.syncState.publish")
        #endif
        NotificationCenter.default.post(name: .healthKitSyncStatusChanged, object: nil)
    }
}
