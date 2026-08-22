import Foundation

/// 后台低功耗足迹的交通模式。只依赖数值，便于在无 CoreLocation 环境下测试。
public enum BackgroundTravelMode: String, Equatable {
    case local
    case highSpeedRail
    case airborne
}

public struct BackgroundLocationSample: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: TimeInterval
    public let speedMPS: Double
    public let altitude: Double
    public let horizontalAccuracy: Double

    public init(latitude: Double, longitude: Double, timestamp: TimeInterval,
                speedMPS: Double, altitude: Double, horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.speedMPS = speedMPS
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
    }
}

public struct BackgroundTrackDecision: Equatable {
    public let shouldRecord: Bool
    public let mode: BackgroundTravelMode
    public let distanceMeters: Double
}

/// 访问监测负责“停留地点”，重大位置变化负责“移动过程”。
/// 飞机和高铁只保留稀疏关键点，既能还原旅程，又避免长途产生大量点和频繁唤醒。
public enum BackgroundTrackPolicy {
    public static func evaluate(previous: BackgroundLocationSample?,
                                current: BackgroundLocationSample) -> BackgroundTrackDecision {
        guard GeoMath.isValid(latitude: current.latitude, longitude: current.longitude),
              current.horizontalAccuracy >= 0,
              current.horizontalAccuracy <= 1_000 else {
            return BackgroundTrackDecision(shouldRecord: false, mode: .local, distanceMeters: 0)
        }

        guard let previous else {
            return BackgroundTrackDecision(shouldRecord: current.horizontalAccuracy <= 300,
                                           mode: mode(speed: max(current.speedMPS, 0),
                                                      altitude: current.altitude),
                                           distanceMeters: 0)
        }

        let elapsed = current.timestamp - previous.timestamp
        guard elapsed > 0 else {
            return BackgroundTrackDecision(shouldRecord: false, mode: .local, distanceMeters: 0)
        }
        let distance = GeoMath.distanceMeters(
            from: (previous.latitude, previous.longitude),
            to: (current.latitude, current.longitude))
        let calculatedSpeed = distance / elapsed
        let speed = max(current.speedMPS >= 0 ? current.speedMPS : 0, calculatedSpeed)
        let travelMode = mode(speed: speed, altitude: current.altitude)

        let shouldRecord: Bool
        switch travelMode {
        case .airborne:
            // 巡航阶段约每 30km 或 15 分钟一个关键点。
            shouldRecord = distance >= 30_000 || elapsed >= 15 * 60
        case .highSpeedRail:
            // 高铁/快速交通约每 5km 或 4 分钟一个关键点。
            shouldRecord = distance >= 5_000 || elapsed >= 4 * 60
        case .local:
            // 与系统重大位置变化服务的约 500m 粒度一致。
            shouldRecord = distance >= 450 || elapsed >= 30 * 60
        }
        return BackgroundTrackDecision(shouldRecord: shouldRecord,
                                       mode: travelMode,
                                       distanceMeters: distance)
    }

    private static func mode(speed: Double, altitude: Double) -> BackgroundTravelMode {
        // 无需依赖气压计：高速 + 明显离地高度，或极速本身即可识别飞行阶段。
        if speed >= 83 || (speed >= 55 && altitude >= 1_500) { return .airborne }
        if speed >= 22 { return .highSpeedRail }
        return .local
    }
}
