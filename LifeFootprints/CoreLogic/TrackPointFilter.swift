import Foundation

/// 主动轨迹记录流水线的拒绝原因。
/// 每一个被拒绝的 GPS 点都必须携带一个原因，便于定位「16 个点」到底卡在哪一层。
public enum TrackRejectionReason: String, CaseIterable {
    case invalidCoordinate
    case invalidTimestamp
    case poorAccuracy
    case stationary
    case duplicate
    case impossibleJump
    case other

    /// 诊断摘要里对外展示的归类名（invalidCoordinate / invalidTimestamp / other 统一归入 Other）。
    public var summaryCategory: String {
        switch self {
        case .poorAccuracy: return "Poor accuracy"
        case .stationary: return "Stationary"
        case .duplicate: return "Duplicate"
        case .impossibleJump: return "Impossible jump"
        case .invalidCoordinate, .invalidTimestamp, .other: return "Other"
        }
    }
}

/// 一条被拒绝点的明细（用于诊断日志；值类型，无 CoreLocation 依赖）。
public struct TrackRejectionRecord: Equatable {
    public let reason: TrackRejectionReason
    public let timestamp: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let distanceToLastMeters: Double

    public init(reason: TrackRejectionReason, timestamp: TimeInterval,
                latitude: Double, longitude: Double,
                horizontalAccuracy: Double, distanceToLastMeters: Double) {
        self.reason = reason
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.distanceToLastMeters = distanceToLastMeters
    }
}

/// 过滤流水线的输入：一次原始 GPS 回调（CLLocation 的纯值投影）。
public struct TrackSample: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: TimeInterval   // Unix 秒
    public let speedMPS: Double          // 设备报告速度；<0 视为无效
    public let course: Double            // 朝向（度）；<0 视为无效
    public let horizontalAccuracy: Double // 精度（米）；<0 视为无效

    public init(latitude: Double, longitude: Double, timestamp: TimeInterval,
                speedMPS: Double, course: Double, horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.speedMPS = speedMPS
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// 一次过滤决策。
public struct TrackFilterDecision: Equatable {
    public let accept: Bool
    public let reason: TrackRejectionReason?
    public let distanceMeters: Double
    public let elapsedSeconds: Double
    public let headingChangeDegrees: Double
    public let speedMPS: Double

    public init(accept: Bool, reason: TrackRejectionReason?,
                distanceMeters: Double, elapsedSeconds: Double,
                headingChangeDegrees: Double, speedMPS: Double) {
        self.accept = accept
        self.reason = reason
        self.distanceMeters = distanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.headingChangeDegrees = headingChangeDegrees
        self.speedMPS = speedMPS
    }
}

/// 主动轨迹点的联合决策过滤器（距离 + 时间 + 速度 + 方向变化 + GPS 精度）。
///
/// 不是简单的 `distance >= X`：步行约 3–8m 产生一个点，同时提供
/// 时间兜底与转向兜底，避免慢速/原地踱步时长期不落点。
public struct TrackPointFilter {

    public struct Config: Equatable {
        // 距离触发：步行 3–8m 的目标区间
        public var minDistanceMeters: Double = 3
        // 时间兜底：即使未到 minDistance，合理时间 + 可信位移也落点
        public var timeFallbackSeconds: Double = 8
        public var fallbackMinDistanceMeters: Double = 1.5
        public var fallbackMaxAccuracyMeters: Double = 35
        // 转向兜底：明显转向即使短距也落点（还原路口/折返）
        public var turnThresholdDegrees: Double = 40
        public var turnMinDistanceMeters: Double = 1.0
        public var turnMaxAccuracyMeters: Double = 50
        // 精度门控：超过即 poorAccuracy（明显漂移/极差精度）
        public var maxAccuracyMeters: Double = 100
        // 真正重复坐标
        public var duplicateDistanceMeters: Double = 1.0
        // 不合理瞬移：位移巨大且速度离谱
        public var maxPlausibleSpeedMPS: Double = 45     // 约 162 km/h
        public var jumpMinDistanceMeters: Double = 100

        public init() {}
    }

    /// 上一个已接受的点（用于距离/时间基准）
    public private(set) var lastAccepted: TrackSample?
    /// 上一个原始点（用于方向变化判断，无论是否被接受）
    private var lastRaw: TrackSample?

    public init() {}

    public mutating func reset() {
        lastAccepted = nil
        lastRaw = nil
    }

    public mutating func evaluate(_ sample: TrackSample,
                                  config: Config = Config()) -> TrackFilterDecision {
        defer { lastRaw = sample }

        let reportedSpeed = sample.speedMPS >= 0 ? sample.speedMPS : 0
        guard GeoMath.isValid(latitude: sample.latitude, longitude: sample.longitude) else {
            return .init(accept: false, reason: .invalidCoordinate,
                         distanceMeters: 0, elapsedSeconds: 0,
                         headingChangeDegrees: 0, speedMPS: reportedSpeed)
        }
        guard sample.horizontalAccuracy >= 0 else {
            return .init(accept: false, reason: .poorAccuracy,
                         distanceMeters: 0, elapsedSeconds: 0,
                         headingChangeDegrees: 0, speedMPS: reportedSpeed)
        }
        guard sample.horizontalAccuracy <= config.maxAccuracyMeters else {
            return .init(accept: false, reason: .poorAccuracy,
                         distanceMeters: 0, elapsedSeconds: 0,
                         headingChangeDegrees: 0, speedMPS: reportedSpeed)
        }

        guard let last = lastAccepted else {
            // 起点：首个精度可接受的点
            lastAccepted = sample
            return .init(accept: true, reason: nil,
                         distanceMeters: 0, elapsedSeconds: 0,
                         headingChangeDegrees: 0, speedMPS: reportedSpeed)
        }

        let distance = GeoMath.distanceMeters(from: (last.latitude, last.longitude),
                                              to: (sample.latitude, sample.longitude))
        let elapsed = sample.timestamp - last.timestamp
        guard elapsed > 0 else {
            return .init(accept: false, reason: .invalidTimestamp,
                         distanceMeters: distance, elapsedSeconds: 0,
                         headingChangeDegrees: 0, speedMPS: reportedSpeed)
        }

        let calcSpeed = distance / elapsed
        let speed = max(reportedSpeed, calcSpeed)
        let heading = headingChange(from: lastRaw, to: sample)

        // 不合理瞬移：位移大且速度离谱（GPS 跳点）
        if calcSpeed > config.maxPlausibleSpeedMPS, distance > config.jumpMinDistanceMeters {
            return .init(accept: false, reason: .impossibleJump,
                         distanceMeters: distance, elapsedSeconds: elapsed,
                         headingChangeDegrees: heading, speedMPS: speed)
        }

        // 真正重复坐标（同一位置反复回调）
        if distance < config.duplicateDistanceMeters {
            return .init(accept: false, reason: .duplicate,
                         distanceMeters: distance, elapsedSeconds: elapsed,
                         headingChangeDegrees: heading, speedMPS: speed)
        }

        // 距离触发（步行 3–8m）
        if distance >= config.minDistanceMeters {
            lastAccepted = sample
            return .init(accept: true, reason: nil,
                         distanceMeters: distance, elapsedSeconds: elapsed,
                         headingChangeDegrees: heading, speedMPS: speed)
        }

        // 转向触发（明显转向且确实发生了有效位移）
        if heading >= config.turnThresholdDegrees,
           distance >= config.turnMinDistanceMeters,
           sample.horizontalAccuracy <= config.turnMaxAccuracyMeters {
            lastAccepted = sample
            return .init(accept: true, reason: nil,
                         distanceMeters: distance, elapsedSeconds: elapsed,
                         headingChangeDegrees: heading, speedMPS: speed)
        }

        // 时间兜底（合理时间 + 可信位移 + 合理精度）
        if elapsed >= config.timeFallbackSeconds,
           distance >= config.fallbackMinDistanceMeters,
           sample.horizontalAccuracy <= config.fallbackMaxAccuracyMeters {
            lastAccepted = sample
            return .init(accept: true, reason: nil,
                         distanceMeters: distance, elapsedSeconds: elapsed,
                         headingChangeDegrees: heading, speedMPS: speed)
        }

        return .init(accept: false, reason: .stationary,
                     distanceMeters: distance, elapsedSeconds: elapsed,
                     headingChangeDegrees: heading, speedMPS: speed)
    }

    private func headingChange(from a: TrackSample?, to b: TrackSample) -> Double {
        guard let a, a.course >= 0, b.course >= 0 else { return 0 }
        let diff = abs(b.course - a.course).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
}
