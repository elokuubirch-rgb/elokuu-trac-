import Foundation
import CoreLocation
import SwiftData

/// 逆地理结果分类（批量流程据此决定重试还是永久标记）
enum GeocodeOutcome: Equatable {
    case success(RegionInfo)
    case noResult      // 编码成功但无行政区（海域等）→ 永久标记 regionState=2
    case failure       // 网络/限速失败 → 保持 regionState=0，稍后重试
}

/// 行政区逆地理编码：CLGeocoder + 网格缓存 + 批量限速（文档 §9/§12）
@MainActor
enum RegionService {

    /// 坐标（按 0.01°≈1km 网格）→ 四级行政区，带内存缓存（供交互即时查询）
    static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> RegionInfo {
        if case .success(let region) = await geocodeOutcome(coordinate) {
            return region
        }
        return RegionInfo()
    }

    /// 带结果分类的逆地理（缓存只存成功结果——失败的网格下轮可重试；
    /// 复用单个 CLGeocoder 实例，避免并发实例触发系统限速）
    static func geocodeOutcome(_ coordinate: CLLocationCoordinate2D) async -> GeocodeOutcome {
        let key = gridKey(coordinate)
        if let cached = cache[key] {
            return .success(cached)
        }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                preferredLocale: Locale(identifier: "zh_CN"))
            let region = RegionInfo(from: placemarks.first)
            guard region.country != nil else {
                return .noResult
            }
            cache[key] = region
            return .success(region)
        } catch {
            appLog.error("[Region] 逆地理失败: \(error.localizedDescription)")
            return .failure
        }
    }

    /// 批量：处理下一批待逆地理照片（按 0.05° 网格去重，一次请求服务同网格全部照片；
    /// 网格按照片数降序——人口最密集的网格先出，主要城市标记最快出现）。
    /// 返回本次处理的照片条数；0 = 全部完成或连续失败（限速/断网，未处理项保持 0，下次续跑）。
    /// 成功 400ms 限速；失败退避 3s，连续 5 次失败即停本轮。
    static func geocodeNextBatch(in context: ModelContext) async -> Int {
        guard let token = LocalImportCoordinator.shared.capture() else { return 0 }
        let allPending = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
        let pending = allPending.filter { $0.regionState == 0 }
        guard !pending.isEmpty else { return 0 }
        var gridMap: [String: [PhotoRecord]] = [:]
        for r in pending {
            gridMap[gridKey(CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)),
                    default: []].append(r)
        }
        let top = gridMap.sorted { $0.value.count > $1.value.count }.prefix(60)
        var processed = 0
        var consecutiveFailures = 0
        for (_, records) in top {
            guard let first = records.first else { continue }
            let outcome = await geocodeOutcome(CLLocationCoordinate2D(latitude: first.latitude,
                                                                      longitude: first.longitude))
            guard LocalImportCoordinator.shared.isCurrent(token) else { return processed }
            switch outcome {
            case .success(let region):
                for r in records {
                    r.countryName = region.country
                    r.provinceName = region.province
                    r.cityName = region.city
                    r.districtName = region.district
                    r.regionState = 1
                }
                processed += records.count
                consecutiveFailures = 0
            case .noResult:
                for r in records { r.regionState = 2 }
                processed += records.count
                consecutiveFailures = 0
            case .failure:
                consecutiveFailures += 1
                appLog.info("[Region] 网格失败（限速/网络）→ 退避 3s，保持待处理")
            }
            try? context.save()
            if consecutiveFailures >= 5 { break }
            try? await Task.sleep(nanoseconds: UInt64((outcome == .failure ? 3.0 : 0.4) * 1e9))
        }
        #if DEBUG
        MapDebugLog.log("逆地理批次：处理\(processed)条 网格\(top.count)个 失败\(consecutiveFailures)连")
        #endif
        appLog.info("[Region] 批量处理完成：\(processed) 条 / 本轮网格 \(top.count)")
        return processed
    }

    private static func gridKey(_ c: CLLocationCoordinate2D) -> String {
        // 0.05°≈5km 网格：批量去重粒度（城市级命名足够，请求数降一个量级）
        String(format: "%.2f_%.2f", (c.latitude * 20).rounded() / 20, (c.longitude * 20).rounded() / 20)
    }

    private static let geocoder = CLGeocoder()
    private static var cache: [String: RegionInfo] = [:]
}

extension Notification.Name {
    /// 照片行政区逆地理有进展 → 地图页重载快照刷新照片标记
    static let photoRegionsUpdated = Notification.Name("photoRegionsUpdated")
    /// 足迹/照片数据入库完成 → 地图页重载快照（替代主线程 @Query 监听）
    static let dataImported = Notification.Name("dataImported")
}

extension RegionInfo {
    /// 从 CLPlacemark 构建四级行政区（直辖市规范化：北京/上海/天津/重庆
    /// 的 locality 常为区名 → city 用直辖市名，区名归入 district）
    init(from placemark: CLPlacemark?) {
        let admin = placemark?.administrativeArea
        let sub = placemark?.subAdministrativeArea
        let locality = placemark?.locality
        let subLocality = placemark?.subLocality
        let municipalities = ["北京市", "上海市", "天津市", "重庆市"]
        if let admin = admin, municipalities.contains(admin),
           let loc = locality, loc != admin {
            self.init(country: placemark?.country,
                      province: admin,
                      city: admin,
                      district: subLocality ?? loc)
        } else {
            self.init(country: placemark?.country,
                      province: admin,
                      city: sub ?? locality ?? admin,
                      district: subLocality)
        }
    }
}
