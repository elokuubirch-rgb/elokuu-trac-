import XCTest
import MapKit
@testable import LifeFootprints

final class MapStartupTests: XCTestCase {
    func testTimeFilterChoicesAndRecordsAcrossCalendarYears() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for year in [2026, 2027, 2028] {
            let scopes = MapTimeScope.choices(currentYear: year)
            XCTAssertEqual(scopes, [.all, .year(year), .year(year - 1)])
            let dates = (year - 2...year).map {
                calendar.date(from: DateComponents(year: $0, month: 6, day: 1))!
            }
            XCTAssertEqual(dates.filter { scopes[0].contains($0, calendar: calendar) }.count, 3)
            XCTAssertEqual(dates.filter { scopes[1].contains($0, calendar: calendar) }, [dates[2]])
            XCTAssertEqual(dates.filter { scopes[2].contains($0, calendar: calendar) }, [dates[1]])
        }
    }
    func testReviewPhotoHighlightUsesNearbyRegionInsteadOfPreviousMapScale() {
        let highlight = MapPhotoHighlight(
            assetID: "photo-1",
            latitude: 31.2304,
            longitude: 121.4737,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            thumbnailPath: nil,
            clusterID: nil,
            focusDistance: 1_200
        )

        XCTAssertEqual(highlight.focusRegion.center.latitude, 31.2304, accuracy: 0.000_001)
        XCTAssertEqual(highlight.focusRegion.center.longitude, 121.4737, accuracy: 0.000_001)
        XCTAssertEqual(highlight.focusRegion.span.latitudeDelta, 1_200 / 55_000, accuracy: 0.000_001)
        XCTAssertEqual(highlight.focusRegion.span.longitudeDelta, 1_200 / 55_000, accuracy: 0.000_001)
        XCTAssertLessThan(highlight.focusRegion.span.latitudeDelta, 0.03,
                          "回顾地点跳转不能沿用全览地图跨度")
    }

    func testQuietMapPresentationHidesBuildingsOnlyForQuietStyle() {
        XCTAssertFalse(MapBasePresentation.showsBuildings(for: "quiet"))
        XCTAssertEqual(MapBasePresentation.quietWashOpacity, 0.22, accuracy: 0.0001)
        XCTAssertTrue(MapBasePresentation.showsBuildings(for: "standard"))
        XCTAssertTrue(MapBasePresentation.showsBuildings(for: "satellite"))
        XCTAssertTrue(MapBasePresentation.showsBuildings(for: "topographic"))
        XCTAssertTrue(MapBasePresentation.showsBuildings(for: "custom:test"))
    }

    func testMapLoadingBackgroundMatchesDesignToken() {
        let color = MapBasePresentation.loadingBackground
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 9.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(green, 11.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(blue, 18.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(alpha, 1, accuracy: 0.0001)
    }

    func testMilestonesKeepFirstOccurrenceAndUseRelativeTime() {
        let recorder = MapStartupDiagnostics()
        recorder.mark(.processStarted)
        recorder.mark(.photoLayerReady)
        let first = recorder.snapshot()
        recorder.mark(.photoLayerReady)
        XCTAssertEqual(recorder.snapshot(), first)
        XCTAssertEqual(first["processStarted"], 0)
        XCTAssertGreaterThanOrEqual(first["photoLayerReady"] ?? -1, 0)
        XCTAssertNil(first["cachedContentReady"])
    }

    func testPreviewPreservesBoundariesAndReducesLargeHistory() throws {
        let points = (0..<100_000).map { index in
            FootprintSnapshot(lat: 31 + Double(index) / 1e7, lon: 121,
                t: Date(timeIntervalSince1970: Double(index)), source: "health",
                trajectoryID: "workout", sessionID: "workout",
                segmentID: index < 50_001 ? "first" : "second")
        }
        let preview = try XCTUnwrap(MapDisplaySnapshotStore.previewPoints(points))
        XCTAssertLessThanOrEqual(preview.count, MapDisplaySnapshotStore.maximumPoints)
        XCTAssertEqual(preview.first?.snapshot, points.first)
        XCTAssertEqual(preview.last?.snapshot, points.last)
        XCTAssertTrue(preview.contains { $0.snapshot == points[50_000] })
        XCTAssertTrue(preview.contains { $0.snapshot == points[50_001] })
    }

    func testPreviewDoesNotTreatInterleavedLayersAsRouteBoundaries() throws {
        let points = (0..<100_000).map { index in
            let workout = index.isMultiple(of: 2)
            return FootprintSnapshot(
                lat: 31 + Double(index) / 1e7, lon: 121,
                t: Date(timeIntervalSince1970: Double(index)),
                source: workout ? FootprintSource.health.rawValue : FootprintSource.gps.rawValue,
                trajectoryID: workout ? "workout" : "location",
                sessionID: workout ? "workout" : "location",
                segmentID: workout ? "workout-segment" : "location-segment")
        }
        let preview = try XCTUnwrap(MapDisplaySnapshotStore.previewPoints(points))
        XCTAssertLessThanOrEqual(preview.count, MapDisplaySnapshotStore.maximumPoints)
        XCTAssertEqual(preview.first?.snapshot, points.first)
        XCTAssertEqual(preview.last?.snapshot, points.last)
    }

    func testPreviewDoesNotTreatInterleavedWorkoutsAsRouteBoundaries() throws {
        let points = (0..<100_000).map { index in
            let route = index % 20
            return FootprintSnapshot(
                lat: 31 + Double(index) / 1e7, lon: 121,
                t: Date(timeIntervalSince1970: Double(index)),
                source: FootprintSource.health.rawValue,
                trajectoryID: "workout-\(route)", sessionID: "workout-\(route)",
                segmentID: "segment-\(route)")
        }
        let preview = try XCTUnwrap(MapDisplaySnapshotStore.previewPoints(points))
        XCTAssertLessThanOrEqual(preview.count, MapDisplaySnapshotStore.targetPointCount)
        for route in 0..<20 {
            XCTAssertTrue(preview.contains {
                $0.snapshot.trajectoryID == "workout-\(route)"
                    && $0.snapshot.t == Date(timeIntervalSince1970: Double(route))
            })
            let lastIndex = 99_980 + route
            XCTAssertTrue(preview.contains {
                $0.snapshot.trajectoryID == "workout-\(route)"
                    && $0.snapshot.t == Date(timeIntervalSince1970: Double(lastIndex))
            })
        }
    }

    func testDisplayCacheRejectsRevisionChangesAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.plist")
        let store = MapDisplaySnapshotStore(url: url)
        let revision = DataRevisionStore.snapshot()
        XCTAssertNil(store.load(revision: revision))
        let point = FootprintSnapshot(lat: 31, lon: 121, t: Date(), source: "gps")
        var stats = FootprintStats()
        stats.pointCount = 1_826_794
        XCTAssertTrue(store.save(points: [point], months: [point.t],
            region: .init(center: .init(latitude: 31, longitude: 121),
                          span: .init(latitudeDelta: 1, longitudeDelta: 1)),
            stats: stats, revision: revision))
        let restored = try XCTUnwrap(store.load(revision: revision))
        XCTAssertEqual(restored.points.first?.snapshot, point)
        XCTAssertEqual(restored.stats.pointCount, 1_826_794)
        XCTAssertNotNil(store.load(revision: DataRevisionSnapshot(
            trajectory: revision.trajectory + 1, photo: revision.photo,
            place: revision.place, stats: revision.stats)))
        XCTAssertNotNil(store.load(revision: DataRevisionSnapshot(
            trajectory: revision.trajectory, photo: revision.photo,
            place: revision.place + 1, stats: revision.stats)))
        XCTAssertNil(store.load(revision: revision,
            safetyRevision: DataRevisionStore.displaySafetyRevision() + 1))
        try Data("corrupt".utf8).write(to: url)
        XCTAssertNil(store.load(revision: revision))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStatsSnapshotLoadsWithoutMapSnapshotAndTracksFreshness() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatsSnapshotStore(
            url: directory.appendingPathComponent("stats.plist"))
        let revision = DataRevisionSnapshot(
            trajectory: 7, photo: 2, place: 5, stats: 9)
        var stats = FootprintStats()
        stats.pointCount = 1_826_794
        stats.distanceKM = 12_345.5
        stats.activeDays = 730
        stats.firstDate = Date(timeIntervalSince1970: 100)
        stats.lastDate = Date(timeIntervalSince1970: 200)
        stats.perYear = [(2025, 800_000), (2026, 1_026_794)]

        XCTAssertTrue(store.saveSummary(stats, revision: revision))
        let fresh = try XCTUnwrap(store.load(revision: revision))
        XCTAssertTrue(fresh.summaryIsFresh)
        XCTAssertFalse(fresh.clustersAreFresh)
        XCTAssertEqual(fresh.snapshot.stats.pointCount, 1_826_794)
        XCTAssertEqual(fresh.snapshot.stats.perYear.map(\.year), [2025, 2026])

        let newer = DataRevisionSnapshot(
            trajectory: 8, photo: 2, place: 6, stats: 10)
        let stale = try XCTUnwrap(store.load(revision: newer))
        XCTAssertFalse(stale.summaryIsFresh)
        XCTAssertEqual(stale.snapshot.stats.pointCount, 1_826_794)
    }

    func testStatsSnapshotPersistsVersionedDenseAreas() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.plist")
        let store = StatsSnapshotStore(url: url)
        let revision = DataRevisionSnapshot(
            trajectory: 4, photo: 0, place: 3, stats: 4)
        var stats = FootprintStats()
        stats.pointCount = 20
        XCTAssertTrue(store.saveSummary(stats, revision: revision))
        XCTAssertTrue(store.saveClusters([
            StatsDenseArea(lat: 31.2, lon: 121.5, count: 10),
            StatsDenseArea(lat: 35.7, lon: 139.7, count: 8),
        ], revision: revision))

        let restored = try XCTUnwrap(store.load(revision: revision))
        XCTAssertTrue(restored.clustersAreFresh)
        XCTAssertEqual(restored.snapshot.clusters.count, 2)
        XCTAssertEqual(restored.snapshot.clusters.first?.count, 10)

        try Data("corrupt".utf8).write(to: url)
        XCTAssertNil(store.load(revision: revision))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPhotoClustersDoNotRequireTrailIndex() {
        let photo = PhotoRecord(localIdentifier: "photo", latitude: 31.2,
            longitude: 121.5, timestamp: Date())
        photo.regionState = 1
        photo.provinceName = "上海市"
        let clusters = ClusterIndex.build(records: [photo], trails: nil)
        XCTAssertEqual(clusters.province.first?.count, 1)
        XCTAssertEqual(clusters.single.first?.sampleIds, ["photo"])
        XCTAssertEqual(clusters.single.first?.lat ?? 0, photo.latitude, accuracy: 1e-8)
        XCTAssertEqual(clusters.single.first?.lon ?? 0, photo.longitude, accuracy: 1e-8)
    }

    @MainActor
    func testPhotoClusterAnnotationAccessibilityActivationOpensCluster() {
        let cluster = PhotoCluster(
            id: "single|test",
            level: .single,
            name: "上海",
            count: 3,
            visits: 1,
            lat: 31.2,
            lon: 121.5,
            isCountryLevel: false,
            thumbPath: nil,
            sampleIds: nil,
            locationEvidence: "轨迹参考"
        )
        let annotation = PhotoClusterAnnotation(cluster: cluster)
        let view = PhotoClusterAnnotationView(annotation: annotation, reuseIdentifier: "test")
        var activatedID: String?

        view.configure(annotation: annotation, size: 44) { activatedID = $0.id }

        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertTrue(view.accessibilityTraits.contains(.button))
        XCTAssertFalse(view.accessibilityLabel?.isEmpty ?? true)
        XCTAssertFalse(view.accessibilityHint?.isEmpty ?? true)
        XCTAssertTrue(view.accessibilityActivate())
        XCTAssertEqual(activatedID, cluster.id)
    }

    func testPhotoAssociationRoundTripAndPhotoFingerprintInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoTrajectoryAssociationStore(
            url: directory.appendingPathComponent("associations.plist"))
        let photo = PhotoRecord(localIdentifier: "photo-a", latitude: 31.2,
            longitude: 121.5, timestamp: Date(timeIntervalSince1970: 100))
        let result = TrailSnapResult(kind: .snapped, lat: 31.2001, lon: 121.5001,
            trajectoryID: "trajectory-a", sessionID: "session-a", segmentID: "segment-a",
            source: .healthWorkout, confidence: 0.9, distance: 12, timeDelta: 2)
        let record = PhotoTrajectoryAssociationRecord(photo: photo, result: result)
        let safety = DataRevisionStore.displaySafetyRevision()
        XCTAssertTrue(store.save(records: [photo.localIdentifier: record], safetyRevision: safety))
        let hit = store.lookup(photos: [photo], safetyRevision: safety)
        XCTAssertEqual(hit.matches[photo.localIdentifier], result)
        XCTAssertTrue(hit.missingPhotoIDs.isEmpty)

        photo.latitude += 0.01
        let changed = store.lookup(photos: [photo], safetyRevision: safety)
        XCTAssertNil(changed.matches[photo.localIdentifier])
        XCTAssertEqual(changed.missingPhotoIDs, [photo.localIdentifier])
        XCTAssertTrue(store.lookup(photos: [photo], safetyRevision: safety + 1).matches.isEmpty)
    }

    func testPhotoClusterUsesPersistedAssociationWithoutTrailIndex() {
        let photo = PhotoRecord(localIdentifier: "photo", latitude: 31.2,
            longitude: 121.5, timestamp: Date())
        photo.regionState = 1
        photo.provinceName = "上海市"
        let match = TrailSnapResult(kind: .snapped, lat: 30, lon: 120,
            trajectoryID: "route", confidence: 0.8, distance: 20)
        let clusters = ClusterIndex.build(records: [photo], trails: nil,
            associations: [photo.localIdentifier: match])
        XCTAssertEqual(clusters.single.first?.lat ?? 0, match.lat, accuracy: 1e-8)
        XCTAssertEqual(clusters.single.first?.lon ?? 0, match.lon, accuracy: 1e-8)
        XCTAssertEqual(clusters.single.first?.locationEvidence, "轨迹参考")
    }

    func testAdditiveWritesKeepPreviewButDeletionInvalidatesIt() throws {
        let suite = "MapStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = DataRevisionStore.displaySafetyRevision(defaults: defaults)
        DataRevisionStore.commit([.trajectory, .place], reason: "new GPS batch",
            invalidatesDisplay: false, defaults: defaults, publish: false)
        XCTAssertEqual(DataRevisionStore.displaySafetyRevision(defaults: defaults), initial)
        XCTAssertEqual(DataRevisionStore.snapshot(defaults: defaults).trajectory, 1)
        DataRevisionStore.commit([.trajectory, .place], reason: "delete route",
            defaults: defaults, publish: false)
        XCTAssertEqual(DataRevisionStore.displaySafetyRevision(defaults: defaults), initial + 1)
        DataRevisionStore.commit(.photo, reason: "photo changed", defaults: defaults, publish: false)
        XCTAssertEqual(DataRevisionStore.displaySafetyRevision(defaults: defaults), initial + 1)
    }
}
