import XCTest
import CoreLocation
@testable import LifeFootprints

final class LocationPipelineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(seconds: TimeInterval = 0, northMeters: Double = 0,
                        eastMeters: Double = 0, accuracy: Double = 5,
                        speed: Double = -1,
                        source: LocationSampleSource = .standard) -> RawLocationSample {
        RawLocationSample(
            latitude: 31 + northMeters / 111_000,
            longitude: 121 + eastMeters / (111_000 * cos(31 * .pi / 180)),
            timestamp: base.addingTimeInterval(seconds), speed: speed,
            horizontalAccuracy: accuracy, source: source)
    }

    private func candidate(seconds: TimeInterval, northMeters: Double = 0,
                           eastMeters: Double, accuracy: Double = 5,
                           derivedSpeed: Double = 1,
                           motion: MotionState = .moving) -> TrackCandidate {
        let raw = sample(seconds: seconds, northMeters: northMeters,
                         eastMeters: eastMeters, accuracy: accuracy)
        return TrackCandidate(
            coordinate: raw.coordinate, timestamp: raw.timestamp,
            horizontalAccuracy: accuracy, altitude: 0,
            systemSpeed: -1, derivedSpeed: derivedSpeed,
            acceleration: nil, course: -1, source: .standard,
            motionState: motion, realtimeConfidence: 0.9)
    }

    private func correct(_ candidates: [TrackCandidate],
                         configuration: PostFilterConfiguration = .init())
        -> (finalized: [FinalizedTrackPoint], removed: [RemovedCandidate]) {
        let corrector = TrackWindowCorrector()
        var finalized: [FinalizedTrackPoint] = []
        var removed: [RemovedCandidate] = []
        for candidate in candidates {
            let output = corrector.push(candidate, configuration: configuration)
            finalized += output.finalizedPoints
            removed += output.removedCandidates
        }
        finalized += corrector.flush()
        return (finalized, removed)
    }

    func testQualityGateRejectsPoorAccuracy() {
        var gate = LocationQualityGate()
        let decision = gate.evaluate(sample(accuracy: 180), now: base,
                                     maximumAccuracy: 100, maximumAge: 120,
                                     futureTolerance: 5)
        XCTAssertEqual(decision, .reject(.poorAccuracy))
    }

    func testQualityGateRejectsOutOfOrderSample() {
        var gate = LocationQualityGate()
        XCTAssertEqual(gate.evaluate(sample(seconds: 10),
                                     now: base.addingTimeInterval(10),
                                     maximumAccuracy: 100, maximumAge: 120,
                                     futureTolerance: 5),
                       .accept(sample(seconds: 10)))
        XCTAssertEqual(gate.evaluate(sample(seconds: 9),
                                     now: base.addingTimeInterval(10),
                                     maximumAccuracy: 100, maximumAge: 120,
                                     futureTolerance: 5), .reject(.outOfOrder))
    }

    func testRealtimeSpikeRemainsCandidateUntilPostFilterHasContext() {
        var filter = TrackPointFilter()
        let motion = MotionObservation(state: .moving, centerLatitude: 31,
                                       centerLongitude: 121, dynamicRadius: 12)
        guard case .candidate = filter.evaluate(
            sample(), motion: motion, configuration: .init()) else {
            return XCTFail("首点应成为 Candidate")
        }
        guard case .candidate = filter.evaluate(
            sample(seconds: 10, northMeters: 900, eastMeters: 500),
            motion: motion, configuration: .init()) else {
            return XCTFail("非极端 spike 应留给窗口纠错，不能实时武断删除")
        }
    }

    func testSparseLocationsRemainCandidatesButStartNewSegments() {
        for source: LocationSampleSource in [.standard, .significantChange, .visit] {
            var filter = TrackPointFilter()
            let motion = MotionObservation(state: .moving, centerLatitude: 31,
                                           centerLongitude: 121, dynamicRadius: 12)
            _ = filter.evaluate(sample(source: source), motion: motion, configuration: .init())
            let result = filter.evaluate(sample(seconds: 120, northMeters: 1_000, source: source),
                                         motion: motion, configuration: .init())
            guard case let .newSegmentCandidate(point, reason) = result else {
                XCTFail("Sparse location must remain as a new segment: \(source)")
                continue
            }
            XCTAssertEqual(reason, .insufficientConnectionEvidence)
            XCTAssertEqual(point.coordinate.latitude, 31 + 1_000 / 111_000.0, accuracy: 0.0000001)
        }
    }

    func testTriSpikeIsRemovedWithoutFabricatingCoordinate() {
        let points = [
            candidate(seconds: 0, eastMeters: 0),
            candidate(seconds: 10, northMeters: 900, eastMeters: 500,
                      derivedSpeed: 100),
            candidate(seconds: 20, eastMeters: 20),
            candidate(seconds: 30, eastMeters: 30),
            candidate(seconds: 40, eastMeters: 40),
        ]
        let result = correct(points)
        XCTAssertEqual(result.removed,
                       [RemovedCandidate(candidateID: points[1].id, reason: .triSpike)])
        XCTAssertEqual(result.finalized.map(\.candidateID),
                       [points[0], points[2], points[3], points[4]].map(\.id))
    }

    func testQuadSpikeRemovesTwoPointExcursion() {
        let points = [
            candidate(seconds: 0, eastMeters: 0),
            candidate(seconds: 10, northMeters: 600, eastMeters: 500,
                      accuracy: 35, derivedSpeed: 80),
            candidate(seconds: 20, northMeters: 600, eastMeters: 520,
                      accuracy: 35, derivedSpeed: 2),
            candidate(seconds: 30, eastMeters: 30),
            candidate(seconds: 40, eastMeters: 40),
        ]
        let result = correct(points)
        XCTAssertEqual(result.removed.map(\.reason), [.quadSpike, .quadSpike])
        XCTAssertEqual(result.removed.map(\.candidateID), [points[1].id, points[2].id])
        XCTAssertEqual(result.finalized.map(\.candidateID),
                       [points[0], points[3], points[4]].map(\.id))
    }

    func testIsolatedPointRequiresTwoSidedEvidence() {
        let points = [
            candidate(seconds: 0, eastMeters: 0),
            candidate(seconds: 10, eastMeters: 10),
            candidate(seconds: 20, northMeters: 800, eastMeters: 500,
                      accuracy: 40, derivedSpeed: 90),
            candidate(seconds: 30, eastMeters: 30),
            candidate(seconds: 40, eastMeters: 40),
        ]
        let result = correct(points)
        XCTAssertEqual(result.removed,
                       [RemovedCandidate(candidateID: points[2].id, reason: .isolated)])
    }

    func testRedundantSlowPointIsRemovedButTailTimeIsKept() {
        let points = stride(from: 0, through: 8, by: 2).enumerated().map { index, east in
            candidate(seconds: Double(index) * 5, eastMeters: Double(east),
                      derivedSpeed: 0.4, motion: .unknown)
        }
        let result = correct(points)
        XCTAssertTrue(result.removed.contains {
            $0.candidateID == points[1].id && $0.reason == .redundant
        })
        XCTAssertEqual(result.finalized.last?.timestamp, points.last?.timestamp)
    }

    func testRealRightAngleTurnIsKept() {
        let points = [
            candidate(seconds: 0, eastMeters: 0),
            candidate(seconds: 10, eastMeters: 20),
            candidate(seconds: 20, northMeters: 20, eastMeters: 20),
            candidate(seconds: 30, northMeters: 40, eastMeters: 20),
            candidate(seconds: 40, northMeters: 60, eastMeters: 20),
        ]
        let result = correct(points)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.finalized.map(\.candidateID), points.map(\.id))
    }

    func testRealUTurnIsKept() {
        let points = [
            candidate(seconds: 0, eastMeters: 0, derivedSpeed: 10),
            candidate(seconds: 10, eastMeters: 100, derivedSpeed: 10),
            candidate(seconds: 20, eastMeters: 0, derivedSpeed: 10),
            candidate(seconds: 30, eastMeters: -100, derivedSpeed: 10),
            candidate(seconds: 40, eastMeters: -200, derivedSpeed: 10),
        ]
        let result = correct(points)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.finalized.map(\.candidateID), points.map(\.id))
    }

    func testContinuousHighSpeedIsCandidateAndFinalized() {
        var filter = TrackPointFilter()
        let motion = MotionObservation(state: .moving, centerLatitude: 31,
                                       centerLongitude: 121, dynamicRadius: 12)
        var candidates: [TrackCandidate] = []
        for index in 0..<5 {
            let decision = filter.evaluate(
                sample(seconds: Double(index * 10), eastMeters: Double(index * 600),
                       speed: 60), motion: motion, configuration: .init())
            guard case .candidate(let point) = decision else {
                return XCTFail("连续高速不应按绝对速度拒绝")
            }
            candidates.append(point)
        }
        let result = correct(candidates)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.finalized.count, 5)
    }

    func testStationaryJitterIsSuppressed() {
        var pipeline = CoreLocationPipeline()
        _ = pipeline.process(sample(), now: base,
                             wantsDisplay: false, wantsTrack: true)
        _ = pipeline.process(sample(seconds: 20, eastMeters: 1.2),
                             now: base.addingTimeInterval(20),
                             wantsDisplay: false, wantsTrack: true)
        let output = pipeline.process(sample(seconds: 50, eastMeters: 1.8),
                                      now: base.addingTimeInterval(50),
                                      wantsDisplay: false, wantsTrack: true)
        XCTAssertEqual(output.trackMotion?.state, .stationary)
        XCTAssertEqual(output.realtimeDecision, .reject(.stationaryJitter))
        XCTAssertEqual(pipeline.metrics.candidateCount, 1)
        XCTAssertGreaterThan(pipeline.metrics.realtimeRejectedCount, 0)
    }

    func testDisplayLocationConsumesConfirmedStationaryState() {
        var filter = DisplayLocationFilter()
        let config = LocationFilterConfiguration()
        let first = filter.evaluate(sample(), configuration: config)
        let stationary = MotionObservation(
            state: .stationary, centerLatitude: first.latitude,
            centerLongitude: first.longitude, dynamicRadius: 15)
        let locked = filter.evaluate(sample(seconds: 45, eastMeters: 3),
                                     motion: stationary, configuration: config)
        let stillLocked = filter.evaluate(sample(seconds: 50, eastMeters: -4),
                                          motion: stationary, configuration: config)
        XCTAssertEqual(filter.lastDecision, .stationaryLock)
        XCTAssertEqual(locked.latitude, first.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(stillLocked.longitude, first.longitude, accuracy: 0.000_000_1)
    }

    func testStationaryCenterRequiresSeveralSamplesToUnlock() {
        var detector = MotionStateDetector()
        let config = LocationFilterConfiguration()
        _ = detector.observe(sample(), configuration: config)
        _ = detector.observe(sample(seconds: 20, eastMeters: 1), configuration: config)
        XCTAssertEqual(detector.observe(sample(seconds: 45, eastMeters: 2),
                                        configuration: config).state, .stationary)
        XCTAssertEqual(detector.observe(sample(seconds: 46, eastMeters: 35),
                                        configuration: config).state, .stationary)
        XCTAssertEqual(detector.observe(sample(seconds: 47, eastMeters: 36),
                                        configuration: config).state, .stationary)
        XCTAssertEqual(detector.observe(sample(seconds: 48, eastMeters: 37),
                                        configuration: config).state, .moving)
    }

    func testGPSGapFlushesOldTailAndStartsCleanWindow() {
        var pipeline = CoreLocationPipeline()
        let first = pipeline.process(sample(), now: base,
                                     wantsDisplay: false, wantsTrack: true)
        let second = pipeline.process(
            sample(seconds: 10, eastMeters: 20),
            now: base.addingTimeInterval(10),
            wantsDisplay: false, wantsTrack: true)
        XCTAssertTrue(first.finalizedTrackPoints.isEmpty)
        XCTAssertTrue(second.finalizedTrackPoints.isEmpty)

        let gap = pipeline.process(
            sample(seconds: 6 * 60, eastMeters: 30),
            now: base.addingTimeInterval(6 * 60),
            wantsDisplay: false, wantsTrack: true)
        XCTAssertEqual(gap.segmentBreakReason, .timeGap)
        XCTAssertEqual(gap.finalizedTrackPoints.count, 2)
        XCTAssertEqual(pipeline.flushTrack().count, 1,
                       "新 Segment 的 Candidate 应在独立窗口内")
    }

    func testFlushKeepsIncompleteWindowTail() {
        let corrector = TrackWindowCorrector()
        let points = [
            candidate(seconds: 0, eastMeters: 0),
            candidate(seconds: 10, eastMeters: 10),
            candidate(seconds: 20, eastMeters: 20),
        ]
        for point in points {
            XCTAssertEqual(corrector.push(point, configuration: .init()), .pending)
        }
        XCTAssertEqual(corrector.flush().map(\.candidateID), points.map(\.id))
    }

    func testDisplayAndTrackQualityAreIndependent() {
        var pipeline = CoreLocationPipeline()
        var config = LocationFilterConfiguration()
        config.displayMaxAccuracy = 150
        config.trackMaxAccuracy = 50
        let output = pipeline.process(sample(accuracy: 80), now: base,
                                      wantsDisplay: true, wantsTrack: true,
                                      configuration: config)
        XCTAssertNotNil(output.displayLocation)
        XCTAssertNil(output.realtimeDecision)
        XCTAssertEqual(output.trackQualityRejection, .poorAccuracy)
    }

    func testSignificantChangeStartsBoundedPrecisionConfirmation() {
        var policy = BackgroundTrackingPolicy()
        let initial = policy.observe(source: .significantChange, motion: .unknown,
                                     now: base, appIsActive: false)
        XCTAssertEqual(initial.state, .confirmingMovement)
        XCTAssertTrue(initial.wantsStandardUpdates)
        let expired = policy.observe(source: .standard, motion: .stationary,
                                     now: base.addingTimeInterval(121),
                                     appIsActive: false)
        XCTAssertEqual(expired.state, .stationary)
        XCTAssertFalse(expired.wantsStandardUpdates)
    }

    func testRecorderOnlyConvertsFinalizedPointsAndPreservesBoundaries() {
        var recorder = AutomaticTrajectoryRecorder()
        func finalized(_ raw: RawLocationSample) -> FinalizedTrackPoint {
            FinalizedTrackPoint(
                candidateID: UUID(), coordinate: raw.coordinate,
                timestamp: raw.timestamp, horizontalAccuracy: raw.horizontalAccuracy,
                altitude: raw.altitude, derivedSpeed: 2, course: raw.course,
                source: raw.source, motionState: .moving, finalConfidence: 0.9)
        }
        let firstDraft = recorder.draft(for: finalized(sample()))
        recorder.beginNewSegment(.unreliableGap)
        let secondDraft = recorder.draft(
            for: finalized(sample(seconds: 10, eastMeters: 20)))

        XCTAssertEqual(firstDraft.sessionID, secondDraft.sessionID)
        XCTAssertNotEqual(firstDraft.segmentID, secondDraft.segmentID)
        XCTAssertEqual(firstDraft.trajectoryID, secondDraft.trajectoryID)
        XCTAssertNotNil(firstDraft.horizontalAccuracy)
    }
}
