import Foundation

/// A small, rebuildable statistics projection. Statistics must never depend on the
/// million-point map presentation being resident in memory.
struct PersistentStatsSnapshot: Codable, Equatable, Sendable {
    struct YearCount: Codable, Equatable, Sendable {
        let year: Int
        let count: Int
    }

    struct DenseArea: Codable, Equatable, Sendable {
        let lat: Double
        let lon: Double
        let count: Int
    }

    let schemaVersion: Int
    let placeRevision: Int
    let trajectoryRevision: Int
    let generatedAt: Date
    let pointCount: Int
    let distanceKM: Double
    let activeDays: Int
    let firstDate: Date?
    let lastDate: Date?
    let perYear: [YearCount]
    let denseAreas: [DenseArea]
    let denseAreasPlaceRevision: Int?
    let denseAreasTrajectoryRevision: Int?

    var stats: FootprintStats {
        var value = FootprintStats()
        value.pointCount = pointCount
        value.distanceKM = distanceKM
        value.activeDays = activeDays
        value.firstDate = firstDate
        value.lastDate = lastDate
        value.perYear = perYear.map { (year: $0.year, count: $0.count) }
        return value
    }

    var clusters: [StatsDenseArea] {
        denseAreas.map { StatsDenseArea(lat: $0.lat, lon: $0.lon, count: $0.count) }
    }
}

struct PersistentStatsLoadResult: Sendable {
    let snapshot: PersistentStatsSnapshot
    let summaryIsFresh: Bool
    let clustersAreFresh: Bool
}

/// Stores only a few scalar values and at most five dense areas. The file is an
/// optimization, not a source of truth, and can always be rebuilt from SwiftData.
final class StatsSnapshotStore: @unchecked Sendable {
    static let shared = StatsSnapshotStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("stats-snapshot-v1.plist"))
    static let schemaVersion = 1
    static let maximumBytes = 256 * 1_024

    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func load(revision: DataRevisionSnapshot) -> PersistentStatsLoadResult? {
        lock.withLock {
            guard let value = loadLocked() else { return nil }
            return PersistentStatsLoadResult(
                snapshot: value,
                summaryIsFresh: value.placeRevision == revision.place,
                clustersAreFresh: value.denseAreasPlaceRevision == revision.place
                    && value.denseAreasTrajectoryRevision == revision.trajectory)
        }
    }

    @discardableResult
    func saveSummary(_ stats: FootprintStats,
                     revision: DataRevisionSnapshot) -> Bool {
        lock.withLock {
            let previous = loadLocked()
            let canRetainClusters = previous?.denseAreasPlaceRevision == revision.place
                && previous?.denseAreasTrajectoryRevision == revision.trajectory
            let value = PersistentStatsSnapshot(
                schemaVersion: Self.schemaVersion,
                placeRevision: revision.place,
                trajectoryRevision: revision.trajectory,
                generatedAt: Date(),
                pointCount: max(0, stats.pointCount),
                distanceKM: max(0, stats.distanceKM),
                activeDays: max(0, stats.activeDays),
                firstDate: stats.firstDate,
                lastDate: stats.lastDate,
                perYear: stats.perYear.map {
                    PersistentStatsSnapshot.YearCount(year: $0.year, count: max(0, $0.count))
                },
                denseAreas: canRetainClusters ? previous?.denseAreas ?? [] : [],
                denseAreasPlaceRevision: canRetainClusters
                    ? previous?.denseAreasPlaceRevision : nil,
                denseAreasTrajectoryRevision: canRetainClusters
                    ? previous?.denseAreasTrajectoryRevision : nil)
            return writeLocked(value)
        }
    }

    @discardableResult
    func saveClusters(_ clusters: [StatsDenseArea],
                      revision: DataRevisionSnapshot) -> Bool {
        lock.withLock {
            guard let previous = loadLocked(),
                  previous.placeRevision == revision.place else { return false }
            let value = PersistentStatsSnapshot(
                schemaVersion: Self.schemaVersion,
                placeRevision: previous.placeRevision,
                trajectoryRevision: revision.trajectory,
                generatedAt: Date(),
                pointCount: previous.pointCount,
                distanceKM: previous.distanceKM,
                activeDays: previous.activeDays,
                firstDate: previous.firstDate,
                lastDate: previous.lastDate,
                perYear: previous.perYear,
                denseAreas: clusters.prefix(5).map {
                    PersistentStatsSnapshot.DenseArea(
                        lat: $0.lat, lon: $0.lon, count: max(0, $0.count))
                },
                denseAreasPlaceRevision: revision.place,
                denseAreasTrajectoryRevision: revision.trajectory)
            return writeLocked(value)
        }
    }

    func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    private func loadLocked() -> PersistentStatsSnapshot? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let value = try? PropertyListDecoder().decode(
                PersistentStatsSnapshot.self, from: data),
              value.schemaVersion == Self.schemaVersion,
              value.pointCount >= 0,
              value.distanceKM.isFinite, value.distanceKM >= 0,
              value.activeDays >= 0,
              value.perYear.allSatisfy({ $0.count >= 0 }),
              value.denseAreas.count <= 5,
              value.denseAreas.allSatisfy({
                  $0.lat.isFinite && $0.lon.isFinite && $0.count >= 0
                      && abs($0.lat) <= 90 && abs($0.lon) <= 180
              }) else { return nil }
        return value
    }

    private func writeLocked(_ value: PersistentStatsSnapshot) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value),
              data.count <= Self.maximumBytes else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var persistedURL = url
            try? persistedURL.setResourceValues(values)
            #if DEBUG
            PerformanceDiagnostics.event(
                "StatsSnapshot.saved", metadata: "bytes=\(data.count)")
            #endif
            return true
        } catch {
            return false
        }
    }
}
