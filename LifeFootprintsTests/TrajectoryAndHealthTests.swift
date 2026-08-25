import XCTest
import SwiftData
import MapKit
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

    func testBoundsRegionHandlesEmptyAndSinglePointSnapshots() throws {
        XCTAssertNil(MapScreen.boundsRegion([]))

        let point = FootprintSnapshot(
            lat: 31.2304, lon: 121.4737,
            t: Date(timeIntervalSince1970: 1_700_000_000))
        let region = try XCTUnwrap(MapScreen.boundsRegion([point]))

        XCTAssertEqual(region.center.latitude, point.lat, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, point.lon, accuracy: 0.000_001)
        XCTAssertEqual(region.span.latitudeDelta, 0.028, accuracy: 0.000_001)
        XCTAssertEqual(region.span.longitudeDelta, 0.028, accuracy: 0.000_001)
    }

    func testBoundsRegionKeepsExistingPercentileBehaviorForMultiplePoints() throws {
        let points = (0..<100).map { index in
            FootprintSnapshot(
                lat: Double(index), lon: Double(index) * 2,
                t: Date(timeIntervalSince1970: Double(index)))
        }
        let region = try XCTUnwrap(MapScreen.boundsRegion(points))

        XCTAssertEqual(region.center.latitude, 49.5, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, 99, accuracy: 0.000_001)
        XCTAssertEqual(region.span.latitudeDelta, 97 * 1.4, accuracy: 0.000_001)
        XCTAssertEqual(region.span.longitudeDelta, 194 * 1.4, accuracy: 0.000_001)
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

    func testPersistentTrajectoryCacheRequiresExactRevisionAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryCacheTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(
            fileURL: directory.appendingPathComponent("resolution.plist"))
        let resolution = sampleResolution()

        XCTAssertTrue(cache.save(resolution, dataRevision: 41))
        XCTAssertEqual(cache.load(dataRevision: 41), resolution)
        XCTAssertNil(cache.load(dataRevision: 42))
    }

    func testProfessionalLineUsesOneOverlayAndPreservesThreeStrokeParameters() {
        let historical = ProfessionalLineStyle.make(alpha: 0.8, width: 2.6, tag: 0)
        XCTAssertEqual(MapOverlayAmplificationPolicy.overlayCount(forLogicalRouteCount: 900), 900)
        XCTAssertEqual(MapOverlayAmplificationPolicy.polylineCount(forLogicalRouteCount: 900), 0)
        XCTAssertEqual(historical.casing.alpha, 0.34, accuracy: 0.0001)
        XCTAssertEqual(historical.casing.width, 5.0, accuracy: 0.0001)
        XCTAssertEqual(historical.casing.tone, .casing)
        XCTAssertEqual(historical.glow.alpha, 0.05, accuracy: 0.0001)
        XCTAssertEqual(historical.glow.width, 6.6, accuracy: 0.0001)
        XCTAssertEqual(historical.glow.tone, .glow)
        XCTAssertEqual(historical.core.alpha, 0.52, accuracy: 0.0001)
        XCTAssertEqual(historical.core.width, 2.0, accuracy: 0.0001)
        XCTAssertEqual(historical.core.tone, .theme)

        let workout = ProfessionalLineStyle.make(alpha: 1, width: 4.2, tag: 3)
        XCTAssertEqual(workout.casing.alpha, 0.8, accuracy: 0.0001)
        XCTAssertEqual(workout.casing.width, 8.4, accuracy: 0.0001)
        XCTAssertEqual(workout.glow.alpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(workout.glow.width, 12.2, accuracy: 0.0001)
        XCTAssertEqual(workout.core.alpha, 1, accuracy: 0.0001)
        XCTAssertEqual(workout.core.width, 4.2, accuracy: 0.0001)
    }

    func testMapPresentationNoChangeProducesNoMutations() {
        let current = [
            MapRoutePresentationState(id: "a", fingerprint: 1),
            MapRoutePresentationState(id: "b", fingerprint: 2)
        ]
        let diff = MapPresentationDiff.make(current: current, desired: current)

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.changed.isEmpty)
        XCTAssertEqual(diff.unchanged, ["a", "b"])
    }

    func testMapPresentationDiffUpdatesOnlyChangedTrajectory() {
        let current = [
            MapRoutePresentationState(id: "stable", fingerprint: 11),
            MapRoutePresentationState(id: "changed", fingerprint: 22),
            MapRoutePresentationState(id: "removed", fingerprint: 33)
        ]
        let desired = [
            MapRoutePresentationState(id: "stable", fingerprint: 11),
            MapRoutePresentationState(id: "changed", fingerprint: 23),
            MapRoutePresentationState(id: "added", fingerprint: 44)
        ]
        let diff = MapPresentationDiff.make(current: current, desired: desired)

        XCTAssertEqual(diff.unchanged, ["stable"])
        XCTAssertEqual(diff.changed, ["changed"])
        XCTAssertEqual(diff.removed, ["removed"])
        XCTAssertEqual(diff.added, ["added"])
    }

    func testMapPresentationBatchSizeAdaptsToMainThreadBudget() {
        XCTAssertGreaterThan(
            MapPresentationBatchPolicy.nextBatchSize(previous: 64, elapsedMilliseconds: 2), 64)
        XCTAssertLessThan(
            MapPresentationBatchPolicy.nextBatchSize(previous: 64, elapsedMilliseconds: 20), 64)
        XCTAssertEqual(
            MapPresentationBatchPolicy.nextBatchSize(previous: 8, elapsedMilliseconds: 100), 8)
    }

    func testZoomAwareGeometryPreservesEndpointsAndErrorBound() {
        let raw = (0..<1_000).map { index in
            MKMapPoint(x: Double(index) * 1_000,
                       y: sin(Double(index) / 35) * 8_000 + Double(index) * 12)
        }
        let tolerance = 256.0
        let simplified = ZoomAwareRouteGeometry.simplify(raw, tolerance: tolerance)

        XCTAssertLessThan(simplified.count, raw.count)
        XCTAssertEqual(simplified.first?.x, raw.first?.x)
        XCTAssertEqual(simplified.first?.y, raw.first?.y)
        XCTAssertEqual(simplified.last?.x, raw.last?.x)
        XCTAssertEqual(simplified.last?.y, raw.last?.y)
        XCTAssertLessThanOrEqual(
            ZoomAwareRouteGeometry.maximumDeviation(of: raw, from: simplified),
            tolerance + 0.0001)
    }

    func testZoomAwareGeometryUsesRawCloseUpAndSubpointLODWhenFar() {
        let coordinates = (0..<600).map { index in
            CLLocationCoordinate2D(
                latitude: 31.20 + Double(index) * 0.00001,
                longitude: 121.40 + sin(Double(index) / 18) * 0.002)
        }
        let geometry = ZoomAwareRouteGeometry(coordinates: coordinates)
        let close = geometry.level(for: MKZoomScale(1))
        let farScale = MKZoomScale(0.000001)
        let far = geometry.level(for: farScale)

        XCTAssertEqual(close.maximumMapPointError, 0)
        XCTAssertEqual(close.points.count, coordinates.count)
        XCTAssertLessThan(far.points.count, close.points.count)
        XCTAssertLessThanOrEqual(
            far.maximumMapPointError * Double(farScale),
            ZoomAwareRouteGeometry.maximumScreenPointError)
        XCTAssertEqual(far.points.first?.x, close.points.first?.x)
        XCTAssertEqual(far.points.first?.y, close.points.first?.y)
        XCTAssertEqual(far.points.last?.x, close.points.last?.x)
        XCTAssertEqual(far.points.last?.y, close.points.last?.y)
        var previousCount = geometry.rawPoints.count
        for level in geometry.levels {
            XCTAssertLessThanOrEqual(level.points.count * 100, previousCount * 65)
            previousCount = level.points.count
        }
    }

    func testTrailIndexTemporalLookupPreservesOverlapPriorityAndBoundaries() {
        let index = TrailIndex(points: [
            TrailPoint(lat: 31, lon: 121, t: 1_000, source: .coreLocation,
                       trajectoryID: "auto", sessionID: "auto", segmentID: "a",
                       confidence: 0.6),
            TrailPoint(lat: 31.001, lon: 121.001, t: 1_100, source: .coreLocation,
                       trajectoryID: "auto", sessionID: "auto", segmentID: "a",
                       confidence: 0.6),
            TrailPoint(lat: 32, lon: 122, t: 1_000, source: .healthWorkout,
                       trajectoryID: "health", sessionID: "health", segmentID: "h",
                       confidence: 0.95),
            TrailPoint(lat: 32.002, lon: 122.002, t: 1_100, source: .healthWorkout,
                       trajectoryID: "health", sessionID: "health", segmentID: "h",
                       confidence: 0.95)
        ])

        let result = snapPhotoToTrailResult(lat: 999, lon: 999, time: 1_050, trails: index)
        XCTAssertEqual(result.kind, .interpolated)
        XCTAssertEqual(result.source, .healthWorkout)
        XCTAssertEqual(result.trajectoryID, "health")
        XCTAssertEqual(result.sessionID, "health")
        XCTAssertEqual(result.segmentID, "h")
        XCTAssertEqual(result.lat, 32.001, accuracy: 0.000_001)
        XCTAssertEqual(result.lon, 122.001, accuracy: 0.000_001)
        XCTAssertEqual(result.confidence, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(result.timeDelta, 0)
    }

    func testTrailIndexTemporalLookupDoesNotScanAllSegments() {
        var points: [TrailPoint] = []
        points.reserveCapacity(20_000)
        for index in 0..<10_000 {
            let start = Double(index * 30)
            let latitude = 30 + Double(index % 100) * 0.000_01
            let boundary = "segment-\(index)"
            points.append(TrailPoint(
                lat: latitude, lon: 120, t: start,
                trajectoryID: boundary, sessionID: boundary, segmentID: boundary))
            points.append(TrailPoint(
                lat: latitude + 0.000_001, lon: 120.000_001, t: start + 10,
                trajectoryID: boundary, sessionID: boundary, segmentID: boundary))
        }
        let index = TrailIndex(points: points)
        let stats = index.interpolationQueryStats(at: 150_005)

        XCTAssertEqual(stats.totalSegmentCount, 10_000)
        XCTAssertEqual(stats.containingCandidateCount, 1)
        XCTAssertLessThan(stats.indexedCandidateCount, 250)
        XCTAssertLessThan(stats.indexedCandidateCount, stats.totalSegmentCount / 20)
        XCTAssertNotNil(index.interpolate(at: 150_005))
    }

    func testStatsClusterCacheBuildsOnceForConcurrentSameRevisionConsumers() async {
        let cache = StatsClusterRevisionCache()
        let key = StatsClusterCacheKey(
            placeRevision: 17, trajectoryRevision: 23, snapshotGeneration: 4)
        let snapshots = (0..<20_000).map { index in
            FootprintSnapshot(
                lat: 30 + Double(index % 100) * 0.000_1,
                lon: 120 + Double(index % 80) * 0.000_1,
                t: Date(timeIntervalSince1970: Double(index)))
        }

        let values = await withTaskGroup(of: [StatsDenseArea].self) { group in
            for _ in 0..<20 {
                group.addTask { await cache.value(for: key, snapshots: snapshots) }
            }
            var results: [[StatsDenseArea]] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(values.count, 20)
        XCTAssertTrue(values.dropFirst().allSatisfy { $0 == values.first })
        let firstBuildCount = await cache.diagnosticBuildCount()
        XCTAssertEqual(firstBuildCount, 1)
        _ = await cache.value(for: key, snapshots: snapshots)
        let secondBuildCount = await cache.diagnosticBuildCount()
        XCTAssertEqual(secondBuildCount, 1)
    }

    @MainActor
    func testRepositoryRestartUsesPersistentCacheWithoutRawFetch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FootprintPoint.self, WorkoutRecord.self,
            WorkoutRouteRecord.self, WorkoutRoutePoint.self,
            configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let workoutID = "persistent-workout"
        context.insert(WorkoutRecord(
            healthKitUUID: workoutID, workoutType: "walking",
            startDate: base, endDate: base.addingTimeInterval(60),
            duration: 60, distanceMeters: 100, caloriesKCal: 10,
            elevationGain: 0, routeAvailable: true, routeSyncState: .available))
        for index in 0..<3 {
            context.insert(WorkoutRoutePoint(
                workoutID: workoutID, latitude: 31 + Double(index) * 0.0001,
                longitude: 121, altitude: 10,
                timestamp: base.addingTimeInterval(Double(index) * 30),
                routeID: "route", segmentIndex: 0, pointIndex: index,
                horizontalAccuracy: 5))
        }
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryRestartTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(
            fileURL: directory.appendingPathComponent("resolution.plist"))
        let repository = TrajectoryRepository(container: container, persistentCache: cache)
        let first = try repository.loadResolved()
        XCTAssertEqual(first.points.count, 3)

        TrajectoryResolutionCache.shared.invalidate()
        for point in try context.fetch(FetchDescriptor<WorkoutRoutePoint>()) {
            context.delete(point)
        }
        try context.save() // test-only：不 bump revision，用来证明 restart hit 不读取 raw。

        let restarted = TrajectoryRepository(container: container, persistentCache: cache)
        XCTAssertEqual(try restarted.loadResolved(), first)
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

    func testEmptyHealthSyncDoesNotInvalidateAnyDataDomain() {
        let domains = HealthSyncInvalidationPolicy.domains(
            workoutInsertedOrUpdated: false, workoutDeleted: false,
            routeInsertedOrUpdated: false, routeDeleted: false)
        XCTAssertTrue(domains.isEmpty)
    }

    func testRevisionsArePersistentAndDomainScoped() throws {
        let suite = "DataRevisionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = DataRevisionStore.snapshot(defaults: defaults)
        XCTAssertNil(DataRevisionStore.commit([], reason: "empty",
                                              defaults: defaults, publish: false))
        XCTAssertEqual(DataRevisionStore.snapshot(defaults: defaults), initial)

        let statsChange = try XCTUnwrap(DataRevisionStore.commit(
            [.stats], reason: "workout-summary", defaults: defaults, publish: false))
        XCTAssertEqual(statsChange.current.trajectory, initial.trajectory)
        XCTAssertEqual(statsChange.current.stats, initial.stats + 1)

        let routeChange = try XCTUnwrap(DataRevisionStore.commit(
            [.trajectory, .stats], reason: "route", defaults: defaults, publish: false))
        XCTAssertEqual(routeChange.current.trajectory, initial.trajectory + 1)
        XCTAssertEqual(routeChange.current.photo, initial.photo)
        XCTAssertEqual(routeChange.current.place, initial.place)
        XCTAssertEqual(routeChange.current.stats, initial.stats + 2)
    }

    @MainActor
    func testLegacyRouteMigrationIsOneTimeAndPreservesBoundaries() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WorkoutRecord.self, WorkoutRouteRecord.self, WorkoutRoutePoint.self,
            configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let workoutID = "legacy-workout"
        context.insert(WorkoutRecord(
            healthKitUUID: workoutID, workoutType: "walking",
            startDate: base, endDate: base.addingTimeInterval(4_000),
            duration: 4_000, distanceMeters: 1_000, caloriesKCal: 100,
            elevationGain: 0, routeAvailable: false))
        for (index, offset) in [0.0, 30.0, 3_000.0].enumerated() {
            context.insert(WorkoutRoutePoint(
                workoutID: workoutID, latitude: 31 + Double(index) * 0.0001,
                longitude: 121, altitude: 10,
                timestamp: base.addingTimeInterval(offset)))
        }
        try context.save()

        let suite = "LegacyRouteMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LegacyRouteMigration.runIfNeeded(
            container: container, defaults: defaults, publishRevision: false)
        XCTAssertEqual(first.migratedWorkouts, 1)
        XCTAssertEqual(first.migratedPoints, 3)

        let migrated = try context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(migrated.map(\.routeID), Array(repeating: "legacy:\(workoutID)", count: 3))
        XCTAssertEqual(migrated.map(\.segmentIndex), [0, 0, 1])
        XCTAssertEqual(migrated.map(\.pointIndex), [0, 1, 0])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRouteRecord>()), 1)

        let second = LegacyRouteMigration.runIfNeeded(
            container: container, defaults: defaults, publishRevision: false)
        XCTAssertTrue(second.alreadyComplete)
        XCTAssertEqual(second.migratedPoints, 0)
    }

    func testStreamingWorkoutAccumulatorMatchesCanonicalBuilder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let values = [
            WorkoutRoutePointValue(workoutID: "a", routeID: "a-1", latitude: 31,
                                   longitude: 121, altitude: 10, timestamp: base,
                                   horizontalAccuracy: 5, speed: 1, course: 20),
            WorkoutRoutePointValue(workoutID: "b", routeID: "b-1", latitude: 32,
                                   longitude: 120, altitude: 20,
                                   timestamp: base.addingTimeInterval(10),
                                   horizontalAccuracy: nil, speed: nil, course: nil),
            WorkoutRoutePointValue(workoutID: "a", routeID: "a-1", latitude: 31.001,
                                   longitude: 121.001, altitude: 11,
                                   timestamp: base.addingTimeInterval(30),
                                   horizontalAccuracy: 7, speed: 1, course: 30),
            WorkoutRoutePointValue(workoutID: "a", routeID: "a-2", latitude: 31.002,
                                   longitude: 121.002, altitude: 12,
                                   timestamp: base.addingTimeInterval(40),
                                   horizontalAccuracy: 8, speed: 1, course: 40),
            WorkoutRoutePointValue(workoutID: "a", routeID: "a-1", latitude: 31.003,
                                   longitude: 121.003, altitude: 13,
                                   timestamp: base.addingTimeInterval(3_000),
                                   horizontalAccuracy: 9, speed: 1, course: 50),
        ]
        let activities = ["a": "walking", "b": "cycling"]
        let samples = values.enumerated().map { index, value in
            TrajectorySample(
                id: "workout:\(value.workoutID):\(Int64((value.timestamp.timeIntervalSince1970 * 1_000).rounded())):\(index)",
                source: .healthWorkout, sourceIdentifier: value.workoutID,
                sessionID: value.workoutID, routeID: value.routeID,
                activityType: activities[value.workoutID],
                latitude: value.latitude, longitude: value.longitude,
                timestamp: value.timestamp, altitude: value.altitude,
                horizontalAccuracy: value.horizontalAccuracy,
                speed: value.speed, course: value.course)
        }
        let expected = TrajectoryBuilder.build(samples: samples)
        let accumulator = WorkoutTrajectoryAccumulator(activityByWorkout: activities)
        for (index, value) in values.enumerated() {
            accumulator.append(value, globalIndex: index)
        }
        XCTAssertEqual(accumulator.finish(), expected)
    }

    private func sampleResolution() -> TrajectoryResolution {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<3).map { index in
            TrajectorySample(
                id: "cache-p\(index)", source: .healthWorkout,
                sourceIdentifier: "cache", sessionID: "cache", routeID: "route",
                activityType: "walking",
                latitude: 31 + Double(index) * 0.0001, longitude: 121,
                timestamp: base.addingTimeInterval(Double(index) * 30),
                horizontalAccuracy: 5)
        }
        return TrajectoryConflictResolver.resolve(TrajectoryBuilder.build(samples: samples))
    }

    @MainActor
    func testRepositoryReadsWorkoutPointsAcrossPageBoundary() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FootprintPoint.self, WorkoutRecord.self,
            WorkoutRouteRecord.self, WorkoutRoutePoint.self,
            configurations: configuration)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let workoutID = "paged-workout"
        let routeID = "paged-route"
        context.insert(WorkoutRecord(
            healthKitUUID: workoutID, workoutType: "walking",
            startDate: base, endDate: base.addingTimeInterval(20_005),
            duration: 20_005, distanceMeters: 20_005, caloriesKCal: 100,
            elevationGain: 0, routeAvailable: true, routeSyncState: .available))
        context.insert(WorkoutRouteRecord(routeID: routeID, workoutID: workoutID))
        for index in 0..<20_005 {
            context.insert(WorkoutRoutePoint(
                workoutID: workoutID,
                latitude: 31 + Double(index) * 0.000001,
                longitude: 121, altitude: 10,
                timestamp: base.addingTimeInterval(Double(index)),
                routeID: routeID, segmentIndex: 0, pointIndex: index,
                horizontalAccuracy: 5))
        }
        try context.save()

        let health = try TrajectoryRepository(container: container).load()
            .filter { $0.source == .healthWorkout }
        XCTAssertEqual(health.count, 1)
        XCTAssertEqual(health[0].segments.count, 1)
        XCTAssertEqual(health[0].segments[0].points.count, 20_005)
        XCTAssertTrue(health[0].segments[0].points.last?.id.hasSuffix(":20004") == true)
    }
}
