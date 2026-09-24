import XCTest
import SwiftData
@testable import LifeFootprints

@MainActor
final class ImportIntegrityTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: FootprintPoint.self, PhotoRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func point(_ seconds: Int, lon: Double = 121) -> FootprintDraft {
        FootprintDraft(latitude: 31, longitude: lon,
                       timestamp: Date(timeIntervalSince1970: Double(seconds)), source: "csv")
    }

    func testLoopAndNearbyPointsSurviveAndRepeatImportAddsZero() async throws {
        let container = try container()
        let points = [point(0), point(1, lon: 121.00001), point(2, lon: 121.001), point(3)]
        let first = await FootprintStore.importMeasurements(points, container: container)
        let second = await FootprintStore.importMeasurements(points, container: container)
        XCTAssertEqual(first.added, 4)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.duplicates, 4)
        XCTAssertEqual(first.status, .completed)
        let records = try ModelContext(container).fetch(FetchDescriptor<FootprintPoint>(
            sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(records.map(\.longitude), points.map(\.longitude))
        XCTAssertEqual(records.map(\.timestamp), points.map(\.timestamp))
    }

    func testConcurrentSameFileImportsAreSerializedAndIdempotent() async throws {
        let container = try container()
        let points = (0..<100).map { point($0) }
        async let first = FootprintStore.importMeasurements(points, container: container)
        async let second = FootprintStore.importMeasurements(points, container: container)
        let results = await [first, second]
        XCTAssertEqual(results.reduce(0) { $0 + $1.added }, 100)
        XCTAssertEqual(results.reduce(0) { $0 + $1.duplicates }, 100)
    }

    func testTransformedCSVRetainsOriginalCoordinateAndProvenance() async throws {
        let container = try container()
        let raw = CoordinateTransform.wgs84ToGcj02(latitude: 31.2304,
                                                    longitude: 121.4737)
        let normalization = CoordinateTransform.normalize(
            latitude: raw.latitude, longitude: raw.longitude, sourceSystem: .gcj02)
        let draft = FootprintDraft(
            latitude: normalization.normalized.latitude,
            longitude: normalization.normalized.longitude,
            timestamp: Date(timeIntervalSince1970: 10), source: "csv",
            rawLatitude: normalization.raw.latitude,
            rawLongitude: normalization.raw.longitude,
            sourceCoordinateSystem: normalization.sourceSystem,
            coordinateTransformVersion: normalization.transformVersion)

        let result = await FootprintStore.importMeasurements([draft], container: container)
        XCTAssertEqual(result.added, 1)
        let record = try XCTUnwrap(ModelContext(container)
            .fetch(FetchDescriptor<FootprintPoint>()).first)
        XCTAssertEqual(record.sourceCoordinateSystem, .gcj02)
        XCTAssertEqual(record.originalLatitude, raw.latitude, accuracy: 1e-12)
        XCTAssertEqual(record.originalLongitude, raw.longitude, accuracy: 1e-12)
        XCTAssertEqual(record.coordinateTransformVersion, CoordinateTransform.algorithmVersion)
        XCTAssertNotEqual(record.latitude, record.originalLatitude)
    }

    func testPartialFailureReportsCommittedCountAndRetryResumesWithoutDuplicates() async throws {
        let container = try container()
        let points = (0..<5_003).map { point($0) }
        let first = await FootprintStore.importMeasurements(points, container: container,
            persistBatch: { batch, container in
                if batch.count < 5_000 { throw NSError(domain: "SyntheticDiskFailure", code: 1) }
                let context = ModelContext(container)
                context.autosaveEnabled = false
                for draft in batch { context.insert(FootprintPoint(draft: draft)) }
                try context.save()
            })
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.added, 5_000)
        let retry = await FootprintStore.importMeasurements(points, container: container)
        XCTAssertEqual(retry.status, .completed)
        XCTAssertEqual(retry.added, 3)
        XCTAssertEqual(retry.duplicates, 5_000)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<FootprintPoint>()), 5_003)
    }

    func testPreResetCSVAndPhotoResultsCannotEnterFreshDatabase() async throws {
        let container = try container()
        let gate = LocalImportCoordinator.shared
        let old = try XCTUnwrap(gate.capture())
        let reset = try gate.beginReset()
        await gate.waitForActiveWrites()
        gate.finishReset(reset)
        let csv = await FootprintStore.importMeasurements([point(0)], container: container, token: old)
        let photo = await PhotoStore.importPhotos([
            PhotoInfo(localIdentifier: "old-photo", latitude: 31, longitude: 121, timestamp: Date())
        ], container: container, token: old)
        XCTAssertEqual(csv.status, .cancelled)
        XCTAssertEqual(photo.status, .cancelled)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FootprintPoint>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoRecord>()), 0)
        let fresh = await FootprintStore.importMeasurements([point(1)], container: container)
        XCTAssertEqual(fresh.added, 1)
    }

    func testResetWaitsForActiveWriteAndInvalidatesQueuedWork() async throws {
        let gate = LocalImportCoordinator()
        let old = try XCTUnwrap(gate.capture())
        let started = expectation(description: "active save")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let running = Task {
            try await gate.run(token: old) {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task { try await gate.run(token: old) { 2 } }
        let reset = try gate.beginReset()
        XCTAssertNil(gate.capture())
        gate.finishReset(reset)
        XCTAssertNil(gate.capture(), "Cannot release reset while a storage operation is active")
        var returned = false
        let waiting = Task { await gate.waitForActiveWrites(); returned = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(returned)
        release.signal()
        _ = try await running.value
        await waiting.value
        do { _ = try await queued.value; XCTFail("Old queued write must be rejected") }
        catch { XCTAssertTrue(error is LocalImportCoordinator.Failure) }
        gate.finishReset(reset)
        XCTAssertNotNil(gate.capture())
        XCTAssertFalse(gate.isCurrent(old))
    }

    func testPhotoRescanUpdatesCoordinatesAndTimestampInsteadOfIgnoringExistingID() async throws {
        let container = try container()
        let old = PhotoInfo(localIdentifier: "same-photo", latitude: 31, longitude: 121,
                            timestamp: Date(timeIntervalSince1970: 0))
        let inserted = await PhotoStore.importPhotos([old, old], container: container)
        XCTAssertEqual(inserted.added, 1)
        XCTAssertEqual(inserted.duplicates, 1)
        let moved = PhotoInfo(localIdentifier: "same-photo", latitude: 32, longitude: 122,
                              timestamp: Date(timeIntervalSince1970: 100))
        let updated = await PhotoStore.importPhotos([moved], container: container)
        XCTAssertEqual(updated.updated, 1)
        XCTAssertEqual(updated.added, 0)
        let records = try ModelContext(container).fetch(FetchDescriptor<PhotoRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.latitude, 32)
        XCTAssertEqual(records.first?.timestamp, moved.timestamp)
        XCTAssertEqual(records.first?.regionState, 0)
    }
}
