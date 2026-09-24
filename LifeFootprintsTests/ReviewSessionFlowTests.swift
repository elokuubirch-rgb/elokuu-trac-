import XCTest
import SwiftData
@testable import LifeFootprints

@MainActor
final class ReviewSessionFlowTests: XCTestCase {
    private func makeContext(photoIDs: [String]) throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PhotoRecord.self, configurations: configuration)
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, id) in photoIDs.enumerated() {
            let record = PhotoRecord(
                localIdentifier: id,
                latitude: 31.2 + Double(offset) * 0.0001,
                longitude: 121.4 + Double(offset) * 0.0001,
                timestamp: start.addingTimeInterval(Double(offset) * 86_400)
            )
            context.insert(record)
        }
        try context.save()
        PhotoStore.invalidateIndex()
        return context
    }

    private func finishBatch(_ session: ExploreSession) {
        for _ in 0..<session.photos.count { session.advance() }
        XCTAssertEqual(session.phase, .review)
    }

    func testReturningFromMapSkipsPhotoDeletedFromItsReviewGroup() throws {
        let context = try makeContext(photoIDs: ["return-a", "return-b", "return-c"])
        let session = ExploreSession(level: RegionLevel.country, regionName: "回顾",
                                     context: context, source: .globalReview)
        session.loadPhotos(ids: ["return-a", "return-b", "return-c"], preservingOrder: true)
        let navigation = AppNavigationCoordinator(selectedTab: .review)
        navigation.globalReviewSession = session
        navigation.showOnMap(photo: try XCTUnwrap(session.currentPhoto), session: session)

        context.delete(try XCTUnwrap(PhotoStore.records(ids: ["return-a"], in: context).first))
        try context.save()
        PhotoStore.invalidateIndex()
        navigation.returnToReview()

        XCTAssertEqual(navigation.selectedTab, .review)
        XCTAssertEqual(session.currentPhoto?.localIdentifier, "return-b")
        XCTAssertEqual(session.photos.map(\.localIdentifier), ["return-b", "return-c"])
    }

    func testReturningFromMapAfterDeletingLastPhotoShowsPreviousAndUpdatesCover() throws {
        let context = try makeContext(photoIDs: ["last-a", "last-b"])
        let session = ExploreSession(level: RegionLevel.country, regionName: "回顾",
                                     context: context, source: .globalReview)
        session.loadPhotos(ids: ["last-a", "last-b"], preservingOrder: true)
        session.advance()
        let navigation = AppNavigationCoordinator(selectedTab: .review)
        navigation.globalReviewSession = session
        navigation.reviewOverviewGroups = [ReviewOverviewGroup(
            title: "回顾", photoIDs: ["last-a", "last-b"], previewID: "last-a")]
        navigation.showOnMap(photo: try XCTUnwrap(session.currentPhoto), session: session)

        context.delete(try XCTUnwrap(PhotoStore.records(ids: ["last-b"], in: context).first))
        try context.save()
        PhotoStore.invalidateIndex()
        navigation.returnToReview()

        XCTAssertEqual(session.currentPhoto?.localIdentifier, "last-a")
        XCTAssertEqual(navigation.reviewOverviewGroups.first?.photoIDs, ["last-a"])
    }

    func testReturningFromMapAfterDeletingEntireGroupShowsOverview() throws {
        let context = try makeContext(photoIDs: ["only-photo"])
        let session = ExploreSession(level: RegionLevel.country, regionName: "回顾",
                                     context: context, source: .globalReview)
        session.loadPhotos(ids: ["only-photo"], preservingOrder: true)
        let navigation = AppNavigationCoordinator(selectedTab: .review)
        navigation.globalReviewSession = session
        navigation.reviewOverviewGroups = [ReviewOverviewGroup(
            title: "回顾", photoIDs: ["only-photo"], previewID: "only-photo")]
        navigation.showOnMap(photo: try XCTUnwrap(session.currentPhoto), session: session)

        context.delete(try XCTUnwrap(PhotoStore.records(ids: ["only-photo"], in: context).first))
        try context.save()
        PhotoStore.invalidateIndex()
        navigation.returnToReview()

        XCTAssertNil(navigation.globalReviewSession)
        XCTAssertTrue(navigation.reviewOverviewGroups.isEmpty)
        XCTAssertEqual(navigation.selectedTab, .review)
    }

    func testLivePhotoPlaybackRequestChangesWhenPreparedResourceArrives() {
        let waiting = ReviewLivePlaybackRequest(
            assetID: "live-2", autoPlayEnabled: true,
            isLivePhoto: true, resourceReady: false)
        let ready = ReviewLivePlaybackRequest(
            assetID: "live-2", autoPlayEnabled: true,
            isLivePhoto: true, resourceReady: true)

        XCTAssertNotEqual(waiting, ready)
        XCTAssertNotEqual(ready, ReviewLivePlaybackRequest(
            assetID: "next-live-photo", autoPlayEnabled: true,
            isLivePhoto: true, resourceReady: true))
        XCTAssertTrue(ReviewLivePlaybackLogic.shouldStart(
            requestedAssetID: ready.assetID,
            currentAssetID: ready.assetID,
            autoPlayEnabled: ready.autoPlayEnabled,
            resourceReady: ready.resourceReady,
            isInteracting: false))
        XCTAssertFalse(ReviewLivePlaybackLogic.shouldStart(
            requestedAssetID: ready.assetID,
            currentAssetID: ready.assetID,
            autoPlayEnabled: true,
            resourceReady: true,
            isInteracting: false,
            isActive: false))
        XCTAssertFalse(ReviewLivePlaybackLogic.shouldStart(
            requestedAssetID: "previous-live-photo",
            currentAssetID: ready.assetID,
            autoPlayEnabled: true,
            resourceReady: true,
            isInteracting: false))
        XCTAssertNotEqual(ready, ReviewLivePlaybackRequest(
            assetID: ready.assetID, autoPlayEnabled: true,
            isLivePhoto: true, resourceReady: true, isActive: false))
    }

    func testLiveAutoplayChoiceSurvivesNewGroupAndMapSessionUntilUserTurnsItOff() throws {
        let context = try makeContext(photoIDs: ["live-1"])
        let suiteName = "ReviewLivePlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ReviewLivePlaybackPreferences(defaults: defaults)
        let firstGroup = ExploreSession(level: RegionLevel.country, regionName: "第一组",
                                        context: context, source: .globalReview,
                                        livePreferences: preferences)
        firstGroup.liveAutoPlayEnabled = true
        firstGroup.liveMuted = false

        let nextGroup = ExploreSession(level: RegionLevel.country, regionName: "第二组",
                                       context: context, source: .globalReview,
                                       livePreferences: preferences)
        let mapReview = ExploreSession(level: RegionLevel.district, regionName: "",
                                       context: context, source: .mapCluster(clusterID: "map"),
                                       livePreferences: preferences)
        XCTAssertTrue(nextGroup.liveAutoPlayEnabled)
        XCTAssertTrue(mapReview.liveAutoPlayEnabled)
        XCTAssertFalse(mapReview.liveMuted)
        XCTAssertTrue(ReviewLivePlaybackPreferences(defaults: defaults).autoPlayEnabled,
                      "重新打开应用后仍应保留用户开启的自动播放")
        XCTAssertFalse(ReviewLivePlaybackPreferences(defaults: defaults).muted)

        mapReview.liveAutoPlayEnabled = false
        XCTAssertFalse(firstGroup.liveAutoPlayEnabled)
        XCTAssertFalse(nextGroup.liveAutoPlayEnabled)
        XCTAssertFalse(ReviewLivePlaybackPreferences(defaults: defaults).autoPlayEnabled)
    }

    func testMapReviewWithTenPhotosLoadsEntireLockedCluster() async throws {
        let ids = (0..<10).map { "map-ten-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.district,
            regionName: "",
            context: context,
            source: .mapCluster(clusterID: "cluster-ten")
        )

        session.loadPhotos(ids: ids)

        XCTAssertEqual(session.photos.count, 10)
        XCTAssertEqual(Set(session.photos.map(\.localIdentifier)), Set(ids))
        XCTAssertEqual(session.sourcePhotoCount, 10)
        finishBatch(session)
        XCTAssertFalse(session.hasUnseenPhotos)
        session.startNextRound()
        XCTAssertEqual(session.phase, .browsing)
        XCTAssertEqual(Set(session.photos.map(\.localIdentifier)), Set(ids))
        XCTAssertEqual(session.index, 0)
    }

    func testMapReviewWithFiftyPhotosUsesUnseenSecondBatchFromSameCluster() async throws {
        let ids = (0..<50).map { "map-fifty-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.district,
            regionName: "",
            context: context,
            source: .mapCluster(clusterID: "cluster-fifty")
        )
        session.loadPhotos(ids: ids)
        let firstBatch = Set(session.photos.map(\.localIdentifier))

        XCTAssertEqual(firstBatch.count, 20)
        finishBatch(session)
        session.startNextRound()

        let secondBatch = Set(session.photos.map(\.localIdentifier))
        XCTAssertEqual(session.phase, .browsing)
        XCTAssertEqual(secondBatch.count, 20)
        XCTAssertTrue(firstBatch.isDisjoint(with: secondBatch))
        XCTAssertTrue(secondBatch.isSubset(of: Set(ids)))
        XCTAssertEqual(session.index, 0)
    }

    func testConfirmedMapDeletionAtomicallySwitchesBatchWithoutOldPhoto() throws {
        let ids = (0..<50).map { "map-delete-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.district,
            regionName: "",
            context: context,
            source: .mapCluster(clusterID: "cluster-delete")
        )
        session.loadPhotos(ids: ids)
        let firstBatch = Set(session.photos.map(\.localIdentifier))
        let firstBatchID = session.batchID
        session.togglePendingRemovalForCurrentPhoto()
        finishBatch(session)

        let deletedIDs = session.beginConfirmedDeletionTransition()
        XCTAssertEqual(deletedIDs.count, 1)
        XCTAssertEqual(session.phase, .transitioningToNextBatch)
        XCTAssertNil(session.currentPhoto)
        XCTAssertEqual(session.progressCount, 0)

        for photo in session.photos where deletedIDs.contains(photo.localIdentifier) {
            context.delete(photo)
        }
        try context.save()
        PhotoStore.invalidateIndex()
        let result = session.completeConfirmedDeletionTransition()

        XCTAssertEqual(result, .mapBatchReady)
        XCTAssertEqual(session.phase, .browsing)
        XCTAssertEqual(session.index, 0)
        XCTAssertNotEqual(session.batchID, firstBatchID)
        XCTAssertEqual(session.photos.count, 20)
        XCTAssertTrue(firstBatch.isDisjoint(with: Set(session.photos.map(\.localIdentifier))))
        XCTAssertTrue(Set(session.photos.map(\.localIdentifier)).isSubset(of: Set(ids)))
        XCTAssertFalse(deletedIDs.contains(session.currentPhoto?.localIdentifier ?? ""))
    }

    func testMapDeletionNeverCrossesFromClusterAToClusterB() throws {
        let clusterA = (0..<30).map { "cluster-a-\($0)" }
        let clusterB = (0..<30).map { "cluster-b-\($0)" }
        let context = try makeContext(photoIDs: clusterA + clusterB)
        let session = ExploreSession(
            level: RegionLevel.district,
            regionName: "",
            context: context,
            source: .mapCluster(clusterID: "cluster-a")
        )
        session.loadPhotos(ids: clusterA)
        session.togglePendingRemovalForCurrentPhoto()
        finishBatch(session)

        _ = session.beginConfirmedDeletionTransition()
        let result = session.completeConfirmedDeletionTransition()

        XCTAssertEqual(result, .mapBatchReady)
        XCTAssertFalse(session.photos.isEmpty)
        XCTAssertTrue(Set(session.photos.map(\.localIdentifier)).isSubset(of: Set(clusterA)))
        XCTAssertTrue(Set(session.photos.map(\.localIdentifier)).isDisjoint(with: Set(clusterB)))
    }

    func testMapDeletionWithNoUnseenPhotosStaysFrozenForImmediateExit() throws {
        let ids = (0..<3).map { "map-exhausted-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.district,
            regionName: "",
            context: context,
            source: .mapCluster(clusterID: "cluster-exhausted")
        )
        session.loadPhotos(ids: ids)
        session.togglePendingRemovalForCurrentPhoto()
        finishBatch(session)

        _ = session.beginConfirmedDeletionTransition()
        let result = session.completeConfirmedDeletionTransition()

        XCTAssertEqual(result, .mapClusterExhausted)
        XCTAssertEqual(session.phase, .transitioningToNextBatch)
        XCTAssertNil(session.currentPhoto)
        XCTAssertTrue(session.photos.isEmpty)
        XCTAssertEqual(session.index, 0)
    }

    func testGlobalDeletionClearsOldBatchBeforeParentAdvances() throws {
        let ids = (0..<20).map { "global-delete-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.country,
            regionName: "全球回顾",
            context: context,
            source: .globalReview
        )
        session.loadPhotos(ids: ids, preservingOrder: true)
        session.togglePendingRemovalForCurrentPhoto()
        finishBatch(session)

        _ = session.beginConfirmedDeletionTransition()
        let result = session.completeConfirmedDeletionTransition()

        XCTAssertEqual(result, .globalReviewNeedsNextGroup)
        XCTAssertEqual(session.phase, .transitioningToNextBatch)
        XCTAssertNil(session.currentPhoto)
        XCTAssertTrue(session.photos.isEmpty)
        XCTAssertEqual(session.progressCount, 0)
        XCTAssertEqual(session.index, 0)
    }

    func testDeletionFailureRestoresReviewWithoutMutatingBatch() throws {
        let ids = (0..<5).map { "delete-failure-\($0)" }
        let context = try makeContext(photoIDs: ids)
        let session = ExploreSession(
            level: RegionLevel.country,
            regionName: "全球回顾",
            context: context,
            source: .globalReview
        )
        session.loadPhotos(ids: ids, preservingOrder: true)
        session.showDeletionReviewForTesting(count: 1)
        XCTAssertEqual(session.index, session.photos.count - 1)
        let originalIDs = session.photos.map(\.localIdentifier)

        _ = session.beginConfirmedDeletionTransition()
        session.restoreDeletionReviewAfterFailure()

        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.photos.map(\.localIdentifier), originalIDs)
        XCTAssertEqual(session.pendingRemovalCount, 1)
    }
}
