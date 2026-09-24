import XCTest
import SwiftData
@testable import LifeFootprints

private actor BatchPersistenceProbe {
    private var batches: [[FootprintDraft]] = []
    private var completions: [CheckedContinuation<Bool, Never>] = []
    private var automaticResults: [Bool]
    private var active = 0
    private var maximumActive = 0

    init(automaticResults: [Bool] = []) { self.automaticResults = automaticResults }

    func persist(_ drafts: [FootprintDraft]) async -> Bool {
        batches.append(drafts)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if !automaticResults.isEmpty { return automaticResults.removeFirst() }
        return await withCheckedContinuation { completions.append($0) }
    }

    func snapshot() -> (batches: [[FootprintDraft]], maximumActive: Int) {
        (batches, maximumActive)
    }

    func finishNext(_ succeeded: Bool) {
        guard !completions.isEmpty else { return }
        completions.removeFirst().resume(returning: succeeded)
    }
}

@MainActor
final class TrackPointBatchWriterTests: XCTestCase {
    private func point(_ id: Int) -> FootprintDraft {
        FootprintDraft(latitude: 31, longitude: 121 + Double(id) / 100_000,
                       timestamp: Date(timeIntervalSince1970: Double(id)), source: "gps")
    }

    private func writer(probe: BatchPersistenceProbe, size: Int = 20,
                        maximumWait: TimeInterval = 60) throws -> TrackPointBatchWriter {
        let container = try ModelContainer(
            for: FootprintPoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writer = TrackPointBatchWriter { drafts, _ in await probe.persist(drafts) }
        var configuration = LocationFilterConfiguration()
        configuration.batchSize = size
        configuration.batchMaxDuration = maximumWait
        writer.configure(container: container, configuration: configuration,
                         retryInitialDelay: 0.05, retryMaximumDelay: 0.2)
        return writer
    }

    private func waitUntil(_ condition: () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for writer state", file: file, line: line)
                throw NSError(domain: "TrackPointBatchWriterTests.Timeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testOldestPointDeadlineIsNotDebouncedByNewPoints() async throws {
        let probe = BatchPersistenceProbe(automaticResults: Array(repeating: true, count: 20))
        let writer = try writer(probe: probe, maximumWait: 0.2)
        writer.append(point(0))
        // Keep appending past the first deadline. The old debounce never saves.
        for id in 1...8 {
            try await Task.sleep(for: .milliseconds(40))
            writer.append(point(id))
        }
        let result = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(result.batches.count, 1)
        XCTAssertEqual(result.batches.first?.first, point(0))
        XCTAssertLessThan(result.batches.first?.count ?? 99, 9)
        await writer.discardPendingAndWait()
    }

    func testFailureRetriesWithoutAnyNewPointOrFlush() async throws {
        let probe = BatchPersistenceProbe(automaticResults: [false, false, true])
        let writer = try writer(probe: probe, size: 1)
        writer.append(point(0))
        try await waitUntil { await probe.snapshot().batches.count == 3 }
        let result = await probe.snapshot()
        XCTAssertEqual(result.batches, [[point(0)], [point(0)], [point(0)]])
        XCTAssertEqual(result.maximumActive, 1)
        await writer.discardPendingAndWait()
        XCTAssertEqual(writer.pendingCount, 0)
    }

    func testFlushDuringSaveDrainsInOrderWithoutConcurrentWrites() async throws {
        let probe = BatchPersistenceProbe()
        let writer = try writer(probe: probe, size: 2)
        writer.append(point(0))
        writer.append(point(1))
        try await waitUntil { await probe.snapshot().batches.count == 1 }
        for id in 2...4 { writer.append(point(id)) }
        for _ in 0..<10 { writer.flush(reason: "test") }
        let duringSave = await probe.snapshot()
        XCTAssertEqual(duringSave.batches.count, 1)
        await probe.finishNext(true)
        try await waitUntil { await probe.snapshot().batches.count == 2 }
        await probe.finishNext(true)
        try await waitUntil { await probe.snapshot().batches.count == 3 }
        await probe.finishNext(true)
        await writer.discardPendingAndWait()
        let result = await probe.snapshot()
        XCTAssertEqual(result.batches, [[point(0), point(1)], [point(2), point(3)], [point(4)]])
        XCTAssertEqual(result.maximumActive, 1)
    }

    func testResetWaitsForFailedWriteAndDoesNotRequeueOldPoints() async throws {
        try await verifyReset(succeeded: false)
    }

    func testResetWaitsForSuccessfulWriteBeforeAllowingDeletion() async throws {
        try await verifyReset(succeeded: true)
    }

    private func verifyReset(succeeded: Bool) async throws {
        let probe = BatchPersistenceProbe()
        let writer = try writer(probe: probe, size: 1)
        writer.append(point(0))
        try await waitUntil { await probe.snapshot().batches.count == 1 }
        writer.append(point(1))
        let resetFinished = expectation(description: "reset waits for save")
        let reset = Task {
            await writer.discardPendingAndWait()
            resetFinished.fulfill()
        }
        try await waitUntil { writer.isResetting }
        writer.append(point(2))
        writer.flush(reason: "during-reset")
        XCTAssertTrue(writer.isResetting)
        XCTAssertEqual(writer.pendingCount, 0)
        await probe.finishNext(succeeded)
        await fulfillment(of: [resetFinished], timeout: 3)
        await reset.value
        XCTAssertFalse(writer.isResetting)
        XCTAssertEqual(writer.pendingCount, 0)
        try await Task.sleep(for: .milliseconds(250))
        let afterReset = await probe.snapshot()
        XCTAssertEqual(afterReset.batches, [[point(0)]])

        writer.append(point(3))
        try await waitUntil { await probe.snapshot().batches.count == 2 }
        await probe.finishNext(true)
        await writer.discardPendingAndWait()
        let fresh = await probe.snapshot()
        XCTAssertEqual(fresh.batches, [[point(0)], [point(3)]])
    }

    func testAppendBeforeConfigurationGetsScheduledAfterConfiguration() async throws {
        let probe = BatchPersistenceProbe(automaticResults: [true])
        let writer = TrackPointBatchWriter { drafts, _ in await probe.persist(drafts) }
        writer.append(point(0))
        writer.flush(reason: "before-configure")
        let before = await probe.snapshot()
        XCTAssertTrue(before.batches.isEmpty)
        let container = try ModelContainer(
            for: FootprintPoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        writer.configure(container: container)
        try await waitUntil { await probe.snapshot().batches.count == 1 }
        await writer.discardPendingAndWait()
    }

    func testRetryCommitsExactlyOneCopyToInMemoryDatabase() async throws {
        let probe = BatchPersistenceProbe(automaticResults: [false, true])
        let container = try ModelContainer(
            for: FootprintPoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writer = TrackPointBatchWriter { drafts, container in
            // Simulate an atomic failure before any commit, then use the real store.
            guard await probe.persist(drafts) else { return false }
            return await FootprintStore.persistTrackBatch(drafts, container: container)
        }
        var configuration = LocationFilterConfiguration()
        configuration.batchSize = 2
        writer.configure(container: container, configuration: configuration,
                         retryInitialDelay: 0.05)
        writer.append(point(0))
        writer.append(point(1))
        try await waitUntil { await probe.snapshot().batches.count == 2 }
        await writer.discardPendingAndWait()
        let context = ModelContext(container)
        let persisted = try context.fetch(FetchDescriptor<FootprintPoint>(
            sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.map(\.timestamp), [point(0), point(1)].map(\.timestamp))
        XCTAssertEqual(persisted.map(\.longitude), [point(0), point(1)].map(\.longitude))
    }
}
