import Foundation
import UIKit
import SwiftData

#if DEBUG
/// 仅 DEBUG 构建生效的自动化测试钩子（通过环境变量控制，正式包不受影响）
///
/// 用法示例：
///   FP_SEED=1                      启动时注入一组模拟足迹（上海周边 2025-01~2026-08）
///   FP_AUTO_SCAN=1                 引导页自动开始扫描相册（需先 simctl privacy 授权）
///   FP_CSV=1                       启动时导入 App 沙盒 Documents/sample.csv
///   FP_TAB=0|1|2                   初始选中标签（地图/统计/设置）
///   FP_THEME=crimson|arctic|...    初始主题
///   FP_MONTH=8                     地图时间轴初始月份（0 起）
///   FP_DOT=1                       地图初始为点模式
///   FP_SKIP_LOCATION=1             自动截图时跳过系统定位权限弹窗
///   FP_HOLD_LOGO=1                 自动截图时将 Logo 过渡保持 3 秒
///   FP_LANGUAGE=zh-Hans|zh-Hant|en|fr  初始应用语言
///   FP_SEED_CUSTOM_MAP=1           注入并选中测试瓦片源（验证冷启动恢复）
///   FP_PERF_VISUAL_SEED=1          注入确定性轨迹，供性能修复前后地图视觉回归
///   FP_MAP=standard|satellite|topographic  初始地图源
///   FP_PITCH=0...70                初始地图俯角
///   FP_PHOTO_TOGGLE=1              快速关闭/开启照片图层回归测试
///   FP_ROUTE_TOGGLE=1              快速隐藏/显示路线崩溃回归测试
///   FP_HEADING_FOLLOW=1            开启位置+指南针朝向跟随回归测试
///   FP_REVIEW_TEST=1               照片探索页直达结束页视觉回归测试
enum TestHooks {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var seedSample: Bool { env["FP_SEED"] == "1" }
    static var seedPhotos: Bool { env["FP_SEED_PHOTOS"] == "1" }
    static var autoScan: Bool { env["FP_AUTO_SCAN"] == "1" }
    static var importCSV: Bool { env["FP_CSV"] == "1" }
    static var startTab: Int? { env["FP_TAB"].flatMap(Int.init) }
    static var startTheme: String? { env["FP_THEME"] }
    static var startMonth: Int? { env["FP_MONTH"].flatMap(Int.init) }
    static var dotMode: Bool { env["FP_DOT"] == "1" }
    static var doubleTap: Bool { env["FP_DOUBLE_TAP"] == "1" }
    static var fakePan: Bool { env["FP_FAKE_PAN"] == "1" }
    static var autoRecenter: Bool { env["FP_AUTO_RECENTER"] == "1" }
    static var autoExplore: Bool { env["FP_AUTO_EXPLORE"] == "1" }
    static var photoLayoutMode: String? { env["FP_PHOTO_LAYOUT_TEST"] }
    static var reviewTest: Bool { env["FP_REVIEW_TEST"] == "1" }
    static var autoReviewGroup: Bool { env["FP_AUTO_REVIEW_GROUP"] == "1" }
    static var autoOrientationSwipe: Bool { env["FP_AUTO_ORIENTATION_SWIPE"] == "1" }
    static var reviewDeletionCount: Int? { env["FP_REVIEW_DELETE_COUNT"].flatMap(Int.init) }
    static var photosHidden: Bool { env["FP_PHOTOS"] == "0" }
    static var photoToggle: Bool { env["FP_PHOTO_TOGGLE"] == "1" }
    static var routeToggle: Bool { env["FP_ROUTE_TOGGLE"] == "1" }
    static var headingFollow: Bool { env["FP_HEADING_FOLLOW"] == "1" }
    static var markerTap: Bool { env["FP_MARKER_TAP"] == "1" }
    static var startMapType: String? { env["FP_MAP"] }
    static var startPitch: Double? { env["FP_PITCH"].flatMap(Double.init) }
    static var seedCustomMap: Bool { env["FP_SEED_CUSTOM_MAP"] == "1" }
    static var tabCycle: Bool { env["FP_TAB_CYCLE"] == "1" }
    static var performanceAutoCycle: Bool { env["FP_PERF_AUTO_CYCLE"] == "1" }
    static var performanceVisualSeed: Bool { env["FP_PERF_VISUAL_SEED"] == "1" }

    /// 性能专项的确定性地图夹具。坐标、顺序和来源固定，确保优化前后的截图可逐像素比较。
    /// 仅 DEBUG 环境变量可触发，不进入正式业务路径。
    @MainActor
    static func seedPerformanceVisualData(into context: ModelContext) {
        let origin = (lat: 31.2304, lon: 121.4737)
        let started = Date(timeIntervalSince1970: 1_753_948_800) // 2025-08-01 UTC
        var drafts: [FootprintDraft] = []

        for route in 0..<4 {
            for point in 0..<48 {
                let phase = Double(point) / 47
                let lat = origin.lat + Double(route - 1) * 0.006
                    + phase * 0.018
                    + sin(phase * .pi * 2) * (0.0015 + Double(route) * 0.0003)
                let lon = origin.lon - 0.018
                    + phase * 0.036
                    + cos(phase * .pi * 2 + Double(route)) * 0.0018
                let timestamp = started
                    .addingTimeInterval(Double(route) * 86_400 + Double(point) * 60)
                drafts.append(FootprintDraft(latitude: lat, longitude: lon,
                                             timestamp: timestamp,
                                             source: FootprintSource.gps.rawValue))
            }
        }
        _ = FootprintStore.importDrafts(drafts, into: context)

        let workoutID = "performance-visual-workout"
        let workoutStart = started.addingTimeInterval(8 * 86_400)
        context.insert(WorkoutRecord(
            healthKitUUID: workoutID, workoutType: "walking",
            startDate: workoutStart, endDate: workoutStart.addingTimeInterval(3_000),
            duration: 3_000, distanceMeters: 4_800, caloriesKCal: 280,
            elevationGain: 35, routeAvailable: true, routeSyncState: .available))
        let routeID = "performance-visual-route"
        context.insert(WorkoutRouteRecord(routeID: routeID, workoutID: workoutID,
                                          sourceIdentifier: "performance-visual"))
        for point in 0..<52 {
            let phase = Double(point) / 51
            context.insert(WorkoutRoutePoint(
                workoutID: workoutID,
                latitude: origin.lat - 0.012 + phase * 0.025 + sin(phase * .pi) * 0.003,
                longitude: origin.lon - 0.02 + phase * 0.04,
                altitude: 12 + sin(phase * .pi * 4) * 8,
                timestamp: workoutStart.addingTimeInterval(Double(point) * 55),
                routeID: routeID, segmentIndex: 0, pointIndex: point,
                horizontalAccuracy: 5, sourceIdentifier: "performance-visual"))
        }
        try? context.save()
        appLog.info("[Seed] 注入性能视觉回归轨迹 \(drafts.count + 52) 点")
    }

    /// 启动时注入一组模拟足迹：覆盖 2025-01 ~ 2026-08 的 8 条路线，
    /// 常走路线更密（多次往返），与原型一致
    @MainActor
    static func seedSampleData(into context: ModelContext) {
        let routes: [(freq: Int, month: Int, coords: [(Double, Double)])] = [
            (4, 1, [(31.2215, 121.4455), (31.2230, 121.4510), (31.2250, 121.4580), (31.2275, 121.4660), (31.2304, 121.4737)]),
            (4, 1, [(31.2304, 121.4737), (31.2268, 121.4660), (31.2242, 121.4580), (31.2222, 121.4510), (31.2208, 121.4455)]),
            (3, 3, [(31.2304, 121.4737), (31.2335, 121.4770), (31.2360, 121.4810), (31.2385, 121.4850), (31.2405, 121.4895)]),
            (3, 3, [(31.2304, 121.4737), (31.2270, 121.4770), (31.2245, 121.4815), (31.2225, 121.4860), (31.2210, 121.4910)]),
            (2, 6, [(31.2304, 121.4737), (31.2330, 121.4790), (31.2355, 121.4840), (31.2380, 121.4895)]),
            (2, 8, [(31.2215, 121.4455), (31.2160, 121.4480), (31.2120, 121.4520), (31.2085, 121.4560)]),
            (1, 13, [(31.2085, 121.4560), (31.2040, 121.4620), (31.2005, 121.4690)]),
            (1, 16, [(31.2304, 121.4737), (31.2320, 121.4850), (31.2340, 121.4950), (31.2365, 121.5050), (31.2390, 121.5150)]),
            (1, 18, [(31.2380, 121.4895), (31.2340, 121.4950), (31.2280, 121.4990), (31.2220, 121.5020)]),
        ]

        var drafts: [FootprintDraft] = []
        var rng = SeededGenerator(seed: 20260816)
        for route in routes {
            // 每条路线按频次重复「往返」，点密集程度 = 频次
            for pass in 0..<route.freq {
                let forward = pass % 2 == 0
                let coords = forward ? route.coords : route.coords.reversed()
                let dayBase = 5 + pass * 4
                for (i, coord) in coords.enumerated() {
                    let monthDate = monthStart(route.month)
                    let date = Calendar.current.date(byAdding: .day, value: dayBase + i, to: monthDate)!
                        .addingTimeInterval(Double(9 + i * 2) * 3600)
                    let jitter = 0.0004 * rng.next() - 0.0002
                    drafts.append(FootprintDraft(
                        latitude: coord.0 + jitter,
                        longitude: coord.1 + jitter * 1.3,
                        timestamp: date,
                        source: FootprintSource.photo.rawValue))
                }
            }
        }
        _ = FootprintStore.importDrafts(drafts, into: context)
    }

    /// 注入模拟照片数据：覆盖 10 个城市（含哈尔滨 2 个区），生成占位缩略图。
    /// 区域名直接写入（regionState=1），缩略图为程序生成的渐变图（thumbState=1）。
    @MainActor
    static func seedPhotoData(into context: ModelContext) {
        let cities: [(province: String, city: String, district: String, lat: Double, lon: Double)] = [
            ("黑龙江省", "哈尔滨市", "南岗区", 45.755, 126.633),
            ("黑龙江省", "哈尔滨市", "道里区", 45.772, 126.612),
            ("辽宁省", "大连市", "中山区", 38.915, 121.638),
            ("云南省", "昆明市", "五华区", 25.043, 102.707),
            ("四川省", "成都市", "锦江区", 30.657, 104.080),
            ("陕西省", "西安市", "碑林区", 34.258, 108.946),
            ("山东省", "青岛市", "市南区", 36.066, 120.382),
            ("浙江省", "杭州市", "西湖区", 30.274, 120.155),
            ("上海市", "上海市", "黄浦区", 31.2304, 121.4737),
            ("广东省", "深圳市", "福田区", 22.541, 114.058),
        ]
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var rng = SeededGenerator(seed: 99)
        var count = 0
        for (ci, city) in cities.enumerated() {
            let photoCount = 3 + ci % 3   // 3~5 张
            for pi in 0..<photoCount {
                let id = "seed-\(count)"
                let lat = city.lat + (rng.next() - 0.5) * 0.02
                let lon = city.lon + (rng.next() - 0.5) * 0.02
                let date = Calendar.current.date(byAdding: .day, value: -(count * 23 + pi * 7), to: Date()) ?? Date()
                let thumbURL = dir.appendingPathComponent("\(id).jpg")
                makePlaceholderThumbnail(at: thumbURL, index: count)
                let record = PhotoRecord(localIdentifier: id, latitude: lat, longitude: lon,
                                         timestamp: date, altitude: Double(30 + (count * 13) % 240),
                                         thumbnailPath: thumbURL.path)
                record.countryName = "中国"
                record.provinceName = city.province
                record.cityName = city.city
                record.districtName = city.district
                record.regionState = 1
                record.thumbState = 1
                context.insert(record)
                count += 1
            }
        }
        try? context.save()
        appLog.info("[Seed] 注入模拟照片 \(count) 张（10 城市）")
    }

    /// 生成渐变占位缩略图
    private static func makePlaceholderThumbnail(at url: URL, index: Int) {
        // 交替生成横屏、竖屏与方形图，专门覆盖照片页布局回归。
        let size: CGSize
        switch index % 3 {
        case 0: size = CGSize(width: 420, height: 236)
        case 1: size = CGSize(width: 236, height: 420)
        default: size = CGSize(width: 300, height: 300)
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let hue = CGFloat((index * 37) % 360) / 360
        let image = renderer.image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.4, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 76, y: 76, width: 48, height: 48))
        }
        if let data = image.jpegData(compressionQuality: 0.75) {
            try? data.write(to: url)
        }
    }

    /// 从 App 沙盒 Documents/sample.csv 导入（配合 FP_CSV=1）
    @MainActor
    static func importSampleCSV(into context: ModelContext) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample.csv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = CSVParser.parse(text)
        let mapping = ColumnMapping(latIndex: 0, lonIndex: 1, timeIndex: 2, nameIndex: 3)
        let mapped = parsed.mapPoints(mapping)
        _ = FootprintStore.importDrafts(mapped.points, into: context)
    }

    private static func monthStart(_ month: Int) -> Date {
        // month: 1 = 2025-01, 20 = 2026-08
        let year = 2025 + (month - 1) / 12
        let m = (month - 1) % 12 + 1
        return Calendar.current.date(from: DateComponents(year: year, month: m, day: 1)) ?? Date()
    }
}

/// 确定性伪随机数生成器（保证每次测试数据一致）
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 10000) / 10000
    }
}
#endif
