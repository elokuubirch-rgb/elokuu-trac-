import Foundation
import SwiftData
import CoreLocation
import Photos
import QuartzCore

/// 照片扫描元数据（不含缩略图）
struct PhotoInfo {
    var localIdentifier: String
    var latitude: Double
    var longitude: Double
    var timestamp: Date
}

/// 照片仓储：入库去重、按行政区筛选/分组、同级候选、区域质心。
/// P0-3：查询全部走内存索引——全量 fetch 只发生在「首次使用」与「数据变更」两个时刻。
@MainActor
enum PhotoStore {

    enum SystemPhotoDeletionError: LocalizedError {
        case permissionDenied
        case assetsUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有照片删除权限，请前往系统设置允许访问照片。"
            case .assetsUnavailable: return "未能在系统照片库中找到这些照片。"
            }
        }
    }

    nonisolated private static let hiddenPhotoIDsKey = "hiddenPhotoLocalIdentifiers"

    // MARK: - 内存索引（P0-3：点击路径零 DB I/O）

    private static var indexBuilt = false
    private static var indexedAll: [PhotoRecord] = []
    private static var indexedByID: [String: PhotoRecord] = [:]
    /// level -> 区域名 -> 按时间排序的照片
    private static var indexedByRegion: [String: [String: [PhotoRecord]]] = [:]
    /// level -> 区域列表（按照片数降序，含质心）
    private static var indexedRegionList: [String: [(name: String, count: Int, lat: Double, lon: Double)]] = [:]

    static func rebuildIndex(in context: ModelContext) {
        #if DEBUG
        let startedAt = CACurrentMediaTime()
        #endif
        let hidden = hiddenPhotoIDs()
        let all = allIncludingHidden(in: context).filter { !hidden.contains($0.localIdentifier) }
        indexedAll = all
        indexedByID = Dictionary(uniqueKeysWithValues: all.map { ($0.localIdentifier, $0) })
        var byRegion: [String: [String: [PhotoRecord]]] = [:]
        var regionList: [String: [(name: String, count: Int, lat: Double, lon: Double)]] = [:]
        for level in [RegionLevel.country, RegionLevel.province, RegionLevel.city, RegionLevel.district] {
            var groups: [String: [PhotoRecord]] = [:]
            for record in all {
                if let name = record.regionName(at: level) { groups[name, default: []].append(record) }
            }
            byRegion[level] = groups.mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
            regionList[level] = groups.map { name, photos in
                (name: name, count: photos.count,
                 lat: photos.reduce(0) { $0 + $1.latitude } / Double(photos.count),
                 lon: photos.reduce(0) { $0 + $1.longitude } / Double(photos.count))
            }.sorted { $0.count > $1.count }
        }
        indexedByRegion = byRegion
        indexedRegionList = regionList
        indexBuilt = true
        #if DEBUG
        MapDebugLog.log("PhotoStore 索引重建: \(all.count) 张照片 \(String(format: "%.1f", (CACurrentMediaTime() - startedAt) * 1000))ms")
        #endif
    }

    static func invalidateIndex() {
        indexBuilt = false
    }

    private static func ensureIndex(_ context: ModelContext) {
        guard !indexBuilt else { return }
        rebuildIndex(in: context)
    }

    /// 用户在回忆浏览中移除的照片。只隐藏足迹记录，不删除系统相册原图。
    nonisolated static func hiddenPhotoIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenPhotoIDsKey) ?? [])
    }

    static func hide(ids: Set<String>, in context: ModelContext) {
        guard !ids.isEmpty else { return }
        var hidden = hiddenPhotoIDs()
        hidden.formUnion(ids)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenPhotoIDsKey)
        for record in allIncludingHidden(in: context) where ids.contains(record.localIdentifier) {
            context.delete(record)
        }
        try? context.save()
        invalidateIndex()
        #if DEBUG
        PerformanceDiagnostics.event("dataImported.post.PhotoStore.hide")
        PerformanceDiagnostics.count("dataImported.post.total")
        #endif
        NotificationCenter.default.post(name: .dataImported, object: nil)
    }

    /// 请求读写权限并交由系统确认删除。iCloud 照片会同步到所有设备，系统会保留在“最近删除”。
    nonisolated static func deleteFromSystemLibrary(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            throw SystemPhotoDeletionError.permissionDenied
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard assets.count > 0 else { throw SystemPhotoDeletionError.assetsUnavailable }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    nonisolated private static func allIncludingHidden(in context: ModelContext) -> [PhotoRecord] {
        (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
    }

    /// 按 localIdentifier 去重入库，返回新增数量
    static func upsert(_ infos: [PhotoInfo], in context: ModelContext) -> Int {
        let existing = Set((try? context.fetch(FetchDescriptor<PhotoRecord>()))?.map(\.localIdentifier) ?? [])
        let hidden = hiddenPhotoIDs()
        var added = 0
        for info in infos {
            guard !existing.contains(info.localIdentifier), !hidden.contains(info.localIdentifier) else { continue }
            let record = PhotoRecord(localIdentifier: info.localIdentifier,
                                     latitude: info.latitude,
                                     longitude: info.longitude,
                                     timestamp: info.timestamp)
            context.insert(record)
            added += 1
        }
        try? context.save()
        if added > 0 { invalidateIndex() }
        return added
    }

    /// 后台线程版入库（万级照片专用）
    static func upsertInBackground(_ infos: [PhotoInfo], container: ModelContainer) async -> Int {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let bg = ModelContext(container)
                bg.autosaveEnabled = false
                let existing = Set((try? bg.fetch(FetchDescriptor<PhotoRecord>()))?.map(\.localIdentifier) ?? [])
                let hidden = hiddenPhotoIDs()
                var added = 0
                for info in infos where !existing.contains(info.localIdentifier) && !hidden.contains(info.localIdentifier) {
                    bg.insert(PhotoRecord(localIdentifier: info.localIdentifier,
                                          latitude: info.latitude,
                                          longitude: info.longitude,
                                          timestamp: info.timestamp))
                    added += 1
                }
                try? bg.save()
                appLog.info("[Import] 照片后台入库：\(infos.count) 条 → 新增 \(added)")
                if added > 0 {
                    await MainActor.run {
                        invalidateIndex()
                        #if DEBUG
                        PerformanceDiagnostics.event("dataImported.post.PhotoStore.upsert")
                        PerformanceDiagnostics.count("dataImported.post.total")
                        #endif
                        NotificationCenter.default.post(name: .dataImported, object: nil)
                    }
                }
                continuation.resume(returning: added)
            }
        }
    }

    static func all(in context: ModelContext) -> [PhotoRecord] {
        ensureIndex(context)
        return indexedAll
    }

    /// 按 localIdentifier 批量取照片（地点级聚合点击用）——内存索引 O(ids)
    static func records(ids: [String], in context: ModelContext) -> [PhotoRecord] {
        ensureIndex(context)
        return ids.compactMap { indexedByID[$0] }
    }

    /// 某层级区域下的照片（按时间排序）——内存索引 O(1)
    static func photos(level: String, regionName: String, in context: ModelContext) -> [PhotoRecord] {
        ensureIndex(context)
        return indexedByRegion[level]?[regionName] ?? []
    }

    /// 某层级下所有有照片的区域（名称 + 数量 + 质心坐标）——内存索引 O(1)
    static func regions(level: String, in context: ModelContext) -> [(name: String, count: Int, lat: Double, lon: Double)] {
        ensureIndex(context)
        return indexedRegionList[level] ?? []
    }

    /// 点击某坐标：从最细层级开始找有照片的区域（文档 §12）
    static func finestRegionWithPhotos(region: RegionInfo, in context: ModelContext) -> (level: String, name: String)? {
        for level in [RegionLevel.district, RegionLevel.city, RegionLevel.province, RegionLevel.country] {
            guard let name = region.name(at: level) else { continue }
            if !photos(level: level, regionName: name, in: context).isEmpty {
                return (level, name)
            }
        }
        return nil
    }

    /// 同级随机候选：排除当前区域与最近浏览区域（文档 §18/§22/§23）
    static func randomRegion(level: String, excluding: String, recent: [String], in context: ModelContext) -> String? {
        let candidates = regions(level: level, in: context).map(\.name)
        return randomCandidate(candidates, excluding: excluding, recent: recent)
    }

    /// 区域质心（用于地图相机移动）
    static func centroid(level: String, regionName: String, in context: ModelContext) -> CLLocationCoordinate2D? {
        let regions = regions(level: level, in: context)
        guard let r = regions.first(where: { $0.name == regionName }) else { return nil }
        return CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon)
    }

    /// 待逆地理的照片（限 60 条/批，避免触发 Apple 限流）——内存索引
    static func pendingGeocode(in context: ModelContext) -> [PhotoRecord] {
        ensureIndex(context)
        return Array(indexedAll.filter { $0.regionState == 0 }.prefix(60))
    }

    /// 待生成缩略图的照片——内存索引
    static func pendingThumbnails(in context: ModelContext) -> [PhotoRecord] {
        ensureIndex(context)
        return Array(indexedAll.filter { $0.thumbState == 0 }.prefix(200))
    }

    // MARK: - 后台直查（不经内存索引：SwiftData 模型不可跨线程使用）

    /// 后台线程专用：按 id 批量取照片（openShelf 等 detached 路径使用）
    nonisolated static func recordsInBackground(ids: [String], in context: ModelContext) -> [PhotoRecord] {
        let idSet = Set(ids)
        return allIncludingHidden(in: context)
            .filter { !hiddenPhotoIDs().contains($0.localIdentifier) && idSet.contains($0.localIdentifier) }
    }

    /// 后台线程专用：某层级区域下的照片（按时间排序）
    nonisolated static func photosInBackground(level: String, regionName: String, in context: ModelContext) -> [PhotoRecord] {
        allIncludingHidden(in: context)
            .filter { !hiddenPhotoIDs().contains($0.localIdentifier) && $0.regionName(at: level) == regionName }
            .sorted { $0.timestamp < $1.timestamp }
    }
}
