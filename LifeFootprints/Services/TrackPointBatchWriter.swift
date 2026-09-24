import Foundation
import SwiftData

/// Serial, bounded batches with an oldest-point deadline and autonomous retry.
/// Pending points are memory-only; this does not provide crash recovery.
final class TrackPointBatchWriter: @unchecked Sendable {
    static let shared = TrackPointBatchWriter()
    typealias Persistence = @Sendable ([FootprintDraft], ModelContainer) async -> Bool
    private typealias Work = (batch: TrackBatchBuffer.Batch, container: ModelContainer)

    private let lock = NSLock()
    private let persist: Persistence
    private var buffer = TrackBatchBuffer()
    private var container: ModelContainer?
    private var timer: DispatchWorkItem?
    private var timerGeneration: UInt64 = 0
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []

    // Internal injection keeps tests off the shared writer and real user stores.
    init(persist: @escaping Persistence = { drafts, container in
        await FootprintStore.persistTrackBatch(drafts, container: container)
    }) {
        self.persist = persist
    }

    func configure(container: ModelContainer,
                   configuration: LocationFilterConfiguration = .init(),
                   retryInitialDelay: TimeInterval = 2,
                   retryMaximumDelay: TimeInterval = 60) {
        let work = lock.withLock {
            self.container = container
            buffer.configuration = .init(
                batchSize: configuration.batchSize,
                maximumWait: configuration.batchMaxDuration,
                retryInitialDelay: retryInitialDelay,
                retryMaximumDelay: retryMaximumDelay)
            return prepareWorkLocked()
        }
        start(work, reason: "configure")
    }

    func append(_ draft: FootprintDraft) {
        let work = lock.withLock {
            buffer.append(draft, at: ProcessInfo.processInfo.systemUptime)
            return prepareWorkLocked()
        }
        start(work, reason: "count")
    }

    func flush(reason: String) {
        let work = lock.withLock {
            buffer.requestFlush()
            return prepareWorkLocked()
        }
        start(work, reason: reason)
    }

    func discardPending() {
        lock.withLock {
            buffer.discardPending()
            cancelTimerLocked()
        }
    }

    /// Reject new points during the barrier; stale failures cannot resurrect points.
    /// Reserving work and starting the reset share a lock, closing the old enter race.
    func discardPendingAndWait() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock {
                buffer.beginReset()
                cancelTimerLocked()
                if buffer.finishResetIfIdle() { return true }
                resetWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
        timerGeneration &+= 1
    }

    /// Called only under lock. Reserve before launching any asynchronous work.
    private func prepareWorkLocked() -> Work? {
        cancelTimerLocked()
        guard let container else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let batch = buffer.beginBatch(at: now) { return (batch, container) }
        guard let deadline = buffer.nextAttemptTime else { return nil }
        let generation = timerGeneration
        let scheduled = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let work = self.lock.withLock { () -> Work? in
                guard generation == self.timerGeneration else { return nil }
                return self.prepareWorkLocked()
            }
            self.start(work, reason: "deadline/retry")
        }
        timer = scheduled
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, deadline - now), execute: scheduled)
        return nil
    }

    private func start(_ work: Work?, reason: String) {
        guard let work else { return }
        // Strong ownership lasts until completion so reset waiters always resume.
        Task.detached(priority: .utility) { [self] in
            let saved = await persist(work.batch.drafts, work.container)
            let completion = lock.withLock { () -> (Work?, [CheckedContinuation<Void, Never>], Int) in
                buffer.complete(batchID: work.batch.id, succeeded: saved,
                                at: ProcessInfo.processInfo.systemUptime)
                var waiters: [CheckedContinuation<Void, Never>] = []
                if buffer.finishResetIfIdle() {
                    waiters = resetWaiters
                    resetWaiters.removeAll()
                }
                return (prepareWorkLocked(), waiters, buffer.pendingCount)
            }
            for waiter in completion.1 { waiter.resume() }
            if saved {
                appLog.info("[TrackBatch] \(reason) 已保存 \(work.batch.drafts.count) 点")
            } else {
                appLog.error("[TrackBatch] \(reason) 保存失败，待重试 \(completion.2) 点")
            }
            start(completion.0, reason: "drain/retry")
        }
    }

    #if DEBUG
    var pendingCount: Int { lock.withLock { buffer.pendingCount } }
    var isResetting: Bool { lock.withLock { buffer.isResetting } }
    #endif
}
