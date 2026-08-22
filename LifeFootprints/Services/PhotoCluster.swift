import Foundation
import UIKit
import CoreLocation
import MapKit

/// 照片聚合标记（Apple 照片地图逻辑：按缩放级别分级聚合，流畅优先）
struct PhotoCluster: Identifiable {
    enum Level: Int, Comparable, CustomStringConvertible {
        case province, city, district, town, block, spot, single
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
        var description: String {
            switch self {
            case .province: return "省"
            case .city: return "市"
            case .district: return "区"
            case .town: return "乡镇"
            case .block: return "街区"
            case .spot: return "点"
            case .single: return "照片"
            }
        }
    }

    let id: String        // 级别+区域key（稳定，用于增量比较）
    let level: Level
    let name: String      // 显示名（省/市/区/附近）
    let count: Int
    /// 到访次数（按拍摄日期去重——不同天拍摄才算不同到访）
    let visits: Int
    let lat: Double
    let lon: Double
    /// 无省份归属的国家集群（如「中国」→ 探索时按 country 级别加载全部照片）
    let isCountryLevel: Bool
    /// 代表性缩略图路径（懒解码：只对可见标记解码）
    let thumbPath: String?
    /// 候选照片 id（随机抽选缩略图容错；spot 级含点击取图样例）
    let sampleIds: [String]?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// 聚合桶（构建过程中的临时结构）
private struct ClusterCell {
    var count = 0
    var latSum = 0.0
    var lonSum = 0.0
    /// 拍摄日期集合（按 UTC 天去重，统计到访次数）
    var visitDays: Set<Int> = []
    var samples: [String] = []
    var thumb: String?
    var thumbTimestamp = Date.distantPast
    var isCountry = false
    /// 地点级：网格内行政区名频次（取众数作为显示名）
    var nameCounts: [String: Int] = [:]
    /// 已经投影到真实轨迹的照片坐标。聚合完成后从中选择代表锚点，
    /// 避免弯曲路线的算术平均值落到路线外。
    var routeAnchors: [(latitude: Double, longitude: Double)] = []
}

/// 四层聚合索引（后台一次性构建；含直辖市城市名规范化）
struct ClusterIndex {
    let province: [PhotoCluster]
    let city: [PhotoCluster]
    let district: [PhotoCluster]
    /// 乡镇级：0.05°≈5km 网格（区与街区之间）
    let town: [PhotoCluster]
    /// 街区级：0.02°≈2km 网格（乡镇与地点之间）
    let block: [PhotoCluster]
    let spot: [PhotoCluster]
    /// 单张级：0.002°≈220m 网格（放大到最近时照片逐个展开）
    let single: [PhotoCluster]

    /// 取某一层级的全部聚合
    func all(at level: PhotoCluster.Level) -> [PhotoCluster] {
        switch level {
        case .province: return province
        case .city: return city
        case .district: return district
        case .town: return town
        case .block: return block
        case .spot: return spot
        case .single: return single
        }
    }

    /// 后台构建：遍历照片记录 → 四级桶（质心 + 计数 + 代表性缩略图 + 样例 id）
    /// 直辖市规范化：北京市/上海市/天津市/重庆市 的 cityName 若为区名 → 归入 district
    /// trails：轨迹索引（健康/记录路线）。精细级（点/单张）坐标经轨迹吸附，
    /// 让照片标记落在线路附近（方案 §4）；省市区级保持真实位置
    static func build(records: [PhotoRecord], trails: TrailIndex? = nil,
                      onSnap: ((TrailSnapResult) -> Void)? = nil) -> ClusterIndex {
        let municipalities = Set(["北京市", "上海市", "天津市", "重庆市"])
        var pBuckets: [String: ClusterCell] = [:]
        var cBuckets: [String: ClusterCell] = [:]
        var dBuckets: [String: ClusterCell] = [:]
        var tBuckets: [String: ClusterCell] = [:]
        var bBuckets: [String: ClusterCell] = [:]
        var sBuckets: [String: ClusterCell] = [:]
        var siBuckets: [String: ClusterCell] = [:]

        func add(_ cell: inout [String: ClusterCell], _ key: String, _ r: PhotoRecord,
                 lat: Double, lon: Double,
                 isCountry: Bool = false, nameForSpot: String? = nil,
                 attachedToRoute: Bool = false) {
            var c = cell[key] ?? ClusterCell()
            c.count += 1
            c.latSum += lat
            c.lonSum += lon
            c.isCountry = c.isCountry || isCountry
            if attachedToRoute {
                c.routeAnchors.append((lat, lon))
            }
            c.visitDays.insert(Int(r.timestamp.timeIntervalSince1970 / 86_400))
            if let n = nameForSpot {
                c.nameCounts[n, default: 0] += 1
                // 地点级：全量记录（浏览全部按网格 ids 走，不截断）
                c.samples.append(r.localIdentifier)
            } else if c.samples.count < 8 {
                c.samples.append(r.localIdentifier)
            }
            if let path = r.thumbnailPath, r.timestamp >= c.thumbTimestamp {
                // 用最近一张作为稳定的集合封面；缺失时渲染层走 PH 后备。
                c.thumb = path
                c.thumbTimestamp = r.timestamp
            }
            cell[key] = c
        }

        for r in records where r.regionState == 1 {
            let province = r.provinceName ?? r.countryName ?? "未知"
            // 无省份归属 → 国家集群（点击后按 country 级别探索全部照片）
            let isCountry = r.provinceName == nil && r.countryName != nil
            // 直辖市规范化：cityName 是区名 → 市名提升为直辖市名，区名归位
            var city = r.cityName ?? province
            var district = r.districtName
            if municipalities.contains(province), let c = r.cityName,
               c != province, c.hasSuffix("区") || c.hasSuffix("县") {
                district = c
                city = province
            }
            if district == nil { district = city == province ? nil : city }

            // 精细级坐标：轨迹吸附（<50m 精确绑定 / ≤300m 吸附到最近轨迹点 /
            // 无 GPS 按拍摄时间插值）——照片标记落在线路附近
            let snapResult = snapPhotoToTrailResult(lat: r.latitude, lon: r.longitude,
                                                    time: r.timestamp.timeIntervalSince1970,
                                                    trails: trails)
            onSnap?(snapResult)
            let snapped: (Double, Double)
            let attachedToRoute: Bool
            switch snapResult {
            case .exact(let a, let b), .snapped(let a, let b),
                 .interpolated(let a, let b):
                snapped = (a, b)
                attachedToRoute = true
            case .kept(let a, let b):
                snapped = (a, b)
                attachedToRoute = false
            }
            add(&pBuckets, province, r, lat: r.latitude, lon: r.longitude, isCountry: isCountry)
            let cityKey = "\(province)|\(city)"
            add(&cBuckets, cityKey, r, lat: r.latitude, lon: r.longitude)
            // 区级：0.1°≈11km 等比网格（吸附坐标；照片组沿路线分布，名字取众数区名）
            let districtKey = String(format: "%.1f_%.1f",
                                     (snapped.0 * 10).rounded() / 10,
                                     (snapped.1 * 10).rounded() / 10)
            add(&dBuckets, districtKey, r, lat: snapped.0, lon: snapped.1,
                nameForSpot: district ?? city, attachedToRoute: attachedToRoute)
            // 乡镇级：0.05°≈5km 网格（吸附坐标；照片组贴路线）
            let townKey = String(format: "%.2f_%.2f",
                                 (snapped.0 * 20).rounded() / 20,
                                 (snapped.1 * 20).rounded() / 20)
            add(&tBuckets, townKey, r, lat: snapped.0, lon: snapped.1,
                nameForSpot: district ?? city, attachedToRoute: attachedToRoute)
            // 街区级：0.02°≈2km 网格（吸附坐标；照片组贴路线）
            let blockKey = String(format: "%.2f_%.2f",
                                  (snapped.0 * 50).rounded() / 50,
                                  (snapped.1 * 50).rounded() / 50)
            add(&bBuckets, blockKey, r, lat: snapped.0, lon: snapped.1,
                nameForSpot: district ?? city, attachedToRoute: attachedToRoute)
            // 地点级：0.005°≈500m 网格（吸附坐标）
            let spotKey = String(format: "%.3f_%.3f",
                                 (snapped.0 * 200).rounded() / 200,
                                 (snapped.1 * 200).rounded() / 200)
            add(&sBuckets, spotKey, r, lat: snapped.0, lon: snapped.1,
                nameForSpot: district ?? city, attachedToRoute: attachedToRoute)
            // 路线照片在最细层仍按约 150m 分组，保持“沿路线的照片组”；
            // 非路线照片保留约 55m 精度。
            let singleFactor = attachedToRoute ? 750.0 : 2000.0
            let singleKey = String(format: "%@_%.4f_%.4f", attachedToRoute ? "route" : "place",
                                   (snapped.0 * singleFactor).rounded() / singleFactor,
                                   (snapped.1 * singleFactor).rounded() / singleFactor)
            add(&siBuckets, singleKey, r, lat: snapped.0, lon: snapped.1,
                nameForSpot: district ?? city, attachedToRoute: attachedToRoute)
        }

        func cluster(_ buckets: [String: ClusterCell], level: PhotoCluster.Level,
                     nameOf: (String, ClusterCell) -> String) -> [PhotoCluster] {
            buckets.map { key, cell in
                let meanLatitude = cell.latSum / Double(max(cell.count, 1))
                let meanLongitude = cell.lonSum / Double(max(cell.count, 1))
                let anchor = PhotoMapLogic.routeAwareAnchor(
                    meanLatitude: meanLatitude,
                    meanLongitude: meanLongitude,
                    routeAnchors: cell.routeAnchors,
                    totalCount: cell.count)
                return PhotoCluster(
                    id: "\(level.rawValue)|\(key)",
                    level: level,
                    name: nameOf(key, cell),
                    count: cell.count,
                    visits: cell.visitDays.count,
                    lat: anchor.latitude,
                    lon: anchor.longitude,
                    isCountryLevel: level == .province && cell.isCountry,
                    thumbPath: cell.thumb,
                    sampleIds: cell.samples.isEmpty ? nil : cell.samples)
            }
        }

        func modeName(_ cell: ClusterCell) -> String {
            cell.nameCounts.max { $0.value < $1.value }?.key ?? "附近"
        }
        return ClusterIndex(
            province: cluster(pBuckets, level: .province) { key, _ in key },
            city: cluster(cBuckets, level: .city) { key, _ in
                String(key.split(separator: "|").last ?? "")
            },
            district: cluster(dBuckets, level: .district) { _, cell in modeName(cell) },
            town: cluster(tBuckets, level: .town) { _, cell in modeName(cell) },
            block: cluster(bBuckets, level: .block) { _, cell in modeName(cell) },
            spot: cluster(sBuckets, level: .spot) { _, cell in modeName(cell) },
            single: cluster(siBuckets, level: .single) { _, cell in modeName(cell) })
    }
}

/// 缩放级别选择（按纬度跨度；阈值贴近 Apple 照片地图观感）
extension PhotoCluster.Level {
    static func level(for span: Double) -> PhotoCluster.Level {
        PhotoCluster.Level(rawValue: PhotoMapLogic.preferredLevel(latitudeSpan: span).rawValue) ?? .province
    }

    static func stableLevel(for span: Double, current: PhotoCluster.Level) -> PhotoCluster.Level {
        let coreCurrent = PhotoMapZoomLevel(rawValue: current.rawValue) ?? .province
        let stable = PhotoMapLogic.stableLevel(latitudeSpan: span, current: coreCurrent)
        return PhotoCluster.Level(rawValue: stable.rawValue) ?? current
    }
}

/// 可见区域过滤：只保留当前级别且在视野（膨胀 30%）内的聚合
extension ClusterIndex {
    static func visible(_ index: ClusterIndex, level: PhotoCluster.Level,
                        region: MKCoordinateRegion) -> [PhotoCluster] {
        return index.all(at: level).filter {
            PhotoMapLogic.contains(latitude: $0.lat, longitude: $0.lon,
                                   centerLatitude: region.center.latitude,
                                   centerLongitude: region.center.longitude,
                                   latitudeSpan: region.span.latitudeDelta,
                                   longitudeSpan: region.span.longitudeDelta)
        }
    }

    /// 高密度区域自动上收一级，确保展示的是可读的“地点集合”。
    static func adaptiveVisible(_ index: ClusterIndex, preferred: PhotoCluster.Level,
                                region: MKCoordinateRegion, maximumCount: Int = 72)
        -> (level: PhotoCluster.Level, clusters: [PhotoCluster]) {
        var level = preferred
        var result = visible(index, level: level, region: region)
        while result.count > maximumCount, level.rawValue > PhotoCluster.Level.province.rawValue {
            level = PhotoCluster.Level(rawValue: level.rawValue - 1) ?? .province
            result = visible(index, level: level, region: region)
        }
        return (level, result)
    }
}
