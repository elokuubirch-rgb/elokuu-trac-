import Foundation
import HealthKit
import SwiftData

/// 保持 HealthKit observer 存活，并把所有手动/后台同步串行化。
@MainActor
final class HealthKitSyncCoordinator {
    static let shared = HealthKitSyncCoordinator()
    static let automaticSyncEnabledKey = "healthKitAutomaticSyncEnabled"

    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private var container: ModelContainer?
    private var isSyncing = false
    private var needsAnotherSync = false

    private init() {}

    func restoreIfEnabled(container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: Self.automaticSyncEnabledKey),
              HKHealthStore.isHealthDataAvailable() else { return }
        activate(container: container)
    }

    func activate(container: ModelContainer) {
        self.container = container
        startObserversIfNeeded()
        Task { await enableBackgroundDelivery() }
        Task { _ = await synchronize(forceFull: false, forcePendingRetry: false) }
    }

    func synchronizeManually(container: ModelContainer,
                             enableAutomaticSync: Bool,
                             progress: @escaping @Sendable (String) -> Void) async -> Int {
        self.container = container
        if enableAutomaticSync { await enableBackgroundDelivery() }
        while isSyncing {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return 0
            }
        }
        let added = await synchronize(
            forceFull: true, forcePendingRetry: true, progress: progress)
        if enableAutomaticSync { startObserversIfNeeded() }
        return added
    }

    func disableAutomaticSync() async {
        for observer in observers { store.stop(observer) }
        observers.removeAll()
        let types: [HKObjectType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for type in types {
            do {
                try await store.disableBackgroundDelivery(for: type)
            } catch {
                appLog.error("[Health] 关闭后台投递失败: \(error.localizedDescription)")
            }
        }
        HealthKitSyncStatusStore.setEnabled(false)
    }

    @discardableResult
    private func synchronize(forceFull: Bool, forcePendingRetry: Bool,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Int {
        guard let container else { return 0 }
        guard !isSyncing else {
            needsAnotherSync = true
            return 0
        }
        isSyncing = true
        HealthKitSyncStatusStore.markStarted()
        let added: Int
        if forceFull {
            added = await HealthKitService.performFullSync(
                store: store, container: container, progress: progress)
        } else {
            added = await HealthKitService.performIncrementalSync(
                store: store, container: container,
                forcePendingRetry: forcePendingRetry, progress: progress)
        }
        isSyncing = false
        if needsAnotherSync {
            needsAnotherSync = false
            Task { _ = await synchronize(forceFull: false, forcePendingRetry: true) }
        }
        return added
    }

    private func startObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let types: [HKSampleType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                if let error {
                    appLog.error("[Health] Observer失败: \(error.localizedDescription)")
                    Task { @MainActor in
                        HealthKitSyncStatusStore.markFailed(error.localizedDescription)
                    }
                    completion()
                    return
                }
                Task { @MainActor [weak self] in
                    if let self {
                        _ = await self.synchronize(forceFull: false, forcePendingRetry: true)
                    }
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
        }
    }

    private func enableBackgroundDelivery() async {
        let types: [HKObjectType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for type in types {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
            } catch {
                // 模拟器和部分数据类型可能拒绝后台投递；前台增量同步仍然可用。
                appLog.error("[Health] 后台投递启用失败: \(error.localizedDescription)")
            }
        }
    }
}
