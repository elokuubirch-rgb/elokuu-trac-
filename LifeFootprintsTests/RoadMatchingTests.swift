import XCTest
import MapKit
@testable import LifeFootprints

final class RoadMatchingTests: XCTestCase {
    func testTwoContinuousRecordedPointsProduceAVisibleRoute() {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let snapshots = [
            FootprintSnapshot(lat: 22.6800, lon: 113.9948, t: start,
                              source: FootprintSource.gps.rawValue,
                              trajectoryID: "trip", sessionID: "session", segmentID: "segment"),
            FootprintSnapshot(lat: 22.6800, lon: 113.9950,
                              t: start.addingTimeInterval(10),
                              source: FootprintSource.gps.rawValue,
                              trajectoryID: "trip", sessionID: "session", segmentID: "segment"),
        ]

        let routes = MapScreen.makeRoutes(
            from: snapshots, workout: false, presentationSystem: .wgs84,
            usesPersistentLODCache: false, matchedSegments: [:],
            includes: { MapLayerSemantics.isAutoTrajectory($0) })

        XCTAssertEqual(routes.routes.count, 1)
        XCTAssertEqual(routes.routes.first?.renderGeometry.rawPoints.count, 2)
    }

    func testPartialRoadMatchDoesNotMoveDotsAwayFromRawLine() {
        let segment = makeSegment()
        let road = [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
        ]
        let snapshots = segment.points.map {
            FootprintSnapshot(lat: $0.latitude, lon: $0.longitude, t: $0.timestamp,
                              source: FootprintSource.gps.rawValue,
                              trajectoryID: segment.trajectoryID,
                              sessionID: segment.sessionID, segmentID: segment.id)
        }
        let matched = RoadMatchedSegment(
            sourceSegmentID: segment.id, status: .matched, geometry: road,
            attachments: snapshots.map { snapshot in
                RoadPointAttachment(
                    pointID: TrajectorySampleIdentity.footprint(
                        source: snapshot.source, latitude: snapshot.lat,
                        longitude: snapshot.lon, timestamp: snapshot.t),
                    coordinate: RoadGeometryCoordinate(
                        latitude: road[0].latitude, longitude: snapshot.lon),
                    displacementMeters: 5)
            }, algorithmVersion: RoadMatchValidator.algorithmVersion)

        let complete = MapScreen.makeRoutes(
            from: snapshots, workout: false, presentationSystem: .wgs84,
            usesPersistentLODCache: false, matchedSegments: [segment.id: matched],
            includes: { MapLayerSemantics.isAutoTrajectory($0) })

        let result = MapScreen.makeRoutes(
            from: Array(snapshots.prefix(2)), workout: false,
            presentationSystem: .wgs84,
            usesPersistentLODCache: false, matchedSegments: [segment.id: matched],
            includes: { MapLayerSemantics.isAutoTrajectory($0) })

        XCTAssertEqual(complete.roadAttachedPointIDs.count, 3)
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertTrue(result.roadAttachedPointIDs.isEmpty)
    }

    func testRecordedRouteCoreRemainsReadableUnderDots() {
        let style = ProfessionalLineStyle.make(alpha: 0.35, width: 1.6, tag: 0)

        XCTAssertGreaterThanOrEqual(style.core.alpha, 0.9)
        XCTAssertGreaterThanOrEqual(style.core.width, 2.8)
    }

    func testValidatorAcceptsNearbyRoadAndMapsEveryMeasuredPoint() throws {
        let segment = makeSegment()
        let geometry = [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
        ]

        let result = RoadMatchValidator.validate(segment: segment, geometry: geometry)

        XCTAssertEqual(result.status, .matched)
        XCTAssertTrue(result.usesRoadGeometry)
        XCTAssertEqual(result.attachments.map(\.pointID), segment.points.map(\.id))
        XCTAssertTrue(result.attachments.allSatisfy { $0.displacementMeters < 10 })
        XCTAssertEqual(segment.points[1].latitude, 22.68005, accuracy: 0.000_000_1)
    }

    func testValidatorRejectsGeometryThatMovesMostPointsTooFar() {
        let segment = makeSegment()
        let geometry = [
            RoadGeometryCoordinate(latitude: 22.6820, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6820, longitude: 113.9958),
        ]

        let result = RoadMatchValidator.validate(segment: segment, geometry: geometry)

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertEqual(result.failureReason, .excessiveDisplacement)
        XCTAssertFalse(result.usesRoadGeometry)
        XCTAssertTrue(result.geometry.isEmpty)
    }

    func testValidatorRejectsImplausibleRoadDetour() {
        let segment = makeSegment()
        let geometry = [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6799, longitude: 113.9950),
            RoadGeometryCoordinate(latitude: 22.6801, longitude: 113.9952),
            RoadGeometryCoordinate(latitude: 22.6799, longitude: 113.9954),
            RoadGeometryCoordinate(latitude: 22.6801, longitude: 113.9956),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
        ]
        let strict = RoadMatchPolicy(
            maximumPointDisplacementMeters: 45,
            maximumMedianDisplacementMeters: 25,
            maximumDetourRatio: 1.05,
            minimumAttachedPointRatio: 0.8)

        let result = RoadMatchValidator.validate(
            segment: segment, geometry: geometry, policy: strict)

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertEqual(result.failureReason, .excessiveDetour)
    }

    func testValidatorRejectsRoadGeometryTraversedOppositeToRecordedPoints() {
        let segment = makeSegment()
        let reversedRoad = [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
        ]

        let result = RoadMatchValidator.validate(
            segment: segment, geometry: reversedRoad)

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertEqual(result.failureReason, .reversedPointOrder)
    }

    func testShortActivityBridgeUsesValidatedRoadAndPreservesMeasurements() async {
        let segment = makeSegment()
        let from = segment.points[0]
        let to = segment.points[1]
        let bridge = ActivityRoadBridge(
            id: "bridge", activityID: "walk", source: .coreLocation,
            activityType: "walking", from: from, to: to)
        let service = RoadMatchingService(
            provider: StraightRoadProvider(latitude: 22.6800))

        let result = await service.matchRoadBridges([bridge], since: from.timestamp)

        XCTAssertEqual(result[bridge.id]?.status, .matched)
        XCTAssertEqual(result[bridge.id]?.attachments.map(\.pointID), ["p0", "p1"])
        XCTAssertEqual(from.latitude, segment.points[0].latitude)
    }

    func testBridgeRejectsRoadThatCannotFitObservedWalkingTime() async {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let from = TrajectoryPoint(
            id: "start", latitude: 22.68, longitude: 113.9900,
            timestamp: start, horizontalAccuracy: 5,
            source: .coreLocation)
        let to = TrajectoryPoint(
            id: "end", latitude: 22.68, longitude: 113.9904,
            timestamp: start.addingTimeInterval(10),
            horizontalAccuracy: 5, source: .coreLocation)
        let bridge = ActivityRoadBridge(
            id: "walking-bridge", activityID: "walk",
            source: .coreLocation, activityType: "walking",
            from: from, to: to)
        let service = RoadMatchingService(provider: VShapedRoadProvider())

        let result = await service.matchRoadBridges([bridge], since: start)

        XCTAssertEqual(result[bridge.id]?.status, .unmatched)
        XCTAssertEqual(result[bridge.id]?.failureReason, .implausibleSpeed)
    }

    func testMapDrawsOnlyValidatedBridgeWithinSelectedTimeWindow() throws {
        let recorded = makeSegment()
        let from = recorded.points[0]
        let to = recorded.points[1]
        let bridge = ActivityRoadBridge(
            id: "bridge", activityID: "walk", source: .coreLocation,
            activityType: "walking", from: from, to: to)
        let quality = TrajectoryQuality(
            pointCount: 2, duration: 20, maximumGap: 20,
            accuratePointRatio: 1, confidence: 0.9)
        let bridgeSegment = TrajectorySegment(
            id: bridge.id, trajectoryID: "walk", sessionID: "walk",
            source: .coreLocation, points: [from, to],
            startTime: from.timestamp, endTime: to.timestamp, quality: quality)
        let matched = RoadMatchValidator.validate(
            segment: bridgeSegment, geometry: [
                RoadGeometryCoordinate(latitude: 22.6800, longitude: from.longitude),
                RoadGeometryCoordinate(latitude: 22.6800, longitude: to.longitude),
            ])
        let visible = MapScreen.makeActivityBridgeRoutes(
            [bridge], matchedSegments: [bridge.id: matched],
            attachedCoordinates: [from.id: RoadGeometryCoordinate(
                latitude: 22.6800, longitude: from.longitude)],
            presentationSystem: .wgs84, usesPersistentLODCache: false,
            includes: { _ in true })
        let outsideWindow = MapScreen.makeActivityBridgeRoutes(
            [bridge], matchedSegments: [bridge.id: matched],
            presentationSystem: .wgs84, usesPersistentLODCache: false,
            includes: { $0 < from.timestamp })
        let noMatch = MapScreen.makeActivityBridgeRoutes(
            [bridge], matchedSegments: [:],
            presentationSystem: .wgs84, usesPersistentLODCache: false,
            includes: { _ in true })

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(try XCTUnwrap(visible[0].renderGeometry.rawPoints.first).coordinate.latitude,
                       22.6800, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(visible[0].renderGeometry.rawPoints.last).coordinate.longitude,
                       to.longitude, accuracy: 0.000_001)
        XCTAssertTrue(outsideWindow.isEmpty)
        XCTAssertTrue(noMatch.isEmpty)
    }

    func testServiceStitchesProviderGeometryAndDoesNotMutateMeasurements() async {
        let segment = makeSegment()
        let original = segment.points
        let service = RoadMatchingService(
            provider: StraightRoadProvider(latitude: 22.6800),
            configuration: .init(
                minimumAnchorDistanceMeters: 30,
                maximumAnchorInterval: 30,
                maximumRequestsPerSegment: 8,
                maximumSegmentsPerRefresh: 2))

        let result = await service.match(segment: segment, activityType: "walking")

        XCTAssertEqual(result.status, .matched)
        XCTAssertGreaterThanOrEqual(result.geometry.count, 2)
        XCTAssertEqual(segment.points, original)
        XCTAssertEqual(result.attachments.count, original.count)
    }

    func testUnavailableProviderReturnsExplicitFallbackState() async {
        let segment = makeSegment()
        let service = RoadMatchingService()

        let result = await service.match(segment: segment, activityType: nil)

        XCTAssertEqual(result.status, .unmatched)
        XCTAssertEqual(result.failureReason, .providerUnavailable)
        XCTAssertTrue(result.geometry.isEmpty)
    }

    func testDisplayGeometrySwitchesPointAndLineTogether() {
        let segment = makeSegment()
        let road = [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
        ]
        let matched = RoadMatchValidator.validate(segment: segment, geometry: road)

        let display = RoadMatchedDisplayGeometry.resolve(
            segment: segment, matched: matched)

        XCTAssertTrue(display.usesRoadGeometry)
        XCTAssertEqual(display.line, road)
        XCTAssertEqual(display.pointCoordinates["p1"]?.latitude, 22.6800)
    }

    func testDisplayGeometryFallsBackAtomicallyWhenMappingIsIncomplete() {
        let segment = makeSegment()
        let incomplete = RoadMatchedSegment(
            sourceSegmentID: segment.id, status: .matched,
            geometry: [
                RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
                RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
            ],
            attachments: [
                RoadPointAttachment(
                    pointID: "p0",
                    coordinate: RoadGeometryCoordinate(
                        latitude: 22.6800, longitude: 113.9948),
                    displacementMeters: 4),
            ], algorithmVersion: RoadMatchValidator.algorithmVersion)

        let display = RoadMatchedDisplayGeometry.resolve(
            segment: segment, matched: incomplete)

        XCTAssertFalse(display.usesRoadGeometry)
        XCTAssertEqual(display.line.first?.latitude, segment.points.first?.latitude)
        XCTAssertEqual(display.pointCoordinates["p1"]?.latitude,
                       segment.points[1].latitude)
    }

    func testMatchedGeometryStoreRequiresExactRevisionAndAlgorithm() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoadMatchedGeometryStore.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoadMatchedGeometryStore(
            fileURL: directory.appendingPathComponent("matches.plist"))
        let segment = makeSegment()
        let matched = RoadMatchValidator.validate(segment: segment, geometry: [
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9948),
            RoadGeometryCoordinate(latitude: 22.6800, longitude: 113.9958),
        ])

        XCTAssertTrue(store.save([segment.id: matched], dataRevision: 8))
        XCTAssertEqual(store.load(dataRevision: 8)?[segment.id], matched)
        XCTAssertNil(store.load(dataRevision: 9))

        store.clear()
        XCTAssertNil(store.load(dataRevision: 8))
    }

    private func makeSegment() -> TrajectorySegment {
        let base = Date(timeIntervalSince1970: 1_795_000_000)
        let points = [
            TrajectoryPoint(
                id: "p0", latitude: 22.68004, longitude: 113.9948,
                timestamp: base, horizontalAccuracy: 6, speed: 1.4,
                course: 90, source: .coreLocation),
            TrajectoryPoint(
                id: "p1", latitude: 22.68005, longitude: 113.9953,
                timestamp: base.addingTimeInterval(20), horizontalAccuracy: 5,
                speed: 1.5, course: 90, source: .coreLocation),
            TrajectoryPoint(
                id: "p2", latitude: 22.68003, longitude: 113.9958,
                timestamp: base.addingTimeInterval(40), horizontalAccuracy: 5,
                speed: 1.5, course: 90, source: .coreLocation),
        ]
        let quality = TrajectoryQuality(
            pointCount: points.count, duration: 40, maximumGap: 20,
            accuratePointRatio: 1, confidence: 0.95)
        return TrajectorySegment(
            id: "segment", trajectoryID: "trajectory", sessionID: "session",
            source: .coreLocation, points: points, startTime: base,
            endTime: base.addingTimeInterval(40), quality: quality)
    }
}

private struct StraightRoadProvider: RoadGeometryProvider {
    let latitude: Double

    func roadGeometry(between start: RoadGeometryCoordinate,
                      and end: RoadGeometryCoordinate,
                      activityType: String?) async throws -> [RoadGeometryCoordinate] {
        [
            RoadGeometryCoordinate(latitude: latitude, longitude: start.longitude),
            RoadGeometryCoordinate(latitude: latitude, longitude: end.longitude),
        ]
    }
}

private struct VShapedRoadProvider: RoadGeometryProvider {
    func roadGeometry(between start: RoadGeometryCoordinate,
                      and end: RoadGeometryCoordinate,
                      activityType: String?) async throws -> [RoadGeometryCoordinate] {
        [start,
         RoadGeometryCoordinate(
            latitude: start.latitude + 0.00015,
            longitude: (start.longitude + end.longitude) / 2),
         end]
    }
}
