#if DEBUG
import Foundation
import QuartzCore
import os

/// 只在 FP_PERF_DIAGNOSTICS=1 时启用。记录 signpost 与内存聚合，
/// 不参与任何产品状态、数据筛选或渲染决策。
enum PerformanceDiagnostics {
    static let reportFilename = "performance_audit.json"

    static let isEnabled = ProcessInfo.processInfo.environment["FP_PERF_DIAGNOSTICS"] == "1"
    private static let log = OSLog(
        subsystem: "com.footprints.LifeFootprints",
        category: "PerformanceAudit")
    private static let storage = PerformanceDiagnosticsStorage()

    static func event(_ name: String, metadata: String = "") {
        guard isEnabled else { return }
        os_signpost(.event, log: log, name: "PERF_EVENT", "%{public}s|%{public}s",
                    name, metadata)
        storage.recordEvent(name: name, mainThread: Thread.isMainThread)
    }

    static func count(_ name: String, by amount: Int = 1) {
        guard isEnabled else { return }
        storage.recordCount(name: name, amount: amount)
    }

    @discardableResult
    static func measure<T>(_ name: String, metadata: String = "",
                           _ operation: () throws -> T) rethrows -> T {
        guard isEnabled else { return try operation() }
        let started = CACurrentMediaTime()
        let beganOnMain = Thread.isMainThread
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "PERF_INTERVAL", signpostID: signpostID,
                    "%{public}s|%{public}s", name, metadata)
        defer {
            let milliseconds = (CACurrentMediaTime() - started) * 1_000
            os_signpost(.end, log: log, name: "PERF_INTERVAL", signpostID: signpostID,
                        "%{public}s|%.3fms", name, milliseconds)
            storage.recordDuration(name: name, milliseconds: milliseconds,
                                   mainThread: beganOnMain)
        }
        return try operation()
    }

    @discardableResult
    static func measureAsync<T>(_ name: String, metadata: String = "",
                                _ operation: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await operation() }
        let started = CACurrentMediaTime()
        // async 区间可能跨 executor / 线程，不能归入连续主线程阻塞。
        let beganOnMain = false
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "PERF_INTERVAL", signpostID: signpostID,
                    "%{public}s|%{public}s", name, metadata)
        defer {
            let milliseconds = (CACurrentMediaTime() - started) * 1_000
            os_signpost(.end, log: log, name: "PERF_INTERVAL", signpostID: signpostID,
                        "%{public}s|%.3fms", name, milliseconds)
            storage.recordDuration(name: name, milliseconds: milliseconds,
                                   mainThread: beganOnMain)
        }
        return try await operation()
    }

    static func recordDuration(_ name: String, milliseconds: Double,
                               mainThread: Bool = false) {
        guard isEnabled else { return }
        storage.recordDuration(name: name, milliseconds: milliseconds,
                               mainThread: mainThread)
    }

    static func tabSelectionChanged(from: Int, to: Int) {
        guard isEnabled else { return }
        event("TAB_SELECTION_CHANGED", metadata: "\(from)->\(to)")
        storage.beginTabTransition(from: from, to: to)
    }

    /// 下一次主队列提交点；与 Core Animation Hitches trace 配合判断真正首帧。
    static func tabFirstFrameCommitted(tab: Int) {
        guard isEnabled else { return }
        storage.endTabTransition(to: tab)
    }

    static func beginTransition(_ name: String) {
        guard isEnabled else { return }
        event("NAVIGATION_BEGIN", metadata: name)
        storage.beginTransition(name)
    }

    static func endTransition(_ name: String) {
        guard isEnabled else { return }
        event("NAVIGATION_END", metadata: name)
        storage.endTransition(name)
    }

    static func flush() {
        guard isEnabled else { return }
        storage.flush()
    }
}

private final class PerformanceDiagnosticsStorage: @unchecked Sendable {
    private struct Metric: Codable {
        var calls = 0
        var totalMilliseconds = 0.0
        var maximumMilliseconds = 0.0
        var mainThreadCalls = 0
        var mainThreadMilliseconds = 0.0
    }

    private struct EventMetric: Codable {
        var calls = 0
        var mainThreadCalls = 0
    }

    private struct Report: Codable {
        let generatedAt: Date
        let processIdentifier: Int32
        let systemVersion: String
        let metrics: [String: Metric]
        let events: [String: EventMetric]
        let counters: [String: Int]
    }

    private let lock = NSLock()
    private let flushQueue = DispatchQueue(label: "performance-audit.flush", qos: .utility)
    private var metrics: [String: Metric] = [:]
    private var events: [String: EventMetric] = [:]
    private var counters: [String: Int] = [:]
    private var tabTransition: (from: Int, to: Int, started: CFTimeInterval)?
    private var transitions: [String: CFTimeInterval] = [:]
    private var pendingFlush: DispatchWorkItem?

    func recordEvent(name: String, mainThread: Bool) {
        lock.withLock {
            var value = events[name] ?? EventMetric()
            value.calls += 1
            if mainThread { value.mainThreadCalls += 1 }
            events[name] = value
            scheduleFlushLocked()
        }
    }

    func recordCount(name: String, amount: Int) {
        lock.withLock {
            counters[name, default: 0] += amount
            scheduleFlushLocked()
        }
    }

    func recordDuration(name: String, milliseconds: Double, mainThread: Bool) {
        lock.withLock {
            var value = metrics[name] ?? Metric()
            value.calls += 1
            value.totalMilliseconds += milliseconds
            value.maximumMilliseconds = max(value.maximumMilliseconds, milliseconds)
            if mainThread {
                value.mainThreadCalls += 1
                value.mainThreadMilliseconds += milliseconds
            }
            metrics[name] = value
            scheduleFlushLocked()
        }
    }

    func beginTabTransition(from: Int, to: Int) {
        lock.withLock {
            tabTransition = (from, to, CACurrentMediaTime())
            scheduleFlushLocked()
        }
    }

    func endTabTransition(to: Int) {
        let finished: (name: String, duration: Double)? = lock.withLock {
            guard let transition = tabTransition, transition.to == to else { return nil }
            tabTransition = nil
            return ("TAB_TO_FIRST_FRAME.\(transition.from)->\(transition.to)",
                    (CACurrentMediaTime() - transition.started) * 1_000)
        }
        if let finished {
            recordDuration(name: finished.name, milliseconds: finished.duration,
                           mainThread: true)
        }
    }

    func beginTransition(_ name: String) {
        lock.withLock {
            transitions[name] = CACurrentMediaTime()
            scheduleFlushLocked()
        }
    }

    func endTransition(_ name: String) {
        let duration: Double? = lock.withLock {
            guard let started = transitions.removeValue(forKey: name) else { return nil }
            return (CACurrentMediaTime() - started) * 1_000
        }
        if let duration {
            recordDuration(name: "NAVIGATION.\(name)", milliseconds: duration,
                           mainThread: true)
        }
    }

    func flush() {
        let report = lock.withLock {
            Report(generatedAt: Date(), processIdentifier: ProcessInfo.processInfo.processIdentifier,
                   systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                   metrics: metrics, events: events, counters: counters)
        }
        guard let data = try? JSONEncoder.performanceAudit.encode(report) else { return }
        let directory = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)[0]
        try? data.write(to: directory.appendingPathComponent(
            PerformanceDiagnostics.reportFilename), options: .atomic)
    }

    private func scheduleFlushLocked() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        flushQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

private extension JSONEncoder {
    static var performanceAudit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
#endif
