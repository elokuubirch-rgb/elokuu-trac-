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
    /// 冲突候选会用同一条轨迹执行最多 64 次插值探针。旧实现每个探针都重新
    /// 排序该轨迹的全部 segment points；真实 HealthKit 路线达到百万点后，
    /// 这会把一次冷重建放大到数分钟。准备阶段只做一次完全相同的排序，随后
    /// 的时间窗口和插值均只读复用，不改变候选、阈值或最终点顺序。
    private struct PreparedTrajectory {
        let trajectory: Trajectory
        let pointsBySegment: [[TrajectoryPoint]]

        init(_ trajectory: Trajectory) {
            self.trajectory = trajectory
            pointsBySegment = trajectory.segments.map { segment in
                // Builder 和持久缓存本来就保证段内时间有序。命中这个常规路径时
                // Array 只共享原存储，不再复制百万级点集；异常输入仍按旧语义排序。
                Self.isChronological(segment.points)
                    ? segment.points
                    : segment.points.sorted { $0.timestamp < $1.timestamp }
            }
        }

        static func isChronological(_ points: [TrajectoryPoint]) -> Bool {
            guard points.count > 1 else { return true }
            for index in 1..<points.count
            where points[index].timestamp < points[index - 1].timestamp {
                return false
            }
            return true
        }
    }

    public static func resolve(
        _ trajectories: [Trajectory],
        configuration: TrajectoryConflictConfiguration = .init()
    ) -> TrajectoryResolution {
        let ordered = trajectories.sorted { $0.id < $1.id }
        #if DEBUG && !SWIFT_PACKAGE
        let prepared = PerformanceDiagnostics.measure(
            "TrajectoryConflictResolver.prepare",
            metadata: "trajectories=\(ordered.count)"
        ) {
            ordered.map(PreparedTrajectory.init)
        }
        #else
        let prepared = ordered.map(PreparedTrajectory.init)
        #endif
        var conflicts: [TrajectoryConflict] = []
        var comparedPairCount = 0
        let chronological = prepared.sorted {
            let left = $0.trajectory
            let right = $1.trajectory
            return left.startTime == right.startTime
                ? left.id < right.id : left.startTime < right.startTime
        }
        if chronological.count > 1 {
            for leftIndex in 0..<(chronological.count - 1) {
                for rightIndex in (leftIndex + 1)..<chronological.count {
                    if chronological[rightIndex].trajectory.startTime
                        > chronological[leftIndex].trajectory.endTime {
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
        return materialize(
            ordered, conflicts: conflicts, comparedPairCount: comparedPairCount)
    }

    /// 从持久化的稀疏冲突区间恢复完整运行时解析结果。
    ///
    /// 磁盘只需要保存默认规则之外的冲突区间；每点 suppression metadata 仍可在
    /// 内存中按完全相同的规则重建，避免派生缓存成为第二份逐点数据库。
    public static func materialize(
        _ trajectories: [Trajectory],
        conflicts: [TrajectoryConflict],
        comparedPairCount: Int
    ) -> TrajectoryResolution {
        let ordered = trajectories.sorted { $0.id < $1.id }
        let orderedConflicts = conflicts.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.suppressedTrajectoryID != $1.suppressedTrajectoryID {
                return $0.suppressedTrajectoryID < $1.suppressedTrajectoryID
            }
            return $0.winnerTrajectoryID < $1.winnerTrajectoryID
        }
        let conflictsByLoser = Dictionary(
            grouping: orderedConflicts, by: \.suppressedTrajectoryID)
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
        return TrajectoryResolution(trajectories: ordered, conflicts: orderedConflicts,
                                    points: flattenedPoints,
                                    comparedPairCount: comparedPairCount)
    }

    private static func conflict(
        between preparedLeft: PreparedTrajectory, and preparedRight: PreparedTrajectory,
        configuration: TrajectoryConflictConfiguration
    ) -> TrajectoryConflict? {
        let left = preparedLeft.trajectory
        let right = preparedRight.trajectory
        let overlapStart = max(left.startTime, right.startTime)
        let overlapEnd = min(left.endTime, right.endTime)
        let overlapDuration = overlapEnd.timeIntervalSince(overlapStart)
        guard overlapDuration >= configuration.minimumOverlapDuration else { return nil }
        let shorterDuration = min(left.quality.duration, right.quality.duration)
        guard shorterDuration > 0 else { return nil }
        let overlapRatio = min(1, overlapDuration / shorterDuration)
        guard overlapRatio >= configuration.minimumOverlapRatio else { return nil }

        let leftPoints = points(in: preparedLeft, from: overlapStart, through: overlapEnd)
        let rightPoints = points(in: preparedRight, from: overlapStart, through: overlapEnd)
        let probes = sampled(
            leftPoints.count <= rightPoints.count ? leftPoints : rightPoints,
            maximumCount: configuration.maximumProbeCount)
        let comparison = leftPoints.count <= rightPoints.count ? preparedRight : preparedLeft
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

    private static func points(in prepared: PreparedTrajectory, from start: Date,
                               through end: Date) -> [TrajectoryPoint] {
        var result: [TrajectoryPoint] = []
        for points in prepared.pointsBySegment {
            guard let first = points.first, let last = points.last,
                  first.timestamp <= end, last.timestamp >= start else { continue }
            var lower = 0
            var upper = points.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if points[middle].timestamp < start {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            let startIndex = lower
            upper = points.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if points[middle].timestamp <= end {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            result.append(contentsOf: points[startIndex..<lower])
        }
        // Segments are normally chronological and disjoint. Keep exact legacy behavior
        // for overlapping or out-of-order segment fixtures.
        if !PreparedTrajectory.isChronological(result) {
            result.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }

    private static func sampled(_ points: [TrajectoryPoint], maximumCount: Int) -> [TrajectoryPoint] {
        guard maximumCount > 0, points.count > maximumCount else { return points }
        if maximumCount == 1 { return [points[points.count / 2]] }
        let last = points.count - 1
        return (0..<maximumCount).map { index in
            points[index * last / (maximumCount - 1)]
        }
    }

    private static func interpolatedCoordinate(in prepared: PreparedTrajectory, at time: Date,
                                               maximumGap: TimeInterval) -> (Double, Double)? {
        for points in prepared.pointsBySegment {
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
