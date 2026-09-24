import SwiftUI
import SwiftData
import MapKit

extension Notification.Name {
    static let mapSnapshotReady = Notification.Name("mapSnapshotReady")
    static let reviewPhotoLocationRequested = Notification.Name("reviewPhotoLocationRequested")
    #if DEBUG
    static let performanceOpenSettings = Notification.Name("performanceOpenSettings")
    static let performanceCloseSettings = Notification.Name("performanceCloseSettings")
    #endif
}

enum AppTab: Int, Hashable {
    case map = 0
    case review = 1
    case statistics = 2
}

enum MapEntrySource: Equatable {
    case mapTab
    case review(sessionID: UUID, assetID: String)
}

struct MapPhotoHighlight: Equatable {
    let requestID = UUID()
    let assetID: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let thumbnailPath: String?
    let clusterID: String?
    /// 从回顾进入地图时使用的附近视野宽度；避免沿用全览地图的缩放级别。
    let focusDistance: Double

    var focusRegion: MKCoordinateRegion {
        let delta = max(focusDistance / 55_000, 0.001)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
    }
}

struct MapCameraSnapshot: Equatable {
    let latitude: Double
    let longitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
}

struct SuspendedReviewContext: Equatable {
    let sessionID: UUID
    let assetID: String
    let index: Int
    let source: ReviewSource
}

@MainActor
@Observable
final class AppNavigationCoordinator {
    var selectedTab: AppTab
    var mapEntrySource: MapEntrySource = .mapTab
    var mapPhotoHighlight: MapPhotoHighlight?
    var globalReviewSession: ExploreSession?
    /// Review 概览分组跨 Tab 保持稳定；布局显示与数据生成相互独立。
    var reviewOverviewGroups: [ReviewOverviewGroup] = []
    var locationReviewSession: ExploreSession?
    var suspendedReviewContext: SuspendedReviewContext?
    var mapCameraSnapshot: MapCameraSnapshot?

    init(selectedTab: AppTab = .map) { self.selectedTab = selectedTab }

    func showOnMap(photo: PhotoRecord, session: ExploreSession) {
        suspendedReviewContext = SuspendedReviewContext(
            sessionID: session.id,
            assetID: photo.localIdentifier,
            index: session.index,
            source: session.source
        )
        mapEntrySource = .review(sessionID: session.id, assetID: photo.localIdentifier)
        mapPhotoHighlight = MapPhotoHighlight(assetID: photo.localIdentifier,
                                              latitude: photo.latitude,
                                              longitude: photo.longitude,
                                              timestamp: photo.timestamp,
                                              thumbnailPath: photo.thumbnailPath,
                                              clusterID: nil,
                                              focusDistance: 1_200)
        selectedTab = .map
    }

    func returnToReview() {
        guard suspendedReviewContext != nil else { return }
        if let session = globalReviewSession {
            session.reconcileAvailablePhotos()
            reviewOverviewGroups = reviewOverviewGroups.compactMap { group in
                let available = session.availablePhotoIDs(from: group.photoIDs)
                guard !available.isEmpty else { return nil }
                return ReviewOverviewGroup(title: group.title, photoIDs: available,
                                           previewID: group.previewID, completed: group.completed)
            }
            if session.photos.isEmpty { globalReviewSession = nil }
        }
        mapEntrySource = .mapTab
        mapPhotoHighlight = nil
        selectedTab = .review
        suspendedReviewContext = nil
    }

    func finishLocationReview() {
        locationReviewSession = nil
        mapEntrySource = .mapTab
        mapPhotoHighlight = nil
    }
}

struct MainTabView: View {
    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @AppStorage("mapType") private var mapTypeRaw = "standard"
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigation: AppNavigationCoordinator
    /// 纯净模式：双击「地图」tab 切换（隐藏全部功能控件，图层保留）
    @State private var chromeHidden = false
    @State private var launchDataReady = !SnapshotCache.pointSnapshots.isEmpty
    @State private var minimumLogoElapsed = false
    @State private var reviewImmersive = false
    @State private var didScheduleLegacyRouteMigration = false
    /// Global Review 会话由根协调层持有，临时切到地图/统计时不会销毁。

    init() {
        #if DEBUG
        PerformanceDiagnostics.event("MainTabView.init")
        _navigation = State(initialValue: AppNavigationCoordinator(
            selectedTab: AppTab(rawValue: TestHooks.startTab ?? 0) ?? .map))
        #else
        _navigation = State(initialValue: AppNavigationCoordinator())
        #endif
    }

    var body: some View {
        #if DEBUG
        let _ = PerformanceDiagnostics.event("MainTabView.body")
        #endif
        GeometryReader { viewport in
        ZStack(alignment: .bottom) {
            // P0 性能：三个主页面全部常驻（KEEP ALIVE）。切换 Tab 只改变绘制层级与
            // 命中测试，绝不销毁页面 —— 地图实例、回顾会话、统计缓存跨 Tab 存活。
            ZStack {
                MapScreen(chromeHidden: $chromeHidden, navigation: navigation)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .zIndex(navigation.selectedTab == .map ? 1 : 0)
                    .allowsHitTesting(navigation.selectedTab == .map)
                    .accessibilityHidden(navigation.selectedTab != .map)
                ReviewTabView(
                    session: $navigation.globalReviewSession,
                    groups: $navigation.reviewOverviewGroups,
                    isActive: navigation.selectedTab == .review,
                    onShowLocation: { photo, session in
                        navigation.showOnMap(photo: photo, session: session)
                    },
                    onReturnToMap: { navigation.selectedTab = .map },
                    onImmersiveChanged: { reviewImmersive = $0 }
                )
                .frame(width: viewport.size.width, height: viewport.size.height)
                // 回顾照片的氛围背景需要延伸到状态栏和 Home Indicator 下方。
                // 只裁切照片卡片自身，不能在 Tab 根层裁切整个回顾页的安全区外绘制。
                .zIndex(navigation.selectedTab == .review ? 1 : 0)
                .allowsHitTesting(navigation.selectedTab == .review)
                .accessibilityHidden(navigation.selectedTab != .review)
                StatsScreen(isActive: navigation.selectedTab == .statistics)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .zIndex(navigation.selectedTab == .statistics ? 1 : 0)
                    .allowsHitTesting(navigation.selectedTab == .statistics)
                    .accessibilityHidden(navigation.selectedTab != .statistics)
            }
            .tint(AppTheme(rawValue: themeRaw)?.color ?? .red)
            .preferredColorScheme(.dark)
            .onAppear(perform: applyTestHooks)
            .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
                guard !didScheduleLegacyRouteMigration else { return }
                didScheduleLegacyRouteMigration = true
                let container = context.container
                Task.detached(priority: .utility) {
                    _ = LegacyRouteMigration.runIfNeeded(container: container)
                }
            }
            .task {
                // 照片行政区逆地理：常驻逐批补齐（网格去重+限速退避），
                // 完成后发通知让地图页重载快照 → 聚合标记渐进出现。
                // 仅实际处理过照片才发通知：没有新区域数据时避免整轮无意义重载。
                var batches = 0
                while await RegionService.geocodeNextBatch(in: context) > 0 {
                    batches += 1
                    if batches % 5 == 0 {
                        #if DEBUG
                        PerformanceDiagnostics.event("photoRegionsUpdated.post.batch")
                        #endif
                        NotificationCenter.default.post(name: .photoRegionsUpdated, object: nil)
                    }
                }
                if batches > 0 {
                    #if DEBUG
                    PerformanceDiagnostics.event("photoRegionsUpdated.post.final")
                    #endif
                    NotificationCenter.default.post(name: .photoRegionsUpdated, object: nil)
                }
            }
            .task {
                #if DEBUG
                // 自动切 Tab 回归：验证常驻后页面不再重建（配合 map_debug.txt 挂载计数）
                if TestHooks.tabCycle {
                    for tab in [AppTab.review, .statistics, .map, .review, .statistics, .map] {
                        try? await Task.sleep(for: .seconds(2))
                        navigation.selectedTab = tab
                        appLog.info("[Test] 自动切 Tab → \(tab.rawValue)")
                    }
                }
                #endif
            }
            .task {
                #if DEBUG
                guard TestHooks.performanceAutoCycle else { return }
                for _ in 0..<600 where SnapshotCache.clusterIndex == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let requestedScenario = TestHooks.performanceScenario
                PerformanceDiagnostics.event(
                    "AUDIT_STEADY_STATE_BEGIN",
                    metadata: "scenario=\(requestedScenario ?? "all")|snapshots=\(SnapshotCache.pointSnapshots.count)|clustersReady=\(SnapshotCache.clusterIndex != nil)")

                if requestedScenario == nil || requestedScenario == "map_stats_map" {
                    for iteration in 1...20 {
                        PerformanceDiagnostics.event("AUDIT_SCENARIO",
                                                     metadata: "map_stats_map|\(iteration)")
                        withAnimation(.easeInOut(duration: 0.27)) {
                            navigation.selectedTab = .statistics
                        }
                        try? await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeInOut(duration: 0.27)) {
                            navigation.selectedTab = .map
                        }
                        try? await Task.sleep(for: .milliseconds(450))
                    }
                }

                if requestedScenario == nil || requestedScenario == "map_settings_map" {
                    for iteration in 1...20 {
                        PerformanceDiagnostics.event("AUDIT_SCENARIO",
                                                     metadata: "map_settings_map|\(iteration)")
                        navigation.selectedTab = .statistics
                        try? await Task.sleep(for: .milliseconds(350))
                        NotificationCenter.default.post(name: .performanceOpenSettings, object: nil)
                        try? await Task.sleep(for: .milliseconds(450))
                        NotificationCenter.default.post(name: .performanceCloseSettings, object: nil)
                        try? await Task.sleep(for: .milliseconds(450))
                        navigation.selectedTab = .map
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                }

                if requestedScenario == nil || requestedScenario == "stats_settings_stats" {
                    navigation.selectedTab = .statistics
                    try? await Task.sleep(for: .milliseconds(450))
                    for iteration in 1...20 {
                        PerformanceDiagnostics.event("AUDIT_SCENARIO",
                                                     metadata: "stats_settings_stats|\(iteration)")
                        NotificationCenter.default.post(name: .performanceOpenSettings, object: nil)
                        try? await Task.sleep(for: .milliseconds(450))
                        NotificationCenter.default.post(name: .performanceCloseSettings, object: nil)
                        try? await Task.sleep(for: .milliseconds(450))
                    }
                }
                PerformanceDiagnostics.event("AUDIT_SCENARIO_COMPLETE")
                try? await Task.sleep(for: .seconds(2))
                PerformanceDiagnostics.flush()
                #endif
            }

            // Tab 栏始终保持挂载和同一坐标系。沉浸回顾只隐藏视觉与命中，
            // 从地点跳回地图时不会重新创建内部选中态，避免底栏瞬时错位。
            let hidesTabBar = (navigation.selectedTab == .review && reviewImmersive)
                || (navigation.selectedTab == .map && chromeHidden)
            customTabBar
                .opacity(hidesTabBar ? 0 : 1)
                .allowsHitTesting(!hidesTabBar)
                .accessibilityHidden(hidesTabBar)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: hidesTabBar)

            if !launchDataReady || !minimumLogoElapsed {
                BrandLoadingView(accent: AppTheme(rawValue: themeRaw)?.color ?? .red)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: chromeHidden)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: launchDataReady)
        .task {
            #if DEBUG
            let duration: UInt64 = ProcessInfo.processInfo.environment["FP_HOLD_LOGO"] == "1"
                ? 3_000_000_000 : 650_000_000
            #else
            let duration: UInt64 = 650_000_000
            #endif
            try? await Task.sleep(nanoseconds: duration)
            minimumLogoElapsed = true
            if launchDataReady { MapStartupDiagnostics.shared.mark(.mapShellReady) }
        }
        .task {
            // 地图快照通常会很快就绪；但数据库升级、直接进入其他 tab
            // 或系统忙时都不应让品牌过渡无限等待。
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !launchDataReady {
                appLog.warning("[Launch] 快照准备超时，先进入界面并在后台继续加载")
                launchDataReady = true
                MapStartupDiagnostics.shared.mark(.mapShellReady)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
            launchDataReady = true
            if minimumLogoElapsed { MapStartupDiagnostics.shared.mark(.mapShellReady) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapDisplayPreviewReady)) { _ in
            launchDataReady = true
            if minimumLogoElapsed { MapStartupDiagnostics.shared.mark(.mapShellReady) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localDataReset)) { _ in
            navigation.globalReviewSession = nil
            navigation.reviewOverviewGroups.removeAll(keepingCapacity: false)
            navigation.locationReviewSession = nil
            navigation.suspendedReviewContext = nil
            navigation.mapPhotoHighlight = nil
            navigation.mapEntrySource = .mapTab
            reviewImmersive = false
        }
        .onAppear {
            #if DEBUG
            PerformanceDiagnostics.event("MainTabView.onAppear")
            // 真机长数据性能审计需要等待快照与空间索引完成。仅在显式测试钩子
            // 开启时阻止设备自动息屏，避免远程运行中途把 scene 挂起；正式包及
            // 普通 DEBUG 启动均不受影响。
            if TestHooks.performanceAutoCycle {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            #endif
            LocationService.shared.restoreBackgroundMonitoring()
            // 系统可能因后台定位事件冷启动进程；不能把 View 出现等同于前台。
            LocationService.shared.setAppActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            LocationService.shared.setAppActive(phase == .active)
        }
        .onChange(of: navigation.selectedTab) { oldTab, newTab in
            #if DEBUG
            PerformanceDiagnostics.tabSelectionChanged(from: oldTab.rawValue,
                                                       to: newTab.rawValue)
            DispatchQueue.main.async {
                PerformanceDiagnostics.tabFirstFrameCommitted(tab: newTab.rawValue)
            }
            #endif
        }
        .onDisappear {
            #if DEBUG
            PerformanceDiagnostics.event("MainTabView.onDisappear")
            PerformanceDiagnostics.flush()
            if TestHooks.performanceAutoCycle {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            #endif
        }
    }

    // MARK: - 自定义 tab 栏

    private var customTabBar: some View {
        MainLiquidTabBar(
            selectedTab: Binding(
                get: { navigation.selectedTab },
                set: { tab in
                    navigation.selectedTab = tab
                    if tab == .map, navigation.suspendedReviewContext == nil {
                        navigation.mapEntrySource = .mapTab
                    }
                }
            ),
            accent: AppTheme(rawValue: themeRaw)?.color ?? .mint,
            onMapDoubleTap: {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    chromeHidden.toggle()
                }
                appLog.info("[Chrome] tab 双击 → 纯净模式=\(chromeHidden)")
            }
        )
    }

    // MARK: - 测试钩子

    private func applyTestHooks() {
        #if DEBUG
        guard TestHooks.seedSample || TestHooks.importCSV || TestHooks.seedPhotos
                || TestHooks.seedCustomMap || TestHooks.performanceVisualSeed else { return }
        let hasData = (try? context.fetchCount(FetchDescriptor<FootprintPoint>())) ?? 0
        let photoCount = (try? context.fetchCount(FetchDescriptor<PhotoRecord>())) ?? 0
        // 种子数据只在空库时注入；CSV 导入自带去重，可重复调用
        if TestHooks.seedSample, hasData == 0 {
            TestHooks.seedSampleData(into: context)
        }
        if TestHooks.performanceVisualSeed, hasData == 0 {
            TestHooks.seedPerformanceVisualData(into: context)
        }
        if TestHooks.seedPhotos, photoCount == 0 {
            TestHooks.seedPhotoData(into: context)
        }
        if TestHooks.importCSV {
            TestHooks.importSampleCSV(into: context)
        }
        if TestHooks.seedCustomMap, let template = TopographicMapConfiguration.tileURLTemplate {
            let id = UUID(uuidString: "E8FA647E-2214-4D99-A7D1-C33B33CF5A24")!
            let source = CustomMapSource(id: id, name: "Cold Start Tile Test",
                                         urlTemplate: template, minimumZoom: 0, maximumZoom: 20,
                                         attribution: "© MapTiler · © OpenStreetMap contributors")
            MapSourceStore.upsert(source)
            mapTypeRaw = "custom:\(id.uuidString)"
        }
        #endif
    }
}
