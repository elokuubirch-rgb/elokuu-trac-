import Foundation

public struct TrajectoryConflictConfiguration: Equatable, Sendable {
    public var minimumOverlapDuration: TimeInterval
    public var minimumOverlapRatio: Double
    public var maximumInterpolationGap: TimeInterval
    public var matchingDistanceMeters: Double
    public var maximumMedianDistanceMeters: Double
    public var minimumMatchingPointRatio: Double
    public var maximumProbeCount: Int

    public init(minimumOverlapDuration: TimeInterval = 60,
                minimumOverlapRatio: Double = 0.6,
                maximumInterpolationGap: TimeInterval = 15 * 60,
                matchingDistanceMeters: Double = 180,
                maximumMedianDistanceMeters: Double = 90,
                minimumMatchingPointRatio: Double = 0.7,
                maximumProbeCount: Int = 64) {
        self.minimumOverlapDuration = minimumOverlapDuration
        self.minimumOverlapRatio = minimumOverlapRatio
        self.maximumInterpolationGap = maximumInterpolationGap
        self.matchingDistanceMeters = matchingDistanceMeters
        self.maximumMedianDistanceMeters = maximumMedianDistanceMeters
        self.minimumMatchingPointRatio = minimumMatchingPointRatio
        self.maximumProbeCount = maximumProbeCount
    }
}

public struct TrajectoryConflict: Codable, Equatable, Sendable {
    public let winnerTrajectoryID: String
    public let suppressedTrajectoryID: String
    public let startTime: Date
    public let endTime: Date
    public let overlapRatio: Double
    public let matchingPointRatio: Double
    public let medianDistanceMeters: Double
}

/// 冲突解析后的点仍保留原始身份；suppressedByTrajectoryID 非空时只从显示/匹配层隐藏。
public struct ResolvedTrajectoryPoint: Equatable, Sendable {
    public let trajectoryID: String
    public let sessionID: String
    public let segmentID: String
    public let source: TrajectorySource
    public let point: TrajectoryPoint
    public let confidence: Double
    public let suppressedByTrajectoryID: String?
    public let suppressedBySource: TrajectorySource?
}

public struct TrajectoryResolution: Equatable, Sendable {
    public let trajectories: [Trajectory]
    public let conflicts: [TrajectoryConflict]
    public let points: [ResolvedTrajectoryPoint]
    /// 通过时间窗口剪枝后真正进入空间相似度判断的轨迹对数量。
    public let comparedPairCount: Int

    public var visiblePoints: [ResolvedTrajectoryPoint] {
        points.filter { $0.suppressedByTrajectoryID == nil }
    }
}

public enum TrajectoryConflictResolver {
    public static func resolve(
        _ trajectories: [Trajectory],
        configuration: TrajectoryConflictConfiguration = .init()
    ) -> TrajectoryResolution {
        let ordered = trajectories.sorted { $0.id < $1.id }
        var conflicts: [TrajectoryConflict] = []
        var comparedPairCount = 0
        let chronological = ordered.sorted {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
        }
        if chronological.count > 1 {
            for leftIndex in 0..<(chronological.count - 1) {
                for rightIndex in (leftIndex + 1)..<chronological.count {
                    if chronological[rightIndex].startTime > chronological[leftIndex].endTime {
                        break
                    }
                    comparedPairCount += 1
                    if let conflict = conflict(
                        between: chronological[leftIndex], and: chronological[rightIndex],
                        configuration: configuration) {
                        conflicts.append(conflict)
                    }
                }
            }
        }
        conflicts.sort {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.suppressedTrajectoryID != $1.suppressedTrajectoryID {
                return $0.suppressedTrajectoryID < $1.suppressedTrajectoryID
            }
            return $0.winnerTrajectoryID < $1.winnerTrajectoryID
        }
        let conflictsByLoser = Dictionary(grouping: conflicts, by: \.suppressedTrajectoryID)
        let preferenceRank = Dictionary(uniqueKeysWithValues: ordered.sorted {
            prefers($0, over: $1)
        }.enumerated().map { ($0.element.id, $0.offset) })
        let sourceByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.source) })
        let flattenedPoints: [ResolvedTrajectoryPoint] = ordered.flatMap { trajectory in
            Self.resolvedPoints(for: trajectory,
                                conflicts: conflictsByLoser[trajectory.id] ?? [],
                                preferenceRank: preferenceRank, sourceByID: sourceByID)
        }.sorted {
            if $0.point.timestamp != $1.point.timestamp {
                return $0.point.timestamp < $1.point.timestamp
            }
            if $0.trajectoryID != $1.trajectoryID { return $0.trajectoryID < $1.trajectoryID }
            return $0.point.id < $1.point.id
        }
        return TrajectoryResolution(trajectories: ordered, conflicts: conflicts,
                                    points: flattenedPoints,
                                    comparedPairCount: comparedPairCount)
    }

    private static func conflict(
        between left: Trajectory, and right: Trajectory,
        configuration: TrajectoryConflictConfiguration
    ) -> TrajectoryConflict? {
        let overlapStart = max(left.startTime, right.startTime)
        let overlapEnd = min(left.endTime, right.endTime)
        let overlapDuration = overlapEnd.timeIntervalSince(overlapStart)
        guard overlapDuration >= configuration.minimumOverlapDuration else { return nil }
        let shorterDuration = min(left.quality.duration, right.quality.duration)
        guard shorterDuration > 0 else { return nil }
        let overlapRatio = min(1, overlapDuration / shorterDuration)
        guard overlapRatio >= configuration.minimumOverlapRatio else { return nil }

        let leftPoints = points(in: left, from: overlapStart, through: overlapEnd)
        let rightPoints = points(in: right, from: overlapStart, through: overlapEnd)
        let probes = sampled(
            leftPoints.count <= rightPoints.count ? leftPoints : rightPoints,
            maximumCount: configuration.maximumProbeCount)
        let comparison = leftPoints.count <= rightPoints.count ? right : left
        guard probes.count >= 2 else { return nil }
        let distances = probes.compactMap { probe -> Double? in
            guard let coordinate = interpolatedCoordinate(
                in: comparison, at: probe.timestamp,
                maximumGap: configuration.maximumInterpolationGap) else { return nil }
            return GeoMath.distanceMeters(
                from: (probe.latitude, probe.longitude), to: coordinate)
        }
        guard distances.count >= 2 else { return nil }
        let matchingRatio = Double(distances.filter {
            $0 <= configuration.matchingDistanceMeters
        }.count) / Double(probes.count)
        let sortedDistances = distances.sorted()
        let median = sortedDistances[sortedDistances.count / 2]
        guard matchingRatio >= configuration.minimumMatchingPointRatio,
              median <= configuration.maximumMedianDistanceMeters else { return nil }

        let preferred = preferredTrajectory(left, right)
        let loser = preferred.id == left.id ? right : left
        return TrajectoryConflict(
            winnerTrajectoryID: preferred.id, suppressedTrajectoryID: loser.id,
            startTime: overlapStart, endTime: overlapEnd, overlapRatio: overlapRatio,
            matchingPointRatio: matchingRatio, medianDistanceMeters: median)
    }

    private static func preferredTrajectory(_ left: Trajectory,
                                            _ right: Trajectory) -> Trajectory {
        prefers(left, over: right) ? left : right
    }

    private static func prefers(_ left: Trajectory, over right: Trajectory) -> Bool {
        let leftScore = selectionScore(left)
        let rightScore = selectionScore(right)
        return leftScore == rightScore ? left.id < right.id : leftScore > rightScore
    }

    private static func selectionScore(_ trajectory: Trajectory) -> Double {
        Double(trajectory.displayPriority)
            + trajectory.confidence * 50
            + trajectory.quality.accuratePointRatio * 20
            + min(10, log2(Double(max(1, trajectory.quality.pointCount))))
    }

    private static func resolvedPoints(for trajectory: Trajectory,
                                       conflicts: [TrajectoryConflict],
                                       preferenceRank: [String: Int],
                                       sourceByID: [String: TrajectorySource]) -> [ResolvedTrajectoryPoint] {
        trajectory.segments.flatMap { segment in
            let ordered = segment.points.sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            }
            let suppressors = ordered.map { point in
                conflicts.filter { $0.startTime <= point.timestamp && point.timestamp <= $0.endTime }
                    .map(\.winnerTrajectoryID).min {
                        (preferenceRank[$0] ?? Int.max) < (preferenceRank[$1] ?? Int.max)
                    }
            }
            let hasSuppressedPoint = suppressors.contains { $0 != nil }
            var pieceIndex = 0
            var previousWasSuppressed = false
            return ordered.enumerated().map { index, point in
                let suppressor = suppressors[index]
                if suppressor == nil, previousWasSuppressed { pieceIndex += 1 }
                previousWasSuppressed = suppressor != nil
                let resolvedSegmentID = hasSuppressedPoint
                    ? "\(segment.id):visible:\(pieceIndex)" : segment.id
                return ResolvedTrajectoryPoint(
                    trajectoryID: trajectory.id, sessionID: segment.sessionID,
                    segmentID: resolvedSegmentID, source: trajectory.source,
                    point: point, confidence: segment.quality.confidence,
                    suppressedByTrajectoryID: suppressor,
                    suppressedBySource: suppressor.flatMap { sourceByID[$0] })
            }
        }
    }

    private static func points(in trajectory: Trajectory, from start: Date,
                               through end: Date) -> [TrajectoryPoint] {
        trajectory.segments.flatMap(\.points).filter {
            start <= $0.timestamp && $0.timestamp <= end
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private static func sampled(_ points: [TrajectoryPoint], maximumCount: Int) -> [TrajectoryPoint] {
        guard maximumCount > 0, points.count > maximumCount else { return points }
        if maximumCount == 1 { return [points[points.count / 2]] }
        let last = points.count - 1
        return (0..<maximumCount).map { index in
            points[index * last / (maximumCount - 1)]
        }
    }

    private static func interpolatedCoordinate(in trajectory: Trajectory, at time: Date,
                                               maximumGap: TimeInterval) -> (Double, Double)? {
        for segment in trajectory.segments {
            let points = segment.points.sorted { $0.timestamp < $1.timestamp }
            guard let first = points.first, let last = points.last,
                  first.timestamp <= time, time <= last.timestamp else { continue }
            if time == first.timestamp { return (first.latitude, first.longitude) }
            if time == last.timestamp { return (last.latitude, last.longitude) }
            var low = 0
            var high = points.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if points[middle].timestamp <= time { low = middle } else { high = middle }
            }
            let left = points[low]
            let right = points[high]
            let span = right.timestamp.timeIntervalSince(left.timestamp)
            guard span > 0, span <= maximumGap else { return nil }
            let fraction = time.timeIntervalSince(left.timestamp) / span
            return (left.latitude + (right.latitude - left.latitude) * fraction,
                    left.longitude + (right.longitude - left.longitude) * fraction)
        }
        return nil
    }
}
