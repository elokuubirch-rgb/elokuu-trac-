import SwiftUI
import MapKit
import SwiftData
import UIKit

/// 一条足迹折线（按频次着色）
struct RouteLine: Identifiable {
    /// 跨 SwiftUI / MapKit 更新保持稳定；内容变化由 `contentFingerprint` 单独判断。
    let id: String
    let freq: Int
    let isWorkout: Bool
    /// 与 canonical/raw 数据分离的纯派生显示 geometry；在后台 route 构建阶段生成。
    let renderGeometry: ZoomAwareRouteGeometry

    let contentFingerprint: UInt64

    init(coords: [CLLocationCoordinate2D], freq: Int, isWorkout: Bool,
         stableID: String? = nil, usesPersistentLODCache: Bool = true) {
        self.freq = freq
        self.isWorkout = isWorkout
        let resolvedID = stableID ?? Self.fallbackID(coords: coords, isWorkout: isWorkout)
        let fingerprint = Self.fingerprint(
            coords: coords, freq: freq, isWorkout: isWorkout)
        self.id = resolvedID
        self.contentFingerprint = fingerprint
        #if DEBUG
        self.renderGeometry = PerformanceDiagnostics.measure(
            "RenderGeometry.LOD.build", metadata: "points=\(coords.count)") {
                if usesPersistentLODCache {
                    return ZoomAwareRouteGeometry.cached(
                        coordinates: coords, stableID: resolvedID,
                        contentFingerprint: fingerprint)
                }
                return ZoomAwareRouteGeometry(coordinates: coords)
            }
        let lodPointCount = renderGeometry.levels.reduce(0) { $0 + $1.points.count }
        PerformanceDiagnostics.count("Dataset.lodPoints", by: lodPointCount)
        PerformanceDiagnostics.event(
            "RenderGeometry.LOD.summary",
            metadata: "raw=\(renderGeometry.rawPoints.count) lod=\(lodPointCount) levels=\(renderGeometry.levels.count)")
        #else
        self.renderGeometry = usesPersistentLODCache
            ? ZoomAwareRouteGeometry.cached(
                coordinates: coords, stableID: resolvedID,
                contentFingerprint: fingerprint)
            : ZoomAwareRouteGeometry(coordinates: coords)
        #endif
    }

    private static func fallbackID(coords: [CLLocationCoordinate2D],
                                   isWorkout: Bool) -> String {
        guard let first = coords.first else { return "\(isWorkout ? "workout" : "auto"):empty" }
        return "\(isWorkout ? "workout" : "auto"):\(first.latitude.bitPattern):\(first.longitude.bitPattern)"
    }

    private static func fingerprint(coords: [CLLocationCoordinate2D], freq: Int,
                                    isWorkout: Bool) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func mix(_ component: UInt64) {
            value ^= component
            value &*= 1_099_511_628_211
        }
        mix(UInt64(freq))
        mix(isWorkout ? 1 : 0)
        mix(UInt64(coords.count))
        for coordinate in coords {
            mix(coordinate.latitude.bitPattern)
            mix(coordinate.longitude.bitPattern)
        }
        return value
    }
}

/// 点模式下的足迹点（带频次：密度=去得多频繁）
struct FootprintDot: Identifiable {
    let id: Int
    let lat: Double
    let lon: Double
    let freq: Int
}

struct FootprintSourceCounts: Equatable, Sendable {
    var photo = 0
    var csv = 0
    var manual = 0
    var gps = 0
    var health = 0

    mutating func add(source: String) {
        switch source {
        case FootprintSource.photo.rawValue: photo += 1
        case FootprintSource.csv.rawValue: csv += 1
        case FootprintSource.manual.rawValue: manual += 1
        case FootprintSource.gps.rawValue: gps += 1
        case FootprintSource.health.rawValue: health += 1
        default: break
        }
    }
}

/// 地图照片标记快照（含已解码缩略图；后台构建）— 已由分级聚合 PhotoCluster 取代

/// 快照全局缓存：MapScreen 重建（切标签页）后立即显示上次数据，后台刷新无感
enum SnapshotCache {
    static var pointSnapshots: [FootprintSnapshot] = []
    static var sourceCounts = FootprintSourceCounts()
    /// 只在完成一份新的 point snapshot materialization 后递增。
    static var pointSnapshotGeneration = 0
    static var clusterIndex: ClusterIndex?
    static var monthStarts: [Date] = []
    static var stats: FootprintStats = FootprintStats()
    static var dataRegion: MKCoordinateRegion?

    static func reset() {
        pointSnapshots.removeAll(keepingCapacity: false)
        sourceCounts = FootprintSourceCounts()
        pointSnapshotGeneration += 1
        clusterIndex = nil
        monthStarts.removeAll(keepingCapacity: false)
        stats = FootprintStats()
        dataRegion = nil
    }
}

/// 足迹地图：深色底图 + 频次高亮足迹 + 照片标记 + 时间轴 + 实时定位。
/// 数据全部后台快照化：首帧零重活，万级数据不卡看门狗。
struct MapScreen: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var clusterViewportGeneration = 0
    @State private var navigationFocusPending = false
    /// 纯净模式（由 MainTabView 持有；两指点按地图 / 双击「地图」Tab / 图层菜单切换，单击地图恢复）
    @Binding var chromeHidden: Bool
    @Bindable var navigation: AppNavigationCoordinator
    @AppStorage("mapType") private var mapTypeRaw = "standard"
    @State private var customMapSources: [CustomMapSource] = []
    @State private var cameraPitch: Double = 0
    @State private var headingFollowEnabled = false
    /// 相机朝向是否偏离正北（FootprintMapView 回调；驱动自绘指北按钮显隐）
    @State private var mapIsRotated = false
    @State private var highlightedReviewPhoto: MapPhotoHighlight?
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
    @State private var pendingReload = false
    @State private var photoLoadGeneration = 0
    @State private var usesLaunchPreview = false
    @State private var displayedSafetyRevision: Int?
    @State private var displayedTrajectoryRevision: Int?
    @State private var reloadTask: Task<Void, Never>?
    @State private var roadMatchTask: Task<Void, Never>?
    @State private var roadMatchedSegments: [String: RoadMatchedSegment] = [:]
    @State private var activityRoadBridges: [ActivityRoadBridge] = []
    @State private var roadMatchVersion = 0

    init(chromeHidden: Binding<Bool>, navigation: AppNavigationCoordinator) {
        #if DEBUG
        PerformanceDiagnostics.event("MapScreen.init")
        #endif
        _chromeHidden = chromeHidden
        _navigation = Bindable(wrappedValue: navigation)
    }

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }
    private var activeCustomSource: CustomMapSource? {
        guard mapTypeRaw.hasPrefix("custom:"),
              let id = UUID(uuidString: String(mapTypeRaw.dropFirst("custom:".count))) else { return nil }
        return customMapSources.first(where: { $0.id == id })
    }

    private var mapPresentationSystem: CoordinateReferenceSystem {
        MapCoordinatePresentation.targetSystem(
            mapType: mapTypeRaw,
            customSourceSystem: activeCustomSource?.coordinateReferenceSystem)
    }

    // MARK: - 时间轴（基于缓存月份）

    private var months: [Date] { monthStarts }

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
        var presentationSystem: CoordinateReferenceSystem
        var roadMatchVersion: Int
    }

    private struct DerivedLayers {
        var visible: [FootprintSnapshot] = []
        var routes: [RouteLine] = []
        var workoutRoutes: [RouteLine] = []
        var dots: [FootprintDot] = []
    }

    struct RouteBuildResult {
        var routes: [RouteLine] = []
        var roadAttachedPointIDs: Set<String> = []
    }

    @State private var derivedLayers = DerivedLayers()
    /// 派生图层版本：重算落地后 +1，驱动原生图层重建（contentToken 的组成部分）
    @State private var derivedVersion = 0
    @State private var derivedKey = DerivedKey(reloadVersion: -1, monthIndex: -1,
                                               monthCount: -1, scope: .all, snapshotCount: -1,
                                               showLines: true, showWorkouts: true,
                                               presentationSystem: .wgs84,
                                               roadMatchVersion: -1)
    @State private var derivedGeneration = 0

    private var currentDerivedKey: DerivedKey {
        DerivedKey(reloadVersion: reloadVersion,
                   monthIndex: Int(monthIndex.rounded()),
                   monthCount: monthStarts.count,
                   scope: timeScope,
                   snapshotCount: pointSnapshots.count,
                   showLines: showLines, showWorkouts: showWorkouts,
                   presentationSystem: mapPresentationSystem,
                   roadMatchVersion: roadMatchVersion)
    }

    /// 后台重算全部派生图层；期间旧图层继续显示（交互零等待）。
    private func scheduleDerivedRebuild(_ key: DerivedKey) {
        guard ready else { return }
        guard key != derivedKey else { return }
        derivedKey = key
        derivedGeneration += 1
        let generation = derivedGeneration
        let snapshots = pointSnapshots
        let cutoff = cutoffDate
        let scope = timeScope
        let showLines = key.showLines
        let showWorkouts = key.showWorkouts
        let presentationSystem = key.presentationSystem
        let matchedSegments = roadMatchedSegments
        let activityRoadBridges = activityRoadBridges
        let usesPersistentLODCache = !usesLaunchPreview
        #if DEBUG
        let startedAt = CACurrentMediaTime()
        #endif
        Task.detached(priority: .userInitiated) {
            #if DEBUG
            let layers = PerformanceDiagnostics.measure(
                "CanonicalTrajectory.generation",
                metadata: "snapshots=\(snapshots.count)") {
                    Self.computeDerivedLayers(
                        snapshots: snapshots, cutoff: cutoff, scope: scope,
                        showLines: showLines, showWorkouts: showWorkouts,
                        presentationSystem: presentationSystem,
                        usesPersistentLODCache: usesPersistentLODCache,
                        matchedSegments: matchedSegments,
                        activityRoadBridges: activityRoadBridges)
                }
            #else
            let layers = Self.computeDerivedLayers(
                snapshots: snapshots, cutoff: cutoff, scope: scope,
                showLines: showLines, showWorkouts: showWorkouts,
                presentationSystem: presentationSystem,
                usesPersistentLODCache: usesPersistentLODCache,
                matchedSegments: matchedSegments,
                activityRoadBridges: activityRoadBridges)
            #endif
            #if DEBUG
            let ms = (CACurrentMediaTime() - startedAt) * 1000
            #endif
            await MainActor.run {
                guard self.derivedGeneration == generation else { return }
                self.derivedLayers = layers
                self.derivedVersion += 1
                if usesLaunchPreview {
                    MapStartupDiagnostics.shared.mark(.cachedContentReady)
                    Task { @MainActor in
                        await Task.yield()
                        NotificationCenter.default.post(
                            name: .mapDisplayPreviewReady, object: nil)
                    }
                } else if displayedTrajectoryRevision == DataRevisionStore.snapshot().trajectory {
                    MapStartupDiagnostics.shared.mark(.visibleRegionFresh)
                }
                #if DEBUG
                MapDebugLog.log("derived 重算: \(String(format: "%.1f", ms))ms 可见\(layers.visible.count) 线\(layers.routes.count) 运动线\(layers.workoutRoutes.count) 点\(layers.dots.count)")
                #endif
            }
        }
    }

    /// 只匹配当天最近的 GPS 段。匹配过程可取消，数据版本变化后旧结果不得发布。
    private func scheduleRoadMatching(trajectories: [Trajectory],
                                      activityPlan: RecordedActivityPlan,
                                      revision: Int) {
        roadMatchTask?.cancel()
        roadMatchedSegments = [:]
        activityRoadBridges = activityPlan.roadBridges
        roadMatchVersion += 1
        guard !trajectories.isEmpty else { return }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let service = RoadMatchingService(provider: MapKitRoadGeometryProvider())
        roadMatchTask = Task(priority: .utility) {
            if let cached = RoadMatchedGeometryStore.shared.load(dataRevision: revision) {
                guard !Task.isCancelled,
                      displayedTrajectoryRevision == revision else { return }
                roadMatchedSegments = cached
                roadMatchVersion += 1
                return
            }
            let results = await service.matchRecent(
                trajectories: trajectories, since: startOfToday)
            guard !Task.isCancelled,
                  displayedTrajectoryRevision == revision else { return }
            roadMatchedSegments = results.filter { $0.value.usesRoadGeometry }
            roadMatchVersion += 1
            let bridgeResults = await service.matchRoadBridges(
                activityPlan.roadBridges, since: startOfToday)
            guard !Task.isCancelled,
                  displayedTrajectoryRevision == revision else { return }
            roadMatchedSegments.merge(
                bridgeResults.filter { $0.value.usesRoadGeometry }) { _, latest in latest }
            if !roadMatchedSegments.isEmpty {
                _ = RoadMatchedGeometryStore.shared.save(
                    roadMatchedSegments, dataRevision: revision)
            }
            roadMatchVersion += 1
            #if DEBUG
            let matchedCount = roadMatchedSegments.count
            let rejectedCount = results.count - matchedCount
            PerformanceDiagnostics.event(
                "RoadMatching.completed",
                metadata: "matched=\(matchedCount) rejected=\(rejectedCount)")
            #endif
        }
    }

    /// 纯函数：输入快照 + 时间窗口 → 全部图层（任意线程执行，不触碰任何状态）
    nonisolated private static func computeDerivedLayers(snapshots: [FootprintSnapshot],
                                                         cutoff: Date?, scope: MapTimeScope,
                                                         showLines: Bool,
                                                         showWorkouts: Bool,
                                                         presentationSystem: CoordinateReferenceSystem,
                                                         usesPersistentLODCache: Bool,
                                                         matchedSegments: [String: RoadMatchedSegment],
                                                         activityRoadBridges: [ActivityRoadBridge] = []) -> DerivedLayers {
        var layers = DerivedLayers()
        guard let cutoff else { return layers }
        // pointSnapshots 在进入页面状态前已经按时间排序。这里用两次只读扫描
        // 代替百万级 filtered/auto/workout 三份值数组；筛选谓词、顺序及最终
        // RouteLine 均保持不变。
        let isInWindow: (FootprintSnapshot) -> Bool = {
            $0.t < cutoff && scope.contains($0.t)
        }
        let filteredCount = snapshots.reduce(into: 0) { count, snapshot in
            if isInWindow(snapshot) { count += 1 }
        }
        let cap = 2500
        let stride = filteredCount > cap ? filteredCount / cap : 1
        var visible: [FootprintSnapshot] = []
        visible.reserveCapacity(min(filteredCount, cap + 1))
        var filteredOffset = 0
        for snapshot in snapshots where isInWindow(snapshot) {
            if filteredOffset % stride == 0 { visible.append(snapshot) }
            filteredOffset += 1
        }
        layers.visible = visible

        // 只有真实采样源可进入折线。历史 photo/csv/manual 点即使仍在数据库，
        // 也不能连接成 Personal Trajectory。
        let autoRoutes = makeRoutes(
            from: snapshots, workout: false,
            presentationSystem: presentationSystem,
            usesPersistentLODCache: usesPersistentLODCache,
            matchedSegments: matchedSegments,
            includes: {
                isInWindow($0) && MapLayerSemantics.isAutoTrajectory(
                    $0, workoutSourceVisible: showWorkouts)
            })
        let workoutRoutes = makeRoutes(
            from: snapshots, workout: true,
            presentationSystem: presentationSystem,
            usesPersistentLODCache: usesPersistentLODCache,
            matchedSegments: matchedSegments,
            includes: {
                isInWindow($0) && MapLayerSemantics.isWorkoutTrajectory(
                    $0, autoSourceVisible: showLines)
            })
        var attachedCoordinates: [String: RoadGeometryCoordinate] = [:]
        let roadAttachedPointIDs = autoRoutes.roadAttachedPointIDs
            .union(workoutRoutes.roadAttachedPointIDs)
        for matched in matchedSegments.values
            where matched.usesRoadGeometry
                && !matched.sourceSegmentID.hasPrefix("activity-bridge:") {
            for attachment in matched.attachments
                where roadAttachedPointIDs.contains(attachment.pointID) {
                attachedCoordinates[attachment.pointID] = attachment.coordinate
            }
        }
        layers.routes = autoRoutes.routes
        if showLines {
            layers.routes += makeActivityBridgeRoutes(
                activityRoadBridges, matchedSegments: matchedSegments,
                attachedCoordinates: attachedCoordinates,
                presentationSystem: presentationSystem,
                usesPersistentLODCache: usesPersistentLODCache,
                includes: { $0 < cutoff && scope.contains($0) })
        }
        layers.workoutRoutes = workoutRoutes.routes

        #if DEBUG
        var logicalTrajectoryIDs = Set<String>()
        var trajectorySegmentIDs = Set<String>()
        for snapshot in snapshots where isInWindow(snapshot) {
            if let id = snapshot.trajectoryID { logicalTrajectoryIDs.insert(id) }
            if let id = snapshot.segmentID { trajectorySegmentIDs.insert(id) }
        }
        let renderedRoutes = layers.routes + layers.workoutRoutes
        let renderedPointCount = renderedRoutes.reduce(0) {
            $0 + $1.renderGeometry.rawPoints.count
        }
        PerformanceDiagnostics.count("renderGeometry.rawPointCount", by: filteredCount)
        PerformanceDiagnostics.count("renderGeometry.renderPointCount", by: renderedPointCount)
        PerformanceDiagnostics.count("MapPresentation.logicalTrajectoryCount",
                                     by: logicalTrajectoryIDs.count)
        PerformanceDiagnostics.count("MapPresentation.trajectorySegmentCount",
                                     by: trajectorySegmentIDs.count)
        PerformanceDiagnostics.count("MapPresentation.renderedGeometryCount",
                                     by: renderedRoutes.count)
        #endif

        let dotSnapshots = MapLayerSemantics.footprintDots(
            visible, workoutSourceVisible: showWorkouts)
        let buckets = freqBuckets(of: dotSnapshots)
        // 流畅优先：≤600 点采样（保持密度观感）
        let step = max(1, dotSnapshots.count / 600)
        var dots: [FootprintDot] = []
        for (index, s) in dotSnapshots.enumerated() where index % step == 0 {
            let attached = attachedCoordinates[snapshotPointID(s)]
            let canonical = attached.map {
                CoordinateValue(latitude: $0.latitude, longitude: $0.longitude)
            } ?? CoordinateValue(latitude: s.lat, longitude: s.lon)
            let displayed = MapCoordinatePresentation.display(
                canonical,
                targetSystem: presentationSystem)
            dots.append(FootprintDot(id: index, lat: displayed.latitude,
                                     lon: displayed.longitude,
                                     freq: freq(of: s, buckets: buckets)))
        }
        layers.dots = dots
        return layers
    }

    nonisolated private static func resolvedSnapshots(
        from points: [ResolvedTrajectoryPoint],
        matching footprintOriginalIDs: Set<String>
    ) -> (snapshots: [FootprintSnapshot], matchedOriginalIDs: Set<String>, metadataCount: Int) {
        var metadataPool = FootprintSnapshotMetadataPool()
        var snapshots: [FootprintSnapshot] = []
        snapshots.reserveCapacity(points.count)
        var matchedOriginalIDs = Set<String>()
        matchedOriginalIDs.reserveCapacity(min(footprintOriginalIDs.count, points.count))
        for resolved in points {
            if footprintOriginalIDs.contains(resolved.point.id) {
                matchedOriginalIDs.insert(resolved.point.id)
            }
            snapshots.append(snapshot(from: resolved, metadataPool: &metadataPool))
        }
        return (snapshots, matchedOriginalIDs, metadataPool.count)
    }

    nonisolated private static func snapshot(
        from resolved: ResolvedTrajectoryPoint,
        metadataPool: inout FootprintSnapshotMetadataPool
    ) -> FootprintSnapshot {
        let source: String
        switch resolved.source {
        case .healthWorkout: source = FootprintSource.health.rawValue
        case .coreLocation: source = FootprintSource.gps.rawValue
        case .imported: source = FootprintSource.csv.rawValue
        case .inferred: source = FootprintSource.manual.rawValue
        }
        let metadata = metadataPool.metadata(
            source: source, trajectoryID: resolved.trajectoryID,
            sessionID: resolved.sessionID, segmentID: resolved.segmentID,
            isSuppressedDuplicate: resolved.suppressedByTrajectoryID != nil,
            suppressedBySource: resolved.suppressedBySource?.rawValue)
        return FootprintSnapshot(
            lat: resolved.point.latitude, lon: resolved.point.longitude,
            t: resolved.point.timestamp, metadata: metadata)
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

    nonisolated static func makeRoutes(
        from snapshots: [FootprintSnapshot], workout: Bool,
        presentationSystem: CoordinateReferenceSystem,
        usesPersistentLODCache: Bool,
        matchedSegments: [String: RoadMatchedSegment],
        includes: (FootprintSnapshot) -> Bool
    ) -> RouteBuildResult {
        var buckets: [Int: Int] = [:]
        for snapshot in snapshots where includes(snapshot) {
            let key = (Int((snapshot.lat / 0.002).rounded()) << 16)
                ^ Int((snapshot.lon / 0.002).rounded())
            buckets[key, default: 0] += 1
        }
        var lines: [RouteLine] = []
        var roadAttachedPointIDs = Set<String>()
        var currentCoordinates: [CLLocationCoordinate2D] = []
        var currentFrequencySum = 0
        var currentPointIDs: [String] = []
        var firstSnapshot: FootprintSnapshot?
        var prev: FootprintSnapshot?

        func flush() {
            // 两个连续采样点已经能确定一条短路段；单点仍不成线。
            guard currentCoordinates.count >= 2, let first = firstSnapshot else {
                currentCoordinates = []
                currentFrequencySum = 0
                currentPointIDs = []
                firstSnapshot = nil
                return
            }
            let avg = currentFrequencySum / currentCoordinates.count
            let identity = first.segmentID ?? first.trajectoryID ?? first.sessionID
                ?? "\(Int64((first.t.timeIntervalSince1970 * 1_000).rounded()))"
            let stableID = "\(workout ? "workout" : "auto"):\(identity):\(Int64((first.t.timeIntervalSince1970 * 1_000).rounded()))"
            let renderCoordinates: [CLLocationCoordinate2D]
            if let segmentID = first.segmentID,
               let matched = matchedSegments[segmentID], matched.usesRoadGeometry,
               Set(matched.attachments.map(\.pointID)) == Set(currentPointIDs) {
                roadAttachedPointIDs.formUnion(currentPointIDs)
                renderCoordinates = matched.geometry.map { coordinate in
                    let displayed = MapCoordinatePresentation.display(
                        CoordinateValue(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude),
                        targetSystem: presentationSystem)
                    return CLLocationCoordinate2D(
                        latitude: displayed.latitude, longitude: displayed.longitude)
                }
            } else {
                renderCoordinates = currentCoordinates
            }
            lines.append(RouteLine(coords: renderCoordinates, freq: avg,
                                   isWorkout: workout, stableID: stableID,
                                   usesPersistentLODCache: usesPersistentLODCache))
            currentCoordinates = []
            currentFrequencySum = 0
            currentPointIDs = []
            firstSnapshot = nil
        }

        for s in snapshots where includes(s) {
            if let p = prev {
                let gap = s.t.timeIntervalSince(p.t)
                let dist = GeoMath.distanceMeters(from: (p.lat, p.lon), to: (s.lat, s.lon))
                // 真实轨迹判据：45 分钟内移动 ≤3km（步行/骑行/驾车的连续记录）
                // 超界即断线——不同城市/时段的点绝不相连（消除杂乱蜘蛛网）
                let crossedDomainBoundary = MapLayerSemantics.crossesTrajectoryBoundary(p, s)
                let legacyNeedsInference = !MapLayerSemantics.hasExplicitTrajectoryBoundary(p, s)
                if crossedDomainBoundary || (legacyNeedsInference
                    && (gap > 45 * 60 || dist > 3000)) {
                    flush()
                }
            }
            if firstSnapshot == nil { firstSnapshot = s }
            let displayed = MapCoordinatePresentation.display(
                CoordinateValue(latitude: s.lat, longitude: s.lon),
                targetSystem: presentationSystem)
            currentCoordinates.append(CLLocationCoordinate2D(
                latitude: displayed.latitude, longitude: displayed.longitude))
            currentPointIDs.append(snapshotPointID(s))
            currentFrequencySum += freq(of: s, buckets: buckets)
            prev = s
        }
        flush()
        return RouteBuildResult(
            routes: lines, roadAttachedPointIDs: roadAttachedPointIDs)
    }

    nonisolated static func makeActivityBridgeRoutes(
        _ bridges: [ActivityRoadBridge],
        matchedSegments: [String: RoadMatchedSegment],
        attachedCoordinates: [String: RoadGeometryCoordinate] = [:],
        presentationSystem: CoordinateReferenceSystem,
        usesPersistentLODCache: Bool,
        includes: (Date) -> Bool
    ) -> [RouteLine] {
        bridges.compactMap { bridge in
            guard includes(bridge.startTime), includes(bridge.endTime),
                  let matched = matchedSegments[bridge.id], matched.usesRoadGeometry,
                  Set(matched.attachments.map(\.pointID))
                    == Set([bridge.from.id, bridge.to.id]) else { return nil }
            // Reuse the exact same attachment as the displayed recorded dot.
            let from = attachedCoordinates[bridge.from.id] ?? RoadGeometryCoordinate(
                latitude: bridge.from.latitude,
                longitude: bridge.from.longitude)
            let to = attachedCoordinates[bridge.to.id] ?? RoadGeometryCoordinate(
                    latitude: bridge.to.latitude,
                    longitude: bridge.to.longitude)
            let coordinates = [from] + matched.geometry + [to]
            let displayed = coordinates.map { coordinate in
                let value = MapCoordinatePresentation.display(
                    CoordinateValue(latitude: coordinate.latitude,
                                    longitude: coordinate.longitude),
                    targetSystem: presentationSystem)
                return CLLocationCoordinate2D(
                    latitude: value.latitude, longitude: value.longitude)
            }
            return RouteLine(
                coords: displayed, freq: 1, isWorkout: false,
                stableID: bridge.id,
                usesPersistentLODCache: usesPersistentLODCache)
        }
    }

    nonisolated private static func snapshotPointID(_ snapshot: FootprintSnapshot) -> String {
        TrajectorySampleIdentity.footprint(
            source: snapshot.source, latitude: snapshot.lat,
            longitude: snapshot.lon, timestamp: snapshot.t)
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
        // 单点数据时原算法会得到 hi=1 并越界。把上界夹在最后一个合法下标；
        // 两点及以上时结果与原百分位算法完全一致。
        let hi = min(max(snaps.count - 1 - lo, lo + 1), snaps.count - 1)
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
        let _ = PerformanceDiagnostics.event("MapScreen.body")
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
                // 普通浏览只显示 DisplayLocationFilter 的稳定位置；
                // 指南针跟随期间由 MapKit 暂时接管系统蓝点。
                stableLocation: LocationService.shared.location?.coordinate,
                // Current Location 不能自动形成实时历史线。
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
                onHighlightedPhotoTap: { assetID in
                    openExplore(ids: [assetID], clusterID: "review-photo:\(assetID)", startAt: 0)
                },
                onDoubleTap: toggleChrome,
                onHeadingChanged: { mapIsRotated = $0 })
            .ignoresSafeArea(edges: .all)
            .onAppear {
                #if DEBUG
                PerformanceDiagnostics.event("MapScreen.mapView.onAppear")
                #endif
                // 仅首次出现时定位到数据全貌（防止每次切回标签页都跳镜头）
                if !hasPositioned {
                    cameraCommand = .region(autoRegion, animated: false)
                }
                #if DEBUG
                MapDebugLog.log("onAppear: location=\(String(describing: LocationService.shared.location?.coordinate.latitude)) 快照=\(pointSnapshots.count) 标记=\(clusterMarkers.count)")
                #endif
            }
            .task {
                #if DEBUG
                PerformanceDiagnostics.event("MapScreen.task.locationStart")
                #endif
                LocationService.shared.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: .photoRegionsUpdated)) { _ in
                // 逆地理有进展 → 重载快照，照片标记渐进出现
                #if DEBUG
                PerformanceDiagnostics.event("photoRegionsUpdated.receive.MapScreen")
                PerformanceDiagnostics.count("MapScreen.reload.requested")
                #endif
                scheduleReload()
            }

            // 定位详情只在用户主动点击定位后短暂出现，不长期占据地图。
            if !chromeHidden, locationDetailsVisible, let loc = LocationService.shared.location {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前位置").fontWeight(.semibold)
                    Text(String(format: NSLocalizedString("精度 ±%dm", comment: "Location horizontal accuracy"),
                                Int(loc.horizontalAccuracy)))
                    Text(loc.timestamp.formatted(date: .omitted, time: .standard))
                }
                .multilineTextAlignment(.leading)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .frame(height: 44)
                            .background(.regularMaterial, in: Capsule())
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

            if !chromeHidden, let highlight = highlightedReviewPhoto,
               !timeScope.contains(highlight.timestamp) {
                HStack(spacing: 10) {
                    Text("照片不在当前时间范围")
                        .font(.caption.weight(.medium))
                    Button("显示全部时间") {
                        timeScope = .all
                        lastClusterCenter = nil
                        loadOriginalPhotoLayer()
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 60)
            }

            // 纯净模式仍保留一个低干扰、可聚焦的恢复入口；地图单击与快捷手势继续可用。
            if chromeHidden {
                Button(action: toggleChrome) {
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("显示地图控件")
                .accessibilityHint("退出纯净模式")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }

            if !chromeHidden, layerMenuVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            layerMenuVisible = false
                        }
                    }
                    .zIndex(40)
                mapLayerMenu
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 16)
                    .padding(.top, 62)
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(41)
            }

            // 「暂无照片」等轻提示；纯净模式下也允许显示（进入纯净模式的一次性提示）
            if let toast = tapToast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
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
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
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
                    .accessibilityAction(named: "按朝向跟随") {
                        followCurrentHeading()
                    }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 14)
                .padding(.bottom, 104)
            }

            // 指北按钮：相机偏离正北（双指旋转/朝向跟随）时出现在左下角，
            // 替代被隐藏的系统右上角指南针（原位置与图层按钮重叠）。
            if !chromeHidden, mapIsRotated {
                Button(action: resetNorth) {
                    Image(systemName: "safari")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回正北")
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 14)
                .padding(.bottom, 104)
            }

            // 自定义瓦片源必须保留版权署名；使用轻量标签代替原底部大面板。
            if !chromeHidden, let attribution = activeMapAttribution {
                Text(attribution)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 12)
                    // 根层悬浮 Tab 高 62pt + 8pt 底距；额外留 10pt，避免长期遮挡署名。
                    .padding(.bottom, 80)
            }
        }
        // MainTabView owns the bounded launch transition. Historical loading must
        // not cover this map with a second, unbounded brand overlay.
        .preferredColorScheme(.dark)
        // 纯净模式进入提示：无论从哪个入口（两指点按/双击 Tab/图层菜单）进入都提示恢复方式。
        .onChange(of: chromeHidden) { _, hidden in
            if hidden {
                showTapToast(String(localized: "已进入纯净模式，单击屏幕恢复"))
            }
        }
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
                Task { @MainActor in
                    await Task.yield()
                    if let centroid = PhotoStore.centroid(level: targetLevel, regionName: next, in: context) {
                        appLog.info("[Camera] 自动飞往「\(next)」 质心(\(String(format: "%.4f", centroid.latitude)),\(String(format: "%.4f", centroid.longitude))) 距离\(Int(distance(for: targetLevel)))m")
                        cameraCommand = .region(
                            region(centeredAt: centroid, distance: distance(for: targetLevel)),
                            animated: !reduceMotion)
                    }
                    session.completePlaceTransition(to: next)
                }
            }
        }

        .onAppear {
            #if DEBUG
            PerformanceDiagnostics.event("MapScreen.onAppear")
            #endif
            let loadedSources = MapSourceStore.load()
            customMapSources = loadedSources
            // 内置专业等高线仅在配置 MapTiler Key 后可用；旧版本停留在该图层时平滑回退。
            if mapTypeRaw == "topographic", TopographicMapConfiguration.tileURLTemplate == nil {
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
                    if let index = clusterIndex {
                        let region = navigation.mapPhotoHighlight?.focusRegion
                            ?? SnapshotCache.dataRegion ?? autoRegion
                        let level = PhotoCluster.Level.level(for: region.span.latitudeDelta)
                        let result = ClusterIndex.adaptiveVisible(index, preferred: level, region: region)
                        clusterLevel = result.level
                        clusterMarkers = result.clusters
                        markerToken += 1
                    }
                }
                loadStartupPreview()
            }
            applyNavigationHighlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataRevisionChanged)) { notification in
            // 足迹/照片入库完成 → 重载快照（替代主线程 @Query 监听）
            guard let change = notification.object as? DataRevisionChange,
                  !change.domains.intersection([.trajectory, .place, .photo]).isEmpty else { return }
            if let displayedSafetyRevision,
               displayedSafetyRevision != DataRevisionStore.displaySafetyRevision() {
                pointSnapshots = []
                derivedLayers = DerivedLayers()
                derivedGeneration += 1
                derivedVersion += 1
                self.displayedSafetyRevision = nil
                SnapshotCache.pointSnapshots = []
            }
            if change.domains.contains(.photo) {
                if let selected = navigation.mapPhotoHighlight,
                   PhotoStore.hiddenPhotoIDs().contains(selected.assetID) {
                    navigation.mapPhotoHighlight = nil
                }
                clusterIndex = nil
                clusterMarkers = []
                markerToken += 1
                SnapshotCache.clusterIndex = nil
            }
            #if DEBUG
            PerformanceDiagnostics.event("dataRevision.receive.MapScreen",
                                           metadata: "domains=\(change.domains.rawValue)")
            PerformanceDiagnostics.count("MapScreen.reload.requested")
            #endif
            if change.domains.contains(.trajectory) {
                TrajectoryResolutionCache.shared.invalidate(for: change.current.trajectory)
            }
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
        .onDisappear {
            roadMatchTask?.cancel()
            #if DEBUG
            PerformanceDiagnostics.event("MapScreen.onDisappear")
            #endif
        }
    }

    // MARK: - 地图图层

    private var layerButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                layerMenuVisible.toggle()
            }
        } label: {
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mapTypeRaw == "standard" && showPhotos && (showDots || showLines) && showWorkouts ? .primary : theme.color)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("地图图层")
        .accessibilityValue(layerMenuVisible ? "已展开" : "已收起")
    }

    private var mapLayerMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("地图样式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            layerRow("标准", selected: mapTypeRaw == "standard") { mapTypeRaw = "standard" }
            layerRow("静谧", selected: mapTypeRaw == MapBasePresentation.quietMapType) {
                mapTypeRaw = MapBasePresentation.quietMapType
            }
            layerRow("卫星", selected: mapTypeRaw == "satellite") { mapTypeRaw = "satellite" }
            // 内置等高线仅在提供 MapTiler Key 时可用；无 Key 不再展示不可用的选项。
            if TopographicMapConfiguration.tileURLTemplate != nil {
                layerRow("户外", selected: mapTypeRaw == "topographic") { mapTypeRaw = "topographic" }
            }
            ForEach(customMapSources) { source in
                layerRow(source.name, selected: mapTypeRaw == "custom:\(source.id.uuidString)",
                         verbatim: true) {
                    mapTypeRaw = "custom:\(source.id.uuidString)"
                }
            }
            Divider().overlay(.white.opacity(0.10))
            Text("显示内容").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            layerRow("足迹", selected: showDots || showLines) {
                let next = !(showDots || showLines); showDots = next; showLines = next
            }
            layerRow("运动", selected: showWorkouts) { showWorkouts.toggle() }
            layerRow("照片", selected: showPhotos) { togglePhotos() }
            Divider().overlay(.white.opacity(0.10))
            // 纯净模式显式入口；地图两指点按 / 双击地图 Tab 只是快捷方式。
            Button {
                layerMenuVisible = false
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    chromeHidden = true
                }
            } label: {
                HStack { Text("纯净模式"); Spacer(); Image(systemName: "eye.slash") }
                    .font(.footnote.weight(.medium))
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func layerRow(_ title: String, selected: Bool, verbatim: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { (verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title)));
                     Spacer(); Image(systemName: selected ? "checkmark" : "circle") }
                .font(.footnote.weight(.medium))
                .contentShape(Rectangle())
                .frame(minHeight: 44)
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
                    guard timeScope != scope else { return }
                    timeScope = scope
                    // 时间筛选仅刷新照片与已有轨迹的派生显示，不重读完整轨迹库。
                    lastClusterCenter = nil
                    loadOriginalPhotoLayer()
                } label: {
                    Label(timeScopeTitle(scope), systemImage: timeScope == scope ? "checkmark" : "calendar")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(timeScopeTitle(timeScope))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(timeScope == .all ? Color.primary : theme.color)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func timeScopeTitle(_ scope: MapTimeScope) -> String {
        switch scope {
        case .all: return String(localized: "全部时间")
        case .year(let year):
            return year == Calendar.current.component(.year, from: Date())
                ? String(localized: "今年") : String(localized: "去年")
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
        if navigationFocusPending, let target = navigation.mapPhotoHighlight?.focusRegion {
            let distance = GeoMath.distanceMeters(
                from: (region.center.latitude, region.center.longitude),
                to: (target.center.latitude, target.center.longitude))
            if distance > target.span.latitudeDelta * 111_000 * 0.2 { return }
            navigationFocusPending = false
        }
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
        let photoGeneration = photoLoadGeneration
        let requestedScope = timeScope

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
        clusterViewportGeneration += 1
        let viewportGeneration = clusterViewportGeneration
        Task.detached(priority: .userInitiated) {
            let result = ClusterIndex.adaptiveVisible(indexCopy, preferred: requestedLevel,
                                                      region: region)
            await MainActor.run {
                guard photoGeneration == self.photoLoadGeneration,
                      viewportGeneration == self.clusterViewportGeneration,
                      requestedScope == self.timeScope else { return }
                self.clusterLevel = result.level
                self.clusterMarkers = result.clusters
                self.markerToken += 1
                appLog.info("[Cluster] 级别=\(result.level) 可见集合 \(result.clusters.count) 个")
            }
        }
    }

    /// 用户手势拖动/缩放镜头 → 迟滞判断是否脱离跟随
    private func handleCameraMoved(_ center: CLLocationCoordinate2D) {
        navigationFocusPending = false
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
        let ids = lockedPhotoIDs(for: cluster)
        openExplore(ids: ids, clusterID: cluster.id,
                    startAt: ids.isEmpty ? nil : Int.random(in: 0..<ids.count))
    }

    /// 不改变 PhotoCluster 聚合，只在用户点击时还原该 Cluster 的完整照片 ID。
    /// 粗层级 sampleIds 仅用于封面容错（最多 8 张），不能作为 Review 候选池。
    private func lockedPhotoIDs(for cluster: PhotoCluster) -> [String] {
        switch cluster.level {
        case .province:
            guard let key = cluster.id.split(separator: "|", maxSplits: 1).last.map(String.init) else {
                return []
            }
            return PhotoStore.all(in: context).compactMap { photo in
                let provinceKey = photo.provinceName ?? photo.countryName ?? "未知"
                return provinceKey == key ? photo.localIdentifier : nil
            }
        case .city:
            let parts = cluster.id.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return [] }
            let provinceKey = parts[1]
            let cityKey = parts[2]
            return PhotoStore.all(in: context).compactMap { photo in
                let photoProvince = photo.provinceName ?? photo.countryName ?? "未知"
                let photoCity = photo.cityName ?? photo.provinceName ?? photoProvince
                return photoProvince == provinceKey && photoCity == cityKey
                    ? photo.localIdentifier : nil
            }
        case .district, .town, .block, .spot, .single:
            return cluster.sampleIds ?? []
        }
    }

    // MARK: - 后台快照加载（核心：万级数据零主线程阻塞）

    private func loadStartupPreview() {
        let revision = DataRevisionStore.snapshot()
        let safetyRevision = DataRevisionStore.displaySafetyRevision()
        Task {
            let cached = await Task.detached(priority: .userInitiated) {
                MapDisplaySnapshotStore.shared.load(revision: revision, safetyRevision: safetyRevision)
            }.value
            let current = DataRevisionStore.snapshot()
            var showedPreview = false
            if !ready, let cached, current.trajectory >= revision.trajectory,
               current.place >= revision.place,
               DataRevisionStore.displaySafetyRevision() == safetyRevision {
                usesLaunchPreview = true
                displayedSafetyRevision = safetyRevision
                displayedTrajectoryRevision = cached.trajectoryRevision
                pointSnapshots = cached.points.map(\.snapshot)
                monthStarts = cached.months
                statsCache = cached.stats
                dataRegion = cached.region
                minMonthIndex = 0
                maxMonthIndex = Double(max(0, cached.months.count - 1))
                monthIndex = maxMonthIndex
                if !hasPositioned {
                    cameraCommand = .region(cached.region, animated: false)
                    hasPositioned = true
                }
                ready = true
                reloadVersion += 1
                showedPreview = true
            }
            // Let the bounded preview finish its derived-layer build and first MapKit
            // commit before the million-point exact refresh starts competing for CPU.
            if showedPreview {
                try? await Task.sleep(for: .milliseconds(350))
            }
            loadSnapshots()
        }
    }

    private func loadSnapshots() {
        loadOriginalPhotoLayer()
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        #if DEBUG
        PerformanceDiagnostics.event("MapScreen.loadSnapshots.start")
        PerformanceDiagnostics.count("MapScreen.rebuild.started")
        #endif
        let container = context.container
        let selectedScope = timeScope
        let loadRevision = DataRevisionStore.snapshot()
        let loadSafetyRevision = DataRevisionStore.displaySafetyRevision()
        Task.detached(priority: .userInitiated) {
            // 阶段 1：只读取足迹，先让地图可交互；照片聚合随后渐进出现。
            // fetch 出来的 @Model 图只在这个作用域内存活。返回值类型快照后
            // 立即释放 ModelContext/模型，避免与轨迹缓存解码的峰值叠加。
            var footprintResult: (
                snapshots: [FootprintSnapshot], originalPointIDs: [String], rowCount: Int
            ) =
                autoreleasepool {
                    let pointContext = ModelContext(container)
                    pointContext.autosaveEnabled = false
                    #if DEBUG
                    let rows = PerformanceDiagnostics.measure(
                        "SwiftData.footprint.fetch") {
                            (try? pointContext.fetch(FetchDescriptor<FootprintPoint>(
                                sortBy: [SortDescriptor(\.timestamp)]))) ?? []
                        }
                    let materialized: ([FootprintSnapshot], [String]) = PerformanceDiagnostics.measure(
                        "FootprintSnapshot.build", metadata: "rows=\(rows.count)") {
                            var snapshots: [FootprintSnapshot] = []
                            var originalPointIDs: [String] = []
                            snapshots.reserveCapacity(rows.count)
                            originalPointIDs.reserveCapacity(rows.count)
                            for row in rows {
                                let id = TrajectorySampleIdentity.footprint(
                                    source: row.sourceRaw, latitude: row.latitude,
                                    longitude: row.longitude, timestamp: row.timestamp)
                                snapshots.append(FootprintSnapshot(
                                    lat: row.latitude, lon: row.longitude,
                                    t: row.timestamp, source: row.sourceRaw,
                                    trajectoryID: row.trajectoryID,
                                    sessionID: row.sessionID, segmentID: row.segmentID))
                                originalPointIDs.append(id)
                            }
                            return (snapshots, originalPointIDs)
                        }
                    #else
                    let rows = (try? pointContext.fetch(FetchDescriptor<FootprintPoint>(
                        sortBy: [SortDescriptor(\.timestamp)]))) ?? []
                    var snapshots: [FootprintSnapshot] = []
                    var originalPointIDs: [String] = []
                    snapshots.reserveCapacity(rows.count)
                    originalPointIDs.reserveCapacity(rows.count)
                    for row in rows {
                        let id = TrajectorySampleIdentity.footprint(
                            source: row.sourceRaw, latitude: row.latitude,
                            longitude: row.longitude, timestamp: row.timestamp)
                        snapshots.append(FootprintSnapshot(
                            lat: row.latitude, lon: row.longitude,
                            t: row.timestamp, source: row.sourceRaw,
                            trajectoryID: row.trajectoryID,
                            sessionID: row.sessionID, segmentID: row.segmentID))
                        originalPointIDs.append(id)
                    }
                    let materialized = (snapshots, originalPointIDs)
                    #endif
                    return (materialized.0, materialized.1, rows.count)
                }
            var snaps = footprintResult.snapshots
            var footprintOriginalIDs = footprintResult.originalPointIDs
            let footprintRowCount = footprintResult.rowCount
            footprintResult.snapshots.removeAll(keepingCapacity: false)
            footprintResult.originalPointIDs.removeAll(keepingCapacity: false)
            let trajectoryRevision = DataRevisionStore.snapshot().trajectory
            var trajectoryResolution = try? TrajectoryRepository(container: container).loadResolved()
            let roadMatchTrajectories = trajectoryResolution?.trajectories ?? []
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let visibleRecentPointIDs = Set(trajectoryResolution?.points
                .filter {
                    $0.source == .coreLocation
                        && $0.point.timestamp >= startOfToday
                        && $0.suppressedByTrajectoryID == nil
                }
                .map { $0.point.id } ?? [])
            let roadMatchActivityPlan = RecordedActivityPlanner.plan(
                trajectories: roadMatchTrajectories,
                since: startOfToday,
                visiblePointIDs: visibleRecentPointIDs)
            #if DEBUG
            PerformanceDiagnostics.count("Dataset.footprintRows", by: footprintRowCount)
            #endif
            var footprintOriginalIDSet = Set(footprintOriginalIDs)
            var resolvedOriginalIDs = Set<String>()
            var trajectorySnaps: [FootprintSnapshot]
            if let trajectoryResolution {
                #if DEBUG
                let result = PerformanceDiagnostics.measure(
                    "ResolvedSnapshot.build",
                    metadata: "points=\(trajectoryResolution.points.count)") {
                        Self.resolvedSnapshots(
                            from: trajectoryResolution.points,
                            matching: footprintOriginalIDSet)
                    }
                trajectorySnaps = result.snapshots
                resolvedOriginalIDs = result.matchedOriginalIDs
                PerformanceDiagnostics.count(
                    "FootprintSnapshot.uniqueMetadata", by: result.metadataCount)
                #else
                let result = Self.resolvedSnapshots(
                    from: trajectoryResolution.points,
                    matching: footprintOriginalIDSet)
                trajectorySnaps = result.snapshots
                resolvedOriginalIDs = result.matchedOriginalIDs
                #endif
            } else {
                let workoutSnaps = (try? TrajectoryRepository(container: container)
                    .loadWorkoutSnapshotsFallback()) ?? []
                trajectorySnaps = snaps.filter { $0.source == FootprintSource.gps.rawValue }
                    + workoutSnaps
                for index in snaps.indices
                    where snaps[index].source == FootprintSource.gps.rawValue {
                    resolvedOriginalIDs.insert(footprintOriginalIDs[index])
                }
            }
            // 原始 ID 只用于本轮去重，不再随 171 万个长期显示快照驻留。
            // 输出筛选条件与原实现相同，仍保持原始顺序。
            var displaySnaps: [FootprintSnapshot] = []
            displaySnaps.reserveCapacity(snaps.count + trajectorySnaps.count)
            for index in snaps.indices
                where !resolvedOriginalIDs.contains(footprintOriginalIDs[index]) {
                displaySnaps.append(snaps[index])
            }
            displaySnaps.append(contentsOf: trajectorySnaps)
            #if DEBUG
            PerformanceDiagnostics.measure("FootprintSnapshot.sort.shared") {
                displaySnaps.sort { $0.t < $1.t }
            }
            #else
            displaySnaps.sort { $0.t < $1.t }
            #endif

            let cal = Calendar.current
            var monthCursor = CalendarMonthCursor(calendar: cal)
            var seen = Set<Date>()
            var perYear: [Int: Int] = [:]
            var completedSourceCounts = FootprintSourceCounts()
            for s in displaySnaps {
                if monthCursor.advance(to: s.t), let start = monthCursor.interval?.start {
                    seen.insert(start)
                }
                completedSourceCounts.add(source: s.source)
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
            let completedSourceCountsResult = completedSourceCounts
            // 捕获不可变绑定，避免 Swift 6 把后台任务中的可变数组捕获判为
            // 潜在并发访问；Array 仍通过 CoW 共享同一底层 buffer。
            let completedDisplaySnaps = displaySnaps

            let snapCount = snaps.count
            let phaseOneAccepted = await MainActor.run { () -> Bool in
                let current = DataRevisionStore.snapshot()
                if current.trajectory != loadRevision.trajectory || current.place != loadRevision.place {
                    pendingReload = true
                }
                guard DataRevisionStore.displaySafetyRevision() == loadSafetyRevision else {
                    isLoading = false
                    pendingReload = false
                    scheduleReload()
                    return false
                }
                #if DEBUG
                let mainCommitStarted = CACurrentMediaTime()
                defer {
                    PerformanceDiagnostics.recordDuration(
                        "MapScreen.phase1.mainCommit",
                        milliseconds: (CACurrentMediaTime() - mainCommitStarted) * 1_000,
                        mainThread: true)
                }
                #endif
                reloadVersion += 1
                usesLaunchPreview = false
                displayedSafetyRevision = loadSafetyRevision
                displayedTrajectoryRevision = loadRevision.trajectory
                // 同一份已排序数组同时交给缓存与页面状态；Array 的 CoW 共享底层
                // buffer，避免主线程重复排序两次，元素及顺序完全不变。
                SnapshotCache.pointSnapshots = completedDisplaySnaps
                SnapshotCache.sourceCounts = completedSourceCountsResult
                SnapshotCache.pointSnapshotGeneration += 1
                SnapshotCache.monthStarts = months
                SnapshotCache.stats = completedStats
                SnapshotCache.dataRegion = region
                pointSnapshots = completedDisplaySnaps
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
                scheduleRoadMatching(
                    trajectories: roadMatchTrajectories,
                    activityPlan: roadMatchActivityPlan,
                    revision: loadRevision.trajectory)
                #if DEBUG
                PerformanceDiagnostics.event("mapSnapshotReady.post.MapScreen")
                #endif
                Task { @MainActor in
                    await Task.yield()
                    NotificationCenter.default.post(name: .mapSnapshotReady, object: nil)
                }
                appLog.info("[Load] 首屏快照就绪：足迹\(snapCount)，照片聚合转入后台")
                return true
            }
            guard phaseOneAccepted else { return }

            if let region {
                _ = StatsSnapshotStore.shared.saveSummary(
                    completedStats, revision: loadRevision)
                _ = MapDisplaySnapshotStore.shared.save(
                    points: completedDisplaySnaps, months: months, region: region,
                    stats: completedStats, revision: loadRevision, safetyRevision: loadSafetyRevision)
            }

            // phase 1 的长期数组已由 SnapshotCache/@State 以 CoW 共享。显式释放
            // 构建用数组与交集集合，避免 Debug 真机把它们的生命周期延长到照片
            // 索引结束；这不改变缓存或页面持有的显示快照。
            snaps.removeAll(keepingCapacity: false)
            trajectorySnaps.removeAll(keepingCapacity: false)
            resolvedOriginalIDs.removeAll(keepingCapacity: false)
            footprintOriginalIDSet.removeAll(keepingCapacity: false)
            footprintOriginalIDs.removeAll(keepingCapacity: false)

            // 阶段 2：照片索引不再阻塞 Logo 消失和地图首屏。
            let photoContext = ModelContext(container)
            photoContext.autosaveEnabled = false
            #if DEBUG
            let allPhotoRows = PerformanceDiagnostics.measure("SwiftData.photo.fetch") {
                (try? photoContext.fetch(FetchDescriptor<PhotoRecord>())) ?? []
            }
            #else
            let allPhotoRows = (try? photoContext.fetch(FetchDescriptor<PhotoRecord>())) ?? []
            #endif
            let phRows = allPhotoRows.filter { selectedScope.contains($0.timestamp) }
            #if DEBUG
            PerformanceDiagnostics.count("Dataset.photoRows", by: allPhotoRows.count)
            PerformanceDiagnostics.count("Dataset.filteredPhotoRows", by: phRows.count)
            let photoRowTotal = phRows.count
            let photoRegionTotal = phRows.filter { $0.regionState == 1 }.count
            #else
            let photoRowTotal = 0
            let photoRegionTotal = 0
            #endif
            let matchablePhotos = phRows.filter { $0.regionState == 1 }
            let photoByID = Dictionary(uniqueKeysWithValues: matchablePhotos.map {
                ($0.localIdentifier, $0)
            })
            let associationLookup = PhotoTrajectoryAssociationStore.shared.lookup(
                photos: matchablePhotos, safetyRevision: loadSafetyRevision)
            var associationRecords = associationLookup.reusableRecords
            let trailIndex: TrailIndex?
            if associationLookup.missingPhotoIDs.isEmpty {
                // An unchanged launch does not materialize a global TrailPoint array or index.
                trailIndex = nil
                trajectoryResolution = nil
                TrajectoryResolutionCache.shared.discardTransientValue(for: trajectoryRevision)
                #if DEBUG
                PerformanceDiagnostics.count("PhotoAssociation.cacheHit",
                                             by: associationLookup.matches.count)
                #endif
            } else {
                // Until TrailIndexTile lands, missing associations still use the exact global
                // matcher. Existing photos are supplied from the persisted association map.
                var trailPoints: [TrailPoint]
                if let trajectoryResolution {
                    trailPoints = trajectoryResolution.points.compactMap { resolved in
                        guard resolved.suppressedByTrajectoryID == nil else { return nil }
                        return TrailPoint(
                            lat: resolved.point.latitude, lon: resolved.point.longitude,
                            t: resolved.point.timestamp.timeIntervalSince1970,
                            source: resolved.source, trajectoryID: resolved.trajectoryID,
                            sessionID: resolved.sessionID, segmentID: resolved.segmentID,
                            horizontalAccuracy: resolved.point.horizontalAccuracy,
                            confidence: resolved.confidence,
                            originalPointID: resolved.point.id)
                    }
                } else {
                    trailPoints = displaySnaps.compactMap {
                        let source: TrajectorySource
                        if $0.source == FootprintSource.health.rawValue { source = .healthWorkout }
                        else if $0.source == FootprintSource.csv.rawValue,
                                $0.trajectoryID != nil { source = .imported }
                        else if $0.source == FootprintSource.gps.rawValue { source = .coreLocation }
                        else { return nil }
                        return TrailPoint(lat: $0.lat, lon: $0.lon,
                            t: $0.t.timeIntervalSince1970, source: source,
                            trajectoryID: $0.trajectoryID, sessionID: $0.sessionID,
                            segmentID: $0.segmentID)
                    }
                }
                trajectoryResolution = nil
                TrajectoryResolutionCache.shared.discardTransientValue(for: trajectoryRevision)
                #if DEBUG
                trailIndex = PerformanceDiagnostics.measure(
                    "TrailIndex.build", metadata: "points=\(trailPoints.count)") {
                        TrailIndex(points: trailPoints)
                    }
                PerformanceDiagnostics.count("PhotoAssociation.cacheMiss",
                                             by: associationLookup.missingPhotoIDs.count)
                #else
                trailIndex = TrailIndex(points: trailPoints)
                #endif
                trailPoints.removeAll(keepingCapacity: false)
            }
            var snapExact = 0, snapSnap = 0, snapInterp = 0, snapKept = 0
            func countSnap(_ result: TrailSnapResult) {
                switch result.kind {
                case .exact: snapExact += 1
                case .snapped: snapSnap += 1
                case .interpolated: snapInterp += 1
                case .kept: snapKept += 1
                }
            }
            func captureAssociation(_ photoID: String, _ result: TrailSnapResult) {
                guard let photo = photoByID[photoID] else { return }
                associationRecords[photoID] = PhotoTrajectoryAssociationRecord(
                    photo: photo, result: result)
            }
            #if DEBUG
            let clIndex = PerformanceDiagnostics.measure(
                "PhotoCluster.generation", metadata: "photos=\(phRows.count)") {
                    ClusterIndex.build(records: phRows, trails: trailIndex,
                        associations: associationLookup.matches,
                        onSnap: countSnap, onAssociation: captureAssociation)
                }
            #else
            let clIndex = ClusterIndex.build(records: phRows, trails: trailIndex,
                associations: associationLookup.matches,
                onSnap: countSnap, onAssociation: captureAssociation)
            #endif
            _ = PhotoTrajectoryAssociationStore.shared.save(
                records: associationRecords, safetyRevision: loadSafetyRevision)
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
                let current = DataRevisionStore.snapshot()
                guard current.photo == loadRevision.photo,
                      current.trajectory == loadRevision.trajectory,
                      current.place == loadRevision.place,
                      selectedScope == timeScope else {
                    isLoading = false
                    pendingReload = false
                    scheduleReload()
                    return
                }
                #if DEBUG
                let mainCommitStarted = CACurrentMediaTime()
                defer {
                    PerformanceDiagnostics.recordDuration(
                        "MapScreen.phase2.mainCommit",
                        milliseconds: (CACurrentMediaTime() - mainCommitStarted) * 1_000,
                        mainThread: true)
                }
                #endif
                // 照片聚合索引不改变派生图层（点/线由 phase 1 数据驱动），
                // 不再 bump reloadVersion，避免每次加载触发两轮无意义重算。
                SnapshotCache.clusterIndex = clIndex
                clusterIndex = clIndex
                let count = Double(max(0, months.count - 1))
                let visibleRegion = currentPhotoViewport
                let level = PhotoCluster.Level.level(for: visibleRegion.span.latitudeDelta)
                let initialClusters = ClusterIndex.adaptiveVisible(
                    clIndex, preferred: level, region: visibleRegion)
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
                MapStartupDiagnostics.shared.mark(.photoLayerReady)
                MapStartupDiagnostics.shared.mark(.backgroundRefreshComplete)
                #if DEBUG
                PerformanceDiagnostics.event("MapScreen.loadSnapshots.complete")
                #endif
                applyTestHooks(markerCount: clusterMarkers.count, sliderMax: count)
                if pendingReload {
                    pendingReload = false
                    scheduleReload()
                }
            }
        }
    }

    /// Photo positions are available independently of historical route processing.
    private func loadOriginalPhotoLayer() {
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        let container = context.container
        let scope = timeScope
        let revision = DataRevisionStore.snapshot().photo
        Task.detached(priority: .userInitiated) {
            let photoContext = ModelContext(container)
            photoContext.autosaveEnabled = false
            guard let rows = try? photoContext.fetch(FetchDescriptor<PhotoRecord>()) else { return }
            let index = ClusterIndex.build(records: rows.filter { scope.contains($0.timestamp) })
            await MainActor.run {
                guard generation == photoLoadGeneration,
                      revision == DataRevisionStore.snapshot().photo,
                      scope == timeScope else { return }
                clusterIndex = index
                SnapshotCache.clusterIndex = index
                let region = currentPhotoViewport
                let visible = ClusterIndex.adaptiveVisible(
                    index, preferred: .level(for: region.span.latitudeDelta), region: region)
                clusterLevel = visible.level
                clusterMarkers = visible.clusters
                markerToken += 1
                MapStartupDiagnostics.shared.mark(.photoLayerReady)
            }
        }
    }

    private var currentPhotoViewport: MKCoordinateRegion {
        guard let snapshot = navigation.mapCameraSnapshot else { return dataRegion ?? autoRegion }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: snapshot.latitude, longitude: snapshot.longitude),
            span: MKCoordinateSpan(latitudeDelta: snapshot.latitudeDelta,
                                   longitudeDelta: snapshot.longitudeDelta))
    }

    /// 数据变化后防抖重载
    private func scheduleReload() {
        reloadTask?.cancel()
        #if DEBUG
        PerformanceDiagnostics.count("MapScreen.reload.debounceScheduled")
        #endif
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            #if DEBUG
            PerformanceDiagnostics.count("MapScreen.reload.debounceFired")
            #endif
            loadSnapshots()
        }
    }

    // MARK: - 交互

    /// 纯净模式切换（两指点按地图 / 双击「地图」Tab 进入，单击地图恢复）。
    /// 提示 toast 由 onChange(of: chromeHidden) 统一处理，覆盖所有入口。
    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            chromeHidden.toggle()
        }
        appLog.info("[Chrome] 纯净模式=\(chromeHidden)")
    }

    private func resetNorth() {
        cameraCommand = .north(animated: !reduceMotion)
        appLog.info("[Camera] 朝向回正北")
    }

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        // 纯净模式下单击 → 恢复全部功能（不触发探索）
        if chromeHidden {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                chromeHidden = false
            }
            appLog.info("[Chrome] 单击恢复显示")
            return
        }
        // 普通地图点击不得打开 Review。Review 只由照片组的明确 tap 触发。
        appLog.debug("[Map] 普通点击不打开照片 Review: \(coord.latitude),\(coord.longitude)")
    }

    /// 地点级探索：直接按照片 id 集合浏览（网格内全部照片，随机起点）
    private func openExplore(ids: [String], clusterID: String = "map-selection", startAt: Int? = nil) {
        guard !ids.isEmpty else {
            showTapToast(String(localized: "该区域暂无照片"))
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
            showTapToast(String(localized: "该区域暂无照片"))
            return
        }
        let newSession = ExploreSession(level: level, regionName: name, context: context,
                                        source: .mapCluster(clusterID: clusterID))
        newSession.loadPhotos(for: name, startAt: startAt ?? Int.random(in: 0..<100_000))
        navigation.locationReviewSession = newSession
        if let centroid = PhotoStore.centroid(level: level, regionName: name, in: context) {
            cameraCommand = .region(
                region(centeredAt: centroid, distance: distance(for: level)),
                animated: !reduceMotion)
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
            navigationFocusPending = false
            return
        }
        showPhotos = true
        highlightedReviewPhoto = highlight
        followsUser = false
        headingFollowEnabled = false
        hasPositioned = true
        let region = highlight.focusRegion
        navigationFocusPending = true
        navigation.mapCameraSnapshot = MapCameraSnapshot(
            latitude: region.center.latitude, longitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
        // 回顾地点是一次明确的目的地聚焦：不沿用之前的全览尺度，
        // 直接展示照片位置周围约 1.2 km 的街区语境。
        cameraCommand = .region(region, animated: !reduceMotion)
        refreshNavigationPhotoClusters(for: highlight)
    }

    private func refreshNavigationPhotoClusters(for highlight: MapPhotoHighlight) {
        guard let index = clusterIndex else { return }
        let region = highlight.focusRegion
        let scope = timeScope
        let photoGeneration = photoLoadGeneration
        clusterViewportGeneration += 1
        let viewportGeneration = clusterViewportGeneration
        lastClusterCenter = region.center
        Task.detached(priority: .userInitiated) {
            let result = ClusterIndex.adaptiveVisible(
                index, preferred: .level(for: region.span.latitudeDelta), region: region)
            await MainActor.run {
                guard viewportGeneration == clusterViewportGeneration,
                      photoGeneration == photoLoadGeneration,
                      scope == timeScope,
                      navigation.mapPhotoHighlight?.requestID == highlight.requestID else { return }
                clusterLevel = result.level
                clusterMarkers = result.clusters
                markerToken += 1
            }
        }
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
            animated: !reduceMotion
        )
    }

    /// 相机距离 → 可视区域（跨度近似；用于原生地图相机指令）
    private func region(centeredAt coordinate: CLLocationCoordinate2D, distance: Double) -> MKCoordinateRegion {
        let delta = max(distance / 55_000, 0.001)
        return MKCoordinateRegion(center: coordinate,
                                  span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    private func showTapToast(_ text: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { tapToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { tapToast = nil }
        }
    }

    private func recenter() {
        guard let coord = LocationService.shared.location?.coordinate else {
            showTapToast(String(localized: "正在获取当前位置"))
            LocationService.shared.start()
            return
        }
        appLog.info("[Camera] 回到当前位置: \(String(format: "%.5f", coord.latitude)),\(String(format: "%.5f", coord.longitude))")
        headingFollowEnabled = false
        followsUser = true
        cameraCommand = .follow(coord, animated: !reduceMotion)
        revealLocationDetails()
    }

    private func followCurrentHeading() {
        guard LocationService.shared.location != nil else {
            showTapToast(String(localized: "正在获取当前位置"))
            LocationService.shared.start()
            return
        }
        headingFollowEnabled = true
        followsUser = true
        cameraCommand = .userTracking(followHeading: true, animated: !reduceMotion)
        revealLocationDetails()
        appLog.info("[Camera] 双击定位 → 开启位置与指南针朝向跟随")
    }

    private func revealLocationDetails() {
        locationDetailsTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            locationDetailsVisible = true
        }
        locationDetailsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    locationDetailsVisible = false
                }
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
           ["standard", MapBasePresentation.quietMapType, "satellite", "topographic"].contains(mapType) {
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
