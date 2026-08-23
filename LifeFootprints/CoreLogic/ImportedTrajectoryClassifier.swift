import Foundation

public enum TrajectorySampleIdentity {
    public static func footprint(source: String, latitude: Double, longitude: Double,
                                 timestamp: Date) -> String {
        let millis = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "footprint:\(source):\(millis):\(latitude.bitPattern):\(longitude.bitPattern)"
    }
}

public struct ImportedTrajectoryConfiguration: Equatable, Sendable {
    public var minimumPointCount: Int
    public var minimumDuration: TimeInterval
    public var minimumDistanceMeters: Double
    public var maximumTimeGap: TimeInterval
    public var maximumDistanceGapMeters: Double

    public init(minimumPointCount: Int = 3, minimumDuration: TimeInterval = 60,
                minimumDistanceMeters: Double = 100,
                maximumTimeGap: TimeInterval = 45 * 60,
                maximumDistanceGapMeters: Double = 3_000) {
        self.minimumPointCount = minimumPointCount
        self.minimumDuration = minimumDuration
        self.minimumDistanceMeters = minimumDistanceMeters
        self.maximumTimeGap = maximumTimeGap
        self.maximumDistanceGapMeters = maximumDistanceGapMeters
    }
}

/// 只把连续移动序列解释为 imported 轨迹；稀疏旅行地点仍是普通 CSV 地点。
public enum ImportedTrajectoryClassifier {
    public static func sessions(
        for samples: [TrajectorySample],
        configuration: ImportedTrajectoryConfiguration = .init()
    ) -> [String: String] {
        let ordered = samples.filter {
            GeoMath.isValid(latitude: $0.latitude, longitude: $0.longitude)
        }.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        var partitions: [[TrajectorySample]] = []
        var current: [TrajectorySample] = []
        for sample in ordered {
            if let previous = current.last {
                let timeGap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let distance = GeoMath.distanceMeters(
                    from: (previous.latitude, previous.longitude),
                    to: (sample.latitude, sample.longitude))
                if timeGap <= 0 || timeGap > configuration.maximumTimeGap
                    || distance > configuration.maximumDistanceGapMeters {
                    if !current.isEmpty { partitions.append(current) }
                    current = []
                }
            }
            current.append(sample)
        }
        if !current.isEmpty { partitions.append(current) }

        var result: [String: String] = [:]
        for points in partitions {
            guard points.count >= configuration.minimumPointCount,
                  let first = points.first, let last = points.last,
                  last.timestamp.timeIntervalSince(first.timestamp) >= configuration.minimumDuration
            else { continue }
            let distance = zip(points, points.dropFirst()).reduce(0.0) { partial, pair in
                partial + GeoMath.distanceMeters(
                    from: (pair.0.latitude, pair.0.longitude),
                    to: (pair.1.latitude, pair.1.longitude))
            }
            guard distance >= configuration.minimumDistanceMeters else { continue }
            let sessionID = "csv:\(Int64((first.timestamp.timeIntervalSince1970 * 1_000).rounded()))"
            for point in points { result[point.id] = sessionID }
        }
        return result
    }
}
