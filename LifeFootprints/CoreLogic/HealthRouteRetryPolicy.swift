import Foundation

/// 延迟到达的 Workout Route 重试策略。状态使用持久化 rawValue，避免核心逻辑依赖 SwiftData。
public enum HealthRouteRetryPolicy {
    public static let initialDelay: TimeInterval = 5 * 60
    public static let maximumDelay: TimeInterval = 24 * 60 * 60

    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = min(attempt - 1, 16)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }

    public static func shouldRetry(stateRaw: String?, retryCount: Int?,
                                   lastCheckedAt: Date?, now: Date = Date()) -> Bool {
        let state = stateRaw ?? "unknown"
        guard state == "unknown" || state == "pending" || state == "failed" else {
            return false
        }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= delay(afterAttempt: retryCount ?? 0)
    }
}
