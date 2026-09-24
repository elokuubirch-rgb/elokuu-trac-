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

    func testCoreLocationBuilderUsesPersistedSegmentIDsBeforeLegacyGapInference() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            TrajectorySample(id: "a", source: .coreLocation, sessionID: "session",
                             segmentID: "segment-a", latitude: 31, longitude: 121,
                             timestamp: base),
            TrajectorySample(id: "b", source: .coreLocation, sessionID: "session",
                             segmentID: "segment-a", latitude: 31.0001, longitude: 121,
                             timestamp: base.addingTimeInterval(10)),
            TrajectorySample(id: "c", source: .coreLocation, sessionID: "session",
                             segmentID: "segment-b", latitude: 31.0002, longitude: 121,
                             timestamp: base.addingTimeInterval(20)),
        ]
        let trajectory = try XCTUnwrap(TrajectoryBuilder.build(samples: samples).first)
        XCTAssertEqual(trajectory.segments.count, 2)
        XCTAssertTrue(trajectory.segments[0].id.hasSuffix("segment-a"))
        XCTAssertTrue(trajectory.segments[1].id.hasSuffix("segment-b"))
    }

    func testResolutionCacheCanBeInvalidated() {
        let resolution = TrajectoryConflictResolver.resolve([])
        TrajectoryResolutionCache.shared.value = resolution
        XCTAssertEqual(TrajectoryResolutionCache.shared.value, resolution)

        TrajectoryResolutionCache.shared.invalidate()
        XCTAssertNil(TrajectoryResolutionCache.shared.value)
    }

    func testResolutionCacheTransientDiscardRequiresMatchingRevision() {
        let resolution = TrajectoryConflictResolver.resolve([])
        TrajectoryResolutionCache.shared.store(resolution, for: 41)

        TrajectoryResolutionCache.shared.discardTransientValue(for: 42)
        XCTAssertEqual(TrajectoryResolutionCache.shared.value(for: 41), resolution)

        TrajectoryResolutionCache.shared.discardTransientValue(for: 41)
        XCTAssertNil(TrajectoryResolutionCache.shared.value(for: 41))
    }

    func testPersistentTrajectoryCacheRequiresExactRevisionAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryCacheTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("resolution.bin")
        let cache = PersistentTrajectoryCache(fileURL: fileURL)
        let resolution = sampleResolution()

        XCTAssertTrue(cache.save(resolution, dataRevision: 41))
        let v3Directory = directory.appendingPathComponent(
            "trajectory-resolution-v3", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: v3Directory.appendingPathComponent("manifest-v3.plist").path))
        XCTAssertEqual(try trajectoryChunkURLs(in: directory).count, 1)
        XCTAssertEqual(cache.load(dataRevision: 41), resolution)
        XCTAssertNil(cache.load(dataRevision: 42))
    }

    func testPersistentTrajectoryCacheExposesCanonicalStaleGenerationOnlyForRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryCacheStale.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(
            fileURL: directory.appendingPathComponent("resolution.bin"))
        let resolution = sampleResolution()

        XCTAssertTrue(cache.save(resolution, dataRevision: 41))
        XCTAssertNil(cache.load(dataRevision: 42))

        let stale = try XCTUnwrap(cache.loadStaleTrajectories(before: 42))
        XCTAssertEqual(stale.dataRevision, 41)
        XCTAssertEqual(stale.trajectories, resolution.trajectories)
        XCTAssertNil(cache.loadStaleTrajectories(before: 41))
    }

    func testPersistentTrajectoryCacheReportsComponentMetricsAndBudgetState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryCacheMetrics.\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("resolution.bin")
        let configuration = TrajectoryCacheConfiguration(
            softDiskBudget: 1, hardDiskBudget: 2, schemaVersion: 3,
            chunkSize: 1_024, lodLevels: 5)
        let cache = PersistentTrajectoryCache(
            fileURL: fileURL, configuration: configuration)

        XCTAssertTrue(cache.save(sampleResolution(), dataRevision: 17))
        let disk = cache.diskSnapshot()
        XCTAssertGreaterThan(disk.bytes, 2)
        XCTAssertEqual(disk.budgetState, .aboveHardBudget)

        let metrics = try XCTUnwrap(cache.metricsSnapshot())
        XCTAssertEqual(metrics.totalBytes, Int(disk.bytes))
        XCTAssertGreaterThan(metrics.canonicalPointCount, 0)
        XCTAssertEqual(
            metrics.metadataBytes + metrics.geometryBytes + metrics.indexBytes
                + metrics.conflictBytes + metrics.resolvedMetadataBytes,
            metrics.totalBytes)
        XCTAssertGreaterThan(metrics.bytesPerCanonicalPoint, 0)

        cache.clear()
        XCTAssertEqual(cache.diskSnapshot(),
                       TrajectoryCacheDiskSnapshot(bytes: 0, budgetState: .normal))
        XCTAssertNil(cache.metricsSnapshot())
    }

    func testPersistentTrajectoryFlatCachePreservesOptionalAndConflictMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryCacheMetadata.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("resolution.bin")
        let cache = PersistentTrajectoryCache(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000.125)
        let point = TrajectoryPoint(
            id: "point-with-metadata", latitude: 31.123456, longitude: 121.654321,
            timestamp: base, altitude: 18.5, horizontalAccuracy: 4.25,
            speed: 2.75, course: 179.5, source: .healthWorkout)
        let quality = TrajectoryQuality(
            pointCount: 1, duration: 0, maximumGap: 0,
            accuratePointRatio: 1, confidence: 0.875)
        let segment = TrajectorySegment(
            id: "segment", trajectoryID: "winner", sessionID: "session",
            source: .healthWorkout, points: [point], startTime: base,
            endTime: base, quality: quality)
        let trajectory = Trajectory(
            id: "winner", source: .healthWorkout,
            sourceIdentifier: "source-id", sessionID: "session",
            startTime: base, endTime: base, activityType: "walking",
            segments: [segment], quality: quality,
            confidence: 0.875, displayPriority: 300)
        let conflict = TrajectoryConflict(
            winnerTrajectoryID: "winner", suppressedTrajectoryID: "loser",
            startTime: base, endTime: base.addingTimeInterval(10),
            overlapRatio: 0.9, matchingPointRatio: 0.8,
            medianDistanceMeters: 12.5)
        let resolved = ResolvedTrajectoryPoint(
            trajectoryID: "winner", sessionID: "session", segmentID: "segment",
            source: .healthWorkout, point: point, confidence: 0.875,
            suppressedByTrajectoryID: "loser", suppressedBySource: .imported)
        let resolution = TrajectoryResolution(
            trajectories: [trajectory], conflicts: [conflict], points: [resolved],
            comparedPairCount: 7)

        XCTAssertTrue(cache.save(resolution, dataRevision: 9))
        XCTAssertEqual(cache.load(dataRevision: 9), resolution)

        let chunkURL = try XCTUnwrap(trajectoryChunkURLs(in: directory).first)
        let valid = try Data(contentsOf: chunkURL)
        try Data(valid.prefix(17)).write(to: chunkURL, options: .atomic)
        XCTAssertNil(cache.load(dataRevision: 9))
        XCTAssertTrue(cache.save(resolution, dataRevision: 9))
        XCTAssertEqual(cache.load(dataRevision: 9), resolution)
    }

    func testPersistentTrajectoryChunkCacheDetectsMissingChunk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryMissingChunk.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(
            fileURL: directory.appendingPathComponent("resolution.bin"))
        let resolution = sampleResolution()

        XCTAssertTrue(cache.save(resolution, dataRevision: 1))
        let chunkURL = try XCTUnwrap(trajectoryChunkURLs(in: directory).first)
        try FileManager.default.removeItem(at: chunkURL)
        XCTAssertNil(cache.load(dataRevision: 1))

        XCTAssertTrue(cache.save(resolution, dataRevision: 1))
        XCTAssertEqual(cache.load(dataRevision: 1), resolution)
    }

    func testPersistentTrajectoryChunkCacheReusesOnlyUnchangedTrajectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentTrajectoryChunkReuse.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(
            fileURL: directory.appendingPathComponent("resolution.bin"))

        let first = multiTrajectoryResolution(secondLatitudeOffset: 0)
        XCTAssertTrue(cache.save(first, dataRevision: 1))
        let original = try chunkDataByName(in: directory)
        XCTAssertEqual(original.count, 2)

        XCTAssertTrue(cache.save(first, dataRevision: 2))
        XCTAssertEqual(try chunkDataByName(in: directory), original)

        let changed = multiTrajectoryResolution(secondLatitudeOffset: 0.002)
        XCTAssertTrue(cache.save(changed, dataRevision: 3))
        let updated = try chunkDataByName(in: directory)
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(Set(updated.keys).intersection(original.keys).count, 1)
        XCTAssertEqual(updated.filter { original[$0.key] != $0.value }.count, 1)
        XCTAssertEqual(cache.load(dataRevision: 3), changed)
    }

    func testPersistentCachePreservesExceptionsAboveTenThousandPoints() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeCacheExceptions.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(fileURL: directory.appendingPathComponent("resolution.bin"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<10_001).map { index in
            TrajectorySample(
                id: "p\(index)", source: .healthWorkout,
                sourceIdentifier: "large", sessionID: "large", routeID: "route",
                latitude: 31 + Double(index) * 0.00001, longitude: 121,
                timestamp: base.addingTimeInterval(Double(index)), horizontalAccuracy: 5)
        }
        let baseline = TrajectoryConflictResolver.resolve(TrajectoryBuilder.build(samples: samples))
        var points = baseline.points
        let original = try XCTUnwrap(points.last)
        points[points.count - 1] = ResolvedTrajectoryPoint(
            trajectoryID: original.trajectoryID, sessionID: original.sessionID,
            segmentID: original.segmentID, source: original.source, point: original.point,
            confidence: 0.123, suppressedByTrajectoryID: "special", suppressedBySource: .imported)
        let resolution = TrajectoryResolution(
            trajectories: baseline.trajectories, conflicts: baseline.conflicts,
            points: points, comparedPairCount: baseline.comparedPairCount)
        XCTAssertTrue(cache.save(resolution, dataRevision: 1))
        XCTAssertEqual(cache.load(dataRevision: 1), resolution)

        // 无法无损表达的输入应拒绝保存，旧版本仍然可用。
        let incomplete = TrajectoryResolution(
            trajectories: baseline.trajectories, conflicts: [], points: [], comparedPairCount: 0)
        XCTAssertFalse(cache.save(incomplete, dataRevision: 2))
        XCTAssertEqual(cache.load(dataRevision: 1), resolution)
    }

    func testRouteChunkPrototypeRejectsOutOfRangeNumbers() {
        let sample = RoutePointChunkPrototypeSample(
            latitude: Double.greatestFiniteMagnitude, longitude: 121, altitude: 0,
            timestamp: Date(), horizontalAccuracy: nil, speed: nil, course: nil)
        XCTAssertThrowsError(try RoutePointChunkPrototypeCodec.encode(
            workoutID: "invalid", routeID: nil, segmentID: "segment", samples: [sample]))
    }

    func testPersistentRouteLODCacheRoundTripsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentRouteLOD.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentRouteLODCache(directoryURL: directory)
        let coordinates = (0..<500).map { index in
            CLLocationCoordinate2D(
                latitude: 31 + Double(index) * 0.00001,
                longitude: 121 + sin(Double(index) / 20) * 0.0001)
        }
        let geometry = ZoomAwareRouteGeometry(coordinates: coordinates)
        XCTAssertFalse(geometry.levels.isEmpty)

        cache.save(levels: geometry.levels, stableID: "route-a",
                   contentFingerprint: 42, rawPointCount: coordinates.count)
        let loaded = try XCTUnwrap(cache.load(
            stableID: "route-a", contentFingerprint: 42,
            rawPointCount: coordinates.count))
        XCTAssertEqual(loaded.map(\.maximumMapPointError),
                       geometry.levels.map(\.maximumMapPointError))
        XCTAssertEqual(loaded.map { $0.points.count },
                       geometry.levels.map { $0.points.count })
        XCTAssertGreaterThan(cache.diskBytes(), 0)
        XCTAssertNil(cache.load(stableID: "route-a", contentFingerprint: 43,
                                rawPointCount: coordinates.count))

        let storedURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        var damaged = try Data(contentsOf: storedURL)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: storedURL, options: .atomic)
        XCTAssertNil(cache.load(stableID: "route-a", contentFingerprint: 42,
                                rawPointCount: coordinates.count))
        cache.save(levels: geometry.levels, stableID: "route-a",
                   contentFingerprint: 42, rawPointCount: coordinates.count)
        XCTAssertNotNil(cache.load(stableID: "route-a", contentFingerprint: 42,
                                   rawPointCount: coordinates.count))

        cache.clear()
        XCTAssertEqual(cache.diskBytes(), 0)
    }

    func testRoutePointChunkPrototypePreservesMetadataAndQuantizedSamples() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<10_000).map { index in
            RoutePointChunkPrototypeSample(
                latitude: 31.1234567 + Double(index) * 0.000001,
                longitude: 121.7654321 + sin(Double(index) / 100) * 0.0001,
                altitude: 12.34 + Double(index % 20) / 10,
                timestamp: base.addingTimeInterval(Double(index)),
                horizontalAccuracy: index.isMultiple(of: 7) ? nil : 4.25,
                speed: index.isMultiple(of: 11) ? nil : 1.75,
                course: index.isMultiple(of: 13) ? nil : 123.45)
        }
        let data = try RoutePointChunkPrototypeCodec.encode(
            workoutID: "workout", routeID: "route", segmentID: "segment",
            samples: samples)
        let decoded = try RoutePointChunkPrototypeCodec.decode(data)

        XCTAssertEqual(decoded.workoutID, "workout")
        XCTAssertEqual(decoded.routeID, "route")
        XCTAssertEqual(decoded.segmentID, "segment")
        XCTAssertEqual(decoded.samples.count, samples.count)
        XCTAssertLessThan(data.count, samples.count * 32)
        for index in stride(from: 0, to: samples.count, by: 997) {
            XCTAssertEqual(decoded.samples[index].latitude,
                           samples[index].latitude, accuracy: 0.000000051)
            XCTAssertEqual(decoded.samples[index].longitude,
                           samples[index].longitude, accuracy: 0.000000051)
            XCTAssertEqual(decoded.samples[index].timestamp,
                           samples[index].timestamp)
            XCTAssertEqual(decoded.samples[index].horizontalAccuracy,
                           samples[index].horizontalAccuracy)
            XCTAssertEqual(decoded.samples[index].speed, samples[index].speed)
            XCTAssertEqual(decoded.samples[index].course, samples[index].course)
        }
    }

    func testFootprintSnapshotSharesRepeatedMetadataWithoutChangingValueSemantics() {
        var pool = FootprintSnapshotMetadataPool()
        let firstMetadata = pool.metadata(
            source: FootprintSource.health.rawValue,
            trajectoryID: "trajectory", sessionID: "session", segmentID: "segment",
            isSuppressedDuplicate: true,
            suppressedBySource: TrajectorySource.imported.rawValue)
        let secondMetadata = pool.metadata(
            source: FootprintSource.health.rawValue,
            trajectoryID: "trajectory", sessionID: "session", segmentID: "segment",
            isSuppressedDuplicate: true,
            suppressedBySource: TrajectorySource.imported.rawValue)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pooled = FootprintSnapshot(
            lat: 31, lon: 121, t: timestamp, metadata: firstMetadata)
        let independentlyCreated = FootprintSnapshot(
            lat: 31, lon: 121, t: timestamp,
            source: FootprintSource.health.rawValue,
            trajectoryID: "trajectory", sessionID: "session", segmentID: "segment",
            isSuppressedDuplicate: true,
            suppressedBySource: TrajectorySource.imported.rawValue)

        XCTAssertTrue(firstMetadata === secondMetadata)
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pooled, independentlyCreated)
        XCTAssertEqual(pooled.source, FootprintSource.health.rawValue)
        XCTAssertEqual(pooled.trajectoryID, "trajectory")
        XCTAssertEqual(pooled.sessionID, "session")
        XCTAssertEqual(pooled.segmentID, "segment")
        XCTAssertTrue(pooled.isSuppressedDuplicate)
        XCTAssertEqual(pooled.suppressedBySource, TrajectorySource.imported.rawValue)
        XCTAssertLessThanOrEqual(MemoryLayout<FootprintSnapshot>.stride, 40)
    }

    func testProfessionalLineUsesOneIndexedOverlayAndPreservesThreeStrokeParameters() {
        let historical = ProfessionalLineStyle.make(alpha: 0.8, width: 2.6, tag: 0)
        XCTAssertEqual(MapOverlayAmplificationPolicy.overlayCount(forLogicalRouteCount: 900), 1)
        XCTAssertEqual(MapOverlayAmplificationPolicy.polylineCount(forLogicalRouteCount: 900), 0)
        XCTAssertEqual(historical.casing.alpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(historical.casing.width, 5.0, accuracy: 0.0001)
        XCTAssertEqual(historical.casing.tone, .casing)
        XCTAssertEqual(historical.glow.alpha, 0.09, accuracy: 0.0001)
        XCTAssertEqual(historical.glow.width, 6.6, accuracy: 0.0001)
        XCTAssertEqual(historical.glow.tone, .glow)
        XCTAssertEqual(historical.core.alpha, 0.92, accuracy: 0.0001)
        XCTAssertEqual(historical.core.width, 2.8, accuracy: 0.0001)
        XCTAssertEqual(historical.core.tone, .theme)

        let workout = ProfessionalLineStyle.workoutOverview
        XCTAssertEqual(workout.casing.alpha, 0, accuracy: 0.0001)
        XCTAssertEqual(workout.casing.width, 1.5, accuracy: 0.0001)
        XCTAssertEqual(workout.glow.alpha, 0.025, accuracy: 0.0001)
        XCTAssertEqual(workout.glow.width, 3, accuracy: 0.0001)
        XCTAssertEqual(workout.core.alpha, 0.11, accuracy: 0.0001)
        XCTAssertEqual(workout.core.width, 1.5, accuracy: 0.0001)
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

    func testTrailIndexSpatialBoundsGridMatchesExhaustiveProjection() throws {
        struct SegmentPair {
            let a: TrailPoint
            let b: TrailPoint
        }
        var state: UInt64 = 0x5eed_cafe
        func randomUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
        var pairs: [SegmentPair] = []
        var points: [TrailPoint] = []
        for index in 0..<2_000 {
            let aLat = 31.0 + randomUnit() * 0.4
            let aLon = 121.0 + randomUnit() * 0.4
            let bLat = aLat + (randomUnit() - 0.5) * 0.001
            let bLon = aLon + (randomUnit() - 0.5) * 0.001
            let boundary = "spatial-\(index)"
            let a = TrailPoint(lat: aLat, lon: aLon, t: Double(index * 20),
                               trajectoryID: boundary, sessionID: boundary,
                               segmentID: boundary)
            let b = TrailPoint(lat: bLat, lon: bLon, t: Double(index * 20 + 10),
                               trajectoryID: boundary, sessionID: boundary,
                               segmentID: boundary)
            pairs.append(SegmentPair(a: a, b: b))
            points.append(contentsOf: [a, b])
        }
        let trailIndex = TrailIndex(points: points)

        func exhaustive(lat: Double, lon: Double, within maxMeters: Double)
            -> (lat: Double, lon: Double, distance: Double)? {
            var best: (lat: Double, lon: Double, distance: Double)?
            for pair in pairs {
                let meanLat = (lat + pair.a.lat + pair.b.lat) / 3 * .pi / 180
                let metersPerLon = max(1, 111_320 * cos(meanLat))
                let ax = (pair.a.lon - lon) * metersPerLon
                let ay = (pair.a.lat - lat) * 111_320
                let bx = (pair.b.lon - lon) * metersPerLon
                let by = (pair.b.lat - lat) * 111_320
                let vx = bx - ax, vy = by - ay
                let lengthSquared = vx * vx + vy * vy
                let fraction = lengthSquared > 0
                    ? min(1, max(0, -(ax * vx + ay * vy) / lengthSquared)) : 0
                let projectedLat = pair.a.lat + (pair.b.lat - pair.a.lat) * fraction
                let projectedLon = pair.a.lon + (pair.b.lon - pair.a.lon) * fraction
                let distance = GeoMath.distanceMeters(
                    from: (lat, lon), to: (projectedLat, projectedLon))
                if distance <= maxMeters, best == nil || distance < best!.distance {
                    best = (projectedLat, projectedLon, distance)
                }
            }
            return best
        }

        for _ in 0..<100 {
            let lat = 31.0 + randomUnit() * 0.4
            let lon = 121.0 + randomUnit() * 0.4
            let expected = exhaustive(lat: lat, lon: lon, within: 500)
            let actual = trailIndex.nearestOnRoute(to: lat, lon: lon, within: 500)
            XCTAssertEqual(actual == nil, expected == nil)
            if let expected, let actual {
                XCTAssertEqual(actual.lat, expected.lat, accuracy: 0.000_000_001)
                XCTAssertEqual(actual.lon, expected.lon, accuracy: 0.000_000_001)
                XCTAssertEqual(actual.distance, expected.distance, accuracy: 0.000_001)
            }
        }
    }

    func testTrailIndexSpatialBoundsGridKeepsLongDiagonalSegment() throws {
        let index = TrailIndex(points: [
            TrailPoint(lat: 31, lon: 121, t: 1_000,
                       trajectoryID: "long", sessionID: "long", segmentID: "long"),
            TrailPoint(lat: 31.1, lon: 121.1, t: 2_000,
                       trajectoryID: "long", sessionID: "long", segmentID: "long")
        ])
        let match = try XCTUnwrap(
            index.nearestOnRoute(to: 31.05, lon: 121.05, within: 60))
        XCTAssertEqual(match.lat, 31.05, accuracy: 0.000_001)
        XCTAssertEqual(match.lon, 121.05, accuracy: 0.000_001)
        XCTAssertLessThan(match.distance, 1)
    }

    func testTrailIndexSpatialBoundsGridHandlesPolarLongitudeExpansion() throws {
        let index = TrailIndex(points: [
            TrailPoint(lat: 89.999, lon: 0, t: 1_000,
                       trajectoryID: "polar", sessionID: "polar", segmentID: "polar"),
            TrailPoint(lat: 89.999, lon: 0.01, t: 1_100,
                       trajectoryID: "polar", sessionID: "polar", segmentID: "polar")
        ])
        let match = try XCTUnwrap(
            index.nearestOnRoute(to: 89.999, lon: 0.005, within: 60))
        XCTAssertEqual(match.lat, 89.999, accuracy: 0.000_001)
        XCTAssertEqual(match.lon, 0.005, accuracy: 0.000_001)
        XCTAssertLessThan(match.distance, 1)
    }

    func testPhotoSnapBatchCacheReusesOnlyExactCoordinateSpatialMatch() {
        let index = TrailIndex(points: [
            TrailPoint(lat: 31, lon: 121, t: 1_000,
                       trajectoryID: "near", sessionID: "near", segmentID: "near",
                       confidence: 0.5),
            TrailPoint(lat: 31, lon: 121.01, t: 1_100,
                       trajectoryID: "near", sessionID: "near", segmentID: "near",
                       confidence: 0.5),
            TrailPoint(lat: 32, lon: 122, t: 1_000,
                       trajectoryID: "far", sessionID: "far", segmentID: "far",
                       confidence: 1),
            TrailPoint(lat: 32, lon: 122.01, t: 1_100,
                       trajectoryID: "far", sessionID: "far", segmentID: "far",
                       confidence: 1)
        ])
        var context = TrailSnapQueryContext()
        let first = snapPhotoToTrailResult(
            lat: 31.001, lon: 121.005, time: 1_050, trails: index,
            queryContext: &context)
        let second = snapPhotoToTrailResult(
            lat: 31.001, lon: 121.005, time: 1_060, trails: index,
            queryContext: &context)
        let distinct = snapPhotoToTrailResult(
            lat: 31.001_001, lon: 121.005, time: 1_060, trails: index,
            queryContext: &context)

        XCTAssertEqual(first.kind, .snapped)
        XCTAssertEqual(first.lat, second.lat, accuracy: 0.000_000_001)
        XCTAssertEqual(first.lon, second.lon, accuracy: 0.000_000_001)
        XCTAssertEqual(context.spatialCacheHits, 1)
        XCTAssertEqual(context.spatialCacheMisses, 2)
        XCTAssertEqual(distinct.kind, .snapped)
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

    func testLargeOverlappingTrajectoryConflictReusesPreparedGeometry() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let pointCount = 40_000
        var samples: [TrajectorySample] = []
        samples.reserveCapacity(pointCount * 2)
        for index in 0..<pointCount {
            let timestamp = base.addingTimeInterval(Double(index))
            let latitude = 31 + Double(index) * 0.000_001
            samples.append(TrajectorySample(
                id: "auto-\(index)", source: .coreLocation,
                sessionID: "auto", latitude: latitude, longitude: 121,
                timestamp: timestamp, horizontalAccuracy: 8))
            samples.append(TrajectorySample(
                id: "health-\(index)", source: .healthWorkout,
                sourceIdentifier: "workout", sessionID: "workout", routeID: "route",
                latitude: latitude, longitude: 121,
                timestamp: timestamp, horizontalAccuracy: 5))
        }
        let trajectories = TrajectoryBuilder.build(samples: samples)
        XCTAssertEqual(trajectories.count, 2)

        let started = CACurrentMediaTime()
        let resolution = TrajectoryConflictResolver.resolve(trajectories)
        let elapsed = CACurrentMediaTime() - started

        XCTAssertEqual(resolution.comparedPairCount, 1)
        XCTAssertEqual(resolution.conflicts.count, 1)
        XCTAssertEqual(resolution.points.count, pointCount * 2)
        XCTAssertEqual(resolution.points.filter {
            $0.source == .coreLocation && $0.suppressedBySource == .healthWorkout
        }.count, pointCount)
        XCTAssertLessThan(elapsed, 3,
                          "40k 点重叠轨迹不得为每个插值探针重复排序全部 geometry")
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
                id: "w:\(index)",
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

    private func trajectoryChunkURLs(in directory: URL) throws -> [URL] {
        let chunks = directory
            .appendingPathComponent("trajectory-resolution-v3", isDirectory: true)
            .appendingPathComponent("trajectory", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: chunks, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func chunkDataByName(in directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: trajectoryChunkURLs(in: directory).map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    private func multiTrajectoryResolution(
        secondLatitudeOffset: Double
    ) -> TrajectoryResolution {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [TrajectorySample] = []
        for session in 0..<2 {
            for index in 0..<4 {
                let sessionOffset = session == 1 ? secondLatitudeOffset : 0
                let latitude = 31 + Double(session) * 0.1
                    + sessionOffset + Double(index) * 0.0001
                let timestamp = base.addingTimeInterval(
                    Double(session) * 86_400 + Double(index) * 30)
                samples.append(TrajectorySample(
                    id: "session-\(session)-p\(index)",
                    source: .healthWorkout,
                    sourceIdentifier: "session-\(session)",
                    sessionID: "session-\(session)",
                    routeID: "route-\(session)",
                    latitude: latitude,
                    longitude: 121,
                    timestamp: timestamp,
                    horizontalAccuracy: 5))
            }
        }
        return TrajectoryConflictResolver.resolve(
            TrajectoryBuilder.build(samples: samples))
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
