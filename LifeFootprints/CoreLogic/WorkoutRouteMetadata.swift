import Foundation

public struct WorkoutRouteRawPoint: Equatable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date

    public init(id: String, latitude: Double, longitude: Double, timestamp: Date) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}

public struct WorkoutRoutePointOrder: Equatable, Sendable {
    public let id: String
    public let segmentIndex: Int
    public let pointIndex: Int
}

/// HKWorkoutRouteQuery 的回调 chunk 先整体按时间排序；只有真实时间/距离断层才产生 Segment。
public enum WorkoutRouteMetadata {
    public static func assign(_ points: [WorkoutRouteRawPoint],
                              maximumTimeGap: TimeInterval = 45 * 60,
                              maximumDistanceGapMeters: Double = 3_000) -> [WorkoutRoutePointOrder] {
        let ordered = points.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        var result: [WorkoutRoutePointOrder] = []
        var segmentIndex = 0
        var pointIndex = 0
        var previous: WorkoutRouteRawPoint?
        for point in ordered {
            if let previous {
                let timeGap = point.timestamp.timeIntervalSince(previous.timestamp)
                let distance = GeoMath.distanceMeters(
                    from: (previous.latitude, previous.longitude),
                    to: (point.latitude, point.longitude))
                if timeGap > maximumTimeGap || distance > maximumDistanceGapMeters {
                    segmentIndex += 1
                    pointIndex = 0
                }
            }
            result.append(WorkoutRoutePointOrder(id: point.id, segmentIndex: segmentIndex,
                                                 pointIndex: pointIndex))
            pointIndex += 1
            previous = point
        }
        return result
    }
}
