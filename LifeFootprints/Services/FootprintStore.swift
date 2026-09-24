import Foundation
import SwiftData

struct FootprintStats: Sendable {
    var pointCount = 0
    var distanceKM = 0.0
    var activeDays = 0
    var firstDate: Date?
    var lastDate: Date?
    var perYear: [(year: Int, count: Int)] = []
}

/// 大数据导入只控制持久化边界，不改变去重或数据语义。
enum FootprintImportPersistencePolicy {
    static let existingFetchPageSize = 20_000
    static let insertBatchSize = 5_000

    static func batchCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + insertBatchSize - 1) / insertBatchSize
    }
}

@MainActor
enum FootprintStore {

    /// 自动轨迹 writer 的原子批次入口。一个批次要么全部保存，要么全部留在内存重试。
    nonisolated static func persistTrackBatch(_ drafts: [FootprintDraft],
                                              container: ModelContainer) async -> Bool {
        guard !drafts.isEmpty,
              drafts.allSatisfy({ GeoMath.isValid(latitude: $0.latitude,
                                                   longitude: $0.longitude) }) else { return false }
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                do {
                    try persist(drafts, in: container)
                    DataRevisionStore.commit([.trajectory, .place, .stats],
                                             reason: "FootprintStore.trackBatch", invalidatesDisplay: false)
                    continuation.resume(returning: true)
                } catch {
                    appLog.error("[TrackBatch] 原子保存失败: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// 单个后台关键点专用入库：只查询同一天的数据，避免每次系统唤醒扫描十几万条记录。
    nonisolated static func importBackgroundDraft(_ draft: FootprintDraft,
                                                  container: ModelContainer) async -> Bool {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                guard GeoMath.isValid(latitude: draft.latitude, longitude: draft.longitude) else {
                    continuation.resume(returning: false)
                    return
                }
                let bg = ModelContext(container)
                bg.autosaveEnabled = false
                let dayStart = Date(timeIntervalSince1970:
                    floor(draft.timestamp.timeIntervalSince1970 / 86_400) * 86_400)
                let dayEnd = dayStart.addingTimeInterval(86_400)
                let predicate = #Predicate<FootprintPoint> {
                    $0.timestamp >= dayStart && $0.timestamp < dayEnd
                }
                let sameDay = (try? bg.fetch(FetchDescriptor<FootprintPoint>(predicate: predicate))) ?? []
                let duplicate = sameDay.contains {
                    GeoMath.distanceMeters(from: ($0.latitude, $0.longitude),
                                            to: (draft.latitude, draft.longitude)) < 100
                }
                guard !duplicate else {
                    continuation.resume(returning: false)
                    return
                }
                bg.insert(FootprintPoint(draft: draft))
                do { try bg.save() } catch {
                    continuation.resume(returning: false)
                    return
                }
                DataRevisionStore.commit([.trajectory, .place, .stats],
                                         reason: "FootprintStore.backgroundDraft", invalidatesDisplay: false)
                continuation.resume(returning: true)
            }
        }
    }

    /// 导入草稿：按「同一天 ±50 米」去重。
    /// 跨日同地点保留——这样同一地点（如家）的照片足迹才会密集。
    static func importDrafts(_ drafts: [FootprintDraft], into context: ModelContext) -> Int {
        var index = DedupeIndex()
        let existing = (try? context.fetch(FetchDescriptor<FootprintPoint>())) ?? []
        for p in existing {
            index.add(day: dayKey(p.timestamp), lat: p.latitude, lon: p.longitude)
        }
        var added = 0
        var insertedTrajectory = false
        for d in drafts {
            guard GeoMath.isValid(latitude: d.latitude, longitude: d.longitude) else { continue }
            let day = dayKey(d.timestamp)
            guard !index.hasNearby(day: day, lat: d.latitude, lon: d.longitude, withinMeters: 50) else { continue }
            index.add(day: day, lat: d.latitude, lon: d.longitude)
            context.insert(FootprintPoint(draft: d))
            added += 1
            insertedTrajectory = insertedTrajectory
                || d.source == FootprintSource.gps.rawValue
                || d.source == FootprintSource.csv.rawValue
        }
        do { try context.save() } catch { return 0 }
        if added > 0 {
            var domains: DataRevisionDomains = [.place, .stats]
            if insertedTrajectory { domains.insert(.trajectory) }
            DataRevisionStore.commit(domains, reason: "FootprintStore.importDrafts", invalidatesDisplay: false)
        }
        return added
    }

    nonisolated private static func dayKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// Compatibility entry point. Exact measurement dedupe now applies to both modes.
    static func importDraftsInBackground(_ drafts: [FootprintDraft], container: ModelContainer,
                                         dense: Bool = false) async -> Int {
        // Kept for older internal callers; both paths now preserve measured samples.
        await importMeasurements(drafts, container: container).added
    }

    static func importMeasurements(
        _ drafts: [FootprintDraft], container: ModelContainer,
        token suppliedToken: LocalImportCoordinator.Token? = nil,
        persistBatch: (@Sendable ([FootprintDraft], ModelContainer) throws -> Void)? = nil
    ) async -> LocalImportResult {
        let coordinator = LocalImportCoordinator.shared
        guard let token = suppliedToken ?? coordinator.capture() else {
            return LocalImportResult(status: .cancelled)
        }
        do {
            return try await coordinator.run(token: token) {
                var result = LocalImportResult()
                guard !drafts.isEmpty else { return result }
                var identities = Set<ImportPointIdentity>()
                do {
                    try loadExistingMeasurementIdentities(from: container, into: &identities,
                                                          matching: drafts, token: token)
                } catch {
                    result.status = coordinator.isCurrent(token) ? .failed : .cancelled
                    return result
                }
                var batch: [FootprintDraft] = []
                batch.reserveCapacity(FootprintImportPersistencePolicy.insertBatchSize)
                func saveBatch() throws {
                    guard !batch.isEmpty else { return }
                    guard coordinator.isCurrent(token) else {
                        throw LocalImportCoordinator.Failure.invalidated
                    }
                    if let persistBatch { try persistBatch(batch, container) }
                    else { try persist(batch, in: container) }
                    result.added += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
                do {
                    for (index, draft) in drafts.enumerated() {
                        if index.isMultiple(of: 256), !coordinator.isCurrent(token) {
                            throw LocalImportCoordinator.Failure.invalidated
                        }
                        guard GeoMath.isValid(latitude: draft.latitude, longitude: draft.longitude),
                              draft.timestamp.timeIntervalSince1970.isFinite else {
                            result.invalid += 1
                            continue
                        }
                        guard identities.insert(ImportPointIdentity(draft)).inserted else {
                            result.duplicates += 1
                            continue
                        }
                        batch.append(draft)
                        if batch.count == FootprintImportPersistencePolicy.insertBatchSize {
                            try saveBatch()
                        }
                    }
                    try saveBatch()
                } catch {
                    result.status = coordinator.isCurrent(token) ? .failed : .cancelled
                    appLog.error("[Import] 导入未完成，已提交 \(result.added) 条")
                }
                if result.added > 0, coordinator.isCurrent(token) {
                    DataRevisionStore.commit([.trajectory, .place, .stats],
                                             reason: "FootprintStore.importMeasurements")
                }
                return result
            }
        } catch {
            return LocalImportResult(status: .cancelled)
        }
    }

    nonisolated private static func loadExistingMeasurementIdentities(
        from container: ModelContainer, into identities: inout Set<ImportPointIdentity>,
        matching drafts: [FootprintDraft],
        token: LocalImportCoordinator.Token
    ) throws {
        let times = drafts.map(\.timestamp).filter { $0.timeIntervalSince1970.isFinite }
        guard let first = times.min(), let last = times.max() else { return }
        let sources = Array(Set(drafts.map(\.source)))
        // A short CSV import must not materialize unrelated years of GPS/photo data.
        let predicate = #Predicate<FootprintPoint> {
            $0.timestamp >= first && $0.timestamp <= last && sources.contains($0.sourceRaw)
        }
        var offset = 0
        while true {
            guard LocalImportCoordinator.shared.isCurrent(token) else {
                throw LocalImportCoordinator.Failure.invalidated
            }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var descriptor = FetchDescriptor<FootprintPoint>(predicate: predicate, sortBy: [
                SortDescriptor(\.timestamp), SortDescriptor(\.latitude),
                SortDescriptor(\.longitude), SortDescriptor(\.sourceRaw)
            ])
            descriptor.fetchLimit = FootprintImportPersistencePolicy.existingFetchPageSize
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            for point in page {
                identities.insert(ImportPointIdentity(FootprintDraft(
                    latitude: point.latitude, longitude: point.longitude,
                    timestamp: point.timestamp, source: point.sourceRaw,
                    trajectoryID: point.trajectoryID, sessionID: point.sessionID,
                    segmentID: point.segmentID)))
            }
            if page.count < FootprintImportPersistencePolicy.existingFetchPageSize { return }
            offset += page.count
        }
    }


    /// 每批使用独立 ModelContext；保存后整个对象图即可释放。
    nonisolated private static func persist(
        _ drafts: [FootprintDraft], in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for draft in drafts { context.insert(FootprintPoint(draft: draft)) }
        try context.save()
    }

    /// 统计：总里程只累计时间间隔 < 12 小时的相邻点（避免跨城直线距离虚高）。
    /// 纯整数运算（无 Calendar 调用）——万级数据主线程单次也能毫秒级完成。
    static func stats(of points: [FootprintPoint]) -> FootprintStats {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        var result = FootprintStats()
        result.pointCount = sorted.count
        var days = Set<Int>()
        var perYearDict: [Int: Int] = [:]
        // 近似月份长度做整数年分组（统计图表用，边界误差可忽略）
        let avgMonthSec = 2_629_800.0
        var prev: (lat: Double, lon: Double, time: Double)?
        for p in sorted {
            let t = p.timestamp.timeIntervalSince1970
            days.insert(Int(t / 86_400))
            perYearDict[Int(t / avgMonthSec / 12) + 1970, default: 0] += 1
            if let pv = prev, t - pv.time < 43_200 {
                result.distanceKM += GeoMath.distanceMeters(
                    from: (pv.lat, pv.lon),
                    to: (p.latitude, p.longitude)) / 1000
            }
            prev = (lat: p.latitude, lon: p.longitude, time: t)
        }
        result.activeDays = days.count
        result.firstDate = sorted.first?.timestamp
        result.lastDate = sorted.last?.timestamp
        result.perYear = perYearDict.sorted { $0.key < $1.key }.map { (year: $0.key, count: $0.value) }
        return result
    }

    static func deleteAll(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<FootprintPoint>())) ?? []
        guard !all.isEmpty else { return }
        let affectedTrajectory = all.contains {
            $0.sourceRaw == FootprintSource.gps.rawValue
                || $0.sourceRaw == FootprintSource.csv.rawValue
        }
        for p in all { context.delete(p) }
        do { try context.save() } catch { return }
        var domains: DataRevisionDomains = [.place, .stats]
        if affectedTrajectory { domains.insert(.trajectory) }
        DataRevisionStore.commit(domains, reason: "FootprintStore.deleteAll")
    }

    static func sourceCounts(of points: [FootprintPoint]) -> (photo: Int, csv: Int, manual: Int, gps: Int, health: Int) {
        var photo = 0, csv = 0, manual = 0, gps = 0, health = 0
        for p in points {
            switch p.source {
            case .photo: photo += 1
            case .csv: csv += 1
            case .manual: manual += 1
            case .gps: gps += 1
            case .health: health += 1
            }
        }
        return (photo, csv, manual, gps, health)
    }

    static func exportCSV(_ points: [FootprintPoint]) throws -> URL {
        var text = "latitude,longitude,time,source,source_coordinate_system,raw_latitude,raw_longitude,coordinate_transform_version\n"
        let iso = ISO8601DateFormatter()
        for p in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            let version = p.coordinateTransformVersion.map(String.init) ?? ""
            text += "\(p.latitude),\(p.longitude),\(iso.string(from: p.timestamp)),\(p.sourceRaw),\(p.sourceCoordinateSystem.rawValue),\(p.originalLatitude),\(p.originalLongitude),\(version)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("足迹备份.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func exportCSV(_ snapshots: [FootprintSnapshot]) throws -> URL {
        var text = "latitude,longitude,time,source\n"
        let iso = ISO8601DateFormatter()
        for point in snapshots.sorted(by: { $0.t < $1.t }) {
            text += "\(point.lat),\(point.lon),\(iso.string(from: point.t)),\(point.source)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("足迹备份.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
