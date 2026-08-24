import Foundation
import SwiftData

struct FootprintStats {
    var pointCount = 0
    var distanceKM = 0.0
    var activeDays = 0
    var firstDate: Date?
    var lastDate: Date?
    var perYear: [(year: Int, count: Int)] = []
}

@MainActor
enum FootprintStore {

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
                                         reason: "FootprintStore.backgroundDraft")
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
            DataRevisionStore.commit(domains, reason: "FootprintStore.importDrafts")
        }
        return added
    }

    nonisolated private static func dayKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// 后台线程版导入（十万级数据专用）：后台 ModelContext 插入+保存，主线程零阻塞
    /// dense=true：密集路线导入跳过 50m 去重——
    /// 路线点间距仅几米，去重会互相吞掉导致无法成线
    static func importDraftsInBackground(_ drafts: [FootprintDraft], container: ModelContainer,
                                         dense: Bool = false) async -> Int {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let bg = ModelContext(container)
                bg.autosaveEnabled = false
                let existing = (try? bg.fetch(FetchDescriptor<FootprintPoint>())) ?? []
                var index = DedupeIndex()
                if !dense {
                    for p in existing {
                        index.add(day: dayKey(p.timestamp), lat: p.latitude, lon: p.longitude)
                    }
                }
                var added = 0
                var insertedTrajectory = false
                for d in drafts {
                    guard GeoMath.isValid(latitude: d.latitude, longitude: d.longitude) else { continue }
                    if dense {
                        // 密集路线：保持连续性，不做空间去重（点密度由点模式采样控制）
                        bg.insert(FootprintPoint(draft: d))
                        added += 1
                        insertedTrajectory = insertedTrajectory
                            || d.source == FootprintSource.gps.rawValue
                            || d.source == FootprintSource.csv.rawValue
                        continue
                    }
                    let day = dayKey(d.timestamp)
                    guard !index.hasNearby(day: day, lat: d.latitude, lon: d.longitude, withinMeters: 50) else { continue }
                    index.add(day: day, lat: d.latitude, lon: d.longitude)
                    bg.insert(FootprintPoint(draft: d))
                    added += 1
                    insertedTrajectory = insertedTrajectory
                        || d.source == FootprintSource.gps.rawValue
                        || d.source == FootprintSource.csv.rawValue
                }
                do { try bg.save() } catch {
                    continuation.resume(returning: 0)
                    return
                }
                appLog.info("[Import] 后台导入完成：\(drafts.count) 条 → 新增 \(added)（dense=\(dense)）")
                if added > 0 {
                    var domains: DataRevisionDomains = [.place, .stats]
                    if insertedTrajectory { domains.insert(.trajectory) }
                    DataRevisionStore.commit(domains, reason: "FootprintStore.importDraftsInBackground")
                }
                continuation.resume(returning: added)
            }
        }
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
        var text = "latitude,longitude,time,source\n"
        let iso = ISO8601DateFormatter()
        for p in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            text += "\(p.latitude),\(p.longitude),\(iso.string(from: p.timestamp)),\(p.sourceRaw)\n"
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
