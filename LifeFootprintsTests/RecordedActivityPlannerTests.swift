import XCTest
@testable import LifeFootprints

final class RecordedActivityPlannerTests: XCTestCase {
    func testOneWalkSurvivesLocationRestartAndRequestsShortRoadBridge() {
        let samples = [
            sample("a", seconds: 0, longitude: 113.9900,
                   session: "before-restart", segment: "first"),
            sample("b", seconds: 15, longitude: 113.9902,
                   session: "before-restart", segment: "first"),
            sample("c", seconds: 65, longitude: 113.9909,
                   session: "after-restart", segment: "second"),
            sample("d", seconds: 80, longitude: 113.9911,
                   session: "after-restart", segment: "second"),
        ]

        let plan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: samples))

        XCTAssertEqual(plan.activities.count, 1)
        XCTAssertEqual(plan.activities[0].segmentIDs.count, 2)
        XCTAssertEqual(plan.roadBridges.count, 1)
        XCTAssertEqual(plan.roadBridges[0].from.id, "b")
        XCTAssertEqual(plan.roadBridges[0].to.id, "c")
        XCTAssertEqual(plan.boundaryDecisions[0].reason, .shortRoadGap)
    }

    func testStopRemainsInActivityWithoutInventingTravel() {
        let samples = [
            sample("a", seconds: 0, longitude: 113.9900,
                   session: "s", segment: "one"),
            sample("b", seconds: 300, longitude: 113.99002,
                   session: "s", segment: "two"),
        ]

        let plan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: samples))

        XCTAssertEqual(plan.activities.count, 1)
        XCTAssertTrue(plan.roadBridges.isEmpty)
        XCTAssertEqual(plan.boundaryDecisions[0].reason, .nearbyStop)
    }

    func testDifferentOutingsAndTeleportAreNotBridged() {
        let samples = [
            sample("a", seconds: 0, longitude: 113.9900,
                   session: "s1", segment: "one"),
            sample("b", seconds: 60, longitude: 114.0300,
                   session: "s2", segment: "teleport"),
            sample("c", seconds: 4_000, longitude: 114.0301,
                   session: "s3", segment: "later"),
        ]

        let plan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: samples))

        XCTAssertEqual(plan.activities.count, 3)
        XCTAssertTrue(plan.roadBridges.isEmpty)
        XCTAssertEqual(plan.boundaryDecisions.map(\.continuesActivity),
                       [false, false])
    }

    func testSuppressedEndpointCannotCreateVisibleBridge() {
        let samples = [
            sample("a", seconds: 0, longitude: 113.9900,
                   session: "s", segment: "one"),
            sample("b", seconds: 60, longitude: 113.9907,
                   session: "s", segment: "two"),
        ]

        let plan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: samples),
            visiblePointIDs: ["a"])

        XCTAssertEqual(plan.activities.count, 1)
        XCTAssertTrue(plan.roadBridges.isEmpty)
    }

    func testCyclingCanBridgeLongerShortGapThanWalking() {
        let walking = [
            sample("walk-a", seconds: 0, longitude: 113.9900,
                   session: "walk1", segment: "walk1", activity: "walking"),
            sample("walk-b", seconds: 60, longitude: 113.99245,
                   session: "walk2", segment: "walk2", activity: "walking"),
        ]
        let cycling = [
            sample("cycle-a", seconds: 0, longitude: 113.9900,
                   session: "cycle1", segment: "cycle1", activity: "cycling"),
            sample("cycle-b", seconds: 60, longitude: 113.99245,
                   session: "cycle2", segment: "cycle2", activity: "cycling"),
        ]

        let walkPlan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: walking))
        let cyclePlan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: cycling))

        XCTAssertEqual(walkPlan.activities.count, 1)
        XCTAssertTrue(walkPlan.roadBridges.isEmpty)
        XCTAssertEqual(walkPlan.boundaryDecisions[0].reason, .uncertainPath)
        XCTAssertEqual(cyclePlan.activities.count, 1)
        XCTAssertEqual(cyclePlan.roadBridges.count, 1)
    }

    func testExplicitModeChangeStartsAnotherActivity() {
        let samples = [
            sample("walk", seconds: 0, longitude: 113.9900,
                   session: "walk", segment: "walk", activity: "walking"),
            sample("cycle", seconds: 50, longitude: 113.9903,
                   session: "cycle", segment: "cycle", activity: "cycling"),
        ]

        let plan = RecordedActivityPlanner.plan(
            trajectories: TrajectoryBuilder.build(samples: samples))

        XCTAssertEqual(plan.activities.count, 2)
        XCTAssertTrue(plan.roadBridges.isEmpty)
        XCTAssertEqual(plan.boundaryDecisions.first?.reason, .activityChanged)
    }

    private func sample(_ id: String, seconds: TimeInterval, longitude: Double,
                        session: String, segment: String,
                        activity: String? = nil) -> TrajectorySample {
        TrajectorySample(
            id: id, source: .coreLocation, sessionID: session,
            segmentID: segment, activityType: activity,
            latitude: 22.68, longitude: longitude,
            timestamp: Date(timeIntervalSince1970: 1_795_000_000 + seconds),
            horizontalAccuracy: 5, speed: 1.5)
    }
}
