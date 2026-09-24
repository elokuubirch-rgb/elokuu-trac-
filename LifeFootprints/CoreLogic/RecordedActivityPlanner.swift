import Foundation

/// An outing may contain several recorded segments. Grouping them does not imply that
/// the unobserved path between two segments is known.
public struct RecordedActivity: Equatable, Sendable {
    public let id: String
    public let source: TrajectorySource
    public let activityType: String?
    public let segmentIDs: [String]
    public let startTime: Date
    public let endTime: Date
}

/// A short, plausible interruption that may be filled only after road geometry is
/// validated. The original measurements are never changed.
public struct ActivityRoadBridge: Equatable, Sendable {
    public let id: String
    public let activityID: String
    public let source: TrajectorySource
    public let activityType: String?
    public let from: TrajectoryPoint
    public let to: TrajectoryPoint

    public var startTime: Date { from.timestamp }
    public var endTime: Date { to.timestamp }
}

public enum ActivityBoundaryReason: String, Equatable, Sendable {
    case shortRoadGap
    case nearbyStop
    case uncertainPath
    case nonChronological
    case longPause
    case implausibleMovement
    case activityChanged
}

public struct ActivityBoundaryDecision: Equatable, Sendable {
    public let fromSegmentID: String
    public let toSegmentID: String
    public let continuesActivity: Bool
    public let reason: ActivityBoundaryReason
    public let elapsed: TimeInterval
    public let distanceMeters: Double
}

public struct RecordedActivityPlan: Equatable, Sendable {
    public let activities: [RecordedActivity]
    public let roadBridges: [ActivityRoadBridge]
    public let boundaryDecisions: [ActivityBoundaryDecision]
}

public struct RecordedActivityConfiguration: Equatable, Sendable {
    public var maximumMovingPause: TimeInterval = 10 * 60
    public var maximumNearbyPause: TimeInterval = 30 * 60
    public var nearbyDistanceMeters: Double = 50
    public var maximumRoadBridgeInterval: TimeInterval = 90
    public var maximumWalkingBridgeMeters: Double = 180
    public var maximumCyclingBridgeMeters: Double = 450
    public var maximumVehicleBridgeMeters: Double = 800

    public init() {}
}

public enum RecordedActivityPlanner {
    public static func plan(
        trajectories: [Trajectory], since: Date? = nil,
        visiblePointIDs: Set<String>? = nil,
        configuration: RecordedActivityConfiguration = .init()
    ) -> RecordedActivityPlan {
        var activities: [RecordedActivity] = []
        var bridges: [ActivityRoadBridge] = []
        var decisions: [ActivityBoundaryDecision] = []

        // Explicit workout and imported sessions already carry their own boundary.
        for trajectory in trajectories where trajectory.source != .coreLocation {
            if let since, trajectory.endTime < since { continue }
            activities.append(RecordedActivity(
                id: trajectory.id, source: trajectory.source,
                activityType: trajectory.activityType,
                segmentIDs: trajectory.segments.map(\.id),
                startTime: trajectory.startTime, endTime: trajectory.endTime))
        }

        let segments = trajectories.filter { $0.source == .coreLocation }
            .flatMap { trajectory in
                trajectory.segments.compactMap { segment -> (TrajectorySegment, String?)? in
                    guard !segment.points.isEmpty else { return nil }
                    if let since, segment.endTime < since { return nil }
                    return (segment, trajectory.activityType)
                }
            }
            .sorted {
                if $0.0.startTime == $1.0.startTime { return $0.0.id < $1.0.id }
                return $0.0.startTime < $1.0.startTime
            }

        var current: [(TrajectorySegment, String?)] = []
        var currentActivityID: String?

        func finish() {
            guard let first = current.first, let last = current.last,
                  let activityID = currentActivityID else { return }
            activities.append(RecordedActivity(
                id: activityID, source: .coreLocation,
                activityType: current.compactMap(\.1).first
                    ?? inferredActivityType(in: current),
                segmentIDs: current.map { $0.0.id },
                startTime: first.0.startTime, endTime: last.0.endTime))
            current.removeAll(keepingCapacity: true)
            currentActivityID = nil
        }

        for entry in segments {
            guard let firstPoint = entry.0.points.first else { continue }
            if let previous = current.last, let lastPoint = previous.0.points.last {
                let gap = firstPoint.timestamp.timeIntervalSince(lastPoint.timestamp)
                let distance = GeoMath.distanceMeters(
                    from: (lastPoint.latitude, lastPoint.longitude),
                    to: (firstPoint.latitude, firstPoint.longitude))
                let type = previous.1 ?? entry.1 ?? inferredActivityType(in: current)
                let changedMode = activityModesConflict(previous.1, entry.1)
                let continues = !changedMode && sameActivity(
                    gap: gap, distance: distance, activityType: type,
                    configuration: configuration)
                let canBridge = continues && canRequestRoadBridge(
                    gap: gap, distance: distance, activityType: type,
                    configuration: configuration)
                let reason: ActivityBoundaryReason
                if changedMode { reason = .activityChanged }
                else if gap <= 0 { reason = .nonChronological }
                else if !continues {
                    reason = (gap > configuration.maximumMovingPause
                        && distance > configuration.nearbyDistanceMeters)
                        || gap > configuration.maximumNearbyPause
                        ? .longPause : .implausibleMovement
                } else if canBridge { reason = .shortRoadGap }
                else if distance <= configuration.nearbyDistanceMeters {
                    reason = .nearbyStop
                } else { reason = .uncertainPath }
                decisions.append(ActivityBoundaryDecision(
                    fromSegmentID: previous.0.id,
                    toSegmentID: entry.0.id,
                    continuesActivity: continues, reason: reason,
                    elapsed: gap, distanceMeters: distance))
                if !continues {
                    finish()
                } else if let activityID = currentActivityID,
                          isVisible(lastPoint, visiblePointIDs),
                          isVisible(firstPoint, visiblePointIDs),
                          canBridge {
                    bridges.append(ActivityRoadBridge(
                        id: "activity-bridge:\(lastPoint.id):\(firstPoint.id)",
                        activityID: activityID, source: .coreLocation,
                        activityType: type, from: lastPoint, to: firstPoint))
                }
            }
            if currentActivityID == nil {
                currentActivityID = "recorded-activity:\(firstPoint.id)"
            }
            current.append(entry)
        }
        finish()
        return RecordedActivityPlan(
            activities: activities, roadBridges: bridges,
            boundaryDecisions: decisions)
    }

    private static func isVisible(_ point: TrajectoryPoint,
                                  _ visiblePointIDs: Set<String>?) -> Bool {
        visiblePointIDs?.contains(point.id) ?? true
    }

    private static func activityModesConflict(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = activityMode(lhs), let rhs = activityMode(rhs) else { return false }
        return lhs != rhs
    }

    private static func activityMode(_ value: String?) -> String? {
        let mode = value?.lowercased() ?? ""
        if mode.contains("walk") || mode.contains("run") || mode.contains("hik") {
            return "pedestrian"
        }
        if mode.contains("cycl") || mode.contains("bike") { return "cycling" }
        if mode.contains("drive") || mode.contains("vehicle") { return "vehicle" }
        return nil
    }

    private static func sameActivity(
        gap: TimeInterval, distance: Double, activityType: String?,
        configuration: RecordedActivityConfiguration
    ) -> Bool {
        guard gap > 0, distance.isFinite else { return false }
        if distance <= configuration.nearbyDistanceMeters {
            return gap <= configuration.maximumNearbyPause
        }
        guard gap <= configuration.maximumMovingPause else { return false }
        return distance / gap <= maximumPlausibleSpeed(for: activityType)
    }

    private static func canRequestRoadBridge(
        gap: TimeInterval, distance: Double, activityType: String?,
        configuration: RecordedActivityConfiguration
    ) -> Bool {
        guard gap > 0,
              gap <= configuration.maximumRoadBridgeInterval,
              distance > 8,
              distance / gap <= maximumPlausibleSpeed(for: activityType) else {
            return false
        }
        let mode = activityType?.lowercased() ?? ""
        let limit = mode.contains("cycl") || mode.contains("bike")
            ? configuration.maximumCyclingBridgeMeters
            : (mode.contains("drive") || mode.contains("vehicle")
                ? configuration.maximumVehicleBridgeMeters
                : configuration.maximumWalkingBridgeMeters)
        return distance <= limit
    }

    static func maximumPlausibleSpeed(for activityType: String?) -> Double {
        let mode = activityType?.lowercased() ?? ""
        if mode.contains("walk") || mode.contains("run") || mode.contains("hik") { return 5 }
        if mode.contains("cycl") || mode.contains("bike") { return 16 }
        if mode.contains("drive") || mode.contains("vehicle") { return 45 }
        return 16
    }

    private static func inferredActivityType(
        in segments: [(TrajectorySegment, String?)]
    ) -> String? {
        let speeds = segments.suffix(3).flatMap { $0.0.points.suffix(20) }
            .compactMap(\.speed).filter { $0.isFinite && $0 > 0.4 && $0 < 45 }
            .sorted()
        guard speeds.count >= 3 else { return nil }
        let median = speeds[speeds.count / 2]
        if median >= 8 { return "vehicle" }
        if median >= 3 { return "cycling" }
        return "walking"
    }
}
