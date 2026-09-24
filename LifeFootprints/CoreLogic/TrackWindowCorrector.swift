import Foundation
import CoreLocation

public enum PostFilterRejectReason: String, CaseIterable, Sendable {
    case triSpike
    case quadSpike
    case isolated
    case redundant
    case futureSharpAngle
}

public struct RemovedCandidate: Equatable, Sendable {
    public let candidateID: UUID
    public let reason: PostFilterRejectReason

    public init(candidateID: UUID, reason: PostFilterRejectReason) {
        self.candidateID = candidateID
        self.reason = reason
    }
}

/// 只有此值类型允许进入自动轨迹持久化。
public struct FinalizedTrackPoint: Equatable, Sendable {
    public let candidateID: UUID
    public let coordinate: CLLocationCoordinate2D
    public let timestamp: Date
    public let horizontalAccuracy: Double
    public let altitude: Double
    public let derivedSpeed: Double
    public let course: Double
    public let source: LocationSampleSource
    public let motionState: MotionState
    public let finalConfidence: Double

    public init(candidateID: UUID, coordinate: CLLocationCoordinate2D,
                timestamp: Date, horizontalAccuracy: Double, altitude: Double,
                derivedSpeed: Double, course: Double,
                source: LocationSampleSource, motionState: MotionState,
                finalConfidence: Double) {
        self.candidateID = candidateID
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.derivedSpeed = derivedSpeed
        self.course = course
        self.source = source
        self.motionState = motionState
        self.finalConfidence = finalConfidence
    }

    public static func == (lhs: FinalizedTrackPoint,
                           rhs: FinalizedTrackPoint) -> Bool {
        lhs.candidateID == rhs.candidateID
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.timestamp == rhs.timestamp
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy
            && lhs.altitude == rhs.altitude
            && lhs.derivedSpeed == rhs.derivedSpeed
            && lhs.course == rhs.course
            && lhs.source == rhs.source
            && lhs.motionState == rhs.motionState
            && lhs.finalConfidence == rhs.finalConfidence
    }
}

public enum TrackCorrectionOutput: Equatable, Sendable {
    case pending
    case finalized([FinalizedTrackPoint])
    case removed(candidateIDs: [UUID], reason: PostFilterRejectReason)
    case mixed(finalized: [FinalizedTrackPoint], removed: [RemovedCandidate])

    public var finalizedPoints: [FinalizedTrackPoint] {
        switch self {
        case .finalized(let points): points
        case .mixed(let points, _): points
        case .pending, .removed: []
        }
    }

    public var removedCandidates: [RemovedCandidate] {
        switch self {
        case .mixed(_, let removed): removed
        case .removed(let ids, let reason):
            ids.map { RemovedCandidate(candidateID: $0, reason: reason) }
        case .pending, .finalized: []
        }
    }
}

/// 小滑动窗口二次纠错。只删除有前后文证据的点，不插值、不制造坐标。
public final class TrackWindowCorrector: @unchecked Sendable {
    private var candidates: [TrackCandidate] = []

    public init() {}

    public func push(_ candidate: TrackCandidate,
                     configuration: PostFilterConfiguration)
        -> TrackCorrectionOutput {
        candidates.append(candidate)
        let requiredCount = max(5, configuration.windowPointCount)
        guard candidates.count >= requiredCount else { return .pending }

        let window = Array(candidates.prefix(5))
        let duration = window[4].timestamp.timeIntervalSince(window[0].timestamp)
        guard duration <= configuration.windowMaxDuration else {
            return finalizeOldest()
        }

        if configuration.isolatedPointEnabled,
           isIsolated(window, configuration: configuration) {
            let finalized = [finalize(window[0]), finalize(window[1])]
            let removed = RemovedCandidate(candidateID: window[2].id,
                                           reason: .isolated)
            candidates.removeFirst(3)
            return .mixed(finalized: finalized, removed: [removed])
        }
        if configuration.quadSpikeEnabled,
           isQuadSpike(window, configuration: configuration) {
            let finalized = [finalize(window[0])]
            let removed = [window[1], window[2]].map {
                RemovedCandidate(candidateID: $0.id, reason: .quadSpike)
            }
            candidates.removeFirst(3)
            return .mixed(finalized: finalized, removed: removed)
        }
        if configuration.triSpikeEnabled,
           isTriSpike(window, configuration: configuration) {
            let finalized = [finalize(window[0])]
            let removed = RemovedCandidate(candidateID: window[1].id,
                                           reason: .triSpike)
            candidates.removeFirst(2)
            return .mixed(finalized: finalized, removed: [removed])
        }
        if configuration.redundantPointEnabled,
           isRedundant(window, configuration: configuration) {
            let finalized = [finalize(window[0])]
            let removed = RemovedCandidate(candidateID: window[1].id,
                                           reason: .redundant)
            candidates.removeFirst(2)
            return .mixed(finalized: finalized, removed: [removed])
        }
        return finalizeOldest()
    }

    /// 窗口尾部没有足够未来证据，flush 必须全部 KEEP。
    public func flush() -> [FinalizedTrackPoint] {
        let result = candidates.map(finalize)
        candidates.removeAll(keepingCapacity: true)
        return result
    }

    /// 调用方必须先 flush。此方法只负责确保不跨 Segment 共用窗口。
    public func resetForNewSegment() {
        candidates.removeAll(keepingCapacity: true)
    }

    #if DEBUG
    public var pendingCount: Int { candidates.count }
    #endif

    private func finalizeOldest() -> TrackCorrectionOutput {
        guard !candidates.isEmpty else { return .pending }
        return .finalized([finalize(candidates.removeFirst())])
    }

    private func finalize(_ candidate: TrackCandidate) -> FinalizedTrackPoint {
        FinalizedTrackPoint(
            candidateID: candidate.id, coordinate: candidate.coordinate,
            timestamp: candidate.timestamp,
            horizontalAccuracy: candidate.horizontalAccuracy,
            altitude: candidate.altitude, derivedSpeed: candidate.derivedSpeed,
            course: candidate.course, source: candidate.source,
            motionState: candidate.motionState,
            finalConfidence: candidate.realtimeConfidence)
    }

    private func isTriSpike(_ p: [TrackCandidate],
                            configuration c: PostFilterConfiguration) -> Bool {
        let a = p[0], b = p[1], bridge = p[2]
        let direct = distance(a, bridge)
        let ab = distance(a, b), bc = distance(b, bridge)
        let detour = (ab + bc) / max(1, direct)
        let deviation = distanceFromSegment(b.coordinate,
                                            a.coordinate, bridge.coordinate)
        let turnback = bearingDelta(from: a.coordinate, via: b.coordinate,
                                    to: bridge.coordinate)
        let baseline = max(1, speed(a, bridge), p[3].derivedSpeed,
                           p[4].derivedSpeed)
        let spikeSpeed = max(speed(a, b), speed(b, bridge))
        let speedBreak = spikeSpeed > max(baseline * c.speedContinuityRatio,
                                         baseline + c.speedContinuityDelta)
        let accuracyConcern = b.horizontalAccuracy
            >= max(a.horizontalAccuracy, bridge.horizontalAccuracy)
                + c.accuracyDegradationTolerance
        let evidence = evidenceConfidence(
            detour: detour, threshold: c.minimumTriDetourRatio,
            deviation: deviation, minimumDeviation: c.minimumSpikeDeviation,
            speedBreak: speedBreak,
            trustConcern: accuracyConcern || detour >= c.extremeDetourRatio)
        return deviation >= c.minimumSpikeDeviation
            && detour >= c.minimumTriDetourRatio
            && turnback >= 110
            && speedBreak
            && (accuracyConcern || detour >= c.extremeDetourRatio)
            && evidence >= c.minimumEvidenceConfidence
    }

    private func isQuadSpike(_ p: [TrackCandidate],
                             configuration c: PostFilterConfiguration) -> Bool {
        let a = p[0], b = p[1], middle = p[2], end = p[3]
        let direct = distance(a, end)
        let path = distance(a, b) + distance(b, middle) + distance(middle, end)
        let detour = path / max(1, direct)
        let firstDeviation = distanceFromSegment(
            b.coordinate, a.coordinate, end.coordinate)
        let secondDeviation = distanceFromSegment(
            middle.coordinate, a.coordinate, end.coordinate)
        let deviation = max(firstDeviation, secondDeviation)
        let baseline = max(1, speed(a, end), p[4].derivedSpeed)
        let spikeSpeed = max(speed(a, b), speed(middle, end))
        let speedBreak = spikeSpeed > max(baseline * c.speedContinuityRatio,
                                         baseline + c.speedContinuityDelta)
        let endpointAccuracy = max(a.horizontalAccuracy, end.horizontalAccuracy)
        let accuracyConcern = max(b.horizontalAccuracy, middle.horizontalAccuracy)
            >= endpointAccuracy + c.accuracyDegradationTolerance
        let evidence = evidenceConfidence(
            detour: detour, threshold: c.minimumQuadDetourRatio,
            deviation: deviation, minimumDeviation: c.minimumSpikeDeviation,
            speedBreak: speedBreak,
            trustConcern: accuracyConcern || detour >= c.extremeDetourRatio)
        return deviation >= c.minimumSpikeDeviation
            && min(firstDeviation, secondDeviation) >= c.minimumSpikeDeviation
            && detour >= c.minimumQuadDetourRatio
            && speedBreak
            && (accuracyConcern || detour >= c.extremeDetourRatio)
            && evidence >= c.minimumEvidenceConfidence
    }

    private func isIsolated(_ p: [TrackCandidate],
                            configuration c: PostFilterConfiguration) -> Bool {
        let before = p[1], isolated = p[2], after = p[3]
        let direct = distance(before, after)
        let detour = (distance(before, isolated) + distance(isolated, after))
            / max(1, direct)
        let deviation = distanceFromSegment(isolated.coordinate,
                                            before.coordinate, after.coordinate)
        let baseline = max(1, p[1].derivedSpeed, p[4].derivedSpeed,
                           speed(before, after))
        let spikeSpeed = max(speed(before, isolated), speed(isolated, after))
        let speedBreak = spikeSpeed > max(baseline * c.speedContinuityRatio,
                                         baseline + c.speedContinuityDelta)
        let neighborAccuracy = max(before.horizontalAccuracy, after.horizontalAccuracy)
        let accuracyConcern = isolated.horizontalAccuracy
            >= neighborAccuracy + c.accuracyDegradationTolerance
        let evidence = evidenceConfidence(
            detour: detour, threshold: c.minimumTriDetourRatio,
            deviation: deviation, minimumDeviation: c.isolatedPointDeviation,
            speedBreak: speedBreak,
            trustConcern: accuracyConcern || detour >= c.extremeDetourRatio)
        return deviation >= c.isolatedPointDeviation
            && detour >= c.minimumTriDetourRatio
            && speedBreak
            && (accuracyConcern || detour >= c.extremeDetourRatio)
            && evidence >= c.minimumEvidenceConfidence
    }

    private func isRedundant(_ p: [TrackCandidate],
                             configuration c: PostFilterConfiguration) -> Bool {
        let a = p[0], b = p[1], next = p[2]
        let preservesShape = distanceFromSegment(b.coordinate,
                                                 a.coordinate, next.coordinate)
            <= c.redundantDistance
        let close = distance(a, b) <= c.redundantDistance
            && distance(b, next) <= c.redundantDistance
        let slow = max(b.derivedSpeed, next.derivedSpeed)
            <= c.redundantMaximumSpeed
        return preservesShape && close && slow && b.motionState != .moving
    }

    private func evidenceConfidence(detour: Double, threshold: Double,
                                    deviation: Double, minimumDeviation: Double,
                                    speedBreak: Bool, trustConcern: Bool) -> Double {
        let geometry = min(1, max(0, detour / max(threshold, 0.1) - 0.5))
        let offset = min(1, deviation / max(minimumDeviation, 1))
        return 0.35 * geometry + 0.25 * offset
            + (speedBreak ? 0.20 : 0) + (trustConcern ? 0.20 : 0)
    }

    private func distance(_ lhs: TrackCandidate, _ rhs: TrackCandidate) -> Double {
        GeoMath.distanceMeters(
            from: (lhs.coordinate.latitude, lhs.coordinate.longitude),
            to: (rhs.coordinate.latitude, rhs.coordinate.longitude))
    }

    private func speed(_ lhs: TrackCandidate, _ rhs: TrackCandidate) -> Double {
        let elapsed = rhs.timestamp.timeIntervalSince(lhs.timestamp)
        return elapsed > 0 ? distance(lhs, rhs) / elapsed : 0
    }

    private func distanceFromSegment(_ point: CLLocationCoordinate2D,
                                     _ start: CLLocationCoordinate2D,
                                     _ end: CLLocationCoordinate2D) -> Double {
        let latitudeScale = 111_000.0
        let longitudeScale = latitudeScale
            * cos(((start.latitude + end.latitude) / 2) * .pi / 180)
        let px = (point.longitude - start.longitude) * longitudeScale
        let py = (point.latitude - start.latitude) * latitudeScale
        let ex = (end.longitude - start.longitude) * longitudeScale
        let ey = (end.latitude - start.latitude) * latitudeScale
        let lengthSquared = ex * ex + ey * ey
        guard lengthSquared > 0 else { return hypot(px, py) }
        let t = min(1, max(0, (px * ex + py * ey) / lengthSquared))
        return hypot(px - ex * t, py - ey * t)
    }

    private func bearingDelta(from start: CLLocationCoordinate2D,
                              via middle: CLLocationCoordinate2D,
                              to end: CLLocationCoordinate2D) -> Double {
        func bearing(_ a: CLLocationCoordinate2D,
                     _ b: CLLocationCoordinate2D) -> Double {
            let y = sin((b.longitude - a.longitude) * .pi / 180)
                * cos(b.latitude * .pi / 180)
            let x = cos(a.latitude * .pi / 180)
                * sin(b.latitude * .pi / 180)
                - sin(a.latitude * .pi / 180)
                * cos(b.latitude * .pi / 180)
                * cos((b.longitude - a.longitude) * .pi / 180)
            return atan2(y, x) * 180 / .pi
        }
        let difference = abs(bearing(start, middle) - bearing(middle, end))
            .truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
