import Foundation
import CoreLocation

public enum TrackRejectReason: String, CaseIterable, Sendable {
    case duplicate
    case stationaryJitter
    case obviousTeleport
    case accelerationDiscontinuity
}

public enum TrackSegmentBreakReason: String, CaseIterable, Sendable {
    case timeGap, distanceGap, unreliableGap, sessionBoundary, sourceBoundary, locationRestart
    case insufficientConnectionEvidence
}

/// Realtime filter 认为“值得继续观察”的点。它只存在短窗口内，不能直接入库。
public struct TrackCandidate: Equatable, Sendable {
    public let id: UUID
    public let coordinate: CLLocationCoordinate2D
    public let timestamp: Date
    public let horizontalAccuracy: Double
    public let altitude: Double
    public let systemSpeed: Double
    public let derivedSpeed: Double
    public let acceleration: Double?
    public let course: Double
    public let source: LocationSampleSource
    public let motionState: MotionState
    public let realtimeConfidence: Double

    public init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D,
                timestamp: Date, horizontalAccuracy: Double, altitude: Double,
                systemSpeed: Double, derivedSpeed: Double,
                acceleration: Double?, course: Double,
                source: LocationSampleSource, motionState: MotionState,
                realtimeConfidence: Double) {
        self.id = id
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.systemSpeed = systemSpeed
        self.derivedSpeed = derivedSpeed
        self.acceleration = acceleration
        self.course = course
        self.source = source
        self.motionState = motionState
        self.realtimeConfidence = realtimeConfidence
    }

    public static func == (lhs: TrackCandidate, rhs: TrackCandidate) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.timestamp == rhs.timestamp
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy
            && lhs.altitude == rhs.altitude
            && lhs.systemSpeed == rhs.systemSpeed
            && lhs.derivedSpeed == rhs.derivedSpeed
            && lhs.acceleration == rhs.acceleration
            && lhs.course == rhs.course
            && lhs.source == rhs.source
            && lhs.motionState == rhs.motionState
            && lhs.realtimeConfidence == rhs.realtimeConfidence
    }
}

public enum RealtimeTrackDecision: Equatable, Sendable {
    case reject(TrackRejectReason)
    case candidate(TrackCandidate)
    case newSegmentCandidate(TrackCandidate, TrackSegmentBreakReason)
}

/// 实时层只回答“这个点是否值得继续观察”。
/// 高速本身永远不是拒绝理由；非极端 spike 留给 TrackWindowCorrector。
public struct TrackPointFilter: Sendable {
    private var lastCandidate: TrackCandidate?
    public init() {}

    public mutating func reset() { lastCandidate = nil }

    public mutating func evaluate(_ sample: RawLocationSample, motion: MotionObservation,
                                  configuration: LocationFilterConfiguration)
        -> RealtimeTrackDecision {
        guard let previous = lastCandidate else {
            let candidate = makeCandidate(sample, previous: nil, motion: motion)
            lastCandidate = candidate
            return .candidate(candidate)
        }

        let elapsed = sample.timestamp.timeIntervalSince(previous.timestamp)
        let distance = GeoMath.distanceMeters(
            from: (previous.coordinate.latitude, previous.coordinate.longitude),
            to: (sample.latitude, sample.longitude))
        let derivedSpeed = elapsed > 0 ? distance / elapsed : 0
        let acceleration = elapsed > 0
            ? (derivedSpeed - previous.derivedSpeed) / elapsed : nil
        let candidate = makeCandidate(sample, previous: previous, motion: motion,
                                      derivedSpeed: derivedSpeed,
                                      acceleration: acceleration)

        if sample.source != previous.source {
            lastCandidate = candidate
            return .newSegmentCandidate(candidate, .sourceBoundary)
        }
        if elapsed > configuration.automaticSessionGap {
            lastCandidate = candidate
            return .newSegmentCandidate(candidate, .sessionBoundary)
        }
        let gap = configuration.gapProfile(for: sample.source)
        if elapsed > gap.maximumTimeGap {
            lastCandidate = candidate
            let unreliable = max(sample.horizontalAccuracy,
                                 previous.horizontalAccuracy)
                >= configuration.unreliableAccuracy
            return .newSegmentCandidate(candidate,
                                        unreliable ? .unreliableGap : .timeGap)
        }
        if distance > gap.maximumDistanceGap {
            lastCandidate = candidate
            return .newSegmentCandidate(candidate, .distanceGap)
        }
        if distance < configuration.duplicateDistance {
            return .reject(.duplicate)
        }

        let centerDistance = GeoMath.distanceMeters(
            from: (motion.centerLatitude, motion.centerLongitude),
            to: (sample.latitude, sample.longitude))
        if motion.state == .stationary,
           centerDistance <= min(configuration.stationaryMaximumRadius,
                                 max(configuration.stationaryMinimumRadius,
                                     motion.dynamicRadius)) {
            return .reject(.stationaryJitter)
        }
        if distance < configuration.minimumTrackDistance,
           motion.state != .moving {
            return .reject(.stationaryJitter)
        }

        let accelerationBreak = acceleration.map {
            $0 > configuration.maxPositiveAcceleration
                || $0 < -configuration.maxNegativeAcceleration
        } ?? false
        if distance >= configuration.obviousTeleportMinimumDistance,
           elapsed <= configuration.obviousTeleportMaximumInterval,
           sample.horizontalAccuracy >= configuration.obviousTeleportMinimumAccuracy,
           accelerationBreak {
            return .reject(.obviousTeleport)
        }
        if distance >= configuration.teleportMinimumDistance,
           sample.horizontalAccuracy >= configuration.unreliableAccuracy,
           accelerationBreak,
           elapsed <= 1 {
            return .reject(.accelerationDiscontinuity)
        }

        if !TrackConnectionPolicy.permitsConnection(
            source: sample.source, elapsed: elapsed, distance: distance) {
            lastCandidate = candidate
            return .newSegmentCandidate(candidate, .insufficientConnectionEvidence)
        }
        lastCandidate = candidate
        return .candidate(candidate)
    }

    private func makeCandidate(_ sample: RawLocationSample,
                               previous: TrackCandidate?,
                               motion: MotionObservation,
                               derivedSpeed suppliedSpeed: Double? = nil,
                               acceleration: Double? = nil) -> TrackCandidate {
        let elapsed = previous.map { sample.timestamp.timeIntervalSince($0.timestamp) } ?? 0
        let distance = previous.map {
            GeoMath.distanceMeters(
                from: ($0.coordinate.latitude, $0.coordinate.longitude),
                to: (sample.latitude, sample.longitude))
        } ?? 0
        let derivedSpeed = suppliedSpeed ?? (elapsed > 0 ? distance / elapsed : 0)
        let accuracyScore = max(0, min(1,
            1 - sample.horizontalAccuracy / 100))
        let accelerationMagnitude = acceleration.map(abs) ?? 0
        let continuityPenalty = min(0.35, accelerationMagnitude / 100)
        return TrackCandidate(
            coordinate: sample.coordinate, timestamp: sample.timestamp,
            horizontalAccuracy: sample.horizontalAccuracy, altitude: sample.altitude,
            systemSpeed: sample.systemSpeed, derivedSpeed: derivedSpeed,
            acceleration: acceleration, course: sample.course,
            source: sample.source, motionState: motion.state,
            realtimeConfidence: max(0.05, accuracyScore - continuityPenalty))
    }
}
