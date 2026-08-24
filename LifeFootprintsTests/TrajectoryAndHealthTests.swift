import XCTest
import SwiftData
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
}
