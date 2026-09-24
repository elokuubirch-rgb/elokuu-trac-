import Foundation

/// A token is captured before scanning/parsing, not when the resulting data arrives.
/// Reset invalidates queued/preparing work and waits only for active storage work.
final class LocalImportCoordinator: @unchecked Sendable {
    static let shared = LocalImportCoordinator()
    struct Token: Equatable, Sendable { fileprivate let generation: UUID }
    enum Failure: Error { case resetInProgress, invalidated }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "trace.local-imports", qos: .userInitiated)
    private var generation = UUID()
    private var resetting = false
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func capture() -> Token? {
        lock.withLock { resetting ? nil : Token(generation: generation) }
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.withLock { !resetting && token.generation == generation }
    }

    func run<T: Sendable>(token: Token,
                         _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let allowed = lock.withLock {
                    guard !resetting, token.generation == generation else { return false }
                    active += 1
                    return true
                }
                guard allowed else {
                    continuation.resume(throwing: Failure.invalidated)
                    return
                }
                // Storage and its revision publication finish before releasing the barrier.
                let result = Result { try operation() }
                let completed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    active -= 1
                    guard active == 0 else { return [] }
                    let result = waiters
                    waiters.removeAll()
                    return result
                }
                for waiter in completed { waiter.resume() }
                continuation.resume(with: result)
            }
        }
    }

    /// Synchronous reservation prevents new operations during producer shutdown.
    func beginReset() throws -> Token {
        try lock.withLock {
            guard !resetting else { throw Failure.resetInProgress }
            resetting = true
            generation = UUID()
            return Token(generation: generation)
        }
    }

    func waitForActiveWrites() async {
        await withCheckedContinuation { continuation in
            let idle = lock.withLock {
                if active == 0 { return true }
                waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    func finishReset(_ token: Token) {
        lock.withLock {
            guard token.generation == generation, active == 0 else { return }
            resetting = false
        }
    }
}
