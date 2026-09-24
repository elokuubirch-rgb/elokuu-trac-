import Foundation

public enum RoadMatchStatus: String, Codable, Equatable, Sendable {
    case matched
    case ambiguous
    case unmatched
}

public enum RoadMatchFailureReason: String, Codable, Equatable, Sendable {
    case insufficientPoints
    case invalidGeometry
    case excessiveDisplacement
    case excessiveDetour
    case reversedPointOrder
    case implausibleSpeed
    case providerUnavailable
}

public struct RoadGeometryCoordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct RoadPointAttachment: Codable, Equatable, Sendable {
    public let pointID: String
    public let coordinate: RoadGeometryCoordinate
    public let displacementMeters: Double

    public init(pointID: String, coordinate: RoadGeometryCoordinate,
                displacementMeters: Double) {
        self.pointID = pointID
        self.coordinate = coordinate
        self.displacementMeters = displacementMeters
    }
}

/// 可删除、可重建的显示派生数据。测量坐标、时间与统计数据仍以 TrajectoryPoint 为准。
public struct RoadMatchedSegment: Codable, Equatable, Sendable {
    public let sourceSegmentID: String
    public let status: RoadMatchStatus
    public let geometry: [RoadGeometryCoordinate]
    public let attachments: [RoadPointAttachment]
    public let failureReason: RoadMatchFailureReason?
    public let algorithmVersion: Int

    public init(sourceSegmentID: String, status: RoadMatchStatus,
                geometry: [RoadGeometryCoordinate],
                attachments: [RoadPointAttachment],
                failureReason: RoadMatchFailureReason? = nil,
                algorithmVersion: Int) {
        self.sourceSegmentID = sourceSegmentID
        self.status = status
        self.geometry = geometry
        self.attachments = attachments
        self.failureReason = failureReason
        self.algorithmVersion = algorithmVersion
    }

    public var usesRoadGeometry: Bool {
        status == .matched && geometry.count >= 2
    }
}

public struct RoadMatchedDisplayGeometry: Equatable, Sendable {
    public let line: [RoadGeometryCoordinate]
    public let pointCoordinates: [String: RoadGeometryCoordinate]
    public let usesRoadGeometry: Bool

    public init(line: [RoadGeometryCoordinate],
                pointCoordinates: [String: RoadGeometryCoordinate],
                usesRoadGeometry: Bool) {
        self.line = line
        self.pointCoordinates = pointCoordinates
        self.usesRoadGeometry = usesRoadGeometry
    }

    /// 点和线在同一次解析中选择 matched 或 raw，防止点在线外。
    public static func resolve(segment: TrajectorySegment,
                               matched: RoadMatchedSegment?)
        -> RoadMatchedDisplayGeometry {
        let rawLine = segment.points.map {
            RoadGeometryCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let rawPoints = Dictionary(uniqueKeysWithValues: zip(
            segment.points.map(\.id), rawLine))
        guard let matched, matched.sourceSegmentID == segment.id,
              matched.usesRoadGeometry,
              matched.attachments.count == segment.points.count else {
            return RoadMatchedDisplayGeometry(
                line: rawLine, pointCoordinates: rawPoints,
                usesRoadGeometry: false)
        }
        let attached = Dictionary(uniqueKeysWithValues: matched.attachments.map {
            ($0.pointID, $0.coordinate)
        })
        guard Set(attached.keys) == Set(rawPoints.keys) else {
            return RoadMatchedDisplayGeometry(
                line: rawLine, pointCoordinates: rawPoints,
                usesRoadGeometry: false)
        }
        return RoadMatchedDisplayGeometry(
            line: matched.geometry, pointCoordinates: attached,
            usesRoadGeometry: true)
    }
}

public struct RoadMatchPolicy: Equatable, Sendable {
    public static let standard = RoadMatchPolicy(
        maximumPointDisplacementMeters: 45,
        maximumMedianDisplacementMeters: 25,
        maximumDetourRatio: 2.25,
        minimumAttachedPointRatio: 1)

    public let maximumPointDisplacementMeters: Double
    public let maximumMedianDisplacementMeters: Double
    public let maximumDetourRatio: Double
    public let minimumAttachedPointRatio: Double

    public init(maximumPointDisplacementMeters: Double,
                maximumMedianDisplacementMeters: Double,
                maximumDetourRatio: Double,
                minimumAttachedPointRatio: Double) {
        self.maximumPointDisplacementMeters = maximumPointDisplacementMeters
        self.maximumMedianDisplacementMeters = maximumMedianDisplacementMeters
        self.maximumDetourRatio = maximumDetourRatio
        self.minimumAttachedPointRatio = minimumAttachedPointRatio
    }
}

public enum RoadMatchValidator {
    public static let algorithmVersion = 2

    public static func validate(segment: TrajectorySegment,
                                geometry: [RoadGeometryCoordinate],
                                policy: RoadMatchPolicy = .standard)
        -> RoadMatchedSegment {
        guard segment.points.count >= 2, geometry.count >= 2,
              geometry.allSatisfy({
                  GeoMath.isValid(latitude: $0.latitude, longitude: $0.longitude)
              }) else {
            return rejected(segment: segment, reason: segment.points.count < 2
                ? .insufficientPoints : .invalidGeometry)
        }

        let projected = segment.points.map { point in
            let nearest = nearestCoordinate(
                to: RoadGeometryCoordinate(latitude: point.latitude,
                                           longitude: point.longitude),
                on: geometry)
            return (attachment: RoadPointAttachment(
                pointID: point.id, coordinate: nearest.coordinate,
                displacementMeters: nearest.distance),
                progress: nearest.progress)
        }
        let attachments = projected.map(\.attachment)
        let accepted = attachments.filter {
            $0.displacementMeters <= policy.maximumPointDisplacementMeters
        }
        let ratio = Double(accepted.count) / Double(attachments.count)
        let sortedDisplacements = attachments.map(\.displacementMeters).sorted()
        let median = sortedDisplacements[sortedDisplacements.count / 2]
        guard ratio >= policy.minimumAttachedPointRatio,
              median <= policy.maximumMedianDisplacementMeters else {
            return rejected(segment: segment, reason: .excessiveDisplacement,
                            attachments: attachments)
        }
        for pair in zip(projected, projected.dropFirst())
            where pair.1.progress + 10 < pair.0.progress {
            return rejected(segment: segment, reason: .reversedPointOrder,
                            attachments: attachments)
        }

        let measuredLength = polylineLength(segment.points.map {
            RoadGeometryCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        })
        let roadLength = polylineLength(geometry)
        guard measuredLength > 0,
              roadLength / measuredLength <= policy.maximumDetourRatio else {
            return rejected(segment: segment, reason: .excessiveDetour,
                            attachments: attachments)
        }
        return RoadMatchedSegment(
            sourceSegmentID: segment.id, status: .matched,
            geometry: geometry, attachments: attachments,
            algorithmVersion: algorithmVersion)
    }

    public static func providerUnavailable(segment: TrajectorySegment)
        -> RoadMatchedSegment {
        rejected(segment: segment, reason: .providerUnavailable)
    }

    private static func rejected(segment: TrajectorySegment,
                                 reason: RoadMatchFailureReason,
                                 attachments: [RoadPointAttachment] = [])
        -> RoadMatchedSegment {
        RoadMatchedSegment(
            sourceSegmentID: segment.id, status: .unmatched,
            geometry: [], attachments: attachments, failureReason: reason,
            algorithmVersion: algorithmVersion)
    }

    private static func nearestCoordinate(
        to point: RoadGeometryCoordinate,
        on geometry: [RoadGeometryCoordinate]
    ) -> (coordinate: RoadGeometryCoordinate, distance: Double,
          progress: Double) {
        var best = geometry[0]
        var bestDistance = Double.infinity
        var bestProgress = 0.0
        var progress = 0.0
        for (start, end) in zip(geometry, geometry.dropFirst()) {
            let candidate = projection(of: point, onto: start, end)
            let distance = GeoMath.distanceMeters(
                from: (point.latitude, point.longitude),
                to: (candidate.latitude, candidate.longitude))
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
                bestProgress = progress + GeoMath.distanceMeters(
                    from: (start.latitude, start.longitude),
                    to: (candidate.latitude, candidate.longitude))
            }
            progress += GeoMath.distanceMeters(
                from: (start.latitude, start.longitude),
                to: (end.latitude, end.longitude))
        }
        return (best, bestDistance, bestProgress)
    }

    private static func projection(of point: RoadGeometryCoordinate,
                                   onto start: RoadGeometryCoordinate,
                                   _ end: RoadGeometryCoordinate)
        -> RoadGeometryCoordinate {
        let latitudeScale = 111_000.0
        let longitudeScale = latitudeScale
            * cos((start.latitude + end.latitude) * .pi / 360)
        let px = (point.longitude - start.longitude) * longitudeScale
        let py = (point.latitude - start.latitude) * latitudeScale
        let ex = (end.longitude - start.longitude) * longitudeScale
        let ey = (end.latitude - start.latitude) * latitudeScale
        let lengthSquared = ex * ex + ey * ey
        guard lengthSquared > 0 else { return start }
        let t = min(1, max(0, (px * ex + py * ey) / lengthSquared))
        return RoadGeometryCoordinate(
            latitude: start.latitude + (end.latitude - start.latitude) * t,
            longitude: start.longitude + (end.longitude - start.longitude) * t)
    }

    private static func polylineLength(_ coordinates: [RoadGeometryCoordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { partial, pair in
            partial + GeoMath.distanceMeters(
                from: (pair.0.latitude, pair.0.longitude),
                to: (pair.1.latitude, pair.1.longitude))
        }
    }
}
