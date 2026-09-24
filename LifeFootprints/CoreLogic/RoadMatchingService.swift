import Foundation

public protocol RoadGeometryProvider: Sendable {
    func roadGeometry(between start: RoadGeometryCoordinate,
                      and end: RoadGeometryCoordinate,
                      activityType: String?) async throws -> [RoadGeometryCoordinate]
}

public enum RoadGeometryProviderError: Error {
    case unavailable
    case noRoute
}

/// 默认不联网。产品选择并授权道路数据提供方后，通过初始化注入实现。
public struct UnavailableRoadGeometryProvider: RoadGeometryProvider {
    public init() {}

    public func roadGeometry(between start: RoadGeometryCoordinate,
                             and end: RoadGeometryCoordinate,
                             activityType: String?) async throws
        -> [RoadGeometryCoordinate] {
        throw RoadGeometryProviderError.unavailable
    }
}

public actor RoadMatchingService {
    public struct Configuration: Equatable, Sendable {
        public static let standard = Configuration(
            minimumAnchorDistanceMeters: 100,
            maximumAnchorInterval: 90,
            maximumRequestsPerSegment: 24,
            maximumSegmentsPerRefresh: 8)

        public let minimumAnchorDistanceMeters: Double
        public let maximumAnchorInterval: TimeInterval
        public let maximumRequestsPerSegment: Int
        public let maximumSegmentsPerRefresh: Int

        public init(minimumAnchorDistanceMeters: Double,
                    maximumAnchorInterval: TimeInterval,
                    maximumRequestsPerSegment: Int,
                    maximumSegmentsPerRefresh: Int) {
            self.minimumAnchorDistanceMeters = minimumAnchorDistanceMeters
            self.maximumAnchorInterval = maximumAnchorInterval
            self.maximumRequestsPerSegment = maximumRequestsPerSegment
            self.maximumSegmentsPerRefresh = maximumSegmentsPerRefresh
        }
    }

    private let provider: any RoadGeometryProvider
    private let configuration: Configuration
    private let policy: RoadMatchPolicy

    public init(provider: any RoadGeometryProvider = UnavailableRoadGeometryProvider(),
                configuration: Configuration = .standard,
                policy: RoadMatchPolicy = .standard) {
        self.provider = provider
        self.configuration = configuration
        self.policy = policy
    }

    public func matchRecent(trajectories: [Trajectory], since: Date)
        async -> [String: RoadMatchedSegment] {
        let eligible = trajectories
            .filter { $0.source == .coreLocation && $0.endTime >= since }
            .flatMap { trajectory in
                trajectory.segments.map { (segment: $0, activityType: trajectory.activityType) }
            }
            .filter { $0.segment.points.count >= 2 }
            .sorted { $0.segment.endTime > $1.segment.endTime }
            .prefix(configuration.maximumSegmentsPerRefresh)
        var result: [String: RoadMatchedSegment] = [:]
        for item in eligible {
            if Task.isCancelled { break }
            result[item.segment.id] = await match(
                segment: item.segment, activityType: item.activityType)
        }
        return result
    }

    /// A gap is only drawn when its road geometry passes the same point and
    /// detour validation as a recorded segment. Activity membership alone is
    /// never enough to create a line.
    public func matchRoadBridges(_ bridges: [ActivityRoadBridge], since: Date)
        async -> [String: RoadMatchedSegment] {
        let candidates = bridges.filter { $0.endTime >= since }
            .sorted { $0.endTime > $1.endTime }
            .prefix(24)
        var result: [String: RoadMatchedSegment] = [:]
        for bridge in candidates {
            if Task.isCancelled { break }
            let points = [bridge.from, bridge.to]
            let measuredAccuracy = points.compactMap(\.horizontalAccuracy)
                .filter { $0.isFinite && $0 >= 0 }.max()
            let displacementLimit = measuredAccuracy.map {
                min(25, max(10, $0 * 2 + 5))
            } ?? 25
            let bridgePolicy = RoadMatchPolicy(
                maximumPointDisplacementMeters: displacementLimit,
                maximumMedianDisplacementMeters: displacementLimit,
                maximumDetourRatio: 1.8,
                minimumAttachedPointRatio: 1)
            let matcher = RoadMatchingService(
                provider: provider, configuration: configuration,
                policy: bridgePolicy)
            let quality = TrajectoryQuality(
                pointCount: points.count,
                duration: bridge.endTime.timeIntervalSince(bridge.startTime),
                maximumGap: bridge.endTime.timeIntervalSince(bridge.startTime),
                accuratePointRatio: 1, confidence: 0.5)
            let segment = TrajectorySegment(
                id: bridge.id, trajectoryID: bridge.activityID,
                sessionID: bridge.activityID, source: bridge.source,
                points: points, startTime: bridge.startTime,
                endTime: bridge.endTime, quality: quality)
            let matched = await matcher.match(
                segment: segment, activityType: bridge.activityType)
            let elapsed = bridge.endTime.timeIntervalSince(bridge.startTime)
            let length = zip(matched.geometry, matched.geometry.dropFirst())
                .reduce(0.0) { total, pair in
                    total + GeoMath.distanceMeters(
                        from: (pair.0.latitude, pair.0.longitude),
                        to: (pair.1.latitude, pair.1.longitude))
                }
            if matched.usesRoadGeometry,
               elapsed > 0,
               length / elapsed > RecordedActivityPlanner.maximumPlausibleSpeed(
                for: bridge.activityType) {
                result[bridge.id] = RoadMatchedSegment(
                    sourceSegmentID: bridge.id, status: .unmatched,
                    geometry: [], attachments: matched.attachments,
                    failureReason: .implausibleSpeed,
                    algorithmVersion: RoadMatchValidator.algorithmVersion)
            } else {
                result[bridge.id] = matched
            }
        }
        return result
    }

    public func match(segment: TrajectorySegment, activityType: String?) async
        -> RoadMatchedSegment {
        let anchors = anchorPoints(segment.points)
        guard anchors.count >= 2 else {
            return RoadMatchValidator.validate(segment: segment, geometry: [])
        }
        var geometry: [RoadGeometryCoordinate] = []
        do {
            for (start, end) in zip(anchors, anchors.dropFirst()) {
                if Task.isCancelled {
                    return RoadMatchValidator.providerUnavailable(segment: segment)
                }
                let part = try await provider.roadGeometry(
                    between: coordinate(start), and: coordinate(end),
                    activityType: activityType)
                guard part.count >= 2 else { throw RoadGeometryProviderError.noRoute }
                if let last = geometry.last, last == part.first {
                    geometry.append(contentsOf: part.dropFirst())
                } else {
                    geometry.append(contentsOf: part)
                }
            }
            return RoadMatchValidator.validate(
                segment: segment, geometry: geometry, policy: policy)
        } catch {
            return RoadMatchValidator.providerUnavailable(segment: segment)
        }
    }

    private func anchorPoints(_ points: [TrajectoryPoint]) -> [TrajectoryPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        var anchors = [first]
        for point in points.dropFirst().dropLast() {
            guard let previous = anchors.last else { continue }
            let distance = GeoMath.distanceMeters(
                from: (previous.latitude, previous.longitude),
                to: (point.latitude, point.longitude))
            let elapsed = point.timestamp.timeIntervalSince(previous.timestamp)
            if distance >= configuration.minimumAnchorDistanceMeters
                || elapsed >= configuration.maximumAnchorInterval {
                anchors.append(point)
            }
        }
        if anchors.last?.id != last.id { anchors.append(last) }
        let maximumAnchors = configuration.maximumRequestsPerSegment + 1
        guard anchors.count > maximumAnchors else { return anchors }
        return (0..<maximumAnchors).map { index in
            anchors[index * (anchors.count - 1) / (maximumAnchors - 1)]
        }
    }

    private func coordinate(_ point: TrajectoryPoint) -> RoadGeometryCoordinate {
        RoadGeometryCoordinate(latitude: point.latitude, longitude: point.longitude)
    }
}
