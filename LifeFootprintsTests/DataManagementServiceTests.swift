import XCTest
import SwiftData
@testable import LifeFootprints

@MainActor
final class DataManagementServiceTests: XCTestCase {
    func testEmptyReviewSessionCannotRecreateDeletedPreferences() {
        ReviewSessionPersistence.reset()
        ReviewSessionPersistence.save([String](), currentIndex: nil)
        XCTAssertNil(UserDefaults.standard.data(forKey: ReviewSessionPersistence.groupsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: ReviewSessionPersistence.currentIndexKey))
    }

    func testReviewSessionSaveIsBlockedDuringReset() async throws {
        let gate = LocalImportCoordinator.shared
        let reset = try gate.beginReset()
        await gate.waitForActiveWrites()
        defer { gate.finishReset(reset) }
        ReviewSessionPersistence.reset()
        ReviewSessionPersistence.save(["old-photo"], currentIndex: 0)
        XCTAssertNil(UserDefaults.standard.data(forKey: ReviewSessionPersistence.groupsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: ReviewSessionPersistence.currentIndexKey))
    }

    func testResetDeletesEveryLocalModelAndReviewState() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FootprintPoint.self, PhotoRecord.self, WorkoutRecord.self,
            WorkoutRouteRecord.self, WorkoutRoutePoint.self,
            configurations: configuration)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        context.insert(FootprintPoint(draft: FootprintDraft(
            latitude: 31.2, longitude: 121.4, timestamp: now, source: "csv")))
        context.insert(PhotoRecord(localIdentifier: "reset-photo", latitude: 31.2,
                                   longitude: 121.4, timestamp: now))
        context.insert(WorkoutRecord(healthKitUUID: "reset-workout", workoutType: "walking",
                                     startDate: now, endDate: now.addingTimeInterval(60),
                                     duration: 60, distanceMeters: 100, caloriesKCal: 10,
                                     elevationGain: 0, routeAvailable: true))
        context.insert(WorkoutRouteRecord(routeID: "reset-route", workoutID: "reset-workout"))
        context.insert(WorkoutRoutePoint(workoutID: "reset-workout", latitude: 31.2,
                                         longitude: 121.4, altitude: 0, timestamp: now,
                                         routeID: "reset-route"))
        try context.save()

        ReviewHistoryStore.recordReviewed(photoIDs: ["reset-photo"], at: now)
        UserDefaults.standard.set(Data([1]), forKey: ReviewSessionPersistence.groupsKey)
        UserDefaults.standard.set(["reset-photo"], forKey: "hiddenPhotoLocalIdentifiers")
        SnapshotCache.pointSnapshots = [FootprintSnapshot(
            lat: 31.2, lon: 121.4, t: now, source: "csv")]

        try await DataManagementService.resetAllLocalData(in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FootprintPoint>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PhotoRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRouteRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRoutePoint>()), 0)
        XCTAssertTrue(ReviewHistoryStore.history().isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: ReviewSessionPersistence.groupsKey))
        XCTAssertNil(UserDefaults.standard.array(forKey: "hiddenPhotoLocalIdentifiers"))
        XCTAssertTrue(SnapshotCache.pointSnapshots.isEmpty)
        XCTAssertNil(SnapshotCache.clusterIndex)
    }
}
