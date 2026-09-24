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
    private var didYieldToMapStartup = false
    /// Retain the launch task for its entire lifetime. Creating two fire-and-forget
    /// task futures here could let one future be torn down while its HealthKit/
    /// SwiftData continuation was still completing on another executor.
    private var activationTask: Task<Void, Never>?

    private init() {}

    func restoreIfEnabled(container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: Self.automaticSyncEnabledKey),
              HKHealthStore.isHealthDataAvailable() else { return }
        #if DEBUG
        PerformanceDiagnostics.event("HealthKit.restoreIfEnabled")
        #endif
        activate(container: container)
    }

    func activate(container: ModelContainer) {
        self.container = container
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            // HKObserverQuery may invoke its update handler immediately when it is
            // executed. Registering observers before this initial sync therefore
            // creates two competing startup sync tasks. Finish the owned startup
            // sync first, then install the long-lived observers.
            await self.enableBackgroundDelivery()
            guard !Task.isCancelled else { return }
            _ = await self.synchronize(forceFull: false, forcePendingRetry: false)
            guard !Task.isCancelled else { return }
            self.startObserversIfNeeded()
        }
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
        activationTask?.cancel()
        activationTask = nil
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

    /// 完整清理前等待正在进行的本地同步收尾，避免 Reset 后旧任务再次写回模型。
    func prepareForLocalDataReset() async {
        await disableAutomaticSync()
        while isSyncing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        needsAnotherSync = false
        container = nil
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
        // Observer registration remains immediate. Give the launch preview a
        // bounded head start before automatic maintenance starts using the store.
        // Background-only launches have no map and resume after three seconds.
        if !forceFull, !didYieldToMapStartup {
            didYieldToMapStartup = true
            for _ in 0..<30 {
                let milestones = MapStartupDiagnostics.shared.snapshot()
                if milestones[MapStartupMilestone.cachedContentReady.rawValue] != nil
                    || milestones[MapStartupMilestone.visibleRegionFresh.rawValue] != nil { break }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { isSyncing = false; return 0 }
            }
        }
        #if DEBUG
        PerformanceDiagnostics.event("HealthKit.sync.start",
                                     metadata: forceFull ? "full" : "incremental")
        #endif
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
        #if DEBUG
        PerformanceDiagnostics.event("HealthKit.sync.finish", metadata: "added=\(added)")
        #endif
        if needsAnotherSync {
            needsAnotherSync = false
            // Observer 在启动时可能由 Workout 与 Route 两个类型连续回调。
            // 后续合并同步必须遵守持久退避时间；否则同一批 pending Workout
            // 会在一次启动内被强制重试多轮，放大 HealthKit 查询与 SwiftData 写入。
            Task { _ = await synchronize(forceFull: false, forcePendingRetry: false) }
        }
        return added
    }

    private func startObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let types: [HKSampleType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                #if DEBUG
                PerformanceDiagnostics.event("HealthKit.observer.callback",
                                             metadata: String(describing: type))
                #endif
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
                        _ = await self.synchronize(forceFull: false, forcePendingRetry: false)
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
