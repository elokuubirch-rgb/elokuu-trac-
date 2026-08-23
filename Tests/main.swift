import Foundation
import Darwin
import CoreLocation
import CoreLogic

var failed = 0
var passed = 0
func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        print("FAIL  \(name)  \(detail)")
    }
}

// ── V2 统一时间范围 ──
var v2Calendar = Calendar(identifier: .gregorian)
v2Calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let v2Date = v2Calendar.date(from: DateComponents(year: 2025, month: 6, day: 1))!
check(MapTimeScope.choices(currentYear: 2026) == [.all, .year(2026), .year(2025), .year(2024)],
      "V2 时间筛选仅保留全部/今年/去年/前年")
check(MapTimeScope.year(2025).contains(v2Date, calendar: v2Calendar)
      && !MapTimeScope.year(2024).contains(v2Date, calendar: v2Calendar),
      "V2 统一年份判断")

// ── V2 回顾选择：限制 20、跨月份、连续拍摄降权 ──
let reviewBase = v2Calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
var reviewCandidates: [ReviewCandidate] = []
for index in 0..<36 {
    let monthDate = v2Calendar.date(byAdding: .month, value: index / 3, to: reviewBase)!
    let candidateDate = monthDate.addingTimeInterval(Double(index % 3) * 20)
    let recentlyReviewed: Date? = index < 3 ? Date() : nil
    reviewCandidates.append(ReviewCandidate(
        id: "r\(index)", date: candidateDate,
        latitude: 30 + Double(index % 4), longitude: 110 + Double(index % 4),
        lastReviewedAt: recentlyReviewed, reviewCount: index < 3 ? 5 : 0
    ))
}
let selectedReview = ReviewSelectionLogic.select(reviewCandidates, limit: 20, now: Date(), calendar: v2Calendar)
let selectedMonths = Set(selectedReview.map { v2Calendar.dateComponents([.year, .month], from: $0.date) })
check(selectedReview.count == 20, "V2 回顾每轮固定最多20张")
check(selectedMonths.count >= 8, "V2 回顾时间分层", "months=\(selectedMonths.count)")
check(ReviewCompletionLogic.primaryTitle(for: .global) == "再来一组",
      "Review完成页-Global主操作")
check(ReviewCompletionLogic.primaryTitle(for: .location(hasUnseenPhotos: true)) == "继续看看",
      "Review完成页-地点有未看照片")
check(ReviewCompletionLogic.primaryTitle(for: .location(hasUnseenPhotos: false)) == "返回地图",
      "Review完成页-地点已看完")
check(ReviewMediaFilter.allCases.map(\.title) == ["全部照片", "实况", "自拍", "截屏"],
      "Review洗牌入口-筛选项固定为四类")

// ── Live Photo 播放门控：Preview 可先显示，只有稳定停留的当前资源才能接管 ──
check(ReviewLivePlaybackLogic.shouldStart(
    requestedAssetID: "live-B", currentAssetID: "live-B",
    autoPlayEnabled: true, resourceReady: true, isInteracting: false
), "Live-当前资源稳定后允许播放")
check(!ReviewLivePlaybackLogic.shouldStart(
    requestedAssetID: "live-A", currentAssetID: "live-C",
    autoPlayEnabled: true, resourceReady: true, isInteracting: false
), "Live-快速连滑拒绝旧资源串图")
check(!ReviewLivePlaybackLogic.shouldStart(
    requestedAssetID: "live-B", currentAssetID: "live-B",
    autoPlayEnabled: true, resourceReady: false, isInteracting: false
), "Live-资源未就绪时保持静态Preview")
check(!ReviewLivePlaybackLogic.shouldStart(
    requestedAssetID: "live-B", currentAssetID: "live-B",
    autoPlayEnabled: true, resourceReady: true, isInteracting: true
), "Live-Swipe过程中禁止启动播放")

// ── CSV 基础解析 ──
let r1 = CSVParser.parse("""
latitude,longitude,time,name
31.2304,121.4737,2021-10-01T09:00:00,上海
30.5728,104.0668,2022-08-12T15:30:00,成都
""")
check(r1.header.count == 4 && r1.rows.count == 2, "表头与行数", "header=\(r1.header) rows=\(r1.rows.count)")

// ── 引号与转义 ──
let r2 = CSVParser.parse("lat,lon\n\"31.2,121.4\",\"他说 \"\"你好\"\"\"\n")
check(r2.header == ["lat", "lon"] && r2.rows.count == 1
      && r2.rows[0][0] == "31.2,121.4" && r2.rows[0][1] == "他说 \"你好\"",
      "引号与转义", "\(r2.rows)")

// ── BOM 与 CRLF ──
let r3 = CSVParser.parse("\u{FEFF}lat,lon,time\r\n31,121,2021-01-01\r\n32,122,2021-01-02\r\n")
check(r3.header.first == "lat" && r3.rows.count == 2, "BOM 与 CRLF", "header=\(r3.header) rows=\(r3.rows.count)")

// ── 列映射 + 时间解析 ──
let m1 = ColumnMapping(latIndex: 0, lonIndex: 1, timeIndex: 2, nameIndex: 3)
let mapped = r1.mapPoints(m1)
check(mapped.points.count == 2 && mapped.points[0].city == "上海", "列映射", "\(mapped.points)")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
check(utc.component(.year, from: mapped.points[0].timestamp) == 2021, "ISO8601 时间解析", "\(mapped.points[0].timestamp)")
check(CSVParser.parseDate("2022/08/12 15:30:00") != nil, "斜杠时间格式")
check(CSVParser.parseDate("2021-10-01") != nil, "日期格式")

// ── 非法坐标跳过 ──
let r4 = CSVParser.parse("lat,lon,time\n999,121,2021-01-01\n31,121,2021-01-01\n0,0,2021-01-01\n")
let m4 = ColumnMapping(latIndex: 0, lonIndex: 1, timeIndex: 2, nameIndex: nil)
let mapped4 = r4.mapPoints(m4)
check(mapped4.points.count == 2 && mapped4.skipped == 1, "非法坐标跳过", "pts=\(mapped4.points.count) skip=\(mapped4.skipped)")

// ── 距离计算（经度 0.05° ≈ 4.65km @31.23°N）──
let d = GeoMath.distanceMeters(from: (31.2304, 121.4737), to: (31.2304, 121.5237))
check(abs(d - 4650) < 200, "haversine ≈4.65km", "got \(d)")

// ── 去重：同日 50m 内合并，跨日保留 ──
var idx = DedupeIndex()
let day1 = 19000, day2 = 19001
check(!idx.hasNearby(day: day1, lat: 31.2304, lon: 121.4737, withinMeters: 50), "去重-首次不重复")
idx.add(day: day1, lat: 31.2304, lon: 121.4737)
check(idx.hasNearby(day: day1, lat: 31.2306, lon: 121.4738, withinMeters: 50), "去重-同日50m内命中")
check(!idx.hasNearby(day: day2, lat: 31.2304, lon: 121.4737, withinMeters: 50), "去重-跨日保留")

// ── 网格聚簇（3 簇 × 10 点，簇间距 0.1°，不会跨格）──
let pts = (0..<30).map { i in
    let cluster = i / 10
    let offset = Double(i % 10) * 0.0001
    return (lat: 31.2300 + Double(cluster) * 0.1 + offset, lon: 121.4700 + Double(cluster) * 0.1 + offset)
}
let clusters = GeoMath.topClusters(pts, topN: 3)
check(clusters.count == 3 && clusters.allSatisfy { $0.count == 10 },
      "网格聚簇 top3", "\(clusters.map { $0.count })")

// ── 照片地图缩放层级 / 边界稳定性 ──
check(PhotoMapLogic.preferredLevel(latitudeSpan: 12) == .province
      && PhotoMapLogic.preferredLevel(latitudeSpan: 0.02) == .block
      && PhotoMapLogic.preferredLevel(latitudeSpan: 0.002) == .single,
      "照片地图分级")
check(PhotoMapLogic.stableLevel(latitudeSpan: 1.15, current: .city) == .city,
      "缩放边界迟滞-不闪烁")
check(PhotoMapLogic.stableLevel(latitudeSpan: 0.9, current: .city) == .district,
      "缩放边界迟滞-进入细级")

// 弯曲/折返路线的照片均值会落在线外；聚合锚点必须选择真实路线点。
let curvedRouteAnchors = [
    (latitude: 30.000, longitude: 120.000),
    (latitude: 30.010, longitude: 120.000),
    (latitude: 30.010, longitude: 120.010),
    (latitude: 30.000, longitude: 120.010)
]
let routeAnchor = PhotoMapLogic.routeAwareAnchor(
    meanLatitude: 30.005, meanLongitude: 120.005,
    routeAnchors: curvedRouteAnchors, totalCount: 4)
check(curvedRouteAnchors.contains(where: {
    abs($0.latitude - routeAnchor.latitude) < 0.000001 &&
    abs($0.longitude - routeAnchor.longitude) < 0.000001
}), "路线照片聚合锚点仍在线上", "anchor=\(routeAnchor)")

let mixedAnchor = PhotoMapLogic.routeAwareAnchor(
    meanLatitude: 30.005, meanLongitude: 120.005,
    routeAnchors: [curvedRouteAnchors[0]], totalCount: 4)
check(abs(mixedAnchor.latitude - 30.005) < 0.000001 &&
      abs(mixedAnchor.longitude - 120.005) < 0.000001,
      "非路线照片占多数时保留真实质心", "anchor=\(mixedAnchor)")
check(PhotoMapLogic.contains(latitude: 10, longitude: -179.5,
                             centerLatitude: 10, centerLongitude: 179.5,
                             latitudeSpan: 4, longitudeSpan: 4),
      "跨日期变更线可见性")

// ── 分段距离合理性 ──
let seg1 = GeoMath.distanceMeters(from: (31.2304, 121.4737), to: (31.2310, 121.4740))
let seg2 = GeoMath.distanceMeters(from: (31.2310, 121.4740), to: (31.2315, 121.4745))
check(seg1 > 65 && seg1 < 80 && seg2 > 65 && seg2 < 82, "逐段距离合理", "\(seg1), \(seg2)")

// ── CSV 导出行格式 ──
var drafts: [FootprintDraft] = []
var t = Date(timeIntervalSince1970: 1_700_000_000)
for (lat, lon) in [(31.2304, 121.4737), (31.2310, 121.4740)] {
    drafts.append(FootprintDraft(latitude: lat, longitude: lon, timestamp: t, source: FootprintSource.csv.rawValue))
    t.addTimeInterval(3600)
}
check(drafts.count == 2 && drafts[0].source == FootprintSource.csv.rawValue, "草稿模型", "\(drafts.count)")

// ── 地图图层语义：照片/地点不能冒充轨迹，健康点不能泄漏到普通点层 ──
let semanticBase = Date(timeIntervalSince1970: 1_700_100_000)
let semanticSnapshots = [
    FootprintSnapshot(lat: 31.0, lon: 121.0, t: semanticBase, source: FootprintSource.photo.rawValue),
    FootprintSnapshot(lat: 31.1, lon: 121.1, t: semanticBase, source: FootprintSource.csv.rawValue),
    FootprintSnapshot(lat: 31.2, lon: 121.2, t: semanticBase, source: FootprintSource.manual.rawValue),
    FootprintSnapshot(lat: 31.3, lon: 121.3, t: semanticBase, source: FootprintSource.gps.rawValue),
    FootprintSnapshot(lat: 31.4, lon: 121.4, t: semanticBase, source: FootprintSource.health.rawValue)
]
check(MapLayerSemantics.autoTrajectory(semanticSnapshots).map(\.source) == [FootprintSource.gps.rawValue],
      "图层语义-自动轨迹只消费GPS")
check(MapLayerSemantics.workoutTrajectory(semanticSnapshots).map(\.source) == [FootprintSource.health.rawValue],
      "图层语义-运动轨迹只消费HealthKit")
check(MapLayerSemantics.footprintDots(semanticSnapshots).allSatisfy {
    $0.source != FootprintSource.photo.rawValue && $0.source != FootprintSource.health.rawValue
}, "图层语义-照片和健康点不泄漏到普通点层")

// ── Trajectory Domain：Builder 负责会话/路线/分段，Map 不再猜边界 ──
let trajectoryBase = Date(timeIntervalSince1970: 1_701_000_000)
func trajectorySample(_ id: String, _ source: TrajectorySource, _ seconds: Double,
                      _ lat: Double, _ lon: Double, session: String? = nil,
                      route: String? = nil, accuracy: Double? = 10) -> TrajectorySample {
    TrajectorySample(id: id, source: source, sourceIdentifier: session,
                     sessionID: session, routeID: route,
                     latitude: lat, longitude: lon,
                     timestamp: trajectoryBase.addingTimeInterval(seconds),
                     horizontalAccuracy: accuracy)
}
let domainSamples = [
    trajectorySample("a1", .coreLocation, 0, 31.0000, 121.0000),
    trajectorySample("a2", .coreLocation, 60, 31.0005, 121.0005),
    trajectorySample("a3", .coreLocation, 4_000, 31.0010, 121.0010),
    trajectorySample("w1-r1-1", .healthWorkout, 100, 31.1000, 121.1000, session: "workout-1", route: "route-1"),
    trajectorySample("w1-r1-2", .healthWorkout, 160, 31.1005, 121.1005, session: "workout-1", route: "route-1"),
    trajectorySample("w1-r2-1", .healthWorkout, 170, 31.1006, 121.1006, session: "workout-1", route: "route-2"),
    trajectorySample("w2-1", .healthWorkout, 171, 31.1007, 121.1007, session: "workout-2", route: "route-3")
]
let domainTrajectories = TrajectoryBuilder.build(samples: domainSamples)
let autoDomain = domainTrajectories.filter { $0.source == .coreLocation }
let workoutDomain = domainTrajectories.filter { $0.source == .healthWorkout }
check(autoDomain.count == 2, "轨迹领域-Core Location时间断层生成新Session", "count=\(autoDomain.count)")
check(workoutDomain.count == 2, "轨迹领域-不同Workout永不合并", "count=\(workoutDomain.count)")
check(workoutDomain.first(where: { $0.sessionID == "workout-1" })?.segments.count == 2,
      "轨迹领域-同Workout多Route保持独立Segment")
check(workoutDomain.allSatisfy { Set($0.segments.map(\.sessionID)) == Set([$0.sessionID]) },
      "轨迹领域-Segment保留Session边界")
check(workoutDomain.first(where: { $0.sessionID == "workout-1" })?.quality.accuratePointRatio == 1,
      "轨迹领域-质量统计保留精度")

// ── 同级随机区域候选 ──
let cities = ["哈尔滨市", "大连市", "昆明市", "成都市", "西安市", "青岛市", "杭州市", "上海市", "深圳市"]
let next = randomCandidate(cities, excluding: "哈尔滨市", recent: ["大连市", "昆明市"])
check(next != nil && next != "哈尔滨市" && next != "大连市" && next != "昆明市", "随机候选-排除当前与最近", "next=\(next ?? "nil")")
let none = randomCandidate(["哈尔滨市"], excluding: "哈尔滨市", recent: [])
check(none == nil, "随机候选-无候选返回nil")
let excludeAll = randomCandidate(cities, excluding: "哈尔滨市", recent: Array(cities.filter { $0 != "哈尔滨市" }))
check(excludeAll == nil, "随机候选-全部排除返回nil")

// ── RegionInfo 层级判断 ──
let region = RegionInfo(country: "中国", province: "黑龙江省", city: "哈尔滨市", district: "南岗区")
check(region.finestLevel == RegionLevel.district, "最细层级=district", "\(region.finestLevel)")
check(region.name(at: RegionLevel.city) == "哈尔滨市" && region.name(at: RegionLevel.province) == "黑龙江省", "按层级取名称")
let provinceOnly = RegionInfo(country: "中国", province: "四川省")
check(provinceOnly.finestLevel == RegionLevel.province, "最细层级=province", "\(provinceOnly.finestLevel)")
check(RegionInfo().finestLevel == RegionLevel.country, "空区域最细层级=country")

// ── 海拔平滑 ──
var smoother = AltitudeSmoother(windowSize: 5)
let raw = [48.0, 63.0, 41.0, 57.0, 52.0, 60.0, 44.0]
var smoothedValues: [Double] = []
for v in raw { smoothedValues.append(smoother.push(v)) }
check(abs(smoothedValues[4] - 52.2) < 0.01, "海拔均值(前5个)", "\(smoothedValues[4])")
check(abs(smoothedValues[5] - (63+41+57+52+60)/5.0) < 0.01, "海拔滑动窗口(最后5个)", "\(smoothedValues[5])")
check(smoothedValues[5] > 41 && smoothedValues[5] < 63, "平滑后无明显跳变", "\(smoothedValues[5])")

// ── 智能列映射：中文表头（一生足迹导出风格）──
let r5 = CSVParser.parse("时间,纬度,经度,地址\n2025-01-15 09:30:00,31.2304,121.4737,上海人民广场\n2025-03-08 14:05,39.9042,116.4074,北京天安门\n")
let m5 = CSVParser.headerMapping(r5.header)
check(m5.latIndex == 1 && m5.lonIndex == 2 && m5.timeIndex == 0 && m5.nameIndex == 3, "中文表头映射", "\(m5)")
let smart5 = CSVParser.smartMapping(r5)
check(smart5.latIndex == 1 && smart5.lonIndex == 2, "中文表头智能映射")

// ── 无表头嗅探：数据特征识别 ──
let r6 = CSVParser.parse("2025-01-15 09:30:00,31.2304,121.4737,上海市黄浦区人民大道\n2025-03-08 14:05:00,39.9042,116.4074,北京市东城区东长安街\n2025-06-20 11:40:00,30.5728,104.0668,成都市锦江区\n")
let m6 = CSVParser.sniffMapping(r6)
check(m6.latIndex == 1 && m6.lonIndex == 2 && m6.timeIndex == 0 && m6.nameIndex == 3, "无表头数据嗅探", "\(m6)")

// ── 乱序无表头（经度在前）──
let r7 = CSVParser.parse("121.4737,31.2304,上海市人民广场\n116.4074,39.9042,北京市天安门\n104.0668,30.5728,成都市中心\n")
let m7 = CSVParser.sniffMapping(r7)
check(m7.latIndex == 1 && m7.lonIndex == 0, "乱序列嗅探(经度在前)", "\(m7)")

// ── Unix 时间戳解析 ──
let ts1 = CSVParser.parseDate("1737000000")
let ts2 = CSVParser.parseDate("1737000000000")
check(ts1 != nil && ts2 != nil, "Unix时间戳(秒/毫秒)")
if let t1 = ts1, let t2 = ts2 {
    check(abs(t1.timeIntervalSince(t2)) < 2, "时间戳一致性", "\(t1) vs \(t2)")
}

// ── 嗅探+表头混合（表头只认识一半）──
let r8 = CSVParser.parse("idx,lat,备注\n1,31.2304,人民广场\n2,39.9042,天安门\n3,104.0668,错误经度在前\n")
let m8 = CSVParser.smartMapping(r8)
check(m8.latIndex == 1, "混合映射-表头优先", "\(m8)")

// ── 时间轴年份筛选（今年/去年）──
var months: [Date] = []
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
var comps = DateComponents(); comps.year = 2023; comps.month = 1; comps.day = 1
for m in 0..<44 {   // 2023-01 ~ 2026-08，共 44 个月
    var c = comps; c.month = 1 + m
    months.append(cal.date(from: c)!)
}
check(yearStartIndex(months: months, year: 2023) == 0, "年份起始-2023年首月", "\(yearStartIndex(months: months, year: 2023))")
check(yearStartIndex(months: months, year: 2026) == 36, "年份起始-2026年首月", "\(yearStartIndex(months: months, year: 2026))")
check(yearStartIndex(months: months, year: 2020) == 43, "无数据年回退最后月", "\(yearStartIndex(months: months, year: 2020))")
// 今年范围 [2026首月, 最后月]；去年范围 [0, 2026首月-1]
let cur = 2026
let yMin = Double(yearStartIndex(months: months, year: cur))
let yMax = Double(months.count - 1)
let lastYearMax = Double(max(0, yearStartIndex(months: months, year: cur) - 1))
check(yMin == 36 && yMax == 43, "今年范围 [36,43]（共 8 个月）", "[\\(yMin),\\(yMax)]")
check(lastYearMax == 35, "去年范围上界 35（共 36 个月）", "\(lastYearMax)")
// 边界：数据只有今年 → 去年回退到 0（不越界、不崩溃）
let onlyThisYear = Array(months[36...])
check(yearStartIndex(months: onlyThisYear, year: 2026) == 0
      && max(0, yearStartIndex(months: onlyThisYear, year: 2026) - 1) == 0,
      "仅今年数据-去年回退不越界")


// ── 轨迹平滑曲线（Catmull-Rom 跨城插值）──
let straight = [CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47),
                CLLocationCoordinate2D(latitude: 36.07, longitude: 120.38),
                CLLocationCoordinate2D(latitude: 39.90, longitude: 116.40)]
let smooth = smoothTrail(straight)
check(smooth.count > straight.count, "跨城段插值采样", "\(smooth.count) 点")
check(abs(smooth[3].latitude - 31.23) > 0.01, "曲线偏离直线起点", "第一采样点 lat=\(smooth[3].latitude)")
// 短距离段不插值（保持精度）
let nearby = [CLLocationCoordinate2D(latitude: 31.230, longitude: 121.470),
              CLLocationCoordinate2D(latitude: 31.231, longitude: 121.472),
              CLLocationCoordinate2D(latitude: 31.233, longitude: 121.475)]
check(smoothTrail(nearby).count == 3, "短距段不插值", "\(smoothTrail(nearby).count) 点")
// 端点保持不变
check(abs(smooth.first!.latitude - 31.23) < 1e-9 && abs(smooth.last!.longitude - 116.40) < 1e-9,
      "平滑后端点不变")
// Catmull-Rom 中间值落在控制点之间（无越界跳变）
let mid = catmullRom(a: straight[0], b: straight[0], c: straight[1], d: straight[2], t: 0.5)
check(mid.latitude > 31.23 && mid.latitude < 36.07, "Catmull-Rom 中间值有界", "lat=\(mid.latitude)")


// ── 轨迹吸附（方案 §4：时间优先沿线分布，避免照片堆叠）──
let trail = TrailIndex(points: [
    TrailPoint(lat: 31.2304, lon: 121.4737, t: 1_700_000_000),
    TrailPoint(lat: 31.2320, lon: 121.4750, t: 1_700_000_100),
    TrailPoint(lat: 31.2350, lon: 121.4780, t: 1_700_000_300),
])
// 线段投影：返回位置应在 p0-p1 之间，不应吸到两端的离散 GPS 点。
let routeProjection = trail.nearestOnRoute(to: 31.23115, lon: 121.4747, within: 100)
check(routeProjection != nil
      && routeProjection!.lat > 31.2304 && routeProjection!.lat < 31.2320
      && routeProjection!.distance < 100,
      "照片投影到路线线段", "\(String(describing: routeProjection))")
// 精确匹配：拍摄时间对应轨迹位置 <50m → 绑定该位置（t=50 → p0/p1 插值点）
let exact = snapPhotoToTrail(lat: 31.2312, lon: 121.47435, time: 1_700_000_050, trails: trail)
check(abs(exact.0 - 31.2312) < 0.0001 && abs(exact.1 - 121.47435) < 0.0001,
      "轨迹精确匹配(时间位置<50m)", "\(exact)")
// 轨迹吸附：时间位置 50-300m → 吸附（t=200 → (31.2335,121.4765)，照片偏东 ~140m）
let snap = snapPhotoToTrail(lat: 31.2335, lon: 121.4780, time: 1_700_000_200, trails: trail)
check(abs(snap.0 - 31.2335) < 0.0001 && abs(snap.1 - 121.4765) < 0.0001,
      "轨迹吸附(时间位置50-300m)", "\(snap)")
// 超距不吸附（保持原坐标）
let far = snapPhotoToTrail(lat: 31.2500, lon: 121.4900, time: 1_700_000_200, trails: trail)
check(abs(far.0 - 31.2500) < 0.00001, "超距不吸附(>300m)", "\(far)")
// 时间插值：无 GPS 照片按拍摄时间定位（前后点线性插值）
let interp = snapPhotoToTrail(lat: 999, lon: 999, time: 1_700_000_200, trails: trail)
check(abs(interp.0 - 31.2335) < 0.0001 && abs(interp.1 - 121.4765) < 0.0001,
      "时间插值定位(无GPS)", "\(interp)")
// 无轨迹返回原坐标
let noTrail = snapPhotoToTrail(lat: 31.24, lon: 121.48, time: 1_700_000_100, trails: nil)
check(noTrail.0 == 31.24 && noTrail.1 == 121.48, "无轨迹原坐标", "\(noTrail)")
// 沿线分布：同一轨迹点附近、不同时刻的照片 → 吸附到不同位置（不堆叠）
let sA = snapPhotoToTrail(lat: 31.2321, lon: 121.4751, time: 1_700_000_120, trails: trail)
let sB = snapPhotoToTrail(lat: 31.2319, lon: 121.4749, time: 1_700_000_180, trails: trail)
check(!(abs(sA.0 - sB.0) < 1e-9 && abs(sA.1 - sB.1) < 1e-9),
      "沿线时间分布(不同时刻不同位置)", "A=\(sA) B=\(sB)")

// ── 跨线路间隙（>2h 无轨迹点）：不插值 → 回退空间最近点 ──
let gapped = TrailIndex(points: [
    TrailPoint(lat: 31.2304, lon: 121.4737, t: 0),
    TrailPoint(lat: 31.2320, lon: 121.4750, t: 100),
    TrailPoint(lat: 31.2350, lon: 121.4780, t: 300),
    TrailPoint(lat: 31.2400, lon: 121.4830, t: 100_000),   // 次日线路
])
// 间隙内、GPS 在轨迹 50m 内 → 回退精确绑定最近点
let gapExact = snapPhotoToTrail(lat: 31.2321, lon: 121.4751, time: 40_000, trails: gapped)
let gapExactRoute = gapped.nearestOnRoute(to: gapExact.0, lon: gapExact.1, within: 60)
check(gapExactRoute != nil && gapExactRoute!.distance < 1,
      "间隙回退精确绑定(路线线段)", "\(gapExact)")
// 间隙内、GPS 在轨迹 50-300m → 回退吸附最近点
let gapSnap = snapPhotoToTrail(lat: 31.2355, lon: 121.4785, time: 40_000, trails: gapped)
check(abs(gapSnap.0 - 31.2350) < 0.0001 && abs(gapSnap.1 - 121.4780) < 0.0001,
      "间隙回退吸附(最近点)", "\(gapSnap)")
// 间隙内、无 GPS → 保持原坐标（插值被拒绝，不跨线路乱定位）
let gapInterp = snapPhotoToTrail(lat: 999, lon: 999, time: 40_000, trails: gapped)
check(gapInterp.0 == 999 && gapInterp.1 == 999, "间隙内不跨线路插值", "\(gapInterp)")

// ── 后台低功耗交通策略（本地 / 高铁 / 飞机）──
let bgBase = BackgroundLocationSample(latitude: 31.2304, longitude: 121.4737,
                                      timestamp: 1_700_000_000, speedMPS: 0,
                                      altitude: 10, horizontalAccuracy: 30)
let localMove = BackgroundLocationSample(latitude: 31.2304, longitude: 121.4787,
                                         timestamp: 1_700_000_600, speedMPS: 1.2,
                                         altitude: 10, horizontalAccuracy: 35)
let localDecision = BackgroundTrackPolicy.evaluate(previous: bgBase, current: localMove)
check(localDecision.shouldRecord && localDecision.mode == .local,
      "后台策略-本地重大位移留点", "\(localDecision)")

let railMove = BackgroundLocationSample(latitude: 31.2304, longitude: 121.5337,
                                        timestamp: 1_700_000_180, speedMPS: 82 / 3.6,
                                        altitude: 20, horizontalAccuracy: 80)
let railDecision = BackgroundTrackPolicy.evaluate(previous: bgBase, current: railMove)
check(railDecision.shouldRecord && railDecision.mode == .highSpeedRail,
      "后台策略-高铁稀疏关键点", "\(railDecision)")

let shortFlight = BackgroundLocationSample(latitude: 31.2304, longitude: 121.5737,
                                           timestamp: 1_700_000_300, speedMPS: 220,
                                           altitude: 9_000, horizontalAccuracy: 250)
let shortFlightDecision = BackgroundTrackPolicy.evaluate(previous: bgBase, current: shortFlight)
check(!shortFlightDecision.shouldRecord && shortFlightDecision.mode == .airborne,
      "后台策略-飞机短距离不密集留点", "\(shortFlightDecision)")
let flightMove = BackgroundLocationSample(latitude: 31.2304, longitude: 121.8737,
                                          timestamp: 1_700_000_600, speedMPS: 220,
                                          altitude: 9_500, horizontalAccuracy: 300)
let flightDecision = BackgroundTrackPolicy.evaluate(previous: bgBase, current: flightMove)
check(flightDecision.shouldRecord && flightDecision.mode == .airborne,
      "后台策略-飞机长距离关键点", "\(flightDecision)")

let inaccurate = BackgroundLocationSample(latitude: 31.3, longitude: 121.8,
                                           timestamp: 1_700_001_000, speedMPS: 50,
                                           altitude: 10, horizontalAccuracy: 2_000)
check(!BackgroundTrackPolicy.evaluate(previous: bgBase, current: inaccurate).shouldRecord,
      "后台策略-拒绝低精度漂移")

// ── 主动轨迹点过滤（联合决策：距离 + 时间 + 转向 + 精度 + 瞬移）──
var trackFilter = TrackPointFilter()
let tfBase = 1_700_000_000.0
let tfFirst = TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                          speedMPS: 0, course: 0, horizontalAccuracy: 10)
check(trackFilter.evaluate(tfFirst).accept, "轨迹过滤-首点作为起点")

// 距离触发：向北约 11m → 接受（步行 3–8m 目标区间的下界之外仍接受）
let tfDist = TrackSample(latitude: 31.2305, longitude: 121.4737, timestamp: tfBase + 3,
                         speedMPS: 1.2, course: 0, horizontalAccuracy: 10)
let tfDistDec = trackFilter.evaluate(tfDist)
check(tfDistDec.accept && tfDistDec.distanceMeters > 9,
      "轨迹过滤-距离触发接受", "d=\(tfDistDec.distanceMeters)")

// 静止：相对上一个已接受点（tfDist @31.2305）仅约 2m 位移 + 短时间 + 良好精度 → 拒绝为 stationary
let tfStationary = TrackSample(latitude: 31.23051, longitude: 121.47372, timestamp: tfBase + 4,
                               speedMPS: 0, course: 0, horizontalAccuracy: 10)
let tfStatDec = trackFilter.evaluate(tfStationary)
check(!tfStatDec.accept && tfStatDec.reason == .stationary,
      "轨迹过滤-静止拒绝", "reason=\(String(describing: tfStatDec.reason)) d=\(tfStatDec.distanceMeters)")

// 时间兜底：慢速约 2m 位移，但已过 8s 且精度合理 → 接受
let tfSlow = TrackSample(latitude: 31.23052, longitude: 121.4737, timestamp: tfBase + 12,
                         speedMPS: 0.2, course: 0, horizontalAccuracy: 20)
let tfSlowDec = trackFilter.evaluate(tfSlow)
check(tfSlowDec.accept, "轨迹过滤-时间兜底接受", "d=\(tfSlowDec.distanceMeters) e=\(tfSlowDec.elapsedSeconds)")

// 转向兜底：约 2m 位移 + 90° 转向 → 接受
var tf2 = TrackPointFilter()
_ = tf2.evaluate(TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                             speedMPS: 0, course: 0, horizontalAccuracy: 10))
let tfTurn = TrackSample(latitude: 31.23042, longitude: 121.4737, timestamp: tfBase + 2,
                         speedMPS: 0.5, course: 90, horizontalAccuracy: 15)
let tfTurnDec = tf2.evaluate(tfTurn)
check(tfTurnDec.accept && tfTurnDec.headingChangeDegrees >= 40,
      "轨迹过滤-转向兜底接受", "heading=\(tfTurnDec.headingChangeDegrees)")

// 极差精度：>100m → 拒绝 poorAccuracy
var tf3 = TrackPointFilter()
_ = tf3.evaluate(TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                             speedMPS: 0, course: 0, horizontalAccuracy: 10))
let tfBad = TrackSample(latitude: 31.2305, longitude: 121.4737, timestamp: tfBase + 2,
                        speedMPS: 1, course: 0, horizontalAccuracy: 250)
let tfBadDec = tf3.evaluate(tfBad)
check(!tfBadDec.accept && tfBadDec.reason == .poorAccuracy,
      "轨迹过滤-极差精度拒绝", "reason=\(String(describing: tfBadDec.reason))")

// 真正重复：<1m → 拒绝 duplicate
var tf4 = TrackPointFilter()
_ = tf4.evaluate(TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                             speedMPS: 0, course: 0, horizontalAccuracy: 10))
let tfDup = TrackSample(latitude: 31.2304002, longitude: 121.4737002, timestamp: tfBase + 1,
                        speedMPS: 0, course: 0, horizontalAccuracy: 10)
let tfDupDec = tf4.evaluate(tfDup)
check(!tfDupDec.accept && tfDupDec.reason == .duplicate,
      "轨迹过滤-重复坐标拒绝", "reason=\(String(describing: tfDupDec.reason))")

// 不合理瞬移：约 500m 在 2s 内（250 m/s）→ 拒绝 impossibleJump
var tf5 = TrackPointFilter()
_ = tf5.evaluate(TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                             speedMPS: 0, course: 0, horizontalAccuracy: 10))
let tfJump = TrackSample(latitude: 31.2349, longitude: 121.4737, timestamp: tfBase + 2,
                         speedMPS: 0, course: 0, horizontalAccuracy: 10)
let tfJumpDec = tf5.evaluate(tfJump)
check(!tfJumpDec.accept && tfJumpDec.reason == .impossibleJump,
      "轨迹过滤-不合理瞬移拒绝", "reason=\(String(describing: tfJumpDec.reason)) d=\(tfJumpDec.distanceMeters)")

// 非法坐标与时间倒序 → 拒绝
var tf6 = TrackPointFilter()
_ = tf6.evaluate(TrackSample(latitude: 31.2304, longitude: 121.4737, timestamp: tfBase,
                             speedMPS: 0, course: 0, horizontalAccuracy: 10))
check(tf6.evaluate(TrackSample(latitude: 999, longitude: 121.4737, timestamp: tfBase + 1,
                               speedMPS: 0, course: 0, horizontalAccuracy: 10)).reason == .invalidCoordinate,
      "轨迹过滤-非法坐标拒绝")
check(tf6.evaluate(TrackSample(latitude: 31.2305, longitude: 121.4737, timestamp: tfBase - 1,
                               speedMPS: 0, course: 0, horizontalAccuracy: 10)).reason == .invalidTimestamp,
      "轨迹过滤-时间倒序拒绝")

// ── 回顾 Session 逻辑（再来一组 / 近期去重 / 分组）──
check(ReviewSessionLogic.clampedGroupSize(0) == 1, "回顾-组大小下限")
check(ReviewSessionLogic.clampedGroupSize(20) == 20, "回顾-组大小默认")
check(ReviewSessionLogic.clampedGroupSize(101) == 100, "回顾-组大小上限")
check(ReviewSessionLogic.clampedGroupSize(-3) == 1, "回顾-组大小负数")

let rvNow = 1_800_000_000.0
let rvHistory: [String: ReviewHistoryEntry] = [
    "never1": ReviewHistoryEntry(),
    "never2": ReviewHistoryEntry(),
    "old1": ReviewHistoryEntry(lastReviewedAt: rvNow - 90 * 86_400, reviewCount: 2),
    "recent1": ReviewHistoryEntry(lastReviewedAt: rvNow - 5 * 86_400, reviewCount: 3),
    "recent2": ReviewHistoryEntry(lastReviewedAt: rvNow - 10 * 86_400, reviewCount: 1),
]
let rvOrdered = ReviewSessionLogic.orderedCandidates(
    candidates: ["recent2", "never1", "old1", "excluded", "recent1", "never2"],
    history: rvHistory,
    excludeIDs: ["excluded"],
    recentInterval: 30 * 86_400,
    now: rvNow)
check(!rvOrdered.contains("excluded"), "回顾-排除当前Session已用照片")
let rvPosNever = rvOrdered.firstIndex(of: "never1")!
let rvPosOld = rvOrdered.firstIndex(of: "old1")!
let rvPosRecent = rvOrdered.firstIndex(of: "recent1")!
check(rvPosNever < rvPosOld && rvPosOld < rvPosRecent,
      "回顾-未看过优先于近期看过", "\(rvOrdered)")
let rvPosRecent2 = rvOrdered.firstIndex(of: "recent2")!
check(rvPosRecent2 < rvPosRecent, "回顾-近期内最久未看优先")

let rvNoDedup = ReviewSessionLogic.orderedCandidates(
    candidates: ["recent1", "never1"],
    history: rvHistory, excludeIDs: [], recentInterval: nil, now: rvNow)
check(rvNoDedup.count == 2 && rvNoDedup.first == "never1", "回顾-关闭去重时未看过仍优先")

let rvMany = (0..<55).map { "p\($0)" }
let rvPlans = ReviewSessionLogic.buildGroups(orderedIDs: rvMany, groupSize: 20, groupCount: 3)
check(rvPlans.count == 3 && rvPlans[0].photoIDs.count == 20
      && rvPlans[1].photoIDs.count == 20 && rvPlans[2].photoIDs.count == 15,
      "回顾-三组分桶最后一组可不足", "\(rvPlans.map { $0.photoIDs.count })")
let rvFew = ReviewSessionLogic.buildGroups(orderedIDs: ["a", "b", "c"], groupSize: 20, groupCount: 3)
check(rvFew.count == 1 && rvFew[0].photoIDs.count == 3, "回顾-候选不足只生成一组")
let rvAllIDs = rvPlans.flatMap(\.photoIDs)
check(Set(rvAllIDs).count == rvAllIDs.count, "回顾-同一Session内照片唯一")

// ── 奥维式地图源导入校验 ──
let validXYZ = CustomMapSource(name: "测试等高线",
                               urlTemplate: "https://tiles.example.com/{z}/{x}/{y}.png",
                               scheme: .xyz, minimumZoom: 1, maximumZoom: 18,
                               attribution: "© Example Maps")
check(CustomMapSourceValidator.validationError(for: validXYZ) == nil,
      "地图源-合法XYZ通过")

let validTMS = CustomMapSource(name: "TMS",
                               urlTemplate: "https://{s}.example.com/{z}/{x}/{y}{r}.png",
                               scheme: .tms, minimumZoom: 0, maximumZoom: 20,
                               attribution: "© Example Maps")
check(CustomMapSourceValidator.validationError(for: validTMS) == nil,
      "地图源-合法TMS通过")

let rawGoogle = CustomMapSource(name: "Google raw tiles",
                                urlTemplate: "https://mt1.google.com/vt/{z}/{x}/{y}.png",
                                attribution: "Google")
let googleError = CustomMapSourceValidator.validationError(for: rawGoogle)
check(googleError?.contains("Maps Platform") == true,
      "地图源-拒绝Google非官方直链", googleError ?? "nil")

let insecureSource = CustomMapSource(name: "HTTP",
                                     urlTemplate: "http://tiles.example.com/{z}/{x}/{y}.png",
                                     attribution: "© Example")
check(CustomMapSourceValidator.validationError(for: insecureSource)?.contains("HTTPS") == true,
      "地图源-拒绝非HTTPS")

let mapTilerIframe = #"<iframe width="500" height="300" src="https://api.maptiler.com/maps/outdoor-v4/?key=testKey123#0.2/26.6/4.8"></iframe>"#
let parsedMapTiler = MapSourceInputParser.parse(mapTilerIframe)
check(parsedMapTiler?.urlTemplate ==
      "https://api.maptiler.com/maps/outdoor-v4/256/{z}/{x}/{y}@2x.png?key=testKey123",
      "地图源-粘贴iframe转XYZ", parsedMapTiler?.urlTemplate ?? "nil")
check(parsedMapTiler?.suggestedName == "专业等高线" &&
      parsedMapTiler?.suggestedMaximumZoom == 20,
      "地图源-MapTiler自动补全")

let genericIframe = #"<iframe src='https://tiles.example.com/{z}/{x}/{y}.png'></iframe>"#
check(MapSourceInputParser.parse(genericIframe)?.urlTemplate ==
      "https://tiles.example.com/{z}/{x}/{y}.png",
      "地图源-通用iframe提取src")

if failed == 0 {
    print("\n✅ ALL TESTS PASSED (\(passed) checks)")
} else {
    print("\n❌ \(failed) TEST(S) FAILED")
}
exit(failed == 0 ? 0 : 1)
