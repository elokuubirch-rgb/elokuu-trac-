import SwiftUI
import MapKit
import UIKit

/// 专业等高线底图配置。Key 通过 Info.plist 构建设置注入，不写死在源码。
enum TopographicMapConfiguration {
    static var apiKey: String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["MAPTILER_API_KEY"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value != "$(MAPTILER_API_KEY)" else { return nil }
        return value
    }

    static var mapID: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MapTilerMapID") as? String
        return value?.isEmpty == false ? value! : "outdoor-v4"
    }

    /// Outdoor v4 包含真实等高线、阴影地形、步道与自然地物。
    static var tileURLTemplate: String? {
        guard let apiKey else { return nil }
        let escapedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        return "https://api.maptiler.com/maps/\(mapID)/256/{z}/{x}/{y}@2x.png?key=\(escapedKey)"
    }
}

#if DEBUG
/// 真机诊断：把地图关键事件写入 Documents/map_debug.txt（devicectl copy 取回）
enum MapDebugLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("map_debug.txt")
    static func log(_ s: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
#endif

// MARK: - 相机指令（SwiftUI → MKMapView 单向命令；不双向绑定，避免状态循环）

enum MapCameraCommand: Equatable {
    case none
    case region(MKCoordinateRegion, animated: Bool)
    case follow(CLLocationCoordinate2D, animated: Bool)
    /// 只移动地图中心，不改变缩放（用于「聚焦某张照片但保留周围所有照片标记」）。
    case center(CLLocationCoordinate2D, animated: Bool)
    case userTracking(followHeading: Bool, animated: Bool)
    case pitch(Double, animated: Bool)

    static func == (l: MapCameraCommand, r: MapCameraCommand) -> Bool {
        switch (l, r) {
        case (.none, .none): return true
        case (.region(let lr, let la), .region(let rr, let ra)):
            return la == ra
                && abs(lr.center.latitude - rr.center.latitude) < 0.0001
                && abs(lr.center.longitude - rr.center.longitude) < 0.0001
                && abs(lr.span.latitudeDelta - rr.span.latitudeDelta) < 0.0001
                && abs(lr.span.longitudeDelta - rr.span.longitudeDelta) < 0.0001
        case (.follow(let lc, let la), .follow(let rc, let ra)):
            return la == ra
                && abs(lc.latitude - rc.latitude) < 0.0001
                && abs(lc.longitude - rc.longitude) < 0.0001
        case (.center(let lc, let la), .center(let rc, let ra)):
            return la == ra
                && abs(lc.latitude - rc.latitude) < 0.0001
                && abs(lc.longitude - rc.longitude) < 0.0001
        case (.userTracking(let lh, let la), .userTracking(let rh, let ra)):
            return lh == rh && la == ra
        case (.pitch(let lp, let la), .pitch(let rp, let ra)):
            return la == ra && abs(lp - rp) < 0.1
        default: return false
        }
    }
}

/// 通用 XYZ/TMS 瓦片源；支持 {s} 子域、{r} Retina 占位符。
final class ConfiguredTileOverlay: MKTileOverlay {
    private let source: CustomMapSource
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1_024 * 1_024,
                                          diskCapacity: 512 * 1_024 * 1_024,
                                          diskPath: "custom-map-tiles")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    init(source: CustomMapSource) {
        self.source = source
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = source.minimumZoom
        maximumZ = source.maximumZoom
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let y = source.scheme == .tms ? (1 << path.z) - 1 - path.y : path.y
        let subdomains = ["a", "b", "c"]
        let subdomain = subdomains[abs(path.x + y) % subdomains.count]
        let retina = UIScreen.main.scale > 1 ? "@2x" : ""
        let value = source.urlTemplate
            .replacingOccurrences(of: "{z}", with: String(path.z))
            .replacingOccurrences(of: "{x}", with: String(path.x))
            .replacingOccurrences(of: "{y}", with: String(y))
            .replacingOccurrences(of: "{s}", with: subdomain)
            .replacingOccurrences(of: "{r}", with: retina)
        return URL(string: value)!
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, (any Error)?) -> Void) {
        let request = URLRequest(url: url(forTilePath: path),
                                 cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 20)
        Self.session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                result(nil, URLError(.badServerResponse))
            } else {
                result(data, error)
            }
        }.resume()
    }
}

// MARK: - 标记画布（透明 UIView 盖在地图上；mapView.convert 实时换算屏幕坐标，
// 规避 iOS 26 MKOverlayRenderer point(for:) 坐标 bug；UIKit 坐标系 100% 可控）

final class MarkerCanvasView: UIView {
    weak var mapView: MKMapView?
    var dots: [FootprintDot] = [] { didSet { setNeedsDisplay() } }
    var routes: [RouteLine] = [] { didSet { setNeedsDisplay() } }
    var clusters: [PhotoCluster] = [] { didSet { setNeedsDisplay() } }
    var showDots = true
    var showLines = true
    var dotColor: UIColor = .systemRed
    /// 交互中优先保证底图、路线和照片的缩放跟手性。
    /// 方向箭头需要遍历所有路线坐标，在松手后再恢复即可。
    var isMapInteracting = false

    /// 跨级过渡（Spatial Morphing）
    private var transitionFrom: [PhotoCluster] = []
    private var transitionStart: Date?
    private let transitionDuration: TimeInterval = 0.25
    private var transitionTimer: Timer?

    private var imageCache: [String: UIImage] = [:]
    private var badgeCache: [String: UIImage] = [:]
    private var failedIDs: Set<String> = []
    private var loadingIDs: Set<String> = []
    /// 实际画到屏幕上的标记，命中测试必须与视觉去重结果一致。
    private var renderedClusters: [PhotoCluster] = []
    private let markerSize: CGFloat = 54

    /// 拖动跟随：拖动期间 CADisplayLink 每帧重绘，
    /// 保证点和照片标记实时钉在地理坐标上（规避 iOS 26 拖动中 region 回调压缩）
    private var followLink: CADisplayLink?
    private var followActive = false

    func setFollow(_ active: Bool) {
        guard active != followActive else { return }
        followActive = active
        if active {
            let link = CADisplayLink(target: self, selector: #selector(followTick))
            link.add(to: .main, forMode: .common)
            followLink = link
        } else {
            followLink?.invalidate()
            followLink = nil
        }
    }

    @objc private func followTick() {
        setNeedsDisplay()
    }

    func setClusters(_ new: [PhotoCluster], animate: Bool) {
        #if DEBUG
        MapDebugLog.log("canvas setClusters: \(new.count) 个 动画=\(animate)")
        #endif
        if animate, !clusters.isEmpty {
            transitionFrom = clusters
            transitionStart = Date()
            transitionTimer?.invalidate()
            transitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let s = self.transitionStart,
                   Date().timeIntervalSince(s) >= self.transitionDuration {
                    self.transitionTimer?.invalidate()
                    self.transitionTimer = nil
                    self.transitionFrom = []
                    self.transitionStart = nil
                }
                self.setNeedsDisplay()
            }
        }
        clusters = new
        preloadThumbnails()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let mapView else { return }
        #if DEBUG
        let drawStartedAt = CACurrentMediaTime()
        defer { canvasDiag(durationMS: (CACurrentMediaTime() - drawStartedAt) * 1_000) }
        #endif
        // 运动地图方向提示：稀疏绘制，帮助快速读懂路线走向。
        if showLines && !isMapInteracting {
            drawRouteDirections(mapView: mapView)
        }
        // 足迹点（专业运动路点：深色外圈 + 浅色精密描边 + 主题色核心）
        if showDots { drawDots(mapView: mapView) }
        // 照片聚合标记（缩略图 + 左下角白色数量）
        var transitionProgress: CGFloat?
        if let start = transitionStart {
            let linear = min(1, Date().timeIntervalSince(start) / transitionDuration)
            transitionProgress = CGFloat(linear * linear * (3 - 2 * linear))
        }
        let oldLayout = layoutClusters(transitionFrom, mapView: mapView)
        let newLayout = layoutClusters(clusters, mapView: mapView)
        renderedClusters = newLayout.map(\.cluster)
        if let transitionProgress {
            drawMorphingClusters(from: oldLayout, to: newLayout,
                                 progress: transitionProgress, mapView: mapView)
        } else {
            drawClusters(newLayout, alpha: 1, scale: 1, mapView: mapView)
        }
    }

    private var lastCanvasLog = Date.distantPast

    /// 把逐点 UIBezierPath 分配改为按频次批量填充 CGContext path。
    private func drawDots(mapView: MKMapView) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var pointsByFrequency = Array(repeating: [CGPoint](), count: 4)
        let visibleBounds = bounds.insetBy(dx: -20, dy: -20)
        for dot in dots {
            let point = mapView.convert(CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon),
                                        toPointTo: self)
            guard visibleBounds.contains(point) else { continue }
            pointsByFrequency[min(max(dot.freq, 1), 4) - 1].append(point)
        }

        let sizes: [CGFloat] = [6, 7.5, 9, 11]
        let opacities: [CGFloat] = [0.72, 0.85, 0.95, 1]
        for index in pointsByFrequency.indices where !pointsByFrequency[index].isEmpty {
            let points = pointsByFrequency[index]
            let size = sizes[index]
            if index >= 2 {
                fillCircles(points, radius: size,
                            color: dotColor.withAlphaComponent(index == 3 ? 0.22 : 0.12),
                            context: ctx)
            }
            fillCircles(points, radius: size * 0.72,
                        color: UIColor.black.withAlphaComponent(0.72), context: ctx)
            fillCircles(points, radius: size * 0.55,
                        color: UIColor.white.withAlphaComponent(0.9), context: ctx)
            fillCircles(points, radius: size * 0.38,
                        color: dotColor.withAlphaComponent(opacities[index]), context: ctx)
        }
    }

    private func fillCircles(_ points: [CGPoint], radius: CGFloat, color: UIColor,
                             context ctx: CGContext) {
        ctx.beginPath()
        for point in points {
            ctx.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: radius * 2, height: radius * 2))
        }
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    /// 每条可见路线约每 110pt 放置一个小箭头，整屏最多 48 个，避免复杂轨迹显得嘈杂。
    private func drawRouteDirections(mapView: MKMapView) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let spacing: CGFloat = 110
        var arrowCount = 0
        for route in routes where route.coords.count >= 2 {
            var distanceSinceArrow: CGFloat = 55
            var previous = mapView.convert(route.coords[0], toPointTo: self)
            for coordinate in route.coords.dropFirst() {
                let current = mapView.convert(coordinate, toPointTo: self)
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                let segmentLength = hypot(dx, dy)
                guard segmentLength.isFinite, segmentLength > 1 else {
                    previous = current
                    continue
                }
                var travelled = spacing - distanceSinceArrow
                while travelled <= segmentLength, arrowCount < 48 {
                    let t = travelled / segmentLength
                    let point = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
                    if bounds.insetBy(dx: 16, dy: 16).contains(point) {
                        drawDirectionChevron(at: point, angle: atan2(dy, dx), context: ctx)
                        arrowCount += 1
                    }
                    travelled += spacing
                }
                distanceSinceArrow = (distanceSinceArrow + segmentLength)
                    .truncatingRemainder(dividingBy: spacing)
                previous = current
                if arrowCount >= 48 { return }
            }
        }
    }

    private func drawDirectionChevron(at point: CGPoint, angle: CGFloat, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)
        let outer = UIBezierPath()
        outer.move(to: CGPoint(x: 6, y: 0))
        outer.addLine(to: CGPoint(x: -4.5, y: -5.5))
        outer.addLine(to: CGPoint(x: -2, y: 0))
        outer.addLine(to: CGPoint(x: -4.5, y: 5.5))
        outer.close()
        UIColor.black.withAlphaComponent(0.84).setFill()
        outer.fill()

        let inner = UIBezierPath()
        inner.move(to: CGPoint(x: 3.8, y: 0))
        inner.addLine(to: CGPoint(x: -2.3, y: -3.1))
        inner.addLine(to: CGPoint(x: -0.8, y: 0))
        inner.addLine(to: CGPoint(x: -2.3, y: 3.1))
        inner.close()
        UIColor.white.withAlphaComponent(0.95).setFill()
        inner.fill()
        ctx.restoreGState()
    }
    private func canvasDiag(durationMS: Double) {
        let now = Date()
        if now.timeIntervalSince(lastCanvasLog) > 5 {
            lastCanvasLog = now
            let routePointCount = routes.reduce(0) { $0 + $1.coords.count }
            MapDebugLog.log("canvas draw: \(String(format: "%.1f", durationMS))ms "
                            + "点\(dots.count) 路线坐标\(routePointCount) 标记\(clusters.count) "
                            + "交互=\(isMapInteracting) frame=\(bounds.size)")
        }
    }

    private typealias ClusterLayout = (cluster: PhotoCluster, point: CGPoint, anchor: CGPoint)

    /// 同一屏幕优先保留照片数多的地点集合，避免缩略图互相覆盖。
    private func layoutClusters(_ list: [PhotoCluster], mapView: MKMapView) -> [ClusterLayout] {
        let minimumDistance = Self.markerSize(for: mapView.region.span.latitudeDelta) + 10
        var accepted: [ClusterLayout] = []
        let prioritized = list.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }
        for cluster in prioritized {
            let anchor = mapView.convert(cluster.coordinate, toPointTo: self)
            let size = Self.markerSize(for: mapView.region.span.latitudeDelta)
            // 卡片上移、底部用短针脚连接真实地理坐标，让路线不会被缩略图中心遮断。
            let point = CGPoint(x: anchor.x, y: anchor.y - size * 0.65)
            guard bounds.insetBy(dx: -80, dy: -80).contains(point) else { continue }
            guard accepted.allSatisfy({ hypot($0.point.x - point.x, $0.point.y - point.y) >= minimumDistance }) else {
                continue
            }
            accepted.append((cluster, point, anchor))
        }
        return accepted
    }

    private func drawClusters(_ list: [ClusterLayout], alpha: CGFloat, scale: CGFloat, mapView: MKMapView) {
        guard alpha > 0.01, !list.isEmpty else { return }
        // 苹果地图照片预览大小逻辑：标记随缩放连续变化（全国小 → 最近大）
        let span = mapView.region.span.latitudeDelta
        for item in list {
            drawSingleMarker(item.cluster, at: item.point, anchoredAt: item.anchor,
                             alpha: alpha, scale: scale, span: span)
        }
    }

    /// 跨聚合级别时，让子标记从最近父标记的位置展开，父标记再向最近子标记收拢。
    /// 超过合理屏幕距离则只做淡入淡出，避免跨城市标记横穿屏幕。
    private func drawMorphingClusters(from old: [ClusterLayout], to new: [ClusterLayout],
                                      progress: CGFloat, mapView: MKMapView) {
        let maxLinkDistance: CGFloat = 280
        func nearest(to point: CGPoint, in candidates: [ClusterLayout]) -> ClusterLayout? {
            candidates.min {
                hypot($0.point.x - point.x, $0.point.y - point.y)
                    < hypot($1.point.x - point.x, $1.point.y - point.y)
            }
        }
        func interpolate(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * progress,
                    y: a.y + (b.y - a.y) * progress)
        }

        let span = mapView.region.span.latitudeDelta
        for item in old {
            let target = nearest(to: item.point, in: new)
            let linked = target.map { hypot($0.point.x - item.point.x, $0.point.y - item.point.y) <= maxLinkDistance } ?? false
            let point = linked ? interpolate(item.point, target!.point) : item.point
            let anchor = linked ? interpolate(item.anchor, target!.anchor) : item.anchor
            drawSingleMarker(item.cluster, at: point, anchoredAt: anchor,
                             alpha: 1 - progress, scale: 1 - 0.16 * progress, span: span)
        }
        for item in new {
            let source = nearest(to: item.point, in: old)
            let linked = source.map { hypot($0.point.x - item.point.x, $0.point.y - item.point.y) <= maxLinkDistance } ?? false
            let point = linked ? interpolate(source!.point, item.point) : item.point
            let anchor = linked ? interpolate(source!.anchor, item.anchor) : item.anchor
            drawSingleMarker(item.cluster, at: point, anchoredAt: anchor,
                             alpha: progress, scale: 0.84 + 0.16 * progress, span: span)
        }
    }

    /// 远景 36pt → 近景 58pt，保持照片缩略图始终可辨识。
    static func markerSize(for span: Double) -> CGFloat {
        let t = (log10(max(span, 0.001)) - log10(0.001)) / (log10(8) - log10(0.001))
        return 58 - min(max(t, 0), 1) * 22
    }

    /// 单图标记（所有层级统一样式）：照片 + 白色描边 + 数量角标
    /// 圆角按标记尺寸等比（15%）——缩小不变圆、放大不过度圆角
    private func drawSingleMarker(_ c: PhotoCluster, at p: CGPoint, anchoredAt anchor: CGPoint,
                                  alpha: CGFloat,
                                  scale: CGFloat, span: Double) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let size = Self.markerSize(for: span) * scale
        let frame = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        let radius = size * 0.15
        ctx.saveGState()
        ctx.setAlpha(alpha)
        // 地理锚点：运动路线节点 + 短连接针，明确照片组属于哪一段路线。
        let stemTop = CGPoint(x: anchor.x, y: frame.maxY - 1)
        let stem = UIBezierPath()
        stem.move(to: stemTop)
        stem.addLine(to: anchor)
        stem.lineCapStyle = .round
        UIColor.black.withAlphaComponent(0.78).setStroke()
        stem.lineWidth = 5
        stem.stroke()
        UIColor.white.withAlphaComponent(0.9).setStroke()
        stem.lineWidth = 2
        stem.stroke()
        dotColor.withAlphaComponent(0.2).setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 7, y: anchor.y - 7, width: 14, height: 14)).fill()
        UIColor.black.withAlphaComponent(0.8).setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10)).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 3.5, y: anchor.y - 3.5, width: 7, height: 7)).fill()
        dotColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 2.4, y: anchor.y - 2.4, width: 4.8, height: 4.8)).fill()
        // 多张照片用两层微偏移卡片表达“集合”，单张则保持简洁。
        if c.count > 1 {
            for offset in stride(from: 2, through: 1, by: -1) {
                let back = frame.offsetBy(dx: CGFloat(offset) * 2.5, dy: CGFloat(offset) * -2.5)
                UIColor.white.withAlphaComponent(offset == 2 ? 0.45 : 0.75).setFill()
                UIBezierPath(roundedRect: back, cornerRadius: radius).fill()
            }
        }
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        if let img = thumbnail(for: c) {
            img.draw(in: frame)
        } else {
            UIColor(red: 0.2, green: 0.24, blue: 0.34, alpha: 1).setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: radius).fill()
        }
        UIColor.white.setStroke()
        let border = UIBezierPath(roundedRect: frame, cornerRadius: radius)
        border.lineWidth = 2
        border.stroke()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if c.count > 1, let badge = badgeImage(for: c.count) {
            badge.draw(at: CGPoint(x: frame.minX + 1, y: frame.maxY - badge.size.height - 1))
        }
        ctx.restoreGState()
    }

    // MARK: 缩略图（文件优先 → 随机候选 PH 异步取图；同一聚合只请求一次）

    private func thumbnail(for c: PhotoCluster) -> UIImage? {
        if let img = imageCache[c.id] { return img }
        if failedIDs.contains(c.id) { return nil }
        if let path = c.thumbPath, let img = UIImage(contentsOfFile: path) {
            let rounded = Self.rounded(img, size: markerSize)
            imageCache[c.id] = rounded
            return rounded
        }
        if let samples = c.sampleIds, !samples.isEmpty, !loadingIDs.contains(c.id) {
            let clusterID = c.id
            loadingIDs.insert(clusterID)
            Task.detached(priority: .utility) {
                var got: UIImage?
                for id in samples.prefix(3) {
                    if let img = await PhotoThumbnailGenerator.image(localID: id) {
                        got = img
                        break
                    }
                }
                let loadedImage = got
                await MainActor.run {
                    self.loadingIDs.remove(clusterID)
                    if let img = loadedImage {
                        self.imageCache[clusterID] = Self.rounded(img, size: 44)
                    } else {
                        self.failedIDs.insert(clusterID)
                    }
                    self.setNeedsDisplay()
                }
            }
        }
        return nil
    }

    private func preloadThumbnails() {
        for c in clusters where imageCache[c.id] == nil && !failedIDs.contains(c.id) {
            guard let path = c.thumbPath else { continue }
            let clusterID = c.id
            Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
                await MainActor.run {
                    guard let image = UIImage(data: data) else { return }
                    self.imageCache[clusterID] = Self.rounded(image, size: 44)
                    self.setNeedsDisplay()
                }
            }
        }
    }

    private static func rounded(_ image: UIImage, size: CGFloat, radius: CGFloat = 12) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            image.draw(in: rect)
        }
    }

    /// 数量角标（白字深底圆角，按数量缓存）
    private func badgeImage(for count: Int) -> UIImage? {
        let key = String(count)
        if let img = badgeCache[key] { return img }
        let text = key as NSString
        let font = UIFont.systemFont(ofSize: 12, weight: .bold)
        let textSize = text.size(withAttributes: [.font: font])
        let w = textSize.width + 12
        let h = textSize.height + 5
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { _ in
            let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: h / 2)
            UIColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
            text.draw(at: CGPoint(x: 6, y: 2.5),
                      withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
        badgeCache[key] = img
        return img
    }

    /// 命中测试严格跟随屏幕上照片卡片的真实边界。
    /// 旧实现使用“半径 + 12pt”的圆，会把卡片四周大片地图误判为照片。
    func hitCluster(at point: CGPoint) -> PhotoCluster? {
        guard let mapView else { return nil }
        return renderedClusters.compactMap { cluster -> (PhotoCluster, CGFloat)? in
            let anchor = mapView.convert(cluster.coordinate, toPointTo: self)
            let size = Self.markerSize(for: mapView.region.span.latitudeDelta)
            let projected = CGPoint(x: anchor.x, y: anchor.y - size * 0.65)
            let frame = CGRect(x: projected.x - size / 2,
                               y: projected.y - size / 2,
                               width: size, height: size).insetBy(dx: -2, dy: -2)
            guard UIBezierPath(roundedRect: frame, cornerRadius: size * 0.15).contains(point) else {
                return nil
            }
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            return (cluster, distance)
        }.min { $0.1 < $1.1 }?.0
    }
}

// MARK: - MapKit 原生照片标注 / 足迹点覆盖层

/// 照片必须使用 MKAnnotationView，让 MapKit 在拖动、惯性和缩放时
/// 与底图共享同一个 presentation transform，避免外置 UIView 投影慢一帧。
final class PhotoClusterAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let cluster: PhotoCluster

    init(cluster: PhotoCluster) {
        self.cluster = cluster
        coordinate = cluster.coordinate
        super.init()
    }
}

final class PhotoClusterAnnotationView: MKAnnotationView {
    private var photoCluster: PhotoCluster?
    private var thumbnail: UIImage?
    private var loadID = UUID()
    private var markerSize: CGFloat = 44

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        isOpaque = false
        collisionMode = .rectangle
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadID = UUID()
        photoCluster = nil
        thumbnail = nil
    }

    func configure(annotation: PhotoClusterAnnotation, size: CGFloat) {
        self.annotation = annotation
        photoCluster = annotation.cluster
        displayPriority = MKFeatureDisplayPriority(
            min(1_000, 650 + Float(log10(Double(max(annotation.cluster.count, 1)))) * 110)
        )
        setMarkerSize(size)
        loadThumbnail(for: annotation.cluster)
    }

    func setMarkerSize(_ size: CGFloat) {
        guard abs(markerSize - size) > 0.35 || bounds.isEmpty else { return }
        markerSize = size
        let height = size * 1.72
        bounds = CGRect(x: 0, y: 0, width: size + 14, height: height)
        centerOffset = CGPoint(x: 0, y: -height / 2 + 2)
        setNeedsDisplay()
    }

    private func loadThumbnail(for cluster: PhotoCluster) {
        thumbnail = nil
        let requestID = UUID()
        loadID = requestID
        let path = cluster.thumbPath
        let samples = cluster.sampleIds ?? []
        Task.detached(priority: .utility) {
            var image: UIImage?
            // 1) 封面缓存文件（Caches 可能被系统清理；读取失败必须回退，不得永久空白）
            if let path, let fileImage = UIImage(contentsOfFile: path) {
                image = fileImage
            }
            // 2) 组内样本 PH 回退：全部尝试，任一张可用即作为封面
            if image == nil {
                for id in samples {
                    if let candidate = await PhotoThumbnailGenerator.image(localID: id) {
                        image = candidate
                        break
                    }
                }
            }
            #if DEBUG
            if image == nil {
                MapDebugLog.log("cluster 封面加载失败 id=\(cluster.id) count=\(cluster.count) thumb=\(path ?? "nil") samples=\(samples.count)")
            }
            #endif
            let loadedImage = image
            await MainActor.run { [weak self] in
                guard let self, self.loadID == requestID else { return }
                self.thumbnail = loadedImage
                self.setNeedsDisplay()
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let cluster = photoCluster, let ctx = UIGraphicsGetCurrentContext() else { return }
        let size = markerSize
        let card = CGRect(x: (bounds.width - size) / 2, y: 4, width: size, height: size)
        let radius = size * 0.15
        let anchor = CGPoint(x: bounds.midX, y: bounds.maxY - 5)

        ctx.saveGState()
        let stem = UIBezierPath()
        stem.move(to: CGPoint(x: card.midX, y: card.maxY - 1))
        stem.addLine(to: anchor)
        stem.lineCapStyle = .round
        UIColor.black.withAlphaComponent(0.78).setStroke()
        stem.lineWidth = 5
        stem.stroke()
        UIColor.white.withAlphaComponent(0.92).setStroke()
        stem.lineWidth = 2
        stem.stroke()

        UIColor.systemRed.withAlphaComponent(0.22).setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 7, y: anchor.y - 7, width: 14, height: 14)).fill()
        UIColor.black.withAlphaComponent(0.82).setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10)).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 3.5, y: anchor.y - 3.5, width: 7, height: 7)).fill()
        UIColor.systemRed.setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - 2.4, y: anchor.y - 2.4, width: 4.8, height: 4.8)).fill()

        if cluster.count > 1 {
            for offset in stride(from: 2, through: 1, by: -1) {
                let back = card.offsetBy(dx: CGFloat(offset) * 2.5, dy: CGFloat(offset) * -2.2)
                UIColor(white: 0.16, alpha: offset == 2 ? 0.55 : 0.75).setFill()
                UIBezierPath(roundedRect: back, cornerRadius: radius).fill()
            }
        }
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 7,
                      color: UIColor.black.withAlphaComponent(0.32).cgColor)
        UIBezierPath(roundedRect: card, cornerRadius: radius).addClip()
        if let thumbnail {
            let scale = max(card.width / thumbnail.size.width, card.height / thumbnail.size.height)
            let drawSize = CGSize(width: thumbnail.size.width * scale,
                                  height: thumbnail.size.height * scale)
            thumbnail.draw(in: CGRect(x: card.midX - drawSize.width / 2,
                                      y: card.midY - drawSize.height / 2,
                                      width: drawSize.width, height: drawSize.height))
        } else {
            // 加载失败：中性灰占位，不叠白描边（避免“空相框”观感）。
            UIColor(white: 0.30, alpha: 1).setFill()
            UIBezierPath(roundedRect: card, cornerRadius: radius).fill()
        }
        ctx.restoreGState()

        if cluster.count > 1 {
            let text = String(cluster.count) as NSString
            let font = UIFont.systemFont(ofSize: max(10, size * 0.22), weight: .bold)
            let textSize = text.size(withAttributes: [.font: font])
            let badge = CGRect(x: card.minX + 2, y: card.maxY - textSize.height - 8,
                               width: textSize.width + 10, height: textSize.height + 5)
            UIColor.black.withAlphaComponent(0.62).setFill()
            UIBezierPath(roundedRect: badge, cornerRadius: badge.height / 2).fill()
            text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 2),
                      withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
}

final class FootprintDotsOverlay: NSObject, MKOverlay {
    let dots: [FootprintDot]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(dots: [FootprintDot]) {
        self.dots = dots
        var rect = MKMapRect.null
        for dot in dots {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon))
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        boundingMapRect = rect.isNull ? MKMapRect.world : rect
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        super.init()
    }
}

final class FootprintDotsRenderer: MKOverlayRenderer {
    private let dotsOverlay: FootprintDotsOverlay
    var color: UIColor

    init(overlay: FootprintDotsOverlay, color: UIColor) {
        dotsOverlay = overlay
        self.color = color
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let expanded = mapRect.insetBy(dx: -16 / Double(zoomScale), dy: -16 / Double(zoomScale))
        var groups = Array(repeating: [CGPoint](), count: 4)
        for dot in dotsOverlay.dots {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon))
            guard expanded.contains(mapPoint) else { continue }
            groups[min(max(dot.freq, 1), 4) - 1].append(point(for: mapPoint))
        }
        let sizes: [CGFloat] = [6, 7.5, 9, 11]
        let opacities: [CGFloat] = [0.72, 0.85, 0.95, 1]
        for index in groups.indices where !groups[index].isEmpty {
            let points = groups[index]
            let size = sizes[index] / zoomScale
            if index >= 2 {
                fill(points, radius: size, color: color.withAlphaComponent(index == 3 ? 0.22 : 0.12),
                     context: context)
            }
            fill(points, radius: size * 0.72, color: UIColor.black.withAlphaComponent(0.72), context: context)
            fill(points, radius: size * 0.55, color: UIColor.white.withAlphaComponent(0.9), context: context)
            fill(points, radius: size * 0.38, color: color.withAlphaComponent(opacities[index]), context: context)
        }
    }

    private func fill(_ points: [CGPoint], radius: CGFloat, color: UIColor, context: CGContext) {
        context.beginPath()
        for point in points {
            context.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}

// MARK: - 专业路线 overlay（一条逻辑路线只创建一个 overlay）

struct MapLineStrokeStyle: Equatable {
    let alpha: CGFloat
    let width: CGFloat
    let tone: Tone

    enum Tone: Equatable {
        case casing, glow, theme
    }
}

struct ProfessionalLineStyle: Equatable {
    let tag: Int // 0=历史轨迹，1=实时轨迹，3=Health workout
    let casing: MapLineStrokeStyle
    let glow: MapLineStrokeStyle
    let core: MapLineStrokeStyle

    static func make(alpha: CGFloat, width: CGFloat, tag: Int) -> Self {
        Self(
            tag: tag,
            casing: MapLineStrokeStyle(
                alpha: tag == 0 ? 0.34 : min(0.82, 0.5 + alpha * 0.3),
                width: tag == 0 ? width + 2.4 : width + 4.2,
                tone: .casing),
            glow: MapLineStrokeStyle(
                alpha: tag == 0 ? 0.05 : 0.12 + alpha * 0.08,
                width: tag == 0 ? width + 4 : width + 8,
                tone: .glow),
            core: MapLineStrokeStyle(
                alpha: tag == 0 ? min(alpha, 0.52) : max(alpha, 0.82),
                width: tag == 0 ? min(width, 2.0) : max(width, 2.8),
                tone: .theme))
    }
}

enum MapOverlayAmplificationPolicy {
    static func overlayCount(forLogicalRouteCount count: Int) -> Int { count }
    static func polylineCount(forLogicalRouteCount _: Int) -> Int { 0 }
}

struct MapRoutePresentationState: Equatable {
    let id: String
    let fingerprint: UInt64
}

struct MapPresentationDiff: Equatable {
    let added: [String]
    let removed: [String]
    let changed: [String]
    let unchanged: [String]

    static func make(current: [MapRoutePresentationState],
                     desired: [MapRoutePresentationState]) -> Self {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.fingerprint) })
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0.fingerprint) })
        return Self(
            added: desired.compactMap { currentByID[$0.id] == nil ? $0.id : nil },
            removed: current.compactMap { desiredByID[$0.id] == nil ? $0.id : nil },
            changed: desired.compactMap {
                guard let old = currentByID[$0.id], old != $0.fingerprint else { return nil }
                return $0.id
            },
            unchanged: desired.compactMap {
                currentByID[$0.id] == $0.fingerprint ? $0.id : nil
            })
    }
}

enum MapPresentationBatchPolicy {
    static let targetMainThreadMilliseconds = 5.0

    static func nextBatchSize(previous: Int, elapsedMilliseconds: Double) -> Int {
        guard elapsedMilliseconds > 0 else { return min(previous * 2, 512) }
        let ratio = targetMainThreadMilliseconds / elapsedMilliseconds
        return min(512, max(8, Int((Double(previous) * ratio).rounded())))
    }
}

struct ZoomAwareRouteGeometry {
    struct Level {
        let maximumMapPointError: Double
        let points: [MKMapPoint]
    }

    /// 误差按 screen point 约束；比 1px（@3x）更保守。
    static let maximumScreenPointError = 0.25
    static let mapPointTolerances: [Double] = [
        16, 64, 256, 1_024, 4_096, 16_384, 65_536, 262_144
    ]

    let rawPoints: [MKMapPoint]
    let levels: [Level]

    init(coordinates: [CLLocationCoordinate2D]) {
        let raw = coordinates.map(MKMapPoint.init)
        rawPoints = raw
        guard raw.count > 2, !Self.crossesWorldWrap(raw) else {
            levels = []
            return
        }
        var generated: [Level] = []
        var lastStoredCount = raw.count
        for tolerance in Self.mapPointTolerances {
            let simplified = Self.simplify(raw, tolerance: tolerance)
            // 只保留有实质收益的层级，避免 GPS 噪声使多个近似 raw 数组常驻内存。
            // 跳过层级只会让 renderer 继续使用更精细 geometry，不会扩大误差。
            guard simplified.count * 100 <= lastStoredCount * 65 else { continue }
            generated.append(Level(maximumMapPointError: tolerance, points: simplified))
            lastStoredCount = simplified.count
        }
        levels = generated
    }

    func level(for zoomScale: MKZoomScale) -> Level {
        let scale = max(Double(zoomScale), Double.leastNonzeroMagnitude)
        let allowedMapPointError = Self.maximumScreenPointError / scale
        return levels.last(where: { $0.maximumMapPointError <= allowedMapPointError })
            ?? Level(maximumMapPointError: 0, points: rawPoints)
    }

    static func simplify(_ points: [MKMapPoint], tolerance: Double) -> [MKMapPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var retained = Array(repeating: false, count: points.count)
        retained[0] = true
        retained[points.count - 1] = true
        var ranges: [(Int, Int)] = [(0, points.count - 1)]
        let toleranceSquared = tolerance * tolerance

        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }
            var furthestIndex = -1
            var furthestDistanceSquared = 0.0
            for index in (start + 1)..<end {
                let distance = squaredDistance(
                    from: points[index], toSegmentFrom: points[start], to: points[end])
                if distance > furthestDistanceSquared {
                    furthestDistanceSquared = distance
                    furthestIndex = index
                }
            }
            if furthestIndex >= 0, furthestDistanceSquared > toleranceSquared {
                retained[furthestIndex] = true
                ranges.append((start, furthestIndex))
                ranges.append((furthestIndex, end))
            }
        }
        return points.enumerated().compactMap { retained[$0.offset] ? $0.element : nil }
    }

    static func maximumDeviation(of raw: [MKMapPoint], from simplified: [MKMapPoint]) -> Double {
        guard simplified.count >= 2 else { return raw.isEmpty ? 0 : .infinity }
        return raw.reduce(0) { maximum, point in
            let nearest = zip(simplified, simplified.dropFirst()).reduce(Double.infinity) {
                min($0, squaredDistance(from: point, toSegmentFrom: $1.0, to: $1.1))
            }
            return max(maximum, sqrt(nearest))
        }
    }

    private static func squaredDistance(from point: MKMapPoint,
                                        toSegmentFrom start: MKMapPoint,
                                        to end: MKMapPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let px = point.x - start.x
            let py = point.y - start.y
            return px * px + py * py
        }
        let projection = min(1, max(0,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let px = point.x - (start.x + projection * dx)
        let py = point.y - (start.y + projection * dy)
        return px * px + py * py
    }

    private static func crossesWorldWrap(_ points: [MKMapPoint]) -> Bool {
        let halfWorld = MKMapSize.world.width / 2
        return zip(points, points.dropFirst()).contains { abs($0.x - $1.x) > halfWorld }
    }
}

final class ZoomAwareRouteOverlay: NSObject, MKOverlay {
    let geometry: ZoomAwareRouteGeometry
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(geometry: ZoomAwareRouteGeometry) {
        self.geometry = geometry
        if let first = geometry.rawPoints.first {
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in geometry.rawPoints.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            boundingMapRect = MKMapRect(
                x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
            coordinate = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2).coordinate
        } else {
            boundingMapRect = .null
            coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        super.init()
    }
}

private struct DesiredRoutePresentation {
    let state: MapRoutePresentationState
    let geometry: ZoomAwareRouteGeometry
    let style: ProfessionalLineStyle
    let visible: Bool
}

/// 一个 overlay / 一份 map-point geometry / 一个 renderer；按 MapKit zoomScale
/// 把原始 point 线宽换算到绘图坐标，依次绘制 casing、glow、core。
final class ProfessionalPolylineRenderer: MKOverlayPathRenderer {
    private let routeOverlay: ZoomAwareRouteOverlay
    private let style: ProfessionalLineStyle
    private let themeColor: UIColor
    private var levelPaths: [Double: CGPath] = [:]
    #if DEBUG
    private var lastDiagnosticLevel: Double?
    #endif

    init(routeOverlay: ZoomAwareRouteOverlay, style: ProfessionalLineStyle,
         themeColor: UIColor) {
        self.routeOverlay = routeOverlay
        self.style = style
        self.themeColor = themeColor
        super.init(overlay: routeOverlay)
    }

    override func createPath() {
        path = path(for: .init(
            maximumMapPointError: 0, points: routeOverlay.geometry.rawPoints))
    }

    private func path(for level: ZoomAwareRouteGeometry.Level) -> CGPath? {
        if let cached = levelPaths[level.maximumMapPointError] { return cached }
        let mapPoints = level.points
        guard mapPoints.count >= 2 else { return nil }
        let routePath = CGMutablePath()
        routePath.move(to: point(for: mapPoints[0]))
        for index in 1..<mapPoints.count {
            routePath.addLine(to: point(for: mapPoints[index]))
        }
        levelPaths[level.maximumMapPointError] = routePath
        return routePath
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale,
                       in context: CGContext) {
        let level = routeOverlay.geometry.level(for: zoomScale)
        guard let routePath = path(for: level) else { return }
        #if DEBUG
        if lastDiagnosticLevel != level.maximumMapPointError {
            lastDiagnosticLevel = level.maximumMapPointError
            PerformanceDiagnostics.count(
                "renderGeometry.rendererRawPointCount",
                by: routeOverlay.geometry.rawPoints.count)
            PerformanceDiagnostics.count(
                "renderGeometry.rendererSelectedPointCount", by: level.points.count)
            PerformanceDiagnostics.event(
                "renderGeometry.levelSelected",
                metadata: "tolerance=\(level.maximumMapPointError) raw=\(routeOverlay.geometry.rawPoints.count) selected=\(level.points.count)")
        }
        #endif
        for stroke in [style.casing, style.glow, style.core] {
            context.saveGState()
            // MKOverlayPathRenderer 的 path stroke 以中心线两侧展开；换算自原先
            // MKPolylineRenderer.lineWidth，style 中的用户可见宽度参数保持原值。
            lineWidth = stroke.width / 2
            lineCap = .round
            lineJoin = .round
            switch stroke.tone {
            case .casing:
                strokeColor = UIColor.black.withAlphaComponent(stroke.alpha)
            case .glow, .theme:
                strokeColor = themeColor.withAlphaComponent(stroke.alpha)
            }
            applyStrokeProperties(to: context, atZoomScale: zoomScale)
            strokePath(routePath, in: context)
            context.restoreGState()
        }
    }
}

// MARK: - SwiftUI 包装（MKMapView 原生渲染：真机 iOS 26 唯一可靠路径）

struct FootprintMapView: UIViewRepresentable {
    var dots: [FootprintDot]
    var routes: [RouteLine]
    var workoutRoutes: [RouteLine]
    var markers: [PhotoCluster]
    var highlightedPhoto: CLLocationCoordinate2D?
    var track: [CLLocationCoordinate2D]
    var showPhotos: Bool
    var showDots: Bool
    var showLines: Bool
    var showWorkouts: Bool
    var themeColor: UIColor
    var contentToken: Int
    /// 聚合标记版本：跨级切换时 +1 → 覆盖层数据更新（Morphing 动画）
    var markerToken: Int
    /// 地图类型（standard/satellite/topographic）
    var mapType: String
    var globeMode: Bool
    var customSource: CustomMapSource?
    var camera: MapCameraCommand
    var onCameraMoved: (CLLocationCoordinate2D) -> Void
    var onRegionChanged: (MKCoordinateRegion) -> Void
    var onTap: (CLLocationCoordinate2D) -> Void
    var onMarkerTap: (PhotoCluster) -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> MapCoordinator { MapCoordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        // 视觉层级：地图作为空间背景（muted 降低道路/标签/色块权重，突出照片与轨迹）
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = config
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsTraffic = false
        mapView.overrideUserInterfaceStyle = .dark
        mapView.showsUserLocation = true
        #if DEBUG
        MapDebugLog.log("makeUIView 创建 (frame=\(mapView.bounds.size))")
        #endif
        // 卫星图暗化蒙层：降低卫星影像视觉权重（四层视觉层级：照片>轨迹>地点>地图）
        let dimLayer = UIView(frame: mapView.bounds)
        dimLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        dimLayer.isUserInteractionEnabled = false
        dimLayer.isHidden = true   // 默认标准地图不需要
        mapView.addSubview(dimLayer)
        context.coordinator.dimLayer = dimLayer
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(MapCoordinator.handleTap(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(MapCoordinator.handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)   // 双击时不让单击触发探索/恢复
        // 旁观手势：仅记录用户是否在拖动/缩放（区分程序化镜头移动），不拦截地图自身手势
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(MapCoordinator.noteUserGesture(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(MapCoordinator.noteUserGesture(_:)))
        for g in [single, double, pan, pinch] {
            g.delegate = context.coordinator
            mapView.addGestureRecognizer(g)
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let c = context.coordinator
        #if DEBUG
        let diagnosticStarted = CACurrentMediaTime()
        let mutationsBeforeUpdate = c.diagnosticMutationCount
        PerformanceDiagnostics.event("FootprintMapView.updateUIView")
        defer {
            PerformanceDiagnostics.recordDuration(
                "FootprintMapView.updateUIView",
                milliseconds: (CACurrentMediaTime() - diagnosticStarted) * 1_000,
                mainThread: true)
            if c.diagnosticMutationCount == mutationsBeforeUpdate {
                PerformanceDiagnostics.count("MapKit.updateUIView.noMutation")
            } else {
                PerformanceDiagnostics.count("MapKit.updateUIView.withMutation")
            }
        }
        #endif
        c.parent = self
        c.updateReviewHighlight(on: mapView, coordinate: highlightedPhoto)

        // 1) 相机指令（幂等执行）
        if camera != c.lastCamera {
            c.lastCamera = camera
            switch camera {
            case .none: break
            case .region(let region, let animated):
                #if DEBUG
                MapDebugLog.log("camera→region 中心(\(String(format: "%.3f", region.center.latitude)),\(String(format: "%.3f", region.center.longitude))) 跨度(\(String(format: "%.2f", region.span.latitudeDelta))) 动画=\(animated)")
                #endif
                mapView.setRegion(region, animated: animated)
            case .follow(let coord, let animated):
                #if DEBUG
                MapDebugLog.log("camera→follow 中心(\(String(format: "%.4f", coord.latitude)),\(String(format: "%.4f", coord.longitude))) 动画=\(animated)")
                #endif
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                mapView.setCenter(coord, animated: animated)
            case .center(let coord, let animated):
                #if DEBUG
                MapDebugLog.log("camera→center 中心(\(String(format: "%.4f", coord.latitude)),\(String(format: "%.4f", coord.longitude))) 动画=\(animated)")
                #endif
                mapView.setCenter(coord, animated: animated)
            case .userTracking(let followHeading, let animated):
                mapView.setUserTrackingMode(followHeading ? .followWithHeading : .follow,
                                            animated: animated)
            case .pitch(let pitch, let animated):
                let next = mapView.camera.copy() as! MKMapCamera
                next.pitch = min(max(pitch, 0), 70)
                mapView.setCamera(next, animated: animated)
            }
        }

        // 2) 数据内容：按稳定 route id + presentation fingerprint 增量提交。
        // 新 geometry 分批、隐藏预装；最后一个 batch 后同一主线程事务显现，
        // 因而不会逐条出现，也不会在准备期间清空旧地图内容。
        if contentToken != c.lastContentToken {
            c.lastContentToken = contentToken
            c.lastShowDots = showDots
            c.lastShowLines = showLines
            c.lastShowWorkouts = showWorkouts
            c.lastShowPhotos = showPhotos
            c.lastTrackCount = track.count
            let expectedToken = contentToken
            reconcileRoutePresentation(on: mapView, context: c) { [weak mapView, weak c] in
                guard let mapView, let c, c.lastContentToken == expectedToken else { return }
                replaceTrackLines(mapView, context: c)
                replaceDotsOverlay(on: mapView, context: c)
                replacePhotoAnnotations(on: mapView, context: c, full: true)
            }
        } else {
            if showDots != c.lastShowDots {
                c.lastShowDots = showDots
                replaceDotsOverlay(on: mapView, context: c)
            }
            if showLines != c.lastShowLines {
                c.lastShowLines = showLines
                // 一个 renderer 内保留描边/光晕/主线三次 stroke；开关只改 alpha。
                setHistoricalLinesVisible(showLines, on: mapView, context: c)
            }
            if showWorkouts != c.lastShowWorkouts {
                c.lastShowWorkouts = showWorkouts
                setWorkoutLinesVisible(showWorkouts, on: mapView, context: c)
            }
            if showPhotos != c.lastShowPhotos {
                c.lastShowPhotos = showPhotos
                replacePhotoAnnotations(on: mapView, context: c, full: true)
            }
        }

        // 2.5) 地图类型切换。自定义源会晚于 @AppStorage 恢复，因此配置指纹
        // 必须包含源本身；不能只记住 custom:<id>，否则冷启动会漏装瓦片层。
        let mapConfigurationKey = [mapType, globeMode ? "globe" : "flat",
                                   customSource?.id.uuidString ?? "missing",
                                   customSource?.urlTemplate ?? ""].joined(separator: "|")
        if mapConfigurationKey != c.lastMapConfigurationKey {
            c.lastMapConfigurationKey = mapConfigurationKey
            let isSatellite = mapType == "satellite"
            c.dimLayer?.isHidden = !isSatellite
            if let previous = c.baseTileOverlay {
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.overlays.remove")
                c.diagnosticMutationCount += 1
                #endif
                mapView.removeOverlay(previous)
                c.baseTileOverlay = nil
            }
            if mapType == "topographic", let template = TopographicMapConfiguration.tileURLTemplate {
                // 底层 Apple 地图仅作容错；MapTiler Outdoor v4 瓦片替换其内容。
                let config = MKStandardMapConfiguration(elevationStyle: globeMode ? .realistic : .flat,
                                                        emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                mapView.preferredConfiguration = config
                let tiles = MKTileOverlay(urlTemplate: template)
                tiles.canReplaceMapContent = true
                tiles.minimumZ = 0
                tiles.maximumZ = 20
                c.baseTileOverlay = tiles
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.overlays.add")
                c.diagnosticMutationCount += 1
                #endif
                mapView.addOverlay(tiles, level: .aboveRoads)

            } else if mapType.hasPrefix("custom:"), let customSource {
                let config = MKStandardMapConfiguration(elevationStyle: globeMode ? .realistic : .flat,
                                                        emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                mapView.preferredConfiguration = config
                let tiles = ConfiguredTileOverlay(source: customSource)
                c.baseTileOverlay = tiles
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.overlays.add")
                c.diagnosticMutationCount += 1
                #endif
                mapView.addOverlay(tiles, level: .aboveRoads)
            } else if isSatellite {
                mapView.preferredConfiguration = MKImageryMapConfiguration()
            } else {
                let config = MKStandardMapConfiguration(elevationStyle: globeMode ? .realistic : .flat,
                                                        emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                mapView.preferredConfiguration = config
            }
            let typeName = mapType == "topographic" ? "等高线" :
                (mapType.hasPrefix("custom:") ? "自定义" : (isSatellite ? "卫星" : "标准"))
            appLog.info("[Map] 配置切换 → \(typeName)")
        }

        // 2.5) 聚合标记级别/视野变化（仅跨级触发）→ 画布更新 + Morphing 动画
        if markerToken != c.lastMarkerToken {
            c.lastMarkerToken = markerToken
            replacePhotoAnnotations(on: mapView, context: c)
        }
        // 3) 实时轨迹（每次定位更新增量重建）
        if track.count != c.lastTrackCount {
            c.lastTrackCount = track.count
            replaceTrackLines(mapView, context: c)
        }
    }

    private func replaceDotsOverlay(on mapView: MKMapView, context c: MapCoordinator) {
        if let old = c.dotsOverlay {
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.overlays.remove")
            c.diagnosticMutationCount += 1
            #endif
            mapView.removeOverlay(old)
            c.dotsOverlay = nil
        }
        guard showDots, !dots.isEmpty else { return }
        let overlay = FootprintDotsOverlay(dots: dots)
        c.dotsOverlay = overlay
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.overlays.add")
        c.diagnosticMutationCount += 1
        #endif
        mapView.addOverlay(overlay, level: .aboveLabels)
    }

    /// 照片标注更新。full=true 用于数据真正变化（contentToken / 图层开关）；
    /// full=false 用于视野/级别变化（markerToken），按 cluster.id 增量差分——
    /// 只增删变化项，避免缩放跨级时清空全部缩略图造成闪烁与重复取图。
    private func replacePhotoAnnotations(on mapView: MKMapView, context c: MapCoordinator,
                                         full: Bool = false) {
        let existing = mapView.annotations.compactMap { $0 as? PhotoClusterAnnotation }
        guard showPhotos else {
            if !existing.isEmpty {
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.annotations.remove", by: existing.count)
                c.diagnosticMutationCount += existing.count
                #endif
                mapView.removeAnnotations(existing)
            }
            return
        }
        if full {
            if !existing.isEmpty {
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.annotations.remove", by: existing.count)
                c.diagnosticMutationCount += existing.count
                #endif
                mapView.removeAnnotations(existing)
            }
            let added = markers.map(PhotoClusterAnnotation.init(cluster:))
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.annotations.add", by: added.count)
            c.diagnosticMutationCount += added.count
            #endif
            mapView.addAnnotations(added)
            c.updatePhotoMarkerSizes(on: mapView)
            return
        }
        let wantedIDs = Set(markers.map(\.id))
        let toRemove = existing.filter { !wantedIDs.contains($0.cluster.id) }
        if !toRemove.isEmpty {
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.annotations.remove", by: toRemove.count)
            c.diagnosticMutationCount += toRemove.count
            #endif
            mapView.removeAnnotations(toRemove)
        }
        let existingIDs = Set(existing.map(\.cluster.id))
        let toAdd = markers.filter { !existingIDs.contains($0.id) }
            .map(PhotoClusterAnnotation.init(cluster:))
        if !toAdd.isEmpty {
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.annotations.add", by: toAdd.count)
            c.diagnosticMutationCount += toAdd.count
            #endif
            mapView.addAnnotations(toAdd)
        }
        c.updatePhotoMarkerSizes(on: mapView)
    }

    private func desiredRoutePresentations() -> [DesiredRoutePresentation] {
        var result: [DesiredRoutePresentation] = []
        result.reserveCapacity(routes.count + workoutRoutes.count)
        let last = routes.count - 1
        for (i, route) in routes.enumerated() {
            // 最近轨迹（时间最新）高亮：透明度/线宽提升一档，体现时间流动
            let isLatest = (i == last) && routes.count > 1
            let alpha = min(lineOpacity(route.freq) + (isLatest ? 0.35 : 0), 1.0)
            let width = lineWidth(route.freq) + (isLatest ? 1.6 : 0)
            let style = ProfessionalLineStyle.make(alpha: alpha, width: width, tag: 0)
            result.append(DesiredRoutePresentation(
                state: MapRoutePresentationState(
                    id: route.id,
                    fingerprint: presentationFingerprint(route: route, style: style)),
                geometry: route.renderGeometry, style: style, visible: showLines))
        }
        for route in workoutRoutes {
            let style = ProfessionalLineStyle.make(alpha: 1, width: 4.2, tag: 3)
            result.append(DesiredRoutePresentation(
                state: MapRoutePresentationState(
                    id: route.id,
                    fingerprint: presentationFingerprint(route: route, style: style)),
                geometry: route.renderGeometry, style: style, visible: showWorkouts))
        }
        return result
    }

    private func presentationFingerprint(route: RouteLine,
                                         style: ProfessionalLineStyle) -> UInt64 {
        var value = route.contentFingerprint
        func mix(_ component: UInt64) {
            value ^= component
            value &*= 1_099_511_628_211
        }
        for stroke in [style.casing, style.glow, style.core] {
            mix(Double(stroke.alpha).bitPattern)
            mix(Double(stroke.width).bitPattern)
        }
        // Renderer 持有创建时的主题色；主题变化必须只替换对应 route presentation。
        mix(UInt64(bitPattern: Int64(themeColor.hash)))
        return value
    }

    private func reconcileRoutePresentation(
        on mapView: MKMapView,
        context c: MapCoordinator,
        completion: @escaping @MainActor () -> Void
    ) {
        let desired = desiredRoutePresentations()
        let currentStates = c.routeOrder.compactMap { c.routePresentations[$0]?.state }
        let diff = MapPresentationDiff.make(
            current: currentStates, desired: desired.map(\.state))
        #if DEBUG
        PerformanceDiagnostics.count("MapPresentation.diff.calls")
        PerformanceDiagnostics.count("MapPresentation.diff.added", by: diff.added.count)
        PerformanceDiagnostics.count("MapPresentation.diff.removed", by: diff.removed.count)
        PerformanceDiagnostics.count("MapPresentation.diff.changed", by: diff.changed.count)
        PerformanceDiagnostics.count("MapPresentation.diff.unchanged", by: diff.unchanged.count)
        PerformanceDiagnostics.count("MapPresentation.logicalRouteCount", by: desired.count)
        PerformanceDiagnostics.count(
            "MapPresentation.expectedOverlayCount",
            by: MapOverlayAmplificationPolicy.overlayCount(forLogicalRouteCount: desired.count))
        PerformanceDiagnostics.count(
            "MapPresentation.expectedPolylineCount",
            by: MapOverlayAmplificationPolicy.polylineCount(forLogicalRouteCount: desired.count))
        #endif

        let changedIDs = Set(diff.changed)
        let removedIDs = Set(diff.removed)
        let stagedDesired = desired.filter {
            c.routePresentations[$0.state.id] == nil || changedIDs.contains($0.state.id)
        }

        c.cancelPendingRoutePresentation(on: mapView)
        guard !stagedDesired.isEmpty || !removedIDs.isEmpty else {
            for item in desired {
                guard var existing = c.routePresentations[item.state.id] else { continue }
                existing.visible = item.visible
                c.routePresentations[item.state.id] = existing
                mapView.renderer(for: existing.overlay)?.alpha = item.visible ? 1 : 0
            }
            c.routeOrder = desired.map(\.state.id)
            completion()
            return
        }

        c.routePresentationGeneration += 1
        let generation = c.routePresentationGeneration
        c.routePresentationTask = Task { @MainActor [weak mapView, weak c] in
            guard let mapView, let c else { return }
            var staged: [String: PresentedRoute] = [:]
            staged.reserveCapacity(stagedDesired.count)
            var offset = 0
            var batchSize = min(8, max(1, stagedDesired.count))

            while offset < stagedDesired.count {
                guard !Task.isCancelled, c.routePresentationGeneration == generation else { return }
                let started = CACurrentMediaTime()
                let end = min(offset + batchSize, stagedDesired.count)
                let batch = Array(stagedDesired[offset..<end])
                var overlays: [ZoomAwareRouteOverlay] = []
                overlays.reserveCapacity(batch.count)
                for item in batch where item.geometry.rawPoints.count >= 2 {
                    let overlay = ZoomAwareRouteOverlay(geometry: item.geometry)
                    let identifier = ObjectIdentifier(overlay)
                    c.pendingRouteOverlayIDs.insert(identifier)
                    c.overlayStyles[identifier] = item.style
                    let presented = PresentedRoute(
                        state: item.state, overlay: overlay,
                        style: item.style, visible: item.visible)
                    staged[item.state.id] = presented
                    c.pendingRoutePresentations[item.state.id] = presented
                    overlays.append(overlay)
                }
                if !overlays.isEmpty {
                    mapView.addOverlays(overlays, level: .aboveLabels)
                    #if DEBUG
                    PerformanceDiagnostics.count("MapKit.routeOverlay.create", by: overlays.count)
                    PerformanceDiagnostics.count("MapKit.overlays.add", by: overlays.count)
                    PerformanceDiagnostics.count("MapKit.overlayBatches")
                    c.diagnosticMutationCount += overlays.count
                    #endif
                }
                let elapsed = (CACurrentMediaTime() - started) * 1_000
                #if DEBUG
                PerformanceDiagnostics.recordDuration(
                    "MapKit.overlayBatch.mainThread", milliseconds: elapsed, mainThread: true)
                #endif
                offset = end
                batchSize = MapPresentationBatchPolicy.nextBatchSize(
                    previous: batchSize, elapsedMilliseconds: elapsed)
                if offset < stagedDesired.count { await Task.yield() }
            }

            guard !Task.isCancelled, c.routePresentationGeneration == generation else { return }
            let obsolete = (removedIDs.union(changedIDs)).compactMap {
                c.routePresentations[$0]?.overlay
            }
            UIView.performWithoutAnimation {
                if !obsolete.isEmpty { mapView.removeOverlays(obsolete) }
                for overlay in obsolete {
                    c.overlayStyles.removeValue(forKey: ObjectIdentifier(overlay))
                }

                var next: [String: PresentedRoute] = [:]
                next.reserveCapacity(desired.count)
                for item in desired {
                    if let replacement = staged[item.state.id] {
                        next[item.state.id] = replacement
                    } else if var existing = c.routePresentations[item.state.id] {
                        existing.visible = item.visible
                        next[item.state.id] = existing
                    }
                }
                c.routePresentations = next
                c.routeOrder = desired.map(\.state.id)
                c.reorderDataOverlays(on: mapView)
                for route in next.values {
                    c.pendingRouteOverlayIDs.remove(ObjectIdentifier(route.overlay))
                    mapView.renderer(for: route.overlay)?.alpha = route.visible ? 1 : 0
                }
                c.pendingRoutePresentations.removeAll()
            }
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.overlays.remove", by: obsolete.count)
            c.diagnosticMutationCount += obsolete.count
            #endif
            c.routePresentationTask = nil
            completion()
            appLog.info("[Map] 增量提交：新增=\(diff.added.count) 变更=\(diff.changed.count) 删除=\(diff.removed.count) 保留=\(diff.unchanged.count)")
        }
    }

    private func setWorkoutLinesVisible(_ visible: Bool, on mapView: MKMapView,
                                        context c: MapCoordinator) {
        for overlay in mapView.overlays where c.tag(of: overlay) == 3 {
            mapView.renderer(for: overlay)?.alpha = visible ? 1 : 0
        }
    }

    private func setHistoricalLinesVisible(_ visible: Bool, on mapView: MKMapView,
                                           context c: MapCoordinator) {
        for overlay in mapView.overlays where c.tag(of: overlay) == 0 {
            mapView.renderer(for: overlay)?.alpha = visible ? 1 : 0
        }
    }

    private func replaceTrackLines(_ mapView: MKMapView, context c: MapCoordinator) {
        let removed = mapView.overlays.filter { c.tag(of: $0) == 1 || c.tag(of: $0) == 2 }
        for overlay in removed { c.overlayStyles.removeValue(forKey: ObjectIdentifier(overlay)) }
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.overlays.remove", by: removed.count)
        c.diagnosticMutationCount += removed.count
        #endif
        if !removed.isEmpty { mapView.removeOverlays(removed) }
        guard track.count >= 2 else { return }
        addProfessionalLine(track, alpha: 1, width: 4, tag: 1, to: mapView, context: c)
    }

    /// 专业运动地图三次 stroke：视觉参数与顺序不变，但只创建一个共享 geometry overlay。
    private func addProfessionalLine(_ coordinates: [CLLocationCoordinate2D], alpha: CGFloat,
                                     width: CGFloat, tag: Int, to mapView: MKMapView,
                                     context c: MapCoordinator) {
        guard coordinates.count >= 2 else { return }
        let overlay = ZoomAwareRouteOverlay(
            geometry: ZoomAwareRouteGeometry(coordinates: coordinates))
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.routeOverlay.create")
        PerformanceDiagnostics.count("MapKit.overlays.add")
        c.diagnosticMutationCount += 1
        #endif
        c.overlayStyles[ObjectIdentifier(overlay)] = .make(
            alpha: alpha, width: width, tag: tag)
        mapView.addOverlay(overlay, level: .aboveLabels)
    }

    /// 与 SwiftUI 版一致的频次样式
    private func lineOpacity(_ freq: Int) -> CGFloat {
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
}

// MARK: - 协调器

private final class ReviewPhotoHighlightAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

struct PresentedRoute {
    let state: MapRoutePresentationState
    let overlay: ZoomAwareRouteOverlay
    let style: ProfessionalLineStyle
    var visible: Bool
}

final class MapCoordinator: NSObject, MKMapViewDelegate {
    var parent: FootprintMapView
    var lastContentToken = -1
    var lastShowDots = true
    var lastShowLines = false
    var lastShowWorkouts = true
    var lastShowPhotos = true
    var lastMarkerToken = -1
    var lastTrackCount = -1
    var lastCamera: MapCameraCommand = .none
    var lastRegionTime = Date.distantPast
    var overlayStyles: [ObjectIdentifier: ProfessionalLineStyle] = [:]
    var routePresentations: [String: PresentedRoute] = [:]
    var routeOrder: [String] = []
    var pendingRoutePresentations: [String: PresentedRoute] = [:]
    var pendingRouteOverlayIDs: Set<ObjectIdentifier> = []
    var routePresentationGeneration = 0
    var routePresentationTask: Task<Void, Never>?
    /// 标记画布（点 + 照片聚合）
    var canvas: MarkerCanvasView?
    /// 原生足迹点覆盖层，与 MapKit 底图共用变换。
    var dotsOverlay: FootprintDotsOverlay?
    /// 卫星图暗化蒙层
    var dimLayer: UIView?
    /// 当前自定义瓦片底图。
    var baseTileOverlay: MKTileOverlay?
    var lastMapConfigurationKey = ""
    private var reviewHighlight: ReviewPhotoHighlightAnnotation?
    #if DEBUG
    var diagnosticMutationCount = 0
    #endif

    init(_ parent: FootprintMapView) { self.parent = parent }

    func tag(of overlay: MKOverlay) -> Int { overlayStyles[ObjectIdentifier(overlay)]?.tag ?? -1 }

    func cancelPendingRoutePresentation(on mapView: MKMapView) {
        routePresentationTask?.cancel()
        routePresentationTask = nil
        routePresentationGeneration += 1
        let overlays = pendingRoutePresentations.values.map(\.overlay)
        if !overlays.isEmpty {
            mapView.removeOverlays(overlays)
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.overlays.remove", by: overlays.count)
            diagnosticMutationCount += overlays.count
            #endif
        }
        for overlay in overlays {
            let identifier = ObjectIdentifier(overlay)
            overlayStyles.removeValue(forKey: identifier)
            pendingRouteOverlayIDs.remove(identifier)
        }
        pendingRoutePresentations.removeAll()
    }

    /// 只交换现存 data overlay 的槽位，使 route → live track → dots 的历史绘制顺序不变。
    func reorderDataOverlays(on mapView: MKMapView) {
        let orderedRoutes = routeOrder.compactMap { routePresentations[$0]?.overlay as MKOverlay? }
        let tracks = mapView.overlays.filter { tag(of: $0) == 1 || tag(of: $0) == 2 }
        let dots = dotsOverlay.map { [$0 as MKOverlay] } ?? []
        let desired = orderedRoutes + tracks + dots
        let desiredIDs = Set(desired.map { ObjectIdentifier($0) })
        var actual = mapView.overlays
        let slots = actual.indices.filter { desiredIDs.contains(ObjectIdentifier(actual[$0])) }
        guard slots.count == desired.count else { return }
        for (desiredOffset, targetIndex) in slots.enumerated() {
            let wanted = ObjectIdentifier(desired[desiredOffset])
            guard ObjectIdentifier(actual[targetIndex]) != wanted,
                  let currentIndex = actual.firstIndex(where: { ObjectIdentifier($0) == wanted })
            else { continue }
            mapView.exchangeOverlay(at: currentIndex, withOverlayAt: targetIndex)
            actual.swapAt(currentIndex, targetIndex)
        }
    }

    func updateReviewHighlight(on mapView: MKMapView, coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            if let old = reviewHighlight {
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.annotations.remove")
                diagnosticMutationCount += 1
                #endif
                mapView.removeAnnotation(old)
            }
            reviewHighlight = nil
            return
        }
        if let old = reviewHighlight,
           abs(old.coordinate.latitude - coordinate.latitude) < 0.000001,
           abs(old.coordinate.longitude - coordinate.longitude) < 0.000001 { return }
        if let old = reviewHighlight {
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.annotations.remove")
            diagnosticMutationCount += 1
            #endif
            mapView.removeAnnotation(old)
        }
        let annotation = ReviewPhotoHighlightAnnotation(coordinate: coordinate)
        reviewHighlight = annotation
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.annotations.add")
        diagnosticMutationCount += 1
        #endif
        mapView.addAnnotation(annotation)
        mapView.selectAnnotation(annotation, animated: true)
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if let dots = overlay as? FootprintDotsOverlay {
            return FootprintDotsRenderer(overlay: dots, color: parent.themeColor)
        }
        if let routeOverlay = overlay as? ZoomAwareRouteOverlay {
            let style = overlayStyles[ObjectIdentifier(overlay)]
                ?? .make(alpha: 0.6, width: 2, tag: 0)
            let renderer = ProfessionalPolylineRenderer(
                routeOverlay: routeOverlay,
                style: style, themeColor: parent.themeColor)
            if pendingRouteOverlayIDs.contains(ObjectIdentifier(overlay)) {
                renderer.alpha = 0
            } else if style.tag == 0 {
                renderer.alpha = parent.showLines ? 1 : 0
            } else if style.tag == 3 {
                renderer.alpha = parent.showWorkouts ? 1 : 0
            }
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation is ReviewPhotoHighlightAnnotation {
            let reuseID = "ReviewPhotoHighlight"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.frame.size = CGSize(width: 30, height: 30)
            view.layer.cornerRadius = 15
            view.backgroundColor = parent.themeColor.withAlphaComponent(0.20)
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 3
            view.layer.shadowColor = parent.themeColor.cgColor
            view.layer.shadowOpacity = 0.9
            view.layer.shadowRadius = 9
            view.layer.shadowOffset = .zero
            view.canShowCallout = false
            view.displayPriority = .required
            return view
        }
        guard let photo = annotation as? PhotoClusterAnnotation else { return nil }
        let reuseID = "PhotoClusterAnnotation"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                    as? PhotoClusterAnnotationView)
            ?? PhotoClusterAnnotationView(annotation: photo, reuseIdentifier: reuseID)
        view.configure(annotation: photo,
                       size: MarkerCanvasView.markerSize(for: mapView.region.span.latitudeDelta))
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // MapKit 可能因焦点/标注刷新触发 didSelect；禁止从这里打开 Review。
        // 照片组只能由 handleTap 中确认的用户点击触发。
        guard view.annotation is PhotoClusterAnnotation else { return }
        mapView.deselectAnnotation(view.annotation, animated: false)
    }

    func updatePhotoMarkerSizes(on mapView: MKMapView) {
        let size = MarkerCanvasView.markerSize(for: mapView.region.span.latitudeDelta)
        for annotation in mapView.annotations {
            (mapView.view(for: annotation) as? PhotoClusterAnnotationView)?.setMarkerSize(size)
        }
    }

    /// 镜头变化：画布重画（标记跟随地图连续移动）+ 节流回调级别切换
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        updatePhotoMarkerSizes(on: mapView)
        let now = Date()
        // 拖动期间只更新地理投影，不重新选择聚合层级或替换照片组。
        // 否则边拖边重新聚合，会让照片看起来相对路线自行移动。
        if !userInteracting, now.timeIntervalSince(lastRegionTime) > 0.25 {
            lastRegionTime = now
            parent.onRegionChanged(mapView.region)
        }
    }

    // MARK: 旁观手势（记录用户是否正在操作地图）

    private(set) var userInteracting = false
    private var lastPanEndedAt = Date.distantPast
    private var activeGestures: Set<ObjectIdentifier> = []

    @objc func noteUserGesture(_ g: UIGestureRecognizer) {
        let gestureID = ObjectIdentifier(g)
        switch g.state {
        case .began, .changed:
            let wasInteracting = userInteracting
            activeGestures.insert(gestureID)
            userInteracting = !activeGestures.isEmpty
            if !wasInteracting, let mapView = g.view as? MKMapView {
                parent.onCameraMoved(mapView.centerCoordinate)
            }
        case .ended, .cancelled, .failed:
            activeGestures.remove(gestureID)
            userInteracting = !activeGestures.isEmpty
            if !userInteracting, let mapView = g.view as? MKMapView {
                // 地图停止后一次性刷新可见聚合，锚点切换不会发生在手指拖动过程中。
                lastRegionTime = Date()
                parent.onCameraMoved(mapView.centerCoordinate)
                parent.onRegionChanged(mapView.region)
                updatePhotoMarkerSizes(on: mapView)
            }
            if g is UIPanGestureRecognizer {
                lastPanEndedAt = Date()
            }
        default: break
        }
    }

    // MARK: 双击（纯净模式切换）

    @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        parent.onDoubleTap()
    }

    // MARK: 点击（命中聚合标记 → 标记回调；否则地图坐标 → 探索回调）

    @objc func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let mapView = g.view as? MKMapView else { return }
        // 独立旁观 pan 与 MapKit 手势同时识别，屏蔽拖动结束瞬间残留的 tap。
        guard Date().timeIntervalSince(lastPanEndedAt) > 0.12 else { return }
        let loc = g.location(in: mapView)
        // 只有这条明确用户 tap 路径允许打开照片组 Review。
        if let hit = mapView.annotations.compactMap({ annotation -> (PhotoClusterAnnotation, CGFloat)? in
            guard let photo = annotation as? PhotoClusterAnnotation,
                  let view = mapView.view(for: annotation),
                  view.frame.insetBy(dx: -4, dy: -4).contains(loc) else { return nil }
            let center = CGPoint(x: view.frame.midX, y: view.frame.midY)
            return (photo, hypot(center.x - loc.x, center.y - loc.y))
        }).min(by: { $0.1 < $1.1 })?.0 {
            parent.onMarkerTap(hit.cluster)
            return
        }
        parent.onTap(mapView.convert(loc, toCoordinateFrom: mapView))
    }
}

extension MapCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
