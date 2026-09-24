import Foundation
import CoreLocation

public enum LocationSampleSource: String, Codable, Hashable, Sendable {
    case standard
    case significantChange
    case visit
}

/// Core Location 回调的短生命周期值投影。原始样本只在流水线内流动，不持久化。
public struct RawLocationSample: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let altitude: Double
    public let verticalAccuracy: Double
    public let speed: Double
    public let course: Double
    public let horizontalAccuracy: Double
    public let source: LocationSampleSource
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    public var systemSpeed: Double { speed }

    public init(latitude: Double, longitude: Double, timestamp: Date,
                altitude: Double = 0, speed: Double = -1, course: Double = -1,
                horizontalAccuracy: Double, verticalAccuracy: Double = -1,
                source: LocationSampleSource) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.source = source
    }

    public init(_ location: CLLocation, source: LocationSampleSource) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  timestamp: location.timestamp, altitude: location.altitude,
                  speed: location.speed, course: location.course,
                  horizontalAccuracy: location.horizontalAccuracy,
                  verticalAccuracy: location.verticalAccuracy, source: source)
    }
}

public struct SegmentGapProfile: Equatable, Sendable {
    public var maximumTimeGap: TimeInterval
    public var maximumDistanceGap: Double
    public init(maximumTimeGap: TimeInterval, maximumDistanceGap: Double) {
        self.maximumTimeGap = maximumTimeGap
        self.maximumDistanceGap = maximumDistanceGap
    }
}

public struct PostFilterConfiguration: Equatable, Sendable {
    public var windowPointCount: Int = 5
    public var windowMaxDuration: TimeInterval = 3 * 60
    public var triSpikeEnabled = true
    public var quadSpikeEnabled = true
    public var isolatedPointEnabled = true
    public var redundantPointEnabled = true
    public var maxAccuracyForAngleAnalysis: Double = 80
    public var minimumEvidenceConfidence: Double = 0.72
    public var minimumSpikeDeviation: Double = 45
    public var isolatedPointDeviation: Double = 70
    public var minimumTriDetourRatio: Double = 2.8
    public var minimumQuadDetourRatio: Double = 3.4
    public var extremeDetourRatio: Double = 7
    public var speedContinuityRatio: Double = 3.2
    public var speedContinuityDelta: Double = 12
    public var accuracyDegradationTolerance: Double = 10
    public var redundantDistance: Double = 6
    public var redundantMaximumSpeed: Double = 1.8

    public init() {}
}

/// 所有定位阈值的单一入口。产品调参不再散落在 delegate、地图和过滤器中。
public struct LocationFilterConfiguration: Equatable, Sendable {
    public var displayMaxAccuracy: Double = 150
    public var trackMaxAccuracy: Double = 100
    public var maximumDisplayAge: TimeInterval = 120
    public var maximumTrackAge: TimeInterval = 15 * 60
    public var futureTimestampTolerance: TimeInterval = 5
    public var stationaryEntryDuration: TimeInterval = 40
    public var stationaryEntryBaseRadius: Double = 12
    public var stationaryAccuracyCap: Double = 35
    public var stationaryExitBaseRadius: Double = 24
    public var stationaryMinimumRadius: Double = 8
    public var stationaryMaximumRadius: Double = 35
    public var stationaryAccuracyWeight: Double = 0.35
    public var stationaryRecentPointCount: Int = 16
    public var stationaryRecentDuration: TimeInterval = 75
    public var movingMinimumStepDistance: Double = 8
    public var movingMinimumDerivedSpeed: Double = 0.8
    public var movementConfirmationCount: Int = 3
    public var displaySmoothingStrength: Double = 0.38
    public var minimumTrackDistance: Double = 3
    public var duplicateDistance: Double = 0.8
    public var maxPositiveAcceleration: Double = 12
    public var maxNegativeAcceleration: Double = 18
    public var teleportMinimumDistance: Double = 120
    public var teleportReturnRadius: Double = 60
    public var unreliableAccuracy: Double = 65
    public var obviousTeleportMinimumDistance: Double = 5_000
    public var obviousTeleportMaximumInterval: TimeInterval = 20
    public var obviousTeleportMinimumAccuracy: Double = 55
    public var segmentGapProfiles: [LocationSampleSource: SegmentGapProfile] = [
        .standard: .init(maximumTimeGap: 5 * 60, maximumDistanceGap: 5_000),
        .significantChange: .init(maximumTimeGap: 45 * 60,
                                  maximumDistanceGap: 75_000),
        .visit: .init(maximumTimeGap: 12 * 60 * 60, maximumDistanceGap: 250_000),
    ]
    public var automaticSessionGap: TimeInterval = 6 * 60 * 60
    public var batchSize: Int = 20
    public var batchMaxDuration: TimeInterval = 60
    public var postFilter = PostFilterConfiguration()
    public init() {}

    public func gapProfile(for source: LocationSampleSource) -> SegmentGapProfile {
        segmentGapProfiles[source]
            ?? .init(maximumTimeGap: 5 * 60, maximumDistanceGap: 5_000)
    }

    public func dynamicStationaryRadius(horizontalAccuracy: Double) -> Double {
        let accuracy = min(stationaryAccuracyCap, max(0, horizontalAccuracy))
        return min(stationaryMaximumRadius,
                   max(stationaryMinimumRadius,
                       stationaryEntryBaseRadius + accuracy * stationaryAccuracyWeight))
    }
}

public enum LocationQualityRejectionReason: String, CaseIterable, Sendable {
    case invalidCoordinate, invalidAccuracy, poorAccuracy
    case staleTimestamp, futureTimestamp, outOfOrder
}

public enum LocationQualityDecision: Equatable, Sendable {
    case accept(RawLocationSample)
    case reject(LocationQualityRejectionReason)
}

public struct LocationQualityGate: Sendable {
    private var lastAcceptedTimestamp: Date?
    public init() {}
    public mutating func reset() { lastAcceptedTimestamp = nil }

    public mutating func evaluate(_ sample: RawLocationSample, now: Date,
                                  maximumAccuracy: Double, maximumAge: TimeInterval,
                                  futureTolerance: TimeInterval) -> LocationQualityDecision {
        guard GeoMath.isValid(latitude: sample.latitude, longitude: sample.longitude) else {
            return .reject(.invalidCoordinate)
        }
        guard sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0 else {
            return .reject(.invalidAccuracy)
        }
        guard sample.horizontalAccuracy <= maximumAccuracy else { return .reject(.poorAccuracy) }
        let age = now.timeIntervalSince(sample.timestamp)
        guard age <= maximumAge else { return .reject(.staleTimestamp) }
        guard age >= -futureTolerance else { return .reject(.futureTimestamp) }
        if let lastAcceptedTimestamp, sample.timestamp <= lastAcceptedTimestamp {
            return .reject(.outOfOrder)
        }
        lastAcceptedTimestamp = sample.timestamp
        return .accept(sample)
    }
}

public enum MotionState: String, Sendable { case unknown, moving, stationary }

public struct StationaryState: Equatable, Sendable {
    public let center: CLLocationCoordinate2D
    public let enteredAt: Date
    public let radius: Double
    public let confidence: Double

    public init(center: CLLocationCoordinate2D, enteredAt: Date,
                radius: Double, confidence: Double) {
        self.center = center
        self.enteredAt = enteredAt
        self.radius = radius
        self.confidence = confidence
    }

    public static func == (lhs: StationaryState, rhs: StationaryState) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.enteredAt == rhs.enteredAt
            && lhs.radius == rhs.radius
            && lhs.confidence == rhs.confidence
    }
}

public struct MotionObservation: Equatable, Sendable {
    public let state: MotionState
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let dynamicRadius: Double
    public let stationaryState: StationaryState?

    public init(state: MotionState, centerLatitude: Double, centerLongitude: Double,
                dynamicRadius: Double, stationaryState: StationaryState? = nil) {
        self.state = state
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.dynamicRadius = dynamicRadius
        self.stationaryState = stationaryState
    }
}

/// 用连续样本确认移动/静止；单个远点不会解锁静止中心。
public struct MotionStateDetector: Sendable {
    private var state: MotionState = .unknown
    private var recentSamples: [RawLocationSample] = []
    private var stationaryState: StationaryState?
    private var outsideCount = 0
    private var movingEvidenceCount = 0
    public init() {}

    public mutating func reset() {
        state = .unknown
        recentSamples.removeAll(keepingCapacity: true)
        stationaryState = nil
        outsideCount = 0
        movingEvidenceCount = 0
    }

    public mutating func observe(_ sample: RawLocationSample,
                                 configuration: LocationFilterConfiguration) -> MotionObservation {
        let previous = recentSamples.last
        recentSamples.append(sample)
        let oldestAllowed = sample.timestamp.addingTimeInterval(
            -configuration.stationaryRecentDuration)
        recentSamples.removeAll { $0.timestamp < oldestAllowed }
        if recentSamples.count > configuration.stationaryRecentPointCount {
            recentSamples.removeFirst(recentSamples.count
                                      - configuration.stationaryRecentPointCount)
        }

        if let locked = stationaryState {
            let distance = GeoMath.distanceMeters(
                from: (locked.center.latitude, locked.center.longitude),
                to: (sample.latitude, sample.longitude))
            let exitRadius = max(configuration.stationaryExitBaseRadius,
                                 locked.radius * 1.4)
            if distance > exitRadius { outsideCount += 1 } else { outsideCount = 0 }
            if outsideCount >= max(2, configuration.movementConfirmationCount) {
                state = .moving
                stationaryState = nil
                outsideCount = 0
                movingEvidenceCount = 0
                recentSamples = [sample]
            } else {
                state = .stationary
                return observation(center: locked.center, radius: locked.radius)
            }
        }

        let centerResult = robustCenter(configuration: configuration)
        let radius = configuration.dynamicStationaryRadius(
            horizontalAccuracy: centerResult.meanAccuracy)
        let spread = recentSamples.map {
            GeoMath.distanceMeters(
                from: (centerResult.coordinate.latitude, centerResult.coordinate.longitude),
                to: ($0.latitude, $0.longitude))
        }.max() ?? 0
        let duration = (recentSamples.last?.timestamp.timeIntervalSince(
            recentSamples.first?.timestamp ?? sample.timestamp)) ?? 0

        if duration >= configuration.stationaryEntryDuration,
           spread <= radius,
           recentSamples.count >= max(3, configuration.movementConfirmationCount) {
            let confidence = min(1, max(0,
                (Double(recentSamples.count) / Double(configuration.stationaryRecentPointCount))
                * 0.45 + (1 - spread / max(radius, 1)) * 0.55))
            let locked = StationaryState(
                center: centerResult.coordinate, enteredAt: sample.timestamp,
                radius: radius, confidence: confidence)
            stationaryState = locked
            state = .stationary
            outsideCount = 0
            movingEvidenceCount = 0
            return observation(center: locked.center, radius: locked.radius)
        }

        if let previous {
            let elapsed = sample.timestamp.timeIntervalSince(previous.timestamp)
            let step = GeoMath.distanceMeters(
                from: (previous.latitude, previous.longitude),
                to: (sample.latitude, sample.longitude))
            let speed = elapsed > 0 ? step / elapsed : 0
            let movingEvidence = step >= max(
                configuration.movingMinimumStepDistance,
                configuration.dynamicStationaryRadius(
                    horizontalAccuracy: max(previous.horizontalAccuracy,
                                            sample.horizontalAccuracy)))
                && speed >= configuration.movingMinimumDerivedSpeed
            movingEvidenceCount = movingEvidence ? movingEvidenceCount + 1 : 0
        }
        if movingEvidenceCount >= max(2, configuration.movementConfirmationCount) {
            state = .moving
        } else if state != .moving {
            state = .unknown
        }
        return observation(center: centerResult.coordinate, radius: radius)
    }

    private func observation(center: CLLocationCoordinate2D,
                             radius: Double) -> MotionObservation {
        .init(state: state, centerLatitude: center.latitude,
              centerLongitude: center.longitude, dynamicRadius: radius,
              stationaryState: stationaryState)
    }

    private func robustCenter(configuration: LocationFilterConfiguration)
        -> (coordinate: CLLocationCoordinate2D, meanAccuracy: Double) {
        guard !recentSamples.isEmpty else {
            return (.init(latitude: 0, longitude: 0),
                    configuration.stationaryMaximumRadius)
        }
        let sortedLatitudes = recentSamples.map(\.latitude).sorted()
        let sortedLongitudes = recentSamples.map(\.longitude).sorted()
        let middle = recentSamples.count / 2
        let median = CLLocationCoordinate2D(latitude: sortedLatitudes[middle],
                                            longitude: sortedLongitudes[middle])
        let inliers = recentSamples.filter { candidate in
            let distance = GeoMath.distanceMeters(
                from: (median.latitude, median.longitude),
                to: (candidate.latitude, candidate.longitude))
            let allowance = min(configuration.stationaryMaximumRadius,
                configuration.stationaryEntryBaseRadius
                    + max(0, candidate.horizontalAccuracy))
            return distance <= max(configuration.stationaryMinimumRadius, allowance)
        }
        let values = inliers.isEmpty ? recentSamples : inliers
        var latitude = 0.0
        var longitude = 0.0
        var totalWeight = 0.0
        var accuracy = 0.0
        for value in values {
            let weight = 1 / pow(max(1, value.horizontalAccuracy), 2)
            latitude += value.latitude * weight
            longitude += value.longitude * weight
            accuracy += value.horizontalAccuracy
            totalWeight += weight
        }
        return (.init(latitude: latitude / totalWeight,
                      longitude: longitude / totalWeight),
                accuracy / Double(values.count))
    }
}

public struct DisplayLocation: Equatable, Sendable {
    public let latitude: Double, longitude: Double
    public let timestamp: Date
    public let horizontalAccuracy: Double
    public let altitude: Double
}

public enum DisplayLocationProcessingDecision: String, Sendable {
    case initial
    case smoothedMoving
    case stationaryLock
}

/// 当前位置专用滤波器。它拥有独立状态，不会因为轨迹点被拒绝而冻结蓝点。
public struct DisplayLocationFilter: Sendable {
    private var displayed: DisplayLocation?
    private var stationarySince: Date?
    private var lockedCenter: DisplayLocation?
    private var outsideCount = 0
    public private(set) var lastDecision: DisplayLocationProcessingDecision = .initial
    public init() {}
    public mutating func reset() {
        displayed = nil; stationarySince = nil; lockedCenter = nil; outsideCount = 0
        lastDecision = .initial
    }

    public mutating func evaluate(_ sample: RawLocationSample,
                                  motion: MotionObservation? = nil,
                                  configuration: LocationFilterConfiguration) -> DisplayLocation {
        guard let previous = displayed else {
            let result = makeDisplay(sample); displayed = result
            stationarySince = sample.timestamp
            lastDecision = .initial
            return result
        }
        if motion?.state == .stationary {
            if lockedCenter == nil { lockedCenter = previous }
            lastDecision = .stationaryLock
            return lockedCenter ?? previous
        }
        if motion?.state == .moving { lockedCenter = nil }
        stationarySince = nil
        outsideCount = 0
        let accuracyFactor = max(0, min(1, 1 - sample.horizontalAccuracy
                                        / configuration.displayMaxAccuracy))
        let alpha = min(0.82, max(configuration.displaySmoothingStrength,
                                  configuration.displaySmoothingStrength + accuracyFactor * 0.32))
        let result = DisplayLocation(
            latitude: previous.latitude + (sample.latitude - previous.latitude) * alpha,
            longitude: previous.longitude + (sample.longitude - previous.longitude) * alpha,
            timestamp: sample.timestamp, horizontalAccuracy: sample.horizontalAccuracy,
            altitude: sample.altitude)
        displayed = result
        lastDecision = .smoothedMoving
        return result
    }

    private func makeDisplay(_ sample: RawLocationSample) -> DisplayLocation {
        .init(latitude: sample.latitude, longitude: sample.longitude,
              timestamp: sample.timestamp, horizontalAccuracy: sample.horizontalAccuracy,
              altitude: sample.altitude)
    }
}

public enum BackgroundTrackingState: String, Sendable {
    case lowPower, confirmingMovement, moving, stationary
}

public struct BackgroundSamplingDirective: Equatable, Sendable {
    public let state: BackgroundTrackingState
    public let wantsStandardUpdates: Bool
    public let desiredAccuracy: Double
    public let distanceFilter: Double
}

/// 只决定系统采样模式，不参与轨迹点质量判定。
public struct BackgroundTrackingPolicy: Sendable {
    private(set) var state: BackgroundTrackingState = .lowPower
    private var precisionBurstUntil: Date?
    public init() {}

    public mutating func observe(source: LocationSampleSource, motion: MotionState?, now: Date,
                                 appIsActive: Bool) -> BackgroundSamplingDirective {
        if source == .significantChange || source == .visit {
            state = .confirmingMovement; precisionBurstUntil = now.addingTimeInterval(120)
        } else if motion == .moving {
            state = .moving; precisionBurstUntil = nil
        } else if precisionBurstUntil.map({ $0 > now }) == true {
            state = .confirmingMovement
        } else if motion == .stationary {
            state = .stationary
        } else { state = .lowPower }
        // 开启后台记录后始终保留一条低功耗标准定位链路。visit 与
        // significant-change 仍用于系统终止后的唤醒，但不再是后台唯一数据源。
        let wantsStandard = true
        switch state {
        case .moving, .confirmingMovement:
            return .init(state: state, wantsStandardUpdates: wantsStandard,
                         desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 8)
        case .stationary:
            return .init(state: state, wantsStandardUpdates: wantsStandard,
                         desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 75)
        case .lowPower:
            return .init(state: state, wantsStandardUpdates: wantsStandard,
                         desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 100)
        }
    }
}

public struct LocationPipelineMetrics: Equatable, Sendable {
    public var rawSampleCount = 0
    public var qualityRejectedCount = 0
    public var displayAcceptedCount = 0
    public var displayRejectedCount = 0
    public var displayHeldCount = 0
    public var realtimeRejectedCount = 0
    public var candidateCount = 0
    public var postTriSpikeRemovedCount = 0
    public var postQuadSpikeRemovedCount = 0
    public var postIsolatedRemovedCount = 0
    public var postRedundantRemovedCount = 0
    public var finalizedCount = 0
    public var newSegmentCount = 0
    public var stationaryTransitionCount = 0
    public var movingTransitionCount = 0

    // 保留旧诊断字段的只读语义，避免破坏现有 DEBUG 工具。
    public var rawCount: Int { rawSampleCount }
    public var displayAccepted: Int { displayAcceptedCount }
    public var displayRejected: Int { displayRejectedCount }
    public var trackAccepted: Int { candidateCount }
    public var trackRejected: Int { realtimeRejectedCount + qualityRejectedCount }
    public var stationaryRejectedCount: Int { realtimeRejectedCount }
    public var teleportRejectedCount: Int { realtimeRejectedCount }
    public var motionStateTransitions: Int {
        stationaryTransitionCount + movingTransitionCount
    }
}

public struct LocationPipelineOutput: Equatable, Sendable {
    public let displayLocation: DisplayLocation?
    public let displayDecision: DisplayLocationProcessingDecision?
    public let displayRejection: LocationQualityRejectionReason?
    public let displayMotion: MotionObservation?
    public let realtimeDecision: RealtimeTrackDecision?
    public let trackQualityRejection: LocationQualityRejectionReason?
    public let trackMotion: MotionObservation?
    public let postFilterOutput: TrackCorrectionOutput?
    public let finalizedTrackPoints: [FinalizedTrackPoint]
    public let segmentBreakReason: TrackSegmentBreakReason?

    /// 后台采样策略优先使用 track motion，未开启记录时使用 display motion。
    public var motion: MotionObservation? { trackMotion ?? displayMotion }
}

/// 显示与历史轨迹从同一个 raw sample 分叉，各自拥有质量门与 motion 状态。
public struct CoreLocationPipeline: Sendable {
    private var displayGate = LocationQualityGate()
    private var trackGate = LocationQualityGate()
    private var displayFilter = DisplayLocationFilter()
    private var displayMotionDetector = MotionStateDetector()
    private var trackMotionDetector = MotionStateDetector()
    private var trackFilter = TrackPointFilter()
    private var corrector = TrackWindowCorrector()
    private var lastTrackMotionState: MotionState?
    public private(set) var metrics = LocationPipelineMetrics()
    public init() {}

    public mutating func reset() {
        displayGate.reset()
        trackGate.reset()
        displayFilter.reset()
        displayMotionDetector.reset()
        trackMotionDetector.reset()
        trackFilter.reset()
        corrector.resetForNewSegment()
        lastTrackMotionState = nil
        metrics = .init()
    }

    /// 结束一次记录会话：调用方必须先 `flushTrack()` 保留窗口尾部。
    public mutating func resetTrackState() {
        trackGate.reset()
        trackMotionDetector.reset()
        trackFilter.reset()
        corrector.resetForNewSegment()
        lastTrackMotionState = nil
    }

    /// 窗口尾部没有足够反证，全部升级为 Finalized KEEP。
    public mutating func flushTrack() -> [FinalizedTrackPoint] {
        let points = corrector.flush()
        metrics.finalizedCount += points.count
        return points
    }

    public mutating func process(_ sample: RawLocationSample, now: Date = Date(),
                                 wantsDisplay: Bool, wantsTrack: Bool,
                                 configuration: LocationFilterConfiguration = .init())
        -> LocationPipelineOutput {
        metrics.rawSampleCount += 1
        var display: DisplayLocation?
        var displayDecision: DisplayLocationProcessingDecision?
        var displayRejection: LocationQualityRejectionReason?
        var displayMotion: MotionObservation?
        if wantsDisplay {
            switch displayGate.evaluate(sample, now: now,
                maximumAccuracy: configuration.displayMaxAccuracy,
                maximumAge: configuration.maximumDisplayAge,
                futureTolerance: configuration.futureTimestampTolerance) {
            case .accept(let accepted):
                let observed = displayMotionDetector.observe(
                    accepted, configuration: configuration)
                displayMotion = observed
                display = displayFilter.evaluate(
                    accepted, motion: observed, configuration: configuration)
                displayDecision = displayFilter.lastDecision
                metrics.displayAcceptedCount += 1
                if displayDecision == .stationaryLock { metrics.displayHeldCount += 1 }
            case .reject(let reason):
                displayRejection = reason
                metrics.displayRejectedCount += 1
            }
        }

        var realtimeDecision: RealtimeTrackDecision?
        var trackRejection: LocationQualityRejectionReason?
        var trackMotion: MotionObservation?
        var postOutput: TrackCorrectionOutput?
        var finalized: [FinalizedTrackPoint] = []
        var segmentBreakReason: TrackSegmentBreakReason?
        if wantsTrack {
            switch trackGate.evaluate(sample, now: now,
                maximumAccuracy: configuration.trackMaxAccuracy,
                maximumAge: configuration.maximumTrackAge,
                futureTolerance: configuration.futureTimestampTolerance) {
            case .accept(let accepted):
                let observed = trackMotionDetector.observe(
                    accepted, configuration: configuration)
                trackMotion = observed
                registerMotionTransition(to: observed.state)
                let decision = trackFilter.evaluate(
                    accepted, motion: observed, configuration: configuration)
                realtimeDecision = decision
                switch decision {
                case .reject:
                    metrics.realtimeRejectedCount += 1
                case .candidate(let candidate):
                    metrics.candidateCount += 1
                    let correction = corrector.push(
                        candidate, configuration: configuration.postFilter)
                    postOutput = correction
                    finalized = correction.finalizedPoints
                    register(correction)
                case .newSegmentCandidate(let candidate, let reason):
                    metrics.candidateCount += 1
                    metrics.newSegmentCount += 1
                    // 先 KEEP 旧段尾部，再清窗口。新段 candidate 永远不与旧段比较。
                    let oldTail = corrector.flush()
                    corrector.resetForNewSegment()
                    let correction = corrector.push(
                        candidate, configuration: configuration.postFilter)
                    finalized = oldTail + correction.finalizedPoints
                    metrics.finalizedCount += oldTail.count
                    register(correction)
                    postOutput = combinedOutput(
                        finalized: finalized,
                        removed: correction.removedCandidates)
                    segmentBreakReason = reason
                }
            case .reject(let reason):
                trackRejection = reason
                metrics.qualityRejectedCount += 1
            }
        }
        return .init(
            displayLocation: display, displayDecision: displayDecision,
            displayRejection: displayRejection, displayMotion: displayMotion,
            realtimeDecision: realtimeDecision,
            trackQualityRejection: trackRejection, trackMotion: trackMotion,
            postFilterOutput: postOutput, finalizedTrackPoints: finalized,
            segmentBreakReason: segmentBreakReason)
    }

    private mutating func registerMotionTransition(to next: MotionState) {
        defer { lastTrackMotionState = next }
        guard let previous = lastTrackMotionState, previous != next else { return }
        if next == .stationary { metrics.stationaryTransitionCount += 1 }
        if next == .moving { metrics.movingTransitionCount += 1 }
    }

    private mutating func register(_ output: TrackCorrectionOutput) {
        metrics.finalizedCount += output.finalizedPoints.count
        for removed in output.removedCandidates {
            switch removed.reason {
            case .triSpike: metrics.postTriSpikeRemovedCount += 1
            case .quadSpike: metrics.postQuadSpikeRemovedCount += 1
            case .isolated: metrics.postIsolatedRemovedCount += 1
            case .redundant: metrics.postRedundantRemovedCount += 1
            case .futureSharpAngle: break
            }
        }
    }

    private func combinedOutput(finalized: [FinalizedTrackPoint],
                                removed: [RemovedCandidate])
        -> TrackCorrectionOutput {
        if finalized.isEmpty, removed.isEmpty { return .pending }
        if removed.isEmpty { return .finalized(finalized) }
        if finalized.isEmpty {
            let reason = removed.first?.reason ?? .futureSharpAngle
            return .removed(candidateIDs: removed.map(\.candidateID), reason: reason)
        }
        return .mixed(finalized: finalized, removed: removed)
    }
}

/// 为 Finalized Clean Point 生成并携带显式 session/segment 边界。
public struct AutomaticTrajectoryRecorder: Sendable {
    private var sessionID: String?
    private var segmentID: String?
    private var segmentIndex = 0
    private var pendingBoundary: TrackSegmentBreakReason?
    public init() {}

    public mutating func beginNewSegment(_ reason: TrackSegmentBreakReason) {
        pendingBoundary = reason
    }

    public mutating func markLocationRestart() { beginNewSegment(.locationRestart) }

    public mutating func reset() {
        sessionID = nil
        segmentID = nil
        segmentIndex = 0
        pendingBoundary = nil
    }

    public mutating func draft(for point: FinalizedTrackPoint) -> FootprintDraft {
        let startsSession = sessionID == nil
            || pendingBoundary == .sessionBoundary
            || pendingBoundary == .locationRestart
        if startsSession {
            let stamp = Int64((point.timestamp.timeIntervalSince1970 * 1_000).rounded())
            sessionID = "auto:\(stamp):\(UUID().uuidString.lowercased())"
            segmentIndex = 0
            segmentID = "\(sessionID!):segment:0"
        } else if pendingBoundary != nil {
            segmentIndex += 1
            segmentID = "\(sessionID!):segment:\(segmentIndex)"
        }
        pendingBoundary = nil
        let resolvedSessionID = sessionID!
        let resolvedSegmentID = segmentID!
        return FootprintDraft(
            latitude: point.coordinate.latitude,
            longitude: point.coordinate.longitude,
            timestamp: point.timestamp, source: FootprintSource.gps.rawValue,
            trajectoryID: "coreLocation:\(resolvedSessionID)",
            sessionID: resolvedSessionID, segmentID: resolvedSegmentID,
            altitude: point.altitude,
            horizontalAccuracy: point.horizontalAccuracy,
            speed: point.derivedSpeed,
            course: point.course >= 0 ? point.course : nil,
            sourceCoordinateSystem: .wgs84)
    }
}
