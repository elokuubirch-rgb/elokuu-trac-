import SwiftUI
import SwiftData

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
    let assetID: String
    let latitude: Double
    let longitude: Double
    let clusterID: String?
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
                                              clusterID: nil)
        selectedTab = .map
    }

    func returnToReview() {
        guard suspendedReviewContext != nil else { return }
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
        ZStack(alignment: .bottom) {
            // P0 性能：三个主页面全部常驻（KEEP ALIVE）。切换 Tab 只改变绘制层级与
            // 命中测试，绝不销毁页面 —— 地图实例、回顾会话、统计缓存跨 Tab 存活。
            ZStack {
                MapScreen(chromeHidden: $chromeHidden, navigation: navigation)
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
                .zIndex(navigation.selectedTab == .review ? 1 : 0)
                .allowsHitTesting(navigation.selectedTab == .review)
                .accessibilityHidden(navigation.selectedTab != .review)
                StatsScreen(isActive: navigation.selectedTab == .statistics)
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
                try? await Task.sleep(for: .seconds(8))
                for _ in 0..<600 where SnapshotCache.clusterIndex == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                PerformanceDiagnostics.event(
                    "AUDIT_STEADY_STATE_BEGIN",
                    metadata: "snapshots=\(SnapshotCache.pointSnapshots.count)|clustersReady=\(SnapshotCache.clusterIndex != nil)")

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
                PerformanceDiagnostics.event("AUDIT_SCENARIO_COMPLETE")
                try? await Task.sleep(for: .seconds(2))
                PerformanceDiagnostics.flush()
                #endif
            }

            // 自定义底部 tab 栏：两种模式始终显示（双击「地图」tab 切换纯净模式）
            if navigation.selectedTab != .review || !reviewImmersive {
                customTabBar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !launchDataReady || !minimumLogoElapsed {
                BrandLoadingView(accent: AppTheme(rawValue: themeRaw)?.color ?? .red)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.25), value: chromeHidden)
        .animation(.easeOut(duration: 0.35), value: launchDataReady)
        .task {
            #if DEBUG
            let duration: UInt64 = ProcessInfo.processInfo.environment["FP_HOLD_LOGO"] == "1"
                ? 3_000_000_000 : 650_000_000
            #else
            let duration: UInt64 = 650_000_000
            #endif
            try? await Task.sleep(nanoseconds: duration)
            minimumLogoElapsed = true
        }
        .task {
            // 地图快照通常会很快就绪；但数据库升级、直接进入其他 tab
            // 或系统忙时都不应让品牌过渡无限等待。
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !launchDataReady {
                appLog.warning("[Launch] 快照准备超时，先进入界面并在后台继续加载")
                launchDataReady = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapSnapshotReady)) { _ in
            launchDataReady = true
        }
        .onAppear {
            #if DEBUG
            PerformanceDiagnostics.event("MainTabView.onAppear")
            #endif
            LocationService.shared.restoreBackgroundMonitoring()
            LocationService.shared.setAppActive(true)
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
                withAnimation(.easeOut(duration: 0.25)) { chromeHidden.toggle() }
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
