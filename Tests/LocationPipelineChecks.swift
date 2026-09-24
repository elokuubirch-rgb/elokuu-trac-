import Foundation
import CoreLogic

/// Replaces tests of removed traffic-mode/TrackSample APIs without weakening
/// quality guards. High speed is not itself evidence of an invalid coordinate.
func runLocationPipelineChecks() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func sample(_ seconds: Double = 0, north: Double = 0, east: Double = 0,
                accuracy: Double = 10, speed: Double = 0, course: Double = 0,
                source: LocationSampleSource = .standard) -> RawLocationSample {
        RawLocationSample(latitude: 31 + north / 111_000,
                          longitude: 121 + east / (111_000 * cos(31 * .pi / 180)),
                          timestamp: base.addingTimeInterval(seconds),
                          speed: speed, course: course,
                          horizontalAccuracy: accuracy, source: source)
    }
    let moving = MotionObservation(state: .moving, centerLatitude: 31,
                                   centerLongitude: 121, dynamicRadius: 12)
    let stationary = MotionObservation(state: .stationary, centerLatitude: 31,
                                       centerLongitude: 121, dynamicRadius: 12)
    func isCandidate(_ decision: RealtimeTrackDecision) -> Bool {
        if case .candidate = decision { return true }
        return false
    }

    var background = BackgroundTrackingPolicy()
    let burst = background.observe(source: .significantChange, motion: nil,
                                   now: base, appIsActive: false)
    check(burst.state == .confirmingMovement && burst.wantsStandardUpdates,
          "后台策略-重大位移启动精度确认")
    let activeMove = background.observe(source: .standard, motion: .moving,
                                        now: base.addingTimeInterval(10), appIsActive: false)
    check(activeMove.state == .moving && activeMove.wantsStandardUpdates,
          "后台策略-移动中持续采样")
    let still = background.observe(source: .standard, motion: .stationary,
                                   now: base.addingTimeInterval(150), appIsActive: false)
    check(still.state == .stationary && still.wantsStandardUpdates
          && still.desiredAccuracy == 100,
          "后台策略-静止保持低功耗标准定位")
    let visit = background.observe(source: .visit, motion: .stationary,
                                   now: base.addingTimeInterval(160), appIsActive: false)
    check(visit.wantsStandardUpdates, "后台策略-访问事件重新确认移动")
    let expired = background.observe(source: .standard, motion: .stationary,
                                     now: base.addingTimeInterval(281), appIsActive: false)
    check(expired.wantsStandardUpdates
          && expired.desiredAccuracy == 100,
          "后台策略-确认窗口到期降精度但不中断")

    var filter = TrackPointFilter()
    check(isCandidate(filter.evaluate(sample(), motion: moving, configuration: .init())),
          "轨迹过滤-首点进入候选窗口")
    check(isCandidate(filter.evaluate(sample(3, north: 11, speed: 1.2),
                                       motion: moving, configuration: .init())),
          "轨迹过滤-正常步行点成为候选")
    check(filter.evaluate(sample(4, north: 11.02), motion: stationary,
                          configuration: .init()) == .reject(.duplicate),
          "轨迹过滤-真正重复点拒绝")
    check(filter.evaluate(sample(5, north: 9), motion: stationary,
                          configuration: .init()) == .reject(.stationaryJitter),
          "轨迹过滤-静止中心内漂移拒绝")
    check(isCandidate(filter.evaluate(sample(12, north: 13, speed: 0.2),
                                       motion: moving, configuration: .init())),
          "轨迹过滤-已确认移动时保留慢速候选")
    check(isCandidate(filter.evaluate(sample(14, north: 13, east: 2, course: 90),
                                       motion: moving, configuration: .init())),
          "轨迹过滤-真实转向候选保留")

    for speed in [82.0, 220.0] {
        var fast = TrackPointFilter()
        _ = fast.evaluate(sample(speed: speed), motion: moving, configuration: .init())
        check(isCandidate(fast.evaluate(sample(10, east: speed * 10, speed: speed),
                                         motion: moving, configuration: .init())),
              "轨迹过滤-高速本身不删除真实点 \(speed)m/s")
    }
    var sparse = TrackPointFilter()
    _ = sparse.evaluate(sample(), motion: moving, configuration: .init())
    if case .newSegmentCandidate = sparse.evaluate(
        sample(120, east: 1000), motion: moving, configuration: .init()) {
        check(true, "轨迹过滤-稀疏点保留但断开连接")
    } else { check(false, "轨迹过滤-稀疏点保留但断开连接") }

    var gate = LocationQualityGate()
    func evaluateQuality(_ value: RawLocationSample) -> LocationQualityDecision {
        gate.evaluate(value, now: base.addingTimeInterval(10),
                      maximumAccuracy: 100, maximumAge: 120, futureTolerance: 5)
    }
    check(evaluateQuality(sample(10)) == .accept(sample(10)), "质量门-合法点通过")
    check(evaluateQuality(sample(9)) == .reject(.outOfOrder), "质量门-时间倒序拒绝")
    check(evaluateQuality(sample(11, accuracy: 250)) == .reject(.poorAccuracy),
          "质量门-低精度拒绝")
    check(evaluateQuality(sample(-200)) == .reject(.staleTimestamp), "质量门-过期点拒绝")
    check(evaluateQuality(sample(30)) == .reject(.futureTimestamp), "质量门-未来点拒绝")
    check(evaluateQuality(sample(11, north: 100_000_000)) == .reject(.invalidCoordinate),
          "质量门-非法坐标拒绝")

    // Isolated excursions require two-sided evidence rather than a speed cutoff.
    let corrector = TrackWindowCorrector()
    var finalized: [FinalizedTrackPoint] = []
    var removed: [RemovedCandidate] = []
    let points = (0..<5).map { index -> TrackCandidate in
        let raw = sample(Double(index * 10), north: index == 1 ? 900 : 0,
                         east: index == 1 ? 500 : Double(index * 10))
        return TrackCandidate(coordinate: raw.coordinate, timestamp: raw.timestamp,
                              horizontalAccuracy: 5, altitude: 0, systemSpeed: -1,
                              derivedSpeed: index == 1 ? 100 : 1, acceleration: nil,
                              course: -1, source: .standard, motionState: .moving,
                              realtimeConfidence: 0.9)
    }
    for point in points {
        let result = corrector.push(point, configuration: .init())
        finalized += result.finalizedPoints
        removed += result.removedCandidates
    }
    finalized += corrector.flush()
    check(removed == [RemovedCandidate(candidateID: points[1].id, reason: .triSpike)],
          "窗口纠错-双侧证据剔除单点偏移")
    check(finalized.map(\.candidateID) == [points[0], points[2], points[3], points[4]].map(\.id),
          "窗口纠错-保留真实点与尾点且不伪造坐标")
}
