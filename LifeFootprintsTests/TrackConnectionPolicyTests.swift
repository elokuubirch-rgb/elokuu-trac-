import XCTest
@testable import LifeFootprints

final class TrackConnectionPolicyTests: XCTestCase {
    func testHistoricalSegmentSplitsWithoutLosingPoints() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            TrajectorySample(id: "a", source: .coreLocation, sessionID: "s", segmentID: "old",
                             latitude: 31, longitude: 121, timestamp: date),
            TrajectorySample(id: "b", source: .coreLocation, sessionID: "s", segmentID: "old",
                             latitude: 31.001, longitude: 121, timestamp: date.addingTimeInterval(120))
        ]
        let trajectory = try XCTUnwrap(TrajectoryBuilder.build(samples: samples).first)
        XCTAssertEqual(trajectory.segments.count, 2)
        XCTAssertEqual(trajectory.segments.flatMap(\.points).count, 2)
        XCTAssertEqual(samples.map(\.segmentID), ["old", "old"])
    }

    func testSparseSamplesAreNotContinuousRoutes() {
        XCTAssertFalse(TrackConnectionPolicy.permitsConnection(source: .standard, elapsed: 120, distance: 1_000))
        XCTAssertFalse(TrackConnectionPolicy.permitsConnection(source: .visit, elapsed: 10, distance: 100))
        XCTAssertFalse(TrackConnectionPolicy.permitsConnection(source: .significantChange, elapsed: 10, distance: 100))
    }

    func testContinuousHighSpeedHasNoFixedSpeedCap() {
        XCTAssertTrue(TrackConnectionPolicy.permitsConnection(source: .standard, elapsed: 10, distance: 2_000))
        XCTAssertTrue(TrackConnectionPolicy.permitsConnection(source: .standard, elapsed: 30, distance: 5_000))
        XCTAssertFalse(TrackConnectionPolicy.permitsConnection(source: .standard, elapsed: 30.1, distance: 10))
        XCTAssertFalse(TrackConnectionPolicy.permitsConnection(source: .standard, elapsed: 10, distance: .nan))
    }

    func testPhotoInterpolationIsBoundedAndDoesNotExtrapolate() {
        let index = TrailIndex(points: [TrailPoint(lat: 31, lon: 121, t: 100),
                                       TrailPoint(lat: 31.001, lon: 121, t: 220)])
        XCTAssertNotNil(index.interpolate(at: 160))
        XCTAssertNil(index.interpolate(at: 99))
        XCTAssertNil(index.interpolate(at: 221))
        let sparse = TrailIndex(points: [TrailPoint(lat: 31, lon: 121, t: 100),
                                        TrailPoint(lat: 31.001, lon: 121, t: 221)])
        XCTAssertNil(sparse.interpolate(at: 160))
    }
}
