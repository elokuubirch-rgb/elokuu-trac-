import XCTest
import MapKit
@testable import LifeFootprints

final class LargeDataPerformanceRegressionTests: XCTestCase {
    func testSyntheticScalePagingIsBoundedAt100k300kAnd623k() {
        let cases = [
            (rows: 100_000, batches: 5),
            (rows: 300_000, batches: 15),
            (rows: 623_384, batches: 32)
        ]
        for item in cases {
            XCTAssertEqual(
                TrajectoryReadPagingPolicy.batchCount(forRowCount: item.rows),
                item.batches)
            XCTAssertEqual(
                TrajectoryReadPagingPolicy.maximumMaterializedModels(forRowCount: item.rows),
                20_000)
        }
        XCTAssertEqual(TrajectoryReadPagingPolicy.batchCount(forRowCount: 0), 0)
        XCTAssertEqual(TrajectoryReadPagingPolicy.maximumMaterializedModels(forRowCount: 0), 0)
    }

    func testHundredThousandRouteDiffHasNoAmplification() {
        let current = (0..<100_000).map {
            MapRoutePresentationState(id: "route-\($0)", fingerprint: UInt64($0))
        }
        var desired = current
        desired[54_321] = MapRoutePresentationState(
            id: "route-54321", fingerprint: UInt64.max)

        let noChange = MapPresentationDiff.make(current: current, desired: current)
        XCTAssertTrue(noChange.added.isEmpty)
        XCTAssertTrue(noChange.removed.isEmpty)
        XCTAssertTrue(noChange.changed.isEmpty)
        XCTAssertEqual(noChange.unchanged.count, 100_000)

        let oneChange = MapPresentationDiff.make(current: current, desired: desired)
        XCTAssertTrue(oneChange.added.isEmpty)
        XCTAssertTrue(oneChange.removed.isEmpty)
        XCTAssertEqual(oneChange.changed, ["route-54321"])
        XCTAssertEqual(oneChange.unchanged.count, 99_999)
        XCTAssertEqual(
            MapOverlayAmplificationPolicy.overlayCount(forLogicalRouteCount: current.count),
            current.count)
        XCTAssertEqual(
            MapOverlayAmplificationPolicy.polylineCount(forLogicalRouteCount: current.count), 0)
    }

    func testHundredThousandPointLODDoesNotChangeCanonicalGeometry() {
        let coordinates = (0..<100_000).map { index in
            CLLocationCoordinate2D(
                latitude: 31.20 + Double(index) * 0.000_001,
                longitude: 121.40 + sin(Double(index) / 500) * 0.001)
        }
        let geometry = ZoomAwareRouteGeometry(coordinates: coordinates)
        let close = geometry.level(for: MKZoomScale(1))
        let farScale = MKZoomScale(0.000_001)
        let far = geometry.level(for: farScale)

        XCTAssertEqual(geometry.rawPoints.count, 100_000)
        XCTAssertEqual(close.points.count, 100_000)
        XCTAssertLessThan(far.points.count, close.points.count)
        XCTAssertLessThanOrEqual(
            far.maximumMapPointError * Double(farScale),
            ZoomAwareRouteGeometry.maximumScreenPointError)
        XCTAssertEqual(far.points.first?.x, geometry.rawPoints.first?.x)
        XCTAssertEqual(far.points.first?.y, geometry.rawPoints.first?.y)
        XCTAssertEqual(far.points.last?.x, geometry.rawPoints.last?.x)
        XCTAssertEqual(far.points.last?.y, geometry.rawPoints.last?.y)
    }

    func testLargeTrailIndexPhotoQueriesAvoidFullSegmentScan() {
        let segmentCount = 30_000
        var points: [TrailPoint] = []
        points.reserveCapacity(segmentCount * 2)
        for index in 0..<segmentCount {
            let start = Double(index * 30)
            let boundary = "large-\(index)"
            let latitude = 30 + Double(index % 100) * 0.000_01
            points.append(TrailPoint(
                lat: latitude, lon: 120, t: start,
                trajectoryID: boundary, sessionID: boundary, segmentID: boundary))
            points.append(TrailPoint(
                lat: latitude + 0.000_001, lon: 120.000_001, t: start + 10,
                trajectoryID: boundary, sessionID: boundary, segmentID: boundary))
        }
        let index = TrailIndex(points: points)
        var indexedCandidates = 0
        var containingCandidates = 0
        let photoCount = 10_000
        for photo in 0..<photoCount {
            let segment = (photo * 3) % segmentCount
            let stats = index.interpolationQueryStats(at: Double(segment * 30 + 5))
            XCTAssertEqual(stats.totalSegmentCount, segmentCount)
            indexedCandidates += stats.indexedCandidateCount
            containingCandidates += stats.containingCandidateCount
        }

        XCTAssertEqual(containingCandidates, photoCount)
        XCTAssertLessThan(indexedCandidates, segmentCount * photoCount / 100)
        XCTAssertLessThan(indexedCandidates, 2_500_000)
    }

    func testHundredThousandPointStreamingAccumulatorPreservesEveryPoint() throws {
        let pointCount = 100_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let accumulator = WorkoutTrajectoryAccumulator(
            activityByWorkout: ["large-workout": "walking"])
        for index in 0..<pointCount {
            accumulator.append(WorkoutRoutePointValue(
                workoutID: "large-workout", routeID: "route-1",
                latitude: 31.2, longitude: 121.4 + Double(index) * 0.000_001,
                altitude: 10, timestamp: base.addingTimeInterval(Double(index)),
                horizontalAccuracy: 5, speed: nil, course: nil),
                globalIndex: index)
        }

        let trajectory = try XCTUnwrap(accumulator.finish().first)
        XCTAssertEqual(trajectory.segments.count, 1)
        XCTAssertEqual(trajectory.segments[0].points.count, pointCount)
        XCTAssertTrue(trajectory.segments[0].points.first?.id.hasSuffix(":0") == true)
        XCTAssertTrue(
            trajectory.segments[0].points.last?.id.hasSuffix(":\(pointCount - 1)") == true)
    }
}
