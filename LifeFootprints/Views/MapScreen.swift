import SwiftUI
import MapKit
import SwiftData
import UIKit

/// 一条足迹折线（按频次着色）
struct RouteLine: Identifiable {
    let id = UUID()
    let coords: [CLLocationCoordinate2D]
    let freq: Int
    let isWorkout: Bool
}

/// 点模式下的足迹点（带频次：密度=去得多频繁）
struct FootprintDot: Identifiable {
    let id: Int
    let lat: Double
    let lon: Double
    let freq: Int
}

/// 地图照片标记快照（含已解码缩略图；后台构建）— 已由分级聚合 PhotoCluster 取代

/// 快照全局缓存：MapScreen 重建（切标签页）后立即显示上次数据，后台刷新无感
enum SnapshotCache {
    static var pointSnapshots: [FootprintSnapshot] = []
    static var clusterIndex: ClusterIndex?
    static var monthStarts: [Date] = []
    static var stats: FootprintStats = FootprintStats()
    static var dataRegion: MKCoordinateRegion?
}

/// 足迹地图：深色底图 + 频次高亮足迹 + 照片标记 + 时间轴 + 实时定位。
/// 数据全部后台快照化：首帧零重活，万级数据不卡看门狗。
struct MapScreen: View {
    @Environment(\.locale) private var locale
    // 不声明 @Query：13 万条主线程 fetch 会拖慢启动与重建；数据变化由 .dataImported 通知驱动
    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @Environment(\.modelContext) private var context

    // MARK: - 状态

    @State private var monthIndex: Double = 0
    @State private var minMonthIndex: Double = 0
    @State private var maxMonthIndex: Double = 0
    /// 点模式默认开启（一生足迹逻辑：点密度=频次）；线与点可同时显示
    @State private var showDots = true
    @State private var showLines = true
    @State private var showWorkouts = true
    @State private var showPhotos = true
    @State private var timeScope: MapTimeScope = .all
    /// 原生地图相机指令（单向：SwiftUI 发指令，MKMapView 执行）
    @State private var cameraCommand: MapCameraCommand = .none
    @State private var followsUser = true
    @State private var tapToast: String?
    /// 底部照片架（点击照片标记弹出，Apple Maps 地点卡风格）
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    /// 数据版本号：快照重载完成 +1，驱动原生图层重建
    @State private var reloadVersion = 0
    /// 启动时是否已定位到数据全貌（防止快照加载期间用户操作被覆盖）
    @State private var hasPositioned = false
    /// 足迹百分位包围盒（后台计算，供启动视野）
    @State private var dataRegion: MKCoordinateRegion?
    /// 聚合级别切换时的跨度（级别边界迟滞）
    /// 上次聚合计算的中心（平移超过视野 60% 触发补齐）
    @State private var lastClusterCenter: CLLocationCoordinate2D?
    /// 纯净模式（由 MainTabView 持有；双击「地图」tab 切换，单击地图恢复）
    @Binding var chromeHidden: Bool
    @Bindable var navigation: AppNavigationCoordinator
    @AppStorage("mapType") private var mapTypeRaw = "standard"
    @State private var customMapSources: [CustomMapSource] = []
    @State private var cameraPitch: Double = 0
    @State private var headingFollowEnabled = false
    @State private var highlightedReviewPhoto: CLLocationCoordinate2D?
    @State private var globeMode = false
    @State private var locationDetailsVisible = false
    @State private var locationDetailsTask: Task<Void, Never>?
    @State private var layerMenuVisible = false
    #if DEBUG
    /// P0 验证：统计 body 求值频率（5 秒窗口写入 map_debug.txt）。
    /// 必须是 @State：普通 let 会随 struct 重建而重置，永远等不到 5 秒窗口。
    @State private var bodyDiag = MapBodyDiag()
    #endif

    // 后台快照（UI 只消费值类型）
    @State private var pointSnapshots: [FootprintSnapshot] = []
    @State private var clusterIndex: ClusterIndex?
    @State private var clusterMarkers: [PhotoCluster] = []
    @State private var clusterLevel: PhotoCluster.Level = .province
    /// 聚合标记版本：镜头级别/区域变化 → +1 驱动原生标注重建
    @State private var markerToken = 0
    @State private var monthStarts: [Date] = []
    @State private var statsCache = FootprintStats()
    @State private var ready = false
    @State private var isLoading = false
    @State private var reloadTask: Task<Void, Never>?

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    private var activeCustomSource: CustomMapSource? {
        guard mapTypeRaw.hasPrefix("custom:"),
              let id = UUID(uuidString: String(mapTypeRaw.dropFirst("custom:".count))) else { return nil }
        return customMapSources.first(where: { $0.id == id })
    }

    // MARK: - 时间轴（基于缓存月份）

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy 年 M 月"
        return f
    }()

    private var months: [Date] { monthStarts }

    private var monthLabel: String {
        guard !months.isEmpty else { return "暂无数据" }
        let idx = min(Int(monthIndex.rounded()), months.count - 1)
        return Self.monthFormatter.string(from: months[idx])
    }

    private var cutoffDate: Date? {
        guard !months.isEmpty else { return nil }
        let idx = min(Int(monthIndex.rounded()), months.count - 1)
        return Calendar.current.date(byAdding: .month, value: 1, to: months[idx])
    }

    /// 时间轴过滤 + 万级数据降采样（>2500 按步长抽样，保持时间序）与线/点图层
    /// 全部由后台任务重算后缓存（P0：body 求值零重活，见 DerivedLayers）。
    // MARK: - 派生图层缓存（P0-2）

    private struct DerivedKey: Equatable {
        var reloadVersion: Int
        var monthIndex: Int        // 取整后的月份（滑块连续微调不触发重算）
        var monthCount: Int
        var scope: MapTimeScope
        var snapshotCount: Int
        var showLines: Bool
        var showWorkouts: Bool
    }

    private struct DerivedLayers {
        var visible: [FootprintSnapshot] = []
        var routes: [RouteLine] = []
        var workoutRoutes: [RouteLine] = []
        var dots: [FootprintDot] = []
    }

    @State private var derivedLayers = DerivedLayers()
    /// 派生图层版本：重算落地后 +1，驱动原生图层重建（contentToken 的组成部分）
    @State private var derivedVersion = 0
    @State private var derivedKey = DerivedKey(reloadVersion: -1, monthIndex: -1,
                                               monthCount: -1, scope: .all, snapshotCount: -1,
                                               showLines: true, showWorkouts: true)
    @State private var derivedGeneration = 0

    private var currentDerivedKey: DerivedKey {
        DerivedKey(reloadVersion: reloadVersion,
                   monthIndex: Int(monthIndex.rounded()),
                   monthCount: monthStarts.count,
                   scope: timeScope,
                   snapshotCount: pointSnapshots.count,
                   showLines: showLines, showWorkouts: showWorkouts)
    }

    /// 后台重算全部派生图层；期间旧图层继续显示（交互零等待）。
    private func scheduleDerivedRebuild(_ key: DerivedKey) {
        guard key != derivedKey else { return }
        derivedKey = key
        derivedGeneration += 1
        let generation = derivedGeneration
        let snapshots = pointSnapshots
        let cutoff = cutoffDate
        let scope = timeScope
        let showLines = key.showLines
        let showWorkouts = key.showWorkouts
        #if DEBUG
        let startedAt = CACurrentMediaTime()
        #endif
        Task.detached(priority: .userInitiated) {
            let layers = Self.computeDerivedLayers(
                snapshots: snapshots, cutoff: cutoff, scope: scope,
                showLines: showLines, showWorkouts: showWorkouts)
            #if DEBUG
            let ms = (CACurrentMediaTime() - startedAt) * 1000
            #endif
            await MainActor.run {
                guard self.derivedGeneration == generation else { return }
                self.derivedLayers = layers
                self.derivedVersion += 1
                #if DEBUG
                MapDebugLog.log("derived 重算: \(String(format: "%.1f", ms))ms 可见\(layers.visible.count) 线\(layers.routes.count) 运动线\(layers.workoutRoutes.count) 点\(layers.dots.count)")
                #endif
            }
        }
    }

    /// 纯函数：输入快照 + 时间窗口 → 全部图层（任意线程执行，不触碰任何状态）
    nonisolated private static func computeDerivedLayers(snapshots: [FootprintSnapshot],
                                                         cutoff: Date?, scope: MapTimeScope,
                                                         showLines: Bool,
                                                         showWorkouts: Bool) -> DerivedLayers {
        var layers = DerivedLayers()
        guard let cutoff else { return layers }
        let filtered = snapshots.filter { $0.t < cutoff && scope.contains($0.t) }
        let cap = 2500
        let visible: [FootprintSnapshot]
        if filtered.count > cap {
            let stride = filtered.count / cap
            visible = filtered.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        } else {
            visible = filtered
        }
        layers.visible = visible

        // 只有真实采样源可进入折线。历史 photo/csv/manual 点即使仍在数据库，
        // 也不能连接成 Personal Trajectory。
        layers.routes = makeRoutes(
            from: MapLayerSemantics.autoTrajectory(
                filtered, workoutSourceVisible: showWorkouts).sorted { $0.t < $1.t },
            workout: false)
        layers.workoutRoutes = makeRoutes(
            from: MapLayerSemantics.workoutTrajectory(
                filtered, autoSourceVisible: showLines).sorted { $0.t < $1.t },
            workout: true)

        let dotSnapshots = MapLayerSemantics.footprintDots(
            visible, workoutSourceVisible: showWorkouts)
        let buckets = freqBuckets(of: dotSnapshots)
        // 流畅优先：≤600 点采样（保持密度观感）
        let step = max(1, dotSnapshots.count / 600)
        var dots: [FootprintDot] = []
        for (index, s) in dotSnapshots.enumerated() where index % step == 0 {
            dots.append(FootprintDot(id: index, lat: s.lat, lon: s.lon, freq: freq(of: s, buckets: buckets)))
        }
        layers.dots = dots
        return layers
    }

    /// 频次表（每次构建一次，调用方持有）
    nonisolated private static func freqBuckets(of snaps: [FootprintSnapshot]) -> [Int: Int] {
        var dict: [Int: Int] = [:]
        for s in snaps {
            let key = (Int((s.lat / 0.002).rounded()) << 16) ^ Int((s.lon / 0.002).rounded())
            dict[key, default: 0] += 1
        }
        return dict
    }

    nonisolated private static func freq(of s: FootprintSnapshot, buckets: [Int: Int]) -> Int {
        let key = (Int((s.lat / 0.002).rounded()) << 16) ^ Int((s.lon / 0.002).rounded())
        switch buckets[key] ?? 1 {
        case 1: return 1
        case 2...5: return 2
        case 6...20: return 3
        default: return 4
        }
    }

    nonisolated private static func makeRoutes(from vis: [FootprintSnapshot], workout: Bool) -> [RouteLine] {
        let buckets = freqBuckets(of: vis)
        var lines: [RouteLine] = []
        var current: [(coords: CLLocationCoordinate2D, freq: Int)] = []
        var prev: FootprintSnapshot?

        func flush() {
            // ≥3 点才成线：过滤孤立抖动点
            guard current.count >= 3 else {
                current = []
                return
            }
            let avg = current.map { $0.freq }.reduce(0, +) / current.count
            lines.append(RouteLine(coords: current.map { $0.coords }, freq: avg, isWorkout: workout))
            current = []
        }

        for s in vis {
            if let p = prev {
                let gap = s.t.timeIntervalSince(p.t)
                let dist = GeoMath.distanceMeters(from: (p.lat, p.lon), to: (s.lat, s.lon))
                // 真实轨迹判据：45 分钟内移动 ≤3km（步行/骑行/驾车的连续记录）
                // 超界即断线——不同城市/时段的点绝不相连（消除杂乱蜘蛛网）
                let crossedDomainBoundary = MapLayerSemantics.crossesTrajectoryBoundary(p, s)
                if crossedDomainBoundary || gap > 45 * 60 || dist > 3000 {
                    flush()
                }
            }
            current.append((CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                            freq(of: s, buckets: buckets)))
            prev = s
        }
        flush()
        return lines
    }

    // body 只读缓存，零重算
    private var dots: [FootprintDot] { derivedLayers.dots }
    private var routes: [RouteLine] { derivedLayers.routes }
    private var workoutRoutes: [RouteLine] { derivedLayers.workoutRoutes }

    /// 点视图：频次越高点越大越亮，高频带光晕（一生足迹的核心观感）
    /// （原生 MKMapView 中由 DotOverlayRenderer 等价绘制）

    private var autoRegion: MKCoordinateRegion {
        if let region = dataRegion { return region }
        // 启动缓存：上次数据视野（快照就绪前也能立即定位到数据区，无两次跳转）
        let ud = UserDefaults.standard
        if let lat = ud.object(forKey: "lastRegionLat") as? Double,
           let lon = ud.object(forKey: "lastRegionLon") as? Double,
           let span = ud.object(forKey: "lastRegionSpan") as? Double, span > 0 {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                      span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
    }

    /// 百分位包围盒（剔除 ±1% 离群坐标，防止坏点撑爆视野；后台线程调用）
    nonisolated static func boundsRegion(_ snaps: [FootprintSnapshot]) -> MKCoordinateRegion? {
        guard !snaps.isEmpty else { return nil }
        let lats = snaps.map { $0.lat }.sorted()
        let lons = snaps.map { $0.lon }.sorted()
        let lo = min(Int(Double(snaps.count) * 0.01), snaps.count / 2)
        let hi = max(snaps.count - 1 - lo, lo + 1)
        guard hi > lo else { return nil }
        let minLat = lats[lo], maxLat = lats[hi]
        let minLon = lons[lo], maxLon = lons[hi]
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLat - minLat, 0.02) * 1.4,
                longitudeDelta: max(maxLon - minLon, 0.02) * 1.4))
    }

    // MARK: - 样式

    private func lineOpacity(_ freq: Int) -> Double {
        switch freq {
        case 4: return 0.95
        case 3: return 0.8
        case 2: return 0.6
        default: return 0.35
        }
    }

    private func lineWidth(_ freq: Int) -> CGFloat {
        switch freq {
        case 4: return 3.2
        case 3: return 2.6
        case 2: return 2.2
        default: return 1.6
        }
    }

    // MARK: - Body

    var body: some View {
        #if DEBUG
        let _ = bodyDiag.tick()
        #endif
        ZStack(alignment: .top) {
            // 原生 MKMapView 包装：点/线覆盖层 + 照片标注视图全部走 Apple 自家 UIKit 渲染，
            // 真机 iOS 26 稳定显示，拖动/缩放零 SwiftUI 重建开销。
            // ignoresSafeArea：边缘到边缘全屏（UIViewRepresentable 不像 SwiftUI Map 会自动全屏）
            FootprintMapView(
                dots: dots,
                routes: routes,
                workoutRoutes: workoutRoutes,
                markers: clusterMarkers,
                highlightedPhoto: highlightedReviewPhoto,
                // Current Location 只由 MapKit 蓝点表达，不能自动形成实时历史线。
                track: [],
                showPhotos: showPhotos,
                showDots: showDots,
                showLines: showLines,
                showWorkouts: showWorkouts,
                themeColor: UIColor(theme.color),
                contentToken: contentToken,
                markerToken: markerToken,
                mapType: mapTypeRaw,
                globeMode: false,
                customSource: activeCustomSource,
                camera: cameraCommand,
                onCameraMoved: handleCameraMoved,
                onRegionChanged: handleRegionChanged,
                onTap: handleMapTap,
                onMarkerTap: handleMarkerTap,
                onDoubleTap: toggleChrome)
            .ignoresSafeArea(edges: .all)
            .onAppear {
                // 仅首次出现时定位到数据全貌（防止每次切回标签页都跳镜头）
                if !hasPositioned {
                    cameraCommand = .region(autoRegion, animated: false)
                }
                #if DEBUG
                MapDebugLog.log("onAppear: location=\(String(describing: LocationService.shared.location?.coordinate.latitude)) 快照=\(pointSnapshots.count) 标记=\(clusterMarkers.count)")
                #endif
            }
            .task { LocationService.shared.start() }
            .onReceive(NotificationCenter.default.publisher(for: .photoRegionsUpdated)) { _ in
                // 逆地理有进展 → 重载快照，照片标记渐进出现
                scheduleReload()
            }

            // 定位详情只在用户主动点击定位后短暂出现，不长期占据地图。
            if !chromeHidden, locationDetailsVisible, let loc = LocationService.shared.location {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前位置").fontWeight(.semibold)
                    Text(String(format: "精度 ±%dm", Int(loc.horizontalAccuracy)))
                    Text(loc.timestamp.formatted(date: .omitted, time: .standard))
                }
                .multilineTextAlignment(.leading)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
                .padding(.top, 58)
                .transition(.opacity)
            }

            // 顶栏（纯净模式隐藏）
            if !chromeHidden {
            HStack(alignment: .center, spacing: 12) {
                if navigation.suspendedReviewContext != nil {
                    Button(action: navigation.returnToReview) {
                        Label("回到回顾", systemImage: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 11)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
                timeScopeMenu
                Spacer(minLength: 16)
                layerButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            }

            if !chromeHidden, layerMenuVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { layerMenuVisible = false } }
                    .zIndex(40)
                mapLayerMenu
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 16)
                    .padding(.top, 62)
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(41)
            }

            // 「暂无照片」轻提示（纯净模式隐藏）
            if !chromeHidden, let toast = tapToast {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 210)
            }

            // 定位按钮：单击回到当前位置；双击进入「位置 + 指南针朝向」跟随。
            if !chromeHidden {
                Image(systemName: headingFollowEnabled ? "location.north.line.fill" :
                      (followsUser ? "location.fill" : "location"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(headingFollowEnabled || !followsUser ? theme.color : .primary)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(
                        headingFollowEnabled ? theme.color.opacity(0.75) : .white.opacity(0.18),
                        lineWidth: headingFollowEnabled ? 1.5 : 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .contentShape(Circle())
                    .gesture(
                        TapGesture(count: 2)
                            .exclusively(before: TapGesture(count: 1))
                            .onEnded { gesture in
                                switch gesture {
                                case .first: followCurrentHeading()
                                case .second: recenter()
                                }
                            }
                    )
                    .accessibilityLabel(headingFollowEnabled ? "正在按朝向跟随" : "回到当前位置")
                    .accessibilityHint("单击定位，双击按朝向跟随")
                    .accessibilityAddTraits(.isButton)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 14)
                .padding(.bottom, 104)
            }

            // 自定义瓦片源必须保留版权署名；使用轻量标签代替原底部大面板。
            if !chromeHidden, let attribution = activeMapAttribution {
                Text(attribution)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
            }
        }
        // 加载遮罩：首帧零重活，万级数据后台快照化
        .overlay {
            if !ready {
                BrandLoadingView(accent: theme.color)
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: currentDerivedKey) { _, key in
            scheduleDerivedRebuild(key)
        }
        .fullScreenCover(item: $navigation.locationReviewSession, onDismiss: restoreMapAfterLocationReview) { exploreSession in
            PhotoExploreView(session: exploreSession, theme: theme,
                             onFinishLocationReview: { navigation.finishLocationReview() })
        }
        .onChange(of: navigation.locationReviewSession?.phase) { _, phase in
            if case .transitioning(let next) = phase, let session = navigation.locationReviewSession {
                let targetLevel = session.level
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if let centroid = PhotoStore.centroid(level: targetLevel, regionName: next, in: context) {
                        appLog.info("[Camera] 自动飞往「\(next)」 质心(\(String(format: "%.4f", centroid.latitude)),\(String(format: "%.4f", centroid.longitude))) 距离\(Int(distance(for: targetLevel)))m")
                        cameraCommand = .region(region(centeredAt: centroid, distance: distance(for: targetLevel)), animated: true)
                    }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    session.completePlaceTransition(to: next)
                }
            }
        }

        .onAppear {
            let loadedSources = MapSourceStore.load()
            customMapSources = loadedSources
            // 内置专业等高线已下架；旧版本若停留在该图层，平滑回退标准地图。
            if mapTypeRaw == "topographic" {
                mapTypeRaw = "standard"
            } else if let selectedID = selectedCustomMapID,
                      !loadedSources.contains(where: { $0.id == selectedID }) {
                mapTypeRaw = "standard"
            }
            if !ready {
                // 重建（切标签页）时先用全局缓存秒显，再后台刷新
                if !SnapshotCache.pointSnapshots.isEmpty {
                    pointSnapshots = SnapshotCache.pointSnapshots
                    clusterIndex = SnapshotCache.clusterIndex
                    monthStarts = SnapshotCache.monthStarts
                    statsCache = SnapshotCache.stats
                    dataRegion = SnapshotCache.dataRegion
                    ready = true
                    let count = Double(max(0, SnapshotCache.monthStarts.count - 1))
                    minMonthIndex = 0
                    maxMonthIndex = count
                    monthIndex = count
                    if let index = clusterIndex, let region = SnapshotCache.dataRegion {
                        let level = PhotoCluster.Level.level(for: region.span.latitudeDelta)
                        let result = ClusterIndex.adaptiveVisible(index, preferred: level, region: region)
                        clusterLevel = result.level
                        clusterMarkers = result.clusters
                        markerToken += 1
                    }
                }
                loadSnapshots()
            }
            applyNavigationHighlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataImported)) { _ in
            // 足迹/照片入库完成 → 重载快照（替代主线程 @Query 监听）
            TrajectoryResolutionCache.shared.invalidate()
            scheduleReload()
        }
        .onChange(of: navigation.mapPhotoHighlight) { _, _ in applyNavigationHighlight() }
        .onReceive(NotificationCenter.default.publisher(for: .mapSourcesChanged)) { _ in
            // 必须用本次同步读取的结果判断，不能依赖尚未提交的 @State。
            let loadedSources = MapSourceStore.load()
            customMapSources = loadedSources
            if let selectedID = selectedCustomMapID,
               !loadedSources.contains(where: { $0.id == selectedID }) {
                mapTypeRaw = "standard"
            }
        }
    }

    // MARK: - 地图图层

    private var layerButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { layerMenuVisible.toggle() }
        } label: {
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mapTypeRaw == "standard" && showPhotos && (showDots || showLines) && showWorkouts ? .primary : theme.color)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private var mapLayerMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("地图样式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            layerRow("标准", selected: mapTypeRaw == "standard") { mapTypeRaw = "standard" }
            layerRow("卫星", selected: mapTypeRaw == "satellite") { mapTypeRaw = "satellite" }
            layerRow("户外", selected: mapTypeRaw == "topographic") { mapTypeRaw = "topographic" }
            ForEach(customMapSources) { source in
                layerRow(source.name, selected: mapTypeRaw == "custom:\(source.id.uuidString)") {
                    mapTypeRaw = "custom:\(source.id.uuidString)"
                }
            }
            Divider().overlay(.white.opacity(0.10))
            Text("显示内容").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            layerRow("足迹", selected: showDots || showLines) {
                let next = !(showDots || showLines); showDots = next; showLines = next
            }
            layerRow("运动", selected: showWorkouts) { showWorkouts.toggle() }
            layerRow("照片", selected: showPhotos) { togglePhotos() }
        }
        .padding(14)
        .frame(width: 210)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func layerRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Image(systemName: selected ? "checkmark" : "circle") }
                .font(.system(size: 13, weight: .medium))
                .contentShape(Rectangle())
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var visibilityButtons: some View {
        Button {
            let next = !(showDots || showLines)
            showDots = next
            showLines = next
        } label: {
            Label("足迹", systemImage: showDots || showLines ? "checkmark" : "circle")
        }
        Button { showWorkouts.toggle() } label: {
            Label("运动", systemImage: showWorkouts ? "checkmark" : "circle")
        }
        Button(action: togglePhotos) {
            Label("照片", systemImage: showPhotos ? "checkmark" : "circle")
        }
    }

    private var timeScopeMenu: some View {
        Menu {
            ForEach(MapTimeScope.choices(currentYear: Calendar.current.component(.year, from: Date())), id: \.self) { scope in
                Button {
                    timeScope = scope
                    scheduleReload()
                } label: {
                    Label(timeScopeTitle(scope), systemImage: timeScope == scope ? "checkmark" : "calendar")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(timeScopeTitle(timeScope))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(timeScope == .all ? Color.primary : theme.color)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func timeScopeTitle(_ scope: MapTimeScope) -> String {
        switch scope {
        case .all: return "全部时间"
        case .year(let year): return String(year)
        }
    }

    @ViewBuilder
    private func mapTypeButton(_ type: String, title: String, icon: String) -> some View {
        Button {
            mapTypeRaw = type
            appLog.info("[Map] 地图类型 → \(title)")
        } label: {
            Label(title, systemImage: mapTypeRaw == type ? "checkmark" : icon)
        }
    }

    private var activeMapAttribution: String? {
        return activeCustomSource?.attribution
    }

    private var selectedCustomMapID: UUID? {
        guard mapTypeRaw.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(mapTypeRaw.dropFirst("custom:".count)))
    }

    private func togglePhotos() {
        showPhotos.toggle()
        appLog.info("[Marker] 照片标记\(showPhotos ? "已开启" : "已关闭")")
    }

    private func setGlobeMode(_ enabled: Bool) {
        guard globeMode != enabled else { return }
        globeMode = enabled
        followsUser = false
        headingFollowEnabled = false
        if enabled {
            setPitch(0, animated: false)
            cameraCommand = .region(
                MKCoordinateRegion(center: autoRegion.center,
                                   span: MKCoordinateSpan(latitudeDelta: 145, longitudeDelta: 300)),
                animated: true
            )
        } else {
            cameraCommand = .region(dataRegion ?? autoRegion, animated: true)
        }
        appLog.info("[Map] 地图模式 → \(enabled ? "地球" : "平面")")
    }

    // MARK: - 原生地图内容指纹 / 交互

    /// 任一输入变化 → MKMapView 重建图层与标注（markerToken 独立——级别切换只更新照片覆盖层）。
    /// P0-2：数据层只由 derivedVersion（重算落地版本）驱动，body 高频求值不再改变 token。
    private var contentToken: Int {
        var h = 1123
        h = h &* 31 &+ derivedVersion
        h = h &* 31 &+ themeRaw.hashValue
        return h
    }

    /// 镜头/缩放变化（节流 250ms）→ 仅在聚合级别切换时异步重算（交互优先、计算异步）。
    /// 平移/微缩不重算：标记由覆盖层按地理投影连续驱动（零重建）。
    private func handleRegionChanged(_ region: MKCoordinateRegion) {
        navigation.mapCameraSnapshot = MapCameraSnapshot(
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        guard let index = clusterIndex else { return }
        let requestedLevel = PhotoCluster.Level.stableLevel(for: region.span.latitudeDelta,
                                                            current: clusterLevel)
        let indexCopy = index

        // 缩放跨级或平移超过视野 35% 时刷新；小幅移动由画布投影连续跟随。
        var shouldRefresh = requestedLevel != clusterLevel
        if let last = lastClusterCenter {
            let moved = GeoMath.distanceMeters(from: (last.latitude, last.longitude),
                                               to: (region.center.latitude, region.center.longitude))
            let spanMeters = region.span.latitudeDelta * 111_000
            shouldRefresh = shouldRefresh || moved > spanMeters * 0.35
        }
        guard shouldRefresh || lastClusterCenter == nil else { return }
        lastClusterCenter = region.center
        Task.detached(priority: .userInitiated) {
            let result = ClusterIndex.adaptiveVisible(indexCopy, preferred: requestedLevel,
                                                      region: region)
            await MainActor.run {
                self.clusterLevel = result.level
                self.clusterMarkers = result.clusters
                self.markerToken += 1
                appLog.info("[Cluster] 级别=\(result.level) 可见集合 \(result.clusters.count) 个")
            }
        }
    }

    /// 用户手势拖动/缩放镜头 → 迟滞判断是否脱离跟随
    private func handleCameraMoved(_ center: CLLocationCoordinate2D) {
        if headingFollowEnabled {
            headingFollowEnabled = false
            followsUser = false
            appLog.info("[Camera] 用户拖动地图 → 退出朝向跟随")
            return
        }
        guard let loc = LocationService.shared.location else { return }
        let d = GeoMath.distanceMeters(from: (center.latitude, center.longitude),
                                       to: (loc.coordinate.latitude, loc.coordinate.longitude))
        // 迟滞切换（300m 开 / 150m 关）：减少状态翻转
        if d > 300, followsUser {
            followsUser = false
            appLog.info("[Camera] 用户拖动地图（偏离 GPS \(Int(d))m）→ 显示「回到当前位置」")
        } else if d < 150, !followsUser {
            followsUser = true
        }
    }

    /// 点击照片标记 → 直接进入照片查看器（单张直接看该张，多张按组左右浏览）。
    private func handleMarkerTap(_ cluster: PhotoCluster) {
        tapHaptic.impactOccurred()
        appLog.info("[Marker] 创建 Location Review → \(cluster.name)（×\(cluster.count)）")
        // 相机快照已由 handleRegionChanged 持续维护（含手势结束时的最终视野）。
        if cluster.isCountryLevel {
            openExplore(level: RegionLevel.country, region: cluster.name, clusterID: cluster.id,
                        startAt: Int.random(in: 0..<max(cluster.count, 1)))
        } else if (cluster.level == .district || cluster.level == .town
                   || cluster.level == .block || cluster.level == .spot || cluster.level == .single),
                  let ids = cluster.sampleIds, !ids.isEmpty {
            openExplore(ids: ids, clusterID: cluster.id, startAt: Int.random(in: 0..<ids.count))
        } else {
            let level = cluster.level == .province ? RegionLevel.province : RegionLevel.city
            openExplore(level: level, region: cluster.name, clusterID: cluster.id,
                        startAt: Int.random(in: 0..<max(cluster.count, 1)))
        }
    }

    // MARK: - 后台快照加载（核心：万级数据零主线程阻塞）

    private func loadSnapshots() {
        guard !isLoading else { return }
        isLoading = true
        let container = context.container
        let selectedScope = timeScope
        Task.detached(priority: .userInitiated) {
            let pointContext = ModelContext(container)
            pointContext.autosaveEnabled = false

            // 阶段 1：只读取足迹，先让地图可交互；照片聚合随后渐进出现。
            let ptRows = (try? pointContext.fetch(FetchDescriptor<FootprintPoint>(
                sortBy: [SortDescriptor(\.timestamp)]))) ?? []
            let snaps: [FootprintSnapshot] = ptRows
                .map {
                    let id = TrajectorySampleIdentity.footprint(
                        source: $0.sourceRaw, latitude: $0.latitude,
                        longitude: $0.longitude, timestamp: $0.timestamp)
                    return FootprintSnapshot(lat: $0.latitude, lon: $0.longitude,
                                             t: $0.timestamp, source: $0.sourceRaw,
                                             originalPointID: id)
                }
            let trajectoryResolution = try? TrajectoryRepository(container: container).loadResolved()
            let trajectorySnaps: [FootprintSnapshot]
            if let trajectoryResolution {
                trajectorySnaps = trajectoryResolution.points.map { resolved in
                    let source: String
                    switch resolved.source {
                    case .healthWorkout: source = FootprintSource.health.rawValue
                    case .coreLocation: source = FootprintSource.gps.rawValue
                    case .imported: source = FootprintSource.csv.rawValue
                    case .inferred: source = FootprintSource.manual.rawValue
                    }
                    return FootprintSnapshot(
                        lat: resolved.point.latitude, lon: resolved.point.longitude,
                        t: resolved.point.timestamp, source: source,
                        trajectoryID: resolved.trajectoryID, sessionID: resolved.sessionID,
                        segmentID: resolved.segmentID,
                        isSuppressedDuplicate: resolved.suppressedByTrajectoryID != nil,
                        suppressedBySource: resolved.suppressedBySource?.rawValue,
                        originalPointID: resolved.point.id)
                }
            } else {
                let workoutRows = (try? pointContext.fetch(FetchDescriptor<WorkoutRoutePoint>(
                    sortBy: [SortDescriptor(\.timestamp)]))) ?? []
                let workoutSnaps = workoutRows.map {
                    FootprintSnapshot(lat: $0.latitude, lon: $0.longitude, t: $0.timestamp,
                                      source: FootprintSource.health.rawValue,
                                      trajectoryID: "health:\($0.workoutID)",
                                      sessionID: $0.workoutID,
                                      segmentID: "\($0.routeID ?? "legacy:\($0.workoutID)"):\($0.segmentIndex ?? 0)")
                }
                trajectorySnaps = snaps.filter { $0.source == FootprintSource.gps.rawValue }
                    + workoutSnaps
            }
            let resolvedOriginalIDs = Set(trajectorySnaps.compactMap(\.originalPointID))
            let displaySnaps = snaps.filter {
                guard let id = $0.originalPointID else { return true }
                return !resolvedOriginalIDs.contains(id)
            } + trajectorySnaps

            let cal = Calendar.current
            var seen = Set<Date>()
            var perYear: [Int: Int] = [:]
            for s in displaySnaps {
                if let st = cal.dateInterval(of: .month, for: s.t)?.start { seen.insert(st) }
            }
            for s in snaps {
                perYear[cal.component(.year, from: s.t), default: 0] += 1
            }
            let months = seen.sorted()

            let st = snapshotStats(snaps)
            let region = Self.boundsRegion(displaySnaps)
            var statsResult = FootprintStats()
            statsResult.pointCount = st.count
            statsResult.distanceKM = st.distanceKM
            statsResult.activeDays = st.activeDays
            statsResult.firstDate = st.first
            statsResult.lastDate = st.last
            statsResult.perYear = perYear.sorted { $0.key < $1.key }
                .map { (year: $0.key, count: $0.value) }
            let completedStats = statsResult

            let snapCount = snaps.count
            await MainActor.run {
                reloadVersion += 1
                SnapshotCache.pointSnapshots = displaySnaps.sorted { $0.t < $1.t }
                SnapshotCache.monthStarts = months
                SnapshotCache.stats = completedStats
                SnapshotCache.dataRegion = region
                pointSnapshots = displaySnaps.sorted { $0.t < $1.t }
                monthStarts = months
                statsCache = completedStats
                dataRegion = region
                if let r = region {
                    let defaults = UserDefaults.standard
                    defaults.set(r.center.latitude, forKey: "lastRegionLat")
                    defaults.set(r.center.longitude, forKey: "lastRegionLon")
                    defaults.set(r.span.latitudeDelta, forKey: "lastRegionSpan")
                }
                let count = Double(max(0, months.count - 1))
                minMonthIndex = 0
                maxMonthIndex = count
                monthIndex = count
                if !hasPositioned {
                    hasPositioned = true
                    cameraCommand = .region(region ?? autoRegion, animated: false)
                }
                withAnimation(.easeOut(duration: 0.3)) { ready = true }
                NotificationCenter.default.post(name: .mapSnapshotReady, object: nil)
                appLog.info("[Load] 首屏快照就绪：足迹\(snapCount)，照片聚合转入后台")
            }

            // 阶段 2：照片索引不再阻塞 Logo 消失和地图首屏。
            let photoContext = ModelContext(container)
            photoContext.autosaveEnabled = false
            let allPhotoRows = (try? photoContext.fetch(FetchDescriptor<PhotoRecord>())) ?? []
            let phRows = allPhotoRows.filter { selectedScope.contains($0.timestamp) }
            #if DEBUG
            let photoRowTotal = phRows.count
            let photoRegionTotal = phRows.filter { $0.regionState == 1 }.count
            #else
            let photoRowTotal = 0
            let photoRegionTotal = 0
            #endif
            // 冲突解析与地图线层共用同一结果；重复来源不会再次参与照片吸附。
            let trailPoints: [TrailPoint]
            if let trajectoryResolution {
                trailPoints = trajectoryResolution.visiblePoints.map { resolved in
                    TrailPoint(
                        lat: resolved.point.latitude, lon: resolved.point.longitude,
                        t: resolved.point.timestamp.timeIntervalSince1970,
                        source: resolved.source,
                        trajectoryID: resolved.trajectoryID,
                        sessionID: resolved.sessionID,
                        segmentID: resolved.segmentID,
                        horizontalAccuracy: resolved.point.horizontalAccuracy,
                        confidence: resolved.confidence,
                        originalPointID: resolved.point.id)
                }
            } else {
                trailPoints = displaySnaps.filter {
                    $0.source == FootprintSource.health.rawValue
                        || $0.source == FootprintSource.gps.rawValue
                        || ($0.source == FootprintSource.csv.rawValue && $0.trajectoryID != nil)
                }.map {
                    let source: TrajectorySource
                    if $0.source == FootprintSource.health.rawValue { source = .healthWorkout }
                    else if $0.source == FootprintSource.csv.rawValue { source = .imported }
                    else { source = .coreLocation }
                    return TrailPoint(lat: $0.lat, lon: $0.lon,
                                      t: $0.t.timeIntervalSince1970, source: source,
                                      trajectoryID: $0.trajectoryID, sessionID: $0.sessionID,
                                      segmentID: $0.segmentID)
                }
            }
            let trailIndex = TrailIndex(points: trailPoints)
            var snapExact = 0, snapSnap = 0, snapInterp = 0, snapKept = 0
            let clIndex = ClusterIndex.build(records: phRows, trails: trailIndex, onSnap: { r in
                switch r.kind {
                case .exact: snapExact += 1
                case .snapped: snapSnap += 1
                case .interpolated: snapInterp += 1
                case .kept: snapKept += 1
                }
            })
            let clProvince = clIndex.province.count
            let clCity = clIndex.city.count
            let clDistrict = clIndex.district.count
            let clTown = clIndex.town.count
            let clBlock = clIndex.block.count
            let clSpot = clIndex.spot.count
            let clSingle = clIndex.single.count
            let snapCounts = (exact: snapExact, snapped: snapSnap,
                              interpolated: snapInterp, kept: snapKept)

            appLog.info("[Load] 照片聚合就绪：省\(clProvince)/市\(clCity)/区\(clDistrict)/点\(clSpot)")

            await MainActor.run {
                // 照片聚合索引不改变派生图层（点/线由 phase 1 数据驱动），
                // 不再 bump reloadVersion，避免每次加载触发两轮无意义重算。
                SnapshotCache.clusterIndex = clIndex
                clusterIndex = clIndex
                let count = Double(max(0, months.count - 1))
                let level = PhotoCluster.Level.level(for: region?.span.latitudeDelta ?? 24)
                let initialClusters = ClusterIndex.adaptiveVisible(
                    clIndex, preferred: level, region: region ?? autoRegion)
                clusterLevel = initialClusters.level
                clusterMarkers = initialClusters.clusters
                markerToken += 1
                #if DEBUG
                MapDebugLog.log("快照就绪：足迹\(snapCount) 照片记录\(photoRowTotal)条(区域=\(photoRegionTotal)) 聚合省\(clProvince)/市\(clCity)/区\(clDistrict)/镇\(clTown)/街\(clBlock)/点\(clSpot)/单\(clSingle) 可见标记\(clusterMarkers.count)")
                MapDebugLog.log("轨迹吸附：精确\(snapCounts.exact) 吸附\(snapCounts.snapped) 插值\(snapCounts.interpolated) 保持\(snapCounts.kept)")
                if let r = region {
                    MapDebugLog.log("数据范围：中心(\(String(format: "%.2f", r.center.latitude)),\(String(format: "%.2f", r.center.longitude))) 跨度(\(String(format: "%.2f", r.span.latitudeDelta)))")
                }
                #endif
                isLoading = false
                applyTestHooks(markerCount: clusterMarkers.count, sliderMax: count)
            }
        }
    }

    /// 数据变化后防抖重载
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            loadSnapshots()
        }
    }

    // MARK: - 交互

    /// 纯净模式切换（双击进入/单击恢复由 handleMapTap 处理）
    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.25)) { chromeHidden.toggle() }
        appLog.info("[Chrome] 纯净模式=\(chromeHidden)")
    }

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        // 纯净模式下单击 → 恢复全部功能（不触发探索）
        if chromeHidden {
            withAnimation(.easeOut(duration: 0.25)) { chromeHidden = false }
            appLog.info("[Chrome] 单击恢复显示")
            return
        }
        // 普通地图点击不得打开 Review。Review 只由照片组的明确 tap 触发。
        appLog.debug("[Map] 普通点击不打开照片 Review: \(coord.latitude),\(coord.longitude)")
    }

    /// 地点级探索：直接按照片 id 集合浏览（网格内全部照片，随机起点）
    private func openExplore(ids: [String], clusterID: String = "map-selection", startAt: Int? = nil) {
        guard !ids.isEmpty else {
            showTapToast("该区域暂无照片")
            return
        }
        let newSession = ExploreSession(level: RegionLevel.district, regionName: "", context: context,
                                        source: .mapCluster(clusterID: clusterID))
        newSession.loadPhotos(ids: ids, startAt: startAt ?? Int.random(in: 0..<100_000))
        navigation.locationReviewSession = newSession
    }

    /// 打开照片探索。startAt 缺省时**随机起点**（用户要求：任何层级进入都随机显示照片）。
    private func openExplore(level: String, region name: String,
                             clusterID: String = "map-selection", startAt: Int? = nil) {
        guard !name.isEmpty else {
            showTapToast("该区域暂无照片")
            return
        }
        let newSession = ExploreSession(level: level, regionName: name, context: context,
                                        source: .mapCluster(clusterID: clusterID))
        newSession.loadPhotos(for: name, startAt: startAt ?? Int.random(in: 0..<100_000))
        navigation.locationReviewSession = newSession
        if let centroid = PhotoStore.centroid(level: level, regionName: name, in: context) {
            cameraCommand = .region(region(centeredAt: centroid, distance: distance(for: level)), animated: true)
        }
    }

    private func distance(for level: String) -> Double {
        switch level {
        case RegionLevel.district: return 8000
        case RegionLevel.city: return 50000
        case RegionLevel.province: return 380000
        default: return 2500000
        }
    }

    /// 点选集合时的镜头粒度：粗集合缩放到城市，精细集合保留附近语境。
    private func mapDistance(for level: PhotoCluster.Level) -> Double {
        switch level {
        case .province: return 420_000
        case .city: return 90_000
        case .district: return 24_000
        case .town: return 9_000
        case .block: return 4_000
        case .spot: return 1_400
        case .single: return 600
        }
    }

    private func applyNavigationHighlight() {
        guard let highlight = navigation.mapPhotoHighlight else {
            highlightedReviewPhoto = nil
            return
        }
        showPhotos = true
        let coordinate = CLLocationCoordinate2D(latitude: highlight.latitude,
                                                longitude: highlight.longitude)
        highlightedReviewPhoto = coordinate
        // 只把镜头中心移到该照片位置、保持当前缩放：地图上 A/B/C 全部保留，
        // 不再缩放到 1.2km 导致可视标记只剩一张。
        cameraCommand = .center(coordinate, animated: true)
    }

    private func restoreMapAfterLocationReview() {
        navigation.locationReviewSession = nil
        guard let snapshot = navigation.mapCameraSnapshot else { return }
        cameraCommand = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: snapshot.latitude, longitude: snapshot.longitude),
                span: MKCoordinateSpan(latitudeDelta: snapshot.latitudeDelta,
                                       longitudeDelta: snapshot.longitudeDelta)
            ),
            animated: true
        )
    }

    /// 相机距离 → 可视区域（跨度近似；用于原生地图相机指令）
    private func region(centeredAt coordinate: CLLocationCoordinate2D, distance: Double) -> MKCoordinateRegion {
        let delta = max(distance / 55_000, 0.001)
        return MKCoordinateRegion(center: coordinate,
                                  span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    private func showTapToast(_ text: String) {
        withAnimation { tapToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { tapToast = nil }
        }
    }

    private func recenter() {
        guard let coord = LocationService.shared.location?.coordinate else {
            showTapToast("正在获取当前位置")
            LocationService.shared.start()
            return
        }
        appLog.info("[Camera] 回到当前位置: \(String(format: "%.5f", coord.latitude)),\(String(format: "%.5f", coord.longitude))")
        headingFollowEnabled = false
        followsUser = true
        cameraCommand = .follow(coord, animated: true)
        revealLocationDetails()
    }

    private func followCurrentHeading() {
        guard LocationService.shared.location != nil else {
            showTapToast("正在获取当前位置")
            LocationService.shared.start()
            return
        }
        headingFollowEnabled = true
        followsUser = true
        cameraCommand = .userTracking(followHeading: true, animated: true)
        revealLocationDetails()
        appLog.info("[Camera] 双击定位 → 开启位置与指南针朝向跟随")
    }

    private func revealLocationDetails() {
        locationDetailsTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { locationDetailsVisible = true }
        locationDetailsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) { locationDetailsVisible = false }
            }
        }
    }

    private func setPitch(_ value: Double, animated: Bool) {
        cameraPitch = min(max(value, 0), 70)
        cameraCommand = .pitch(cameraPitch, animated: animated)
        appLog.info("[Camera] 俯角 → \(Int(cameraPitch))°")
    }

    private func cycleTheme() {
        let all = AppTheme.allCases
        let index = all.firstIndex(of: theme) ?? 0
        themeRaw = all[(index + 1) % all.count].rawValue
    }

    private func setRange(_ min: Double, _ max: Double) {
        minMonthIndex = min
        maxMonthIndex = max
        monthIndex = max
    }

    private func yearStart(_ year: Int) -> Double {
        Double(yearStartIndex(months: months, year: year))
    }

    // MARK: - 测试钩子（快照就绪后应用）

    private func applyTestHooks(markerCount: Int, sliderMax: Double) {
        #if DEBUG
        if TestHooks.photosHidden { showPhotos = false }
        if TestHooks.photoToggle {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                togglePhotos()
                appLog.info("[Test] 照片图层快速切换 1/2 → \(showPhotos ? "开" : "关")")
                try? await Task.sleep(nanoseconds: 350_000_000)
                togglePhotos()
                appLog.info("[Test] 照片图层快速切换 2/2 → \(showPhotos ? "开" : "关")")
            }
        }
        if TestHooks.routeToggle {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for index in 1...12 {
                    showLines.toggle()
                    appLog.info("[Test] 路线快速切换 \(index)/12 → \(showLines ? "开" : "关")（路线组=\(routes.count)）")
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
            }
        }
        if TestHooks.headingFollow {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                followCurrentHeading()
                appLog.info("[Test] 位置+指南针朝向跟随已触发")
            }
        }
        let showing = showPhotos
        appLog.info("[Marker] 照片标记 \(markerCount) 个（初始\(showing ? "显示" : "关闭")）")
        if TestHooks.autoExplore { scheduleAutoExplore() }
        if TestHooks.fakePan || TestHooks.autoRecenter { scheduleCameraTestHooks() }
        if TestHooks.markerTap {
            appLog.info("[Test] markerTap 钩子注册（标记数=\(clusterMarkers.count)）")
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                appLog.info("[Test] markerTap 唤醒（标记数=\(clusterMarkers.count)）")
                if let first = clusterMarkers.first {
                    appLog.info("[Test] 模拟点击照片标记 → \(first.name)")
                    handleMarkerTap(first)
                }
            }
        }
        if TestHooks.doubleTap {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                appLog.info("[Test] 模拟双击 → 纯净模式")
                toggleChrome()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                appLog.info("[Test] 模拟单击 → 恢复显示")
                toggleChrome()
            }
        }
        if let month = TestHooks.startMonth {
            minMonthIndex = 0
            maxMonthIndex = sliderMax
            monthIndex = min(Double(month), sliderMax)
        } else if let t = TestHooks.startTheme {
            themeRaw = t
        } else if TestHooks.dotMode {
            showDots = true
        }
        if let mapType = TestHooks.startMapType,
           ["standard", "satellite", "topographic"].contains(mapType) {
            mapTypeRaw = mapType
        }
        if let pitch = TestHooks.startPitch {
            setPitch(pitch, animated: false)
        }
        #endif
    }
    #if DEBUG
    private func scheduleAutoExplore() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            openExplore(level: RegionLevel.city, region: "哈尔滨市")
            appLog.info("[Test] 模拟点击地图 → 打开「哈尔滨市」照片探索")
        }
    }

    private func scheduleCameraTestHooks() {
        if TestHooks.fakePan {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                appLog.info("[Test] 模拟用户拖动地图 → 北京")
                cameraCommand = .region(region(centeredAt: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
                                               distance: 1500), animated: true)
            }
        }
        if TestHooks.autoRecenter {
            Task {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                appLog.info("[Test] 模拟点击「回到当前位置」")
                recenter()
            }
        }
    }
    #endif
}

#if DEBUG
/// 只读计数：MapScreen body 求值频率采样（5 秒窗口），验证相机移动/切 Tab 不再触发重活。
private final class MapBodyDiag {
    private var evals = 0
    private var lastLog = Date()

    func tick() {
        evals += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastLog)
        guard elapsed >= 5 else { return }
        MapDebugLog.log("MapScreen body: \(evals) 次 / \(String(format: "%.1f", elapsed))s")
        evals = 0
        lastLog = now
    }
}
#endif
