import XCTest
import SwiftData
@testable import LifeFootprints

final class MapLoadingRegressionTests: XCTestCase {
    func testCachePublicationKeepsAppendOnlyWorkAsOldSeedButRejectsDestructiveChanges() {
        XCTAssertEqual(TrajectoryCachePublicationPolicy.action(
            readRevision: 10, currentRevision: 10, readSafety: 3, currentSafety: 3), .exact)
        XCTAssertEqual(TrajectoryCachePublicationPolicy.action(
            readRevision: 10, currentRevision: 12, readSafety: 3, currentSafety: 3), .refreshSeed)
        XCTAssertEqual(TrajectoryCachePublicationPolicy.action(
            readRevision: 10, currentRevision: 12, readSafety: 3, currentSafety: 4), .discard)
        XCTAssertEqual(TrajectoryCachePublicationPolicy.action(
            readRevision: 10, currentRevision: 9, readSafety: 3, currentSafety: 3), .discard)
    }

    func testRefreshSeedRetainsReadStartAndCannotHitNewerRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistentTrajectoryCache(fileURL: directory.appendingPathComponent("cache.bin"))
        let readStarted = Date(timeIntervalSince1970: 1_700_000_000)
        let resolution = TrajectoryConflictResolver.resolve([])
        XCTAssertTrue(cache.save(resolution, dataRevision: 10, sourceReadStartedAt: readStarted))
        XCTAssertNil(cache.load(dataRevision: 11))
        let seed = try XCTUnwrap(cache.loadStaleTrajectories(before: 11))
        XCTAssertEqual(seed.dataRevision, 10)
        XCTAssertEqual(seed.createdAt, readStarted)
    }

    @MainActor
    func testIncrementalRefreshIncludesPointsMissingRouteRecordsAndReloadsTheirChanges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(WorkoutRouteRecord(routeID: "recorded", workoutID: "known",
                                          createdAt: base))
        for (route, workout) in [("recorded", "known"), ("orphan", "interrupted")] {
            for index in 0..<3 {
                context.insert(WorkoutRoutePoint(
                    workoutID: workout, latitude: 31 + Double(index) * 0.0001,
                    longitude: 121, altitude: 10,
                    timestamp: base.addingTimeInterval(Double(index)),
                    routeID: route, segmentIndex: 0, pointIndex: index))
            }
        }
        try context.save()
        let repository = TrajectoryRepository(container: container)
        let original = try repository.load()
        let stale = StaleTrajectoryCacheSnapshot(
            trajectories: original, dataRevision: 0, createdAt: base.addingTimeInterval(100))
        let orphanPoint = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            predicate: #Predicate { $0.workoutID == "interrupted" && $0.pointIndex == 1 })).first)
        orphanPoint.latitude = 31.00015
        try context.save()

        // Non-nil proves the incremental path succeeds instead of falling back to a
        // second full read. Same-count coordinate edits in unrecorded routes are fresh.
        let result = try XCTUnwrap(repository.loadIncremental(from: stale))
        XCTAssertEqual(result.points.count, 6)
        XCTAssertEqual(Set(result.trajectories.map(\.sessionID)), ["known", "interrupted"])
        XCTAssertTrue(result.points.contains {
            $0.sessionID == "interrupted" && $0.point.latitude == 31.00015
        })
        XCTAssertEqual(result.trajectories.first { $0.sessionID == "known" },
                       original.first { $0.sessionID == "known" })
    }

    @MainActor
    func testIncrementalRefreshStillRejectsUnexplainedPointCountMismatch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(WorkoutRouteRecord(routeID: "recorded", workoutID: "known", createdAt: base))
        for index in 0..<3 {
            context.insert(WorkoutRoutePoint(workoutID: "known", latitude: 31, longitude: 121,
                altitude: 0, timestamp: base.addingTimeInterval(Double(index)),
                routeID: "recorded", pointIndex: index))
        }
        try context.save()
        let repository = TrajectoryRepository(container: container)
        let stale = StaleTrajectoryCacheSnapshot(trajectories: try repository.load(),
            dataRevision: 0, createdAt: base.addingTimeInterval(100))
        let point = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRoutePoint>(
            predicate: #Predicate { $0.pointIndex == 2 })).first)
        context.delete(point)
        try context.save()
        XCTAssertNil(try repository.loadIncremental(from: stale))
    }

    func testMonthCursorMatchesCalendarAcrossTimeZonesLeapMonthsAndOutOfOrderDates() throws {
        let base = Date(timeIntervalSince1970: 1_672_531_200)
        for identifier in [Calendar.Identifier.gregorian, .chinese, .buddhist] {
            for zone in ["Asia/Shanghai", "America/Los_Angeles", "UTC"] {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                var cursor = CalendarMonthCursor(calendar: calendar)
                var previous: DateInterval?
                let offsets = Array(0..<750) + [40, 0, 749, 365]
                for offset in offsets {
                    let date = base.addingTimeInterval(Double(offset) * 86_400)
                    let expected = calendar.dateInterval(of: .month, for: date)
                    XCTAssertEqual(cursor.advance(to: date), expected != previous)
                    XCTAssertEqual(cursor.interval, expected)
                    previous = expected
                }
            }
        }
    }

    func testMonthCursorUsesExclusiveEndAndKeepsDenseInputUnchanged() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let base = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        var cursor = CalendarMonthCursor(calendar: calendar)
        XCTAssertTrue(cursor.advance(to: base))
        let end = try XCTUnwrap(cursor.interval?.end)
        XCTAssertFalse(cursor.advance(to: end.addingTimeInterval(-0.001)))
        XCTAssertTrue(cursor.advance(to: end))
        XCTAssertEqual(cursor.interval?.start, end)

        var dense = CalendarMonthCursor(calendar: calendar)
        var changes = 0
        let started = CFAbsoluteTimeGetCurrent()
        for index in 0..<200_000 {
            if dense.advance(to: base.addingTimeInterval(Double(index))) { changes += 1 }
        }
        XCTAssertEqual(changes, 1)
        print("MONTH_CURSOR points=200000 elapsedMs=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: FootprintPoint.self, WorkoutRecord.self,
            WorkoutRouteRecord.self, WorkoutRoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
