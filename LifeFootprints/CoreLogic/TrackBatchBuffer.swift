import Foundation

/// Pure queue state. Times are monotonic uptime, not wall-clock dates.
/// The caller serializes access and executes at most the one reserved batch.
public struct TrackBatchBuffer: Sendable {
    public struct Configuration: Sendable {
        public let batchSize: Int
        public let maximumWait: TimeInterval
        public let retryInitialDelay: TimeInterval
        public let retryMaximumDelay: TimeInterval

        public init(batchSize: Int = 20, maximumWait: TimeInterval = 60,
                    retryInitialDelay: TimeInterval = 2,
                    retryMaximumDelay: TimeInterval = 60) {
            self.batchSize = max(1, batchSize)
            self.maximumWait = maximumWait.isFinite ? max(0, maximumWait) : 60
            let initial = retryInitialDelay.isFinite ? max(0.01, retryInitialDelay) : 2
            self.retryInitialDelay = initial
            self.retryMaximumDelay = retryMaximumDelay.isFinite
                ? max(initial, retryMaximumDelay) : max(initial, 60)
        }
    }

    public struct Batch: Equatable, Sendable {
        public let id: UUID
        public let generation: UInt64
        public let drafts: [FootprintDraft]
    }

    private struct Entry: Sendable {
        let draft: FootprintDraft
        let enqueuedAt: TimeInterval
    }

    public var configuration: Configuration
    public private(set) var inFlight: Batch?
    public private(set) var isResetting = false
    private var generation: UInt64 = 0
    private var entries: [Entry] = []
    private var retryBatch: Batch?
    private var retryAt: TimeInterval?
    private var retryDelay: TimeInterval?
    private var flushRequested = false

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Waiting points only; the reserved batch is tracked separately.
    public var pendingCount: Int { entries.count + (retryBatch?.drafts.count ?? 0) }

    @discardableResult
    public mutating func append(_ draft: FootprintDraft, at time: TimeInterval) -> Bool {
        guard !isResetting else { return false }
        entries.append(Entry(draft: draft, enqueuedAt: time))
        return true
    }

    public mutating func requestFlush() {
        if pendingCount > 0 { flushRequested = true }
    }

    public var nextAttemptTime: TimeInterval? {
        guard !isResetting, inFlight == nil else { return nil }
        if retryBatch != nil { return retryAt }
        guard let first = entries.first else { return nil }
        if flushRequested || entries.count >= configuration.batchSize { return first.enqueuedAt }
        return first.enqueuedAt + configuration.maximumWait
    }

    public mutating func beginBatch(at time: TimeInterval) -> Batch? {
        guard let deadline = nextAttemptTime, time >= deadline else { return nil }
        let batch: Batch
        if let retryBatch {
            batch = retryBatch
            self.retryBatch = nil
            retryAt = nil
        } else {
            let count = min(entries.count, configuration.batchSize)
            batch = Batch(id: UUID(), generation: generation,
                          drafts: entries.prefix(count).map(\.draft))
            entries.removeFirst(count)
        }
        inFlight = batch
        if pendingCount == 0 { flushRequested = false }
        return batch
    }

    public mutating func complete(batchID: UUID, succeeded: Bool, at time: TimeInterval) {
        guard let batch = inFlight, batch.id == batchID else { return }
        inFlight = nil
        // A reset/discard invalidates the old write's right to re-enter the queue.
        guard batch.generation == generation, !isResetting else { return }
        if succeeded {
            retryDelay = nil
        } else {
            let delay = min(configuration.retryMaximumDelay,
                            retryDelay.map { $0 * 2 } ?? configuration.retryInitialDelay)
            retryDelay = delay
            retryBatch = batch
            retryAt = time + delay
        }
    }

    public mutating func discardPending() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
        retryBatch = nil
        retryAt = nil
        retryDelay = nil
        flushRequested = false
    }

    public mutating func beginReset() {
        discardPending()
        isResetting = true
    }

    @discardableResult
    public mutating func finishResetIfIdle() -> Bool {
        guard isResetting, inFlight == nil else { return false }
        isResetting = false
        return true
    }
}
