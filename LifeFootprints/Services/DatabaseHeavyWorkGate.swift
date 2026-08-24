import Foundation

/// 串行化会大量读取 SwiftData 的工作。调用方必须在后台线程进入，避免主线程等待。
enum DatabaseHeavyWorkGate {
    private static let lock = NSLock()

    static func withExclusiveAccess<T>(_ label: String, _ operation: () throws -> T) rethrows -> T {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        PerformanceDiagnostics.recordDuration(
            "DatabaseHeavyWorkGate.wait.\(label)",
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000,
            mainThread: Thread.isMainThread)
        #endif
        return try operation()
    }
}
