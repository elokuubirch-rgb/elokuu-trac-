import XCTest
@testable import LifeFootprints

final class TrajectoryAndHealthTests: XCTestCase {
    override func tearDown() {
        TrajectoryResolutionCache.shared.invalidate()
        super.tearDown()
    }

    func testSuppressedAutoTrajectoryReturnsWhenWorkoutLayerIsHidden() {
        let point = FootprintSnapshot(
            lat: 31, lon: 121, t: Date(), source: FootprintSource.gps.rawValue,
            trajectoryID: "auto", sessionID: "auto", segmentID: "auto:0",
            isSuppressedDuplicate: true,
            suppressedBySource: TrajectorySource.healthWorkout.rawValue)

        XCTAssertTrue(MapLayerSemantics.autoTrajectory([point]).isEmpty)
        XCTAssertEqual(MapLayerSemantics.autoTrajectory(
            [point], workoutSourceVisible: false), [point])
    }

    func testNoRouteRequiresAgeAndRepeatedConfirmation() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldEnd = now.addingTimeInterval(-HealthRouteRetryPolicy.noRouteGracePeriod)
        XCTAssertEqual(HealthRouteRetryPolicy.stateAfterEmptyResult(
            retryCount: 7, workoutEnd: oldEnd, now: now), "pending")
        XCTAssertEqual(HealthRouteRetryPolicy.stateAfterEmptyResult(
            retryCount: 8, workoutEnd: oldEnd, now: now), "noRoute")
    }

    func testSparseCSVDoesNotBecomeTrajectory() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<3).map { index in
            TrajectorySample(
                id: "p\(index)", source: .imported,
                latitude: 31 + Double(index), longitude: 121,
                timestamp: base.addingTimeInterval(Double(index) * 86_400))
        }
        XCTAssertTrue(ImportedTrajectoryClassifier.sessions(for: samples).isEmpty)
    }

    func testResolutionCacheCanBeInvalidated() {
        let resolution = TrajectoryConflictResolver.resolve([])
        TrajectoryResolutionCache.shared.value = resolution
        XCTAssertEqual(TrajectoryResolutionCache.shared.value, resolution)

        TrajectoryResolutionCache.shared.invalidate()
        XCTAssertNil(TrajectoryResolutionCache.shared.value)
    }

    func testTemporalPruningPerformanceForDisjointHistory() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<1_000).flatMap { trajectoryIndex in
            (0..<3).map { pointIndex in
                TrajectorySample(
                    id: "t\(trajectoryIndex)-p\(pointIndex)",
                    source: .healthWorkout,
                    sourceIdentifier: "t\(trajectoryIndex)",
                    sessionID: "t\(trajectoryIndex)",
                    latitude: 31 + Double(pointIndex) * 0.0001,
                    longitude: 121,
                    timestamp: base.addingTimeInterval(
                        Double(trajectoryIndex) * 600 + Double(pointIndex) * 30))
            }
        }
        let trajectories = TrajectoryBuilder.build(samples: samples)
        XCTAssertEqual(trajectories.count, 1_000)

        measure {
            let resolution = TrajectoryConflictResolver.resolve(trajectories)
            XCTAssertEqual(resolution.comparedPairCount, 0)
            XCTAssertTrue(resolution.conflicts.isEmpty)
        }
    }
}
