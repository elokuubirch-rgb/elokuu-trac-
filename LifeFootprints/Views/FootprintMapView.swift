import SwiftUI
import MapKit
import UIKit
import CryptoKit

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

/// Apple 地图底图的产品级呈现规则。MapKit 不开放单独的城市/道路标签层级，
/// 因此「静谧」使用公开且稳定的 muted 配置，并进一步隐藏建筑、兴趣点和交通。
enum MapBasePresentation {
    static let quietMapType = "quiet"
    static let quietWashOpacity: CGFloat = 0.22
    static let loadingBackground = UIColor(red: 9 / 255, green: 11 / 255,
                                           blue: 18 / 255, alpha: 1)

    static func showsBuildings(for mapType: String) -> Bool {
        mapType != quietMapType
    }

    static func standardConfiguration(globeMode: Bool) -> MKStandardMapConfiguration {
        let configuration = MKStandardMapConfiguration(
            elevationStyle: globeMode ? .realistic : .flat,
            emphasisStyle: .muted
        )
        configuration.pointOfInterestFilter = .excludingAll
        return configuration
    }
}

/// 只压低 Apple 底图与系统标签，不覆盖应用自己的轨迹、足迹点和照片标记。
final class QuietMapWashOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

final class QuietMapWashRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale,
                       in context: CGContext) {
        context.setFillColor(
            MapBasePresentation.loadingBackground
                .withAlphaComponent(MapBasePresentation.quietWashOpacity).cgColor
        )
        context.fill(rect(for: mapRect))
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
    /// 保留当前中心/缩放/俯角，只把朝向转回正北（自绘指北按钮）。
    case north(animated: Bool)

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
        case (.north(let la), .north(let ra)):
            return la == ra
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

// MARK: - MapKit 原生照片标注 / 足迹点覆盖层

/// 照片必须使用 MKAnnotationView，让 MapKit 在拖动、惯性和缩放时
/// 与底图共享同一个 presentation transform，避免外置 UIView 投影慢一帧。
final class PhotoClusterAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let cluster: PhotoCluster

    init(cluster: PhotoCluster,
         displaySystem: CoordinateReferenceSystem = .wgs84) {
        self.cluster = cluster
        let displayed = MapCoordinatePresentation.display(
            CoordinateValue(latitude: cluster.coordinate.latitude,
                            longitude: cluster.coordinate.longitude),
            targetSystem: displaySystem)
        coordinate = CLLocationCoordinate2D(latitude: displayed.latitude,
                                            longitude: displayed.longitude)
        super.init()
    }
}

final class PhotoClusterAnnotationView: MKAnnotationView {
    private var photoCluster: PhotoCluster?
    private var activationHandler: ((PhotoCluster) -> Void)?
    private var thumbnail: UIImage?
    private var loadID = UUID()
    private var markerSize: CGFloat = 44

    /// 远景 36pt → 近景 58pt，保持照片缩略图始终可辨识。
    static func markerSize(for span: Double) -> CGFloat {
        let t = (log10(max(span, 0.001)) - log10(0.001)) / (log10(8) - log10(0.001))
        return 58 - min(max(t, 0), 1) * 22
    }

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
        activationHandler = nil
        thumbnail = nil
    }

    func configure(annotation: PhotoClusterAnnotation, size: CGFloat,
                   onActivate: @escaping (PhotoCluster) -> Void) {
        self.annotation = annotation
        photoCluster = annotation.cluster
        activationHandler = onActivate
        isAccessibilityElement = true
        accessibilityTraits = .button
        let labelFormat = NSLocalizedString("%@，%ld 张照片", comment: "Map photo cluster accessibility label")
        accessibilityLabel = String.localizedStringWithFormat(
            labelFormat, annotation.cluster.name, annotation.cluster.count)
        accessibilityValue = annotation.cluster.locationEvidence.map {
            NSLocalizedString($0, comment: "Photo position evidence")
        }
        accessibilityHint = NSLocalizedString("双击打开照片组", comment: "Map photo cluster accessibility hint")
        displayPriority = MKFeatureDisplayPriority(
            min(1_000, 650 + Float(log10(Double(max(annotation.cluster.count, 1)))) * 110)
        )
        setMarkerSize(size)
        loadThumbnail(for: annotation.cluster)
    }

    override func accessibilityActivate() -> Bool {
        guard let photoCluster, let activationHandler else { return false }
        activationHandler(photoCluster)
        return true
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

        // 位置来源属于详情语义，不压在缩略图上。VoiceOver 仍通过 accessibilityValue 播报，
        // 视觉标记只承担「照片 + 数量 + 地理锚点」，避免远景信息过载和 11pt 以下文字。
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
            let font = UIFont.systemFont(ofSize: max(11, size * 0.22), weight: .bold)
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
    /// 每个频次独立按 x 排序。MapKit 会按 tile 多次调用 renderer；旧实现每个
    /// tile 都扫描全部足迹并重复做经纬度转换，十万级点会让后台切换时
    /// flushTileLoads 等待超过 watchdog。这里仅改变查询结构，不减少任何点。
    private let mapPointsByFrequency: [[MKMapPoint]]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(dots: [FootprintDot]) {
        var groups = Array(repeating: [MKMapPoint](), count: 4)
        var rect = MKMapRect.null
        for dot in dots {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon))
            groups[min(max(dot.freq, 1), 4) - 1].append(point)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        for index in groups.indices {
            groups[index].sort { $0.x < $1.x }
        }
        mapPointsByFrequency = groups
        boundingMapRect = rect.isNull ? MKMapRect.world : rect
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        super.init()
    }

    /// 先按 x 二分缩小到当前 MapKit tile，再由 renderer 精确判断 y。
    /// 返回的是原数组切片，不复制候选点；方法只读，可安全供多个 renderer 线程调用。
    func mapPoints(frequencyIndex: Int, intersecting rect: MKMapRect) -> ArraySlice<MKMapPoint> {
        guard mapPointsByFrequency.indices.contains(frequencyIndex) else { return [] }
        let points = mapPointsByFrequency[frequencyIndex]
        let lower = lowerBound(in: points, x: rect.minX)
        let upper = lowerBound(in: points, x: rect.maxX.nextUp)
        return points[lower..<upper]
    }

    private func lowerBound(in points: [MKMapPoint], x: Double) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].x < x {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// MapKit 在进入后台时会同步等待所有 overlay tile 完成。大量路线仍在排队绘制时，
/// 该等待可能触发 0x8BADF00D scene-update watchdog。willResignActive 之后让排队中的
/// renderer 快速返回；willEnterForeground 先恢复并使全部数据 overlay 失效重绘。
final class MapRenderActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Returns whether the activity state actually changed. Foreground delivery
    /// includes both willEnterForeground and didBecomeActive; callers use this
    /// transition result to avoid invalidating every MapKit tile twice.
    @discardableResult
    func setActive(_ value: Bool) -> Bool {
        lock.lock()
        let changed = active != value
        active = value
        lock.unlock()
        return changed
    }
}

final class FootprintDotsRenderer: MKOverlayRenderer {
    private let dotsOverlay: FootprintDotsOverlay
    private let renderActivity: MapRenderActivity
    var color: UIColor

    init(overlay: FootprintDotsOverlay, color: UIColor,
         renderActivity: MapRenderActivity) {
        dotsOverlay = overlay
        self.color = color
        self.renderActivity = renderActivity
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard renderActivity.isActive else { return }
        let expanded = mapRect.insetBy(dx: -16 / Double(zoomScale), dy: -16 / Double(zoomScale))
        var groups = Array(repeating: [CGPoint](), count: 4)
        for index in groups.indices {
            let candidates = dotsOverlay.mapPoints(
                frequencyIndex: index, intersecting: expanded)
            groups[index].reserveCapacity(candidates.count)
            for mapPoint in candidates where expanded.contains(mapPoint) {
                groups[index].append(point(for: mapPoint))
            }
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
                alpha: tag == 0 ? 0.2 : min(0.82, 0.5 + alpha * 0.3),
                width: tag == 0 ? width + 2.4 : width + 4.2,
                tone: .casing),
            glow: MapLineStrokeStyle(
                alpha: tag == 0 ? 0.09 : 0.12 + alpha * 0.08,
                width: tag == 0 ? width + 4 : width + 8,
                tone: .glow),
            core: MapLineStrokeStyle(
                alpha: tag == 0 ? max(0.92, min(alpha, 1)) : max(alpha, 0.82),
                width: tag == 0 ? max(width, 2.8) : max(width, 2.8),
                tone: .theme))
    }

    /// Historical workouts are a density context layer, not fourteen selected routes.
    /// A thin translucent core lets repeated laps become legible through compositing without
    /// producing the former opaque neon band and dark seams.
    static let workoutOverview = Self(
        tag: 3,
        casing: MapLineStrokeStyle(alpha: 0, width: 1.5, tone: .casing),
        glow: MapLineStrokeStyle(alpha: 0.025, width: 3, tone: .glow),
        core: MapLineStrokeStyle(alpha: 0.11, width: 1.5, tone: .theme))
}

enum MapOverlayAmplificationPolicy {
    static func overlayCount(forLogicalRouteCount count: Int) -> Int { count > 0 ? 1 : 0 }
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

    static func cached(coordinates: [CLLocationCoordinate2D],
                       stableID: String,
                       contentFingerprint: UInt64) -> Self {
        let raw = coordinates.map(MKMapPoint.init)
        if let levels = PersistentRouteLODCache.shared.load(
            stableID: stableID, contentFingerprint: contentFingerprint,
            rawPointCount: raw.count) {
            #if DEBUG
            PerformanceDiagnostics.count("RouteLODCache.hit")
            #endif
            return Self(rawPoints: raw, levels: levels)
        }
        let geometry = Self(rawPoints: raw)
        PersistentRouteLODCache.shared.save(
            levels: geometry.levels, stableID: stableID,
            contentFingerprint: contentFingerprint,
            rawPointCount: raw.count)
        #if DEBUG
        PerformanceDiagnostics.count("RouteLODCache.miss")
        #endif
        return geometry
    }

    init(coordinates: [CLLocationCoordinate2D]) {
        self.init(rawPoints: coordinates.map(MKMapPoint.init))
    }

    private init(rawPoints raw: [MKMapPoint]) {
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

    private init(rawPoints: [MKMapPoint], levels: [Level]) {
        self.rawPoints = rawPoints
        self.levels = levels
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

/// 地图显示专用 LOD 派生缓存。每条显示路线只保留一个 fingerprint 版本，
/// 总量超过预算时按最近使用时间淘汰；不包含任何原始业务数据。
final class PersistentRouteLODCache: @unchecked Sendable {
    static let shared = PersistentRouteLODCache(directoryURL: defaultDirectoryURL())
    static let schemaVersion = 2
    static let diskBudget: Int64 = 16 * 1_024 * 1_024

    private struct PointRecord: Codable {
        let x: Double
        let y: Double
    }

    private struct LevelRecord: Codable {
        let maximumMapPointError: Double
        let points: [PointRecord]
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let stableID: String
        let contentFingerprint: UInt64
        let rawPointCount: Int
        let levels: [LevelRecord]
    }

    private let directoryURL: URL
    private let lock = NSLock()
    private var trackedDiskBytes: Int64?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func load(stableID: String, contentFingerprint: UInt64,
              rawPointCount: Int) -> [ZoomAwareRouteGeometry.Level]? {
        lock.withLock {
            let url = fileURL(for: stableID)
            guard let data = try? Data(contentsOf: url),
                  data.count > 32 else { return nil }
            let payload = Data(data.dropFirst(32))
            guard Data(SHA256.hash(data: payload)) == data.prefix(32),
                  let envelope = try? PropertyListDecoder().decode(
                    Envelope.self, from: payload),
                  envelope.schemaVersion == Self.schemaVersion,
                  envelope.stableID == stableID,
                  envelope.contentFingerprint == contentFingerprint,
                  envelope.rawPointCount == rawPointCount else {
                return nil
            }
            let levels = envelope.levels.compactMap { record
                -> ZoomAwareRouteGeometry.Level? in
                guard record.maximumMapPointError.isFinite,
                      record.maximumMapPointError > 0,
                      record.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    return nil
                }
                return ZoomAwareRouteGeometry.Level(
                    maximumMapPointError: record.maximumMapPointError,
                    points: record.points.map { MKMapPoint(x: $0.x, y: $0.y) })
            }
            guard levels.count == envelope.levels.count else { return nil }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
            return levels
        }
    }

    func save(levels: [ZoomAwareRouteGeometry.Level], stableID: String,
              contentFingerprint: UInt64, rawPointCount: Int) {
        guard !levels.isEmpty else { return }
        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL, withIntermediateDirectories: true)
                let envelope = Envelope(
                    schemaVersion: Self.schemaVersion,
                    stableID: stableID,
                    contentFingerprint: contentFingerprint,
                    rawPointCount: rawPointCount,
                    levels: levels.map { level in
                        LevelRecord(
                            maximumMapPointError: level.maximumMapPointError,
                            points: level.points.map { PointRecord(x: $0.x, y: $0.y) })
                    })
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let payload = try encoder.encode(envelope)
                var data = Data(SHA256.hash(data: payload))
                data.append(payload)
                guard Int64(data.count) <= Self.diskBudget else { return }
                let url = fileURL(for: stableID)
                let previousSize = Int64((try? url.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let currentBytes = trackedDiskBytes ?? directoryBytes()
                try data.write(to: url, options: .atomic)
                trackedDiskBytes = currentBytes - previousSize + Int64(data.count)
                if (trackedDiskBytes ?? 0) > Self.diskBudget {
                    pruneIfNeeded()
                }
            } catch {
                #if DEBUG
                PerformanceDiagnostics.event(
                    "RouteLODCache.saveFailed", metadata: error.localizedDescription)
                #endif
            }
        }
    }

    func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: directoryURL)
            trackedDiskBytes = nil
        }
    }

    func diskBytes() -> Int64 {
        lock.withLock {
            let bytes = directoryBytes()
            trackedDiskBytes = bytes
            return bytes
        }
    }

    private func pruneIfNeeded() {
        guard directoryBytes() > Self.diskBudget,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        let ordered = urls.sorted {
            let left = (try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        var bytes = directoryBytes()
        for url in ordered where bytes > Self.diskBudget {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                bytes -= Int64(size)
            } catch { /* 下一次写入仍会重试淘汰；不把失败删除计为空闲空间。 */ }
        }
        trackedDiskBytes = bytes
    }

    private func directoryBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func fileURL(for stableID: String) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return directoryURL.appendingPathComponent(
            String(format: "route-%016llx.plist", hash))
    }

    private static func defaultDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeFootprintsDerived", isDirectory: true)
            .appendingPathComponent("lod-v3", isDirectory: true)
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
    private let renderActivity: MapRenderActivity
    /// MapKit may call one renderer concurrently for different tiles. The path cache
    /// and MKOverlayPathRenderer's stroke properties are mutable, so serialize only
    /// this renderer instance; different routes still render in parallel.
    private let renderLock = NSLock()
    private var levelPaths: [Double: CGPath] = [:]
    #if DEBUG
    private var lastDiagnosticLevel: Double?
    #endif

    init(routeOverlay: ZoomAwareRouteOverlay, style: ProfessionalLineStyle,
         themeColor: UIColor, renderActivity: MapRenderActivity) {
        self.routeOverlay = routeOverlay
        self.style = style
        self.themeColor = themeColor
        self.renderActivity = renderActivity
        super.init(overlay: routeOverlay)
    }

    override func createPath() {
        renderLock.lock()
        defer { renderLock.unlock() }
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
        guard renderActivity.isActive else { return }
        renderLock.lock()
        defer { renderLock.unlock() }
        guard renderActivity.isActive else { return }
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
            guard renderActivity.isActive else { return }
            guard stroke.alpha > 0, stroke.width > 0 else { continue }
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

// MARK: - Spatially indexed route presentation

private struct GroupedRouteEntry {
    let state: MapRoutePresentationState
    let geometry: ZoomAwareRouteGeometry
    let style: ProfessionalLineStyle
    let boundingMapRect: MKMapRect

    init(state: MapRoutePresentationState, geometry: ZoomAwareRouteGeometry,
         style: ProfessionalLineStyle) {
        self.state = state
        self.geometry = geometry
        self.style = style
        guard let first = geometry.rawPoints.first else {
            boundingMapRect = .null
            return
        }
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
    }
}

private final class GroupedRouteOverlay: NSObject, MKOverlay {
    private struct XEntry {
        let minimumX: Double
        let routeIndex: Int
    }

    let entries: [GroupedRouteEntry]
    let tag: Int
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    private let entriesByMinimumX: [XEntry]

    init(entries: [GroupedRouteEntry], tag: Int) {
        self.entries = entries
        self.tag = tag
        boundingMapRect = entries.reduce(MKMapRect.null) {
            $0.isNull ? $1.boundingMapRect : $0.union($1.boundingMapRect)
        }
        coordinate = boundingMapRect.isNull
            ? CLLocationCoordinate2D(latitude: 0, longitude: 0)
            : MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        entriesByMinimumX = entries.indices.map {
            XEntry(minimumX: entries[$0].boundingMapRect.minX, routeIndex: $0)
        }.sorted {
            $0.minimumX == $1.minimumX
                ? $0.routeIndex < $1.routeIndex
                : $0.minimumX < $1.minimumX
        }
        super.init()
    }

    /// Returns tile candidates in original route order so alpha compositing and
    /// overlap semantics remain identical to one-overlay-per-route presentation.
    func routeIndices(intersecting mapRect: MKMapRect) -> [Int] {
        var lower = 0
        var upper = entriesByMinimumX.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entriesByMinimumX[middle].minimumX <= mapRect.maxX {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var result: [Int] = []
        result.reserveCapacity(min(lower, 128))
        for candidate in entriesByMinimumX[..<lower] {
            let bounds = entries[candidate.routeIndex].boundingMapRect
            if bounds.maxX >= mapRect.minX,
               bounds.maxY >= mapRect.minY,
               bounds.minY <= mapRect.maxY {
                result.append(candidate.routeIndex)
            }
        }
        result.sort()
        return result
    }
}

private struct DesiredRouteGroup {
    let state: MapRoutePresentationState
    let entries: [GroupedRouteEntry]
    let tag: Int
    let visible: Bool
}

/// One renderer per semantic layer. Geometry selection, route order, stroke order,
/// widths, colors and alpha are the same as ProfessionalPolylineRenderer.
private final class GroupedRouteRenderer: MKOverlayPathRenderer {
    private struct PathKey: Hashable {
        let routeIndex: Int
        let toleranceBits: UInt64
    }

    private let routeGroup: GroupedRouteOverlay
    private let themeColor: UIColor
    private let renderActivity: MapRenderActivity
    private let pathCacheLock = NSLock()
    private var levelPaths: [PathKey: CGPath] = [:]
    #if DEBUG
    private var lastDiagnosticLevels: [Int: Double] = [:]
    #endif

    init(overlay: GroupedRouteOverlay, themeColor: UIColor,
         renderActivity: MapRenderActivity) {
        routeGroup = overlay
        self.themeColor = themeColor
        self.renderActivity = renderActivity
        super.init(overlay: overlay)
    }

    override func createPath() {
        path = CGMutablePath()
    }

    private func path(for level: ZoomAwareRouteGeometry.Level,
                      routeIndex: Int) -> CGPath? {
        let key = PathKey(routeIndex: routeIndex,
                          toleranceBits: level.maximumMapPointError.bitPattern)
        pathCacheLock.lock()
        let cached = levelPaths[key]
        pathCacheLock.unlock()
        if let cached { return cached }
        guard level.points.count >= 2 else { return nil }
        let result = CGMutablePath()
        result.move(to: point(for: level.points[0]))
        for point in level.points.dropFirst() {
            result.addLine(to: self.point(for: point))
        }
        pathCacheLock.lock()
        let shared = levelPaths[key] ?? result
        levelPaths[key] = shared
        pathCacheLock.unlock()
        return shared
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale,
                       in context: CGContext) {
        guard renderActivity.isActive else { return }
        #if DEBUG
        let drawStarted = CACurrentMediaTime()
        #endif
        let mapPadding = 16 / max(Double(zoomScale), Double.leastNonzeroMagnitude)
        let visibleRect = mapRect.insetBy(dx: -mapPadding, dy: -mapPadding)
        let routeIndices = routeGroup.routeIndices(intersecting: visibleRect)
        #if DEBUG
        PerformanceDiagnostics.count("GroupedRouteRenderer.tileQuery")
        PerformanceDiagnostics.count(
            "GroupedRouteRenderer.candidateRoutes", by: routeIndices.count)
        PerformanceDiagnostics.recordDuration(
            "GroupedRouteRenderer.candidateRoutesPerTile",
            milliseconds: Double(routeIndices.count))
        #endif
        for index in routeIndices {
            let entry = routeGroup.entries[index]
            let level = entry.geometry.level(for: zoomScale)
            guard let routePath = path(for: level, routeIndex: index) else { continue }
            #if DEBUG
            pathCacheLock.lock()
            let diagnosticLevelChanged =
                lastDiagnosticLevels[index] != level.maximumMapPointError
            if diagnosticLevelChanged {
                lastDiagnosticLevels[index] = level.maximumMapPointError
            }
            pathCacheLock.unlock()
            if diagnosticLevelChanged {
                PerformanceDiagnostics.count(
                    "renderGeometry.rendererRawPointCount",
                    by: entry.geometry.rawPoints.count)
                PerformanceDiagnostics.count(
                    "renderGeometry.rendererSelectedPointCount", by: level.points.count)
                PerformanceDiagnostics.event(
                    "renderGeometry.levelSelected",
                    metadata: "tolerance=\(level.maximumMapPointError) raw=\(entry.geometry.rawPoints.count) selected=\(level.points.count)")
            }
            #endif
            for stroke in [entry.style.casing, entry.style.glow, entry.style.core] {
                guard renderActivity.isActive else { return }
                guard stroke.alpha > 0, stroke.width > 0 else { continue }
                context.saveGState()
                let color: UIColor
                switch stroke.tone {
                case .casing:
                    color = UIColor.black.withAlphaComponent(stroke.alpha)
                case .glow, .theme:
                    color = themeColor.withAlphaComponent(stroke.alpha)
                }
                // This is the effective conversion used by the former
                // MKOverlayPathRenderer.applyStrokeProperties call. Keep it local
                // to the CGContext so concurrent MapKit tiles never mutate shared
                // renderer properties, without changing the visible stroke width.
                context.setLineWidth(
                    (stroke.width / 2) * contentScaleFactor
                        / max(CGFloat(zoomScale), CGFloat.leastNonzeroMagnitude))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setStrokeColor(color.cgColor)
                context.addPath(routePath)
                context.strokePath()
                context.restoreGState()
            }
        }
        #if DEBUG
        PerformanceDiagnostics.recordDuration(
            "GroupedRouteRenderer.draw",
            milliseconds: (CACurrentMediaTime() - drawStarted) * 1_000)
        #endif
    }
}

// MARK: - SwiftUI 包装（MKMapView 原生渲染：真机 iOS 26 唯一可靠路径）

struct FootprintMapView: UIViewRepresentable {
    var dots: [FootprintDot]
    var routes: [RouteLine]
    var workoutRoutes: [RouteLine]
    var markers: [PhotoCluster]
    var highlightedPhoto: MapPhotoHighlight?
    /// 通过 DisplayLocationFilter 平滑/静止锁定后的地图位置。
    var stableLocation: CLLocationCoordinate2D?
    var track: [CLLocationCoordinate2D]
    var showPhotos: Bool
    var showDots: Bool
    var showLines: Bool
    var showWorkouts: Bool
    var themeColor: UIColor
    var contentToken: Int
    /// 聚合标记版本：跨级切换时 +1 → 覆盖层数据更新（Morphing 动画）
    var markerToken: Int
    /// 地图类型（standard/quiet/satellite/topographic）
    var mapType: String
    var globeMode: Bool
    var customSource: CustomMapSource?
    var camera: MapCameraCommand
    var onCameraMoved: (CLLocationCoordinate2D) -> Void
    var onRegionChanged: (MKCoordinateRegion) -> Void
    var onTap: (CLLocationCoordinate2D) -> Void
    var onMarkerTap: (PhotoCluster) -> Void
    var onHighlightedPhotoTap: (String) -> Void
    var onDoubleTap: () -> Void
    /// 相机朝向偏离/回到正北（跨过 1.5° 阈值）时回调；驱动 MapScreen 自绘指北按钮显隐。
    var onHeadingChanged: (Bool) -> Void = { _ in }

    fileprivate var presentationSystem: CoordinateReferenceSystem {
        MapCoordinatePresentation.targetSystem(
            mapType: mapType,
            customSourceSystem: customSource?.coordinateReferenceSystem)
    }

    fileprivate func displayedCoordinate(
        _ coordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let value = MapCoordinatePresentation.display(
            CoordinateValue(latitude: coordinate.latitude,
                            longitude: coordinate.longitude),
            targetSystem: presentationSystem)
        return CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
    }

    fileprivate func canonicalCoordinate(
        _ coordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let value = MapCoordinatePresentation.canonical(
            CoordinateValue(latitude: coordinate.latitude,
                            longitude: coordinate.longitude),
            sourceSystem: presentationSystem)
        return CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
    }

    fileprivate func displayedRegion(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(center: displayedCoordinate(region.center), span: region.span)
    }

    fileprivate func canonicalRegion(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(center: canonicalCoordinate(region.center), span: region.span)
    }

    func makeCoordinator() -> MapCoordinator { MapCoordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        context.coordinator.attachLifecycle(to: mapView)
        // 地图瓦片到达前保持与启动页一致的深夜底色，避免冷启动或网络抖动时闪白。
        mapView.backgroundColor = MapBasePresentation.loadingBackground
        // 视觉层级：地图作为空间背景（muted 降低道路/标签/色块权重，突出照片与轨迹）
        mapView.preferredConfiguration = MapBasePresentation.standardConfiguration(globeMode: false)
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsBuildings = MapBasePresentation.showsBuildings(for: mapType)
        mapView.showsTraffic = false
        // 系统指南针默认出现在右上角，会与 MapScreen 的图层按钮重叠；
        // 旋转状态下的「回正北」由 MapScreen 的自绘指北按钮承担。
        mapView.showsCompass = false
        mapView.overrideUserInterfaceStyle = .dark
        // 普通浏览不直接显示 raw Core Location 蓝点，避免绕过
        // DisplayLocationFilter。只在指南针跟随时由 MapKit 暂时接管。
        mapView.showsUserLocation = false
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
        // 纯净模式快捷手势：两指点按。不用双击——双击是地图缩放的标准手势
        //（HIG Gestures），自绘双击会与 MapKit 内置放大同时触发。
        let chromeShortcut = UITapGestureRecognizer(target: context.coordinator,
                                                    action: #selector(MapCoordinator.handleChromeShortcut(_:)))
        chromeShortcut.numberOfTouchesRequired = 2
        single.require(toFail: chromeShortcut)   // 两指快速点按时不让单击先触发
        // 旁观手势：仅记录用户是否在拖动/缩放（区分程序化镜头移动），不拦截地图自身手势
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(MapCoordinator.noteUserGesture(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(MapCoordinator.noteUserGesture(_:)))
        for g in [single, chromeShortcut, pan, pinch] {
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
        if c.lastPresentationSystem != presentationSystem {
            let previousSystem = c.lastPresentationSystem
            let center = mapView.centerCoordinate
            let canonical = MapCoordinatePresentation.canonical(
                CoordinateValue(latitude: center.latitude, longitude: center.longitude),
                sourceSystem: previousSystem)
            let displayed = MapCoordinatePresentation.display(
                canonical, targetSystem: presentationSystem)
            c.lastPresentationSystem = presentationSystem
            mapView.setCenter(CLLocationCoordinate2D(
                latitude: displayed.latitude, longitude: displayed.longitude), animated: false)
        }
        c.updateReviewHighlight(on: mapView, highlight: highlightedPhoto,
                                coordinate: highlightedPhoto.map {
                                    displayedCoordinate(CLLocationCoordinate2D(
                                        latitude: $0.latitude, longitude: $0.longitude))
                                })

        // 1) 相机指令（幂等执行）
        if camera != c.lastCamera {
            c.lastCamera = camera
            switch camera {
            case .none: break
            case .region(let region, let animated):
                #if DEBUG
                MapDebugLog.log("camera→region 中心(\(String(format: "%.3f", region.center.latitude)),\(String(format: "%.3f", region.center.longitude))) 跨度(\(String(format: "%.2f", region.span.latitudeDelta))) 动画=\(animated)")
                #endif
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                mapView.setRegion(displayedRegion(region), animated: animated)
            case .follow(let coord, let animated):
                #if DEBUG
                MapDebugLog.log("camera→follow 中心(\(String(format: "%.4f", coord.latitude)),\(String(format: "%.4f", coord.longitude))) 动画=\(animated)")
                #endif
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                mapView.setCenter(displayedCoordinate(coord), animated: animated)
            case .center(let coord, let animated):
                #if DEBUG
                MapDebugLog.log("camera→center 中心(\(String(format: "%.4f", coord.latitude)),\(String(format: "%.4f", coord.longitude))) 动画=\(animated)")
                #endif
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                mapView.setCenter(displayedCoordinate(coord), animated: animated)
            case .userTracking(let followHeading, let animated):
                mapView.showsUserLocation = true
                mapView.setUserTrackingMode(followHeading ? .followWithHeading : .follow,
                                            animated: animated)
            case .pitch(let pitch, let animated):
                let next = mapView.camera.copy() as! MKMapCamera
                next.pitch = min(max(pitch, 0), 70)
                mapView.setCamera(next, animated: animated)
            case .north(let animated):
                let next = mapView.camera.copy() as! MKMapCamera
                next.heading = 0
                mapView.setCamera(next, animated: animated)
            }
        }

        // 用户手势会让 MapKit 自动退出 tracking。每次 SwiftUI 更新都根据
        // MapKit 的实际状态同步标注，不依赖可能滞后的 UI bool。
        c.updateStableLocation(
            on: mapView, coordinate: stableLocation.map(displayedCoordinate))

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
                                   customSource?.urlTemplate ?? "",
                                   presentationSystem.rawValue].joined(separator: "|")
        if mapConfigurationKey != c.lastMapConfigurationKey {
            c.lastMapConfigurationKey = mapConfigurationKey
            let isSatellite = mapType == "satellite"
            let isQuiet = mapType == MapBasePresentation.quietMapType
            c.dimLayer?.isHidden = !isSatellite
            c.setQuietWashVisible(isQuiet, on: mapView)
            mapView.backgroundColor = MapBasePresentation.loadingBackground
            mapView.showsBuildings = MapBasePresentation.showsBuildings(for: mapType)
            mapView.showsTraffic = false
            mapView.pointOfInterestFilter = .excludingAll
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
                mapView.preferredConfiguration = MapBasePresentation.standardConfiguration(
                    globeMode: globeMode
                )
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
                mapView.preferredConfiguration = MapBasePresentation.standardConfiguration(
                    globeMode: globeMode
                )
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
                mapView.preferredConfiguration = MapBasePresentation.standardConfiguration(
                    globeMode: globeMode
                )
            }
            let typeName = mapType == "topographic" ? "等高线" :
                (mapType.hasPrefix("custom:") ? "自定义" :
                    (isSatellite ? "卫星" : (isQuiet ? "静谧" : "标准")))
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
            let added = markers.map {
                PhotoClusterAnnotation(cluster: $0, displaySystem: presentationSystem)
            }
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
            .map { PhotoClusterAnnotation(cluster: $0, displaySystem: presentationSystem) }
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
            let style = ProfessionalLineStyle.workoutOverview
            result.append(DesiredRoutePresentation(
                state: MapRoutePresentationState(
                    id: route.id,
                    fingerprint: presentationFingerprint(route: route, style: style)),
                geometry: route.renderGeometry, style: style, visible: showWorkouts))
        }
        return result
    }

    private func desiredRouteGroups(
        from routes: [DesiredRoutePresentation]
    ) -> [DesiredRouteGroup] {
        var result: [DesiredRouteGroup] = []
        for tag in [0, 3] {
            let matching = routes.filter { $0.style.tag == tag }
            guard !matching.isEmpty else { continue }
            let entries = matching.map {
                GroupedRouteEntry(state: $0.state, geometry: $0.geometry, style: $0.style)
            }
            var fingerprint: UInt64 = 14_695_981_039_346_656_037
            for entry in entries {
                fingerprint ^= entry.state.fingerprint
                fingerprint &*= 1_099_511_628_211
            }
            result.append(DesiredRouteGroup(
                state: MapRoutePresentationState(
                    id: "route-group:\(tag)", fingerprint: fingerprint),
                entries: entries, tag: tag,
                visible: matching.first?.visible ?? true))
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
        let desiredRoutes = desiredRoutePresentations()
        let desiredGroups = desiredRouteGroups(from: desiredRoutes)
        let routeDiff = MapPresentationDiff.make(
            current: c.routeStates, desired: desiredRoutes.map(\.state))
        let currentGroupStates = c.routeGroupOrder.compactMap {
            c.routeGroupPresentations[$0]?.state
        }
        let groupDiff = MapPresentationDiff.make(
            current: currentGroupStates, desired: desiredGroups.map(\.state))
        #if DEBUG
        PerformanceDiagnostics.count("MapPresentation.diff.calls")
        PerformanceDiagnostics.count("MapPresentation.diff.added", by: routeDiff.added.count)
        PerformanceDiagnostics.count("MapPresentation.diff.removed", by: routeDiff.removed.count)
        PerformanceDiagnostics.count("MapPresentation.diff.changed", by: routeDiff.changed.count)
        PerformanceDiagnostics.count("MapPresentation.diff.unchanged", by: routeDiff.unchanged.count)
        PerformanceDiagnostics.count(
            "MapPresentation.logicalRouteCount", by: desiredRoutes.count)
        PerformanceDiagnostics.count(
            "MapPresentation.expectedOverlayCount", by: desiredGroups.count)
        PerformanceDiagnostics.count(
            "MapPresentation.expectedPolylineCount",
            by: MapOverlayAmplificationPolicy.polylineCount(
                forLogicalRouteCount: desiredRoutes.count))
        #endif

        let changedGroupIDs = Set(groupDiff.changed)
        let removedGroupIDs = Set(groupDiff.removed)
        let stagedDesired = desiredGroups.filter {
            c.routeGroupPresentations[$0.state.id] == nil
                || changedGroupIDs.contains($0.state.id)
        }

        c.cancelPendingRoutePresentation(on: mapView)
        guard !stagedDesired.isEmpty || !removedGroupIDs.isEmpty else {
            for item in desiredGroups {
                guard var existing = c.routeGroupPresentations[item.state.id] else { continue }
                existing.visible = item.visible
                c.routeGroupPresentations[item.state.id] = existing
                mapView.renderer(for: existing.overlay)?.alpha = item.visible ? 1 : 0
            }
            c.routeStates = desiredRoutes.map(\.state)
            c.routeGroupOrder = desiredGroups.map(\.state.id)
            completion()
            return
        }

        c.routePresentationGeneration += 1
        let generation = c.routePresentationGeneration
        c.routePresentationTask = Task { @MainActor [weak mapView, weak c] in
            guard let mapView, let c else { return }
            var staged: [String: PresentedRouteGroup] = [:]
            staged.reserveCapacity(stagedDesired.count)
            let desiredOrder = desiredGroups.map(\.state.id)

            for item in stagedDesired {
                guard !Task.isCancelled, c.routePresentationGeneration == generation else { return }
                let started = CACurrentMediaTime()
                let overlay = GroupedRouteOverlay(entries: item.entries, tag: item.tag)
                let identifier = ObjectIdentifier(overlay)
                c.pendingRouteGroupOverlayIDs.insert(identifier)
                let presented = PresentedRouteGroup(
                    state: item.state, overlay: overlay, visible: item.visible)
                staged[item.state.id] = presented
                c.pendingRouteGroupPresentations[item.state.id] = presented
                c.insertRouteGroupOverlay(
                    overlay, groupID: item.state.id,
                    desiredGroupOrder: desiredOrder, on: mapView)
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.routeOverlay.create")
                PerformanceDiagnostics.count(
                    "GroupedRouteOverlay.logicalRoutes", by: item.entries.count)
                PerformanceDiagnostics.count("MapKit.overlays.add")
                PerformanceDiagnostics.count("MapKit.overlayBatches")
                c.diagnosticMutationCount += 1
                PerformanceDiagnostics.recordDuration(
                    "MapKit.overlayBatch.mainThread",
                    milliseconds: (CACurrentMediaTime() - started) * 1_000,
                    mainThread: true)
                #endif
                await Task.yield()
            }

            guard !Task.isCancelled, c.routePresentationGeneration == generation else { return }
            let obsolete = (removedGroupIDs.union(changedGroupIDs)).compactMap {
                c.routeGroupPresentations[$0]?.overlay
            }
            UIView.performWithoutAnimation {
                if !obsolete.isEmpty { mapView.removeOverlays(obsolete) }

                var next: [String: PresentedRouteGroup] = [:]
                next.reserveCapacity(desiredGroups.count)
                for item in desiredGroups {
                    if let replacement = staged[item.state.id] {
                        next[item.state.id] = replacement
                    } else if var existing = c.routeGroupPresentations[item.state.id] {
                        existing.visible = item.visible
                        next[item.state.id] = existing
                    }
                }
                c.routeGroupPresentations = next
                c.routeGroupOrder = desiredGroups.map(\.state.id)
                c.routeStates = desiredRoutes.map(\.state)
                for routeGroup in next.values {
                    c.pendingRouteGroupOverlayIDs.remove(ObjectIdentifier(routeGroup.overlay))
                    mapView.renderer(for: routeGroup.overlay)?.alpha = routeGroup.visible ? 1 : 0
                }
                c.pendingRouteGroupPresentations.removeAll()
            }
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.overlays.remove", by: obsolete.count)
            c.diagnosticMutationCount += obsolete.count
            #endif
            c.routePresentationTask = nil
            completion()
            appLog.info("[Map] 空间索引提交：新增=\(routeDiff.added.count) 变更=\(routeDiff.changed.count) 删除=\(routeDiff.removed.count) 保留=\(routeDiff.unchanged.count) overlays=\(desiredGroups.count)")
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
        addProfessionalLine(track.map(displayedCoordinate), alpha: 1, width: 4,
                            tag: 1, to: mapView, context: c)
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
    let assetID: String
    let thumbnailPath: String?

    init(coordinate: CLLocationCoordinate2D, assetID: String, thumbnailPath: String?) {
        self.coordinate = coordinate
        self.assetID = assetID
        self.thumbnailPath = thumbnailPath
    }
}

private final class WeakReviewPhotoHighlightView: @unchecked Sendable {
    weak var value: ReviewPhotoHighlightAnnotationView?
    init(_ value: ReviewPhotoHighlightAnnotationView) { self.value = value }
}

/// 独立于聚合索引的目的地标记：先展示占位，再异步换成这张照片的缩略图。
private final class ReviewPhotoHighlightAnnotationView: MKAnnotationView {
    private let preview = UIImageView()
    private let stem = UIView()
    private let anchor = UIView()
    private var loadID = UUID()
    private var configuredAssetID: String?
    private var activationHandler: ((String) -> Void)?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 64, height: 72)
        centerOffset = CGPoint(x: 0, y: -32)
        backgroundColor = .clear
        canShowCallout = false
        displayPriority = .required
        collisionMode = .rectangle
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "map-selected-review-photo"

        stem.frame = CGRect(x: 31, y: 49, width: 2, height: 15)
        stem.backgroundColor = .white
        addSubview(stem)
        anchor.frame = CGRect(x: 27, y: 62, width: 10, height: 10)
        anchor.backgroundColor = .white
        anchor.layer.cornerRadius = 5
        addSubview(anchor)
        preview.frame = CGRect(x: 6, y: 0, width: 52, height: 52)
        preview.layer.cornerRadius = 11
        preview.layer.masksToBounds = true
        preview.layer.borderWidth = 3
        preview.layer.borderColor = UIColor.white.cgColor
        preview.backgroundColor = UIColor(white: 0.19, alpha: 1)
        preview.tintColor = .white
        preview.contentMode = .scaleAspectFit
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ highlight: ReviewPhotoHighlightAnnotation,
                   onActivate: @escaping (String) -> Void) {
        annotation = highlight
        activationHandler = onActivate
        accessibilityLabel = NSLocalizedString("回顾照片位置", comment: "Selected review photo on map")
        accessibilityHint = NSLocalizedString("双击查看这张照片", comment: "Open selected review photo")
        guard configuredAssetID != highlight.assetID else { return }
        configuredAssetID = highlight.assetID
        preview.image = UIImage(systemName: "photo.fill")
        preview.contentMode = .scaleAspectFit
        let requestID = UUID()
        loadID = requestID
        let assetID = highlight.assetID
        let path = highlight.thumbnailPath
        let target = WeakReviewPhotoHighlightView(self)
        Task.detached(priority: .userInitiated) {
            var image = path.flatMap(UIImage.init(contentsOfFile:))
            if image == nil {
                image = await PhotoThumbnailGenerator.image(localID: assetID)
            }
            let loadedImage = image
            await MainActor.run {
                guard let view = target.value, view.loadID == requestID else { return }
                if let loadedImage {
                    view.preview.image = loadedImage
                    view.preview.contentMode = .scaleAspectFill
                }
            }
        }
    }

    override func accessibilityActivate() -> Bool {
        guard let assetID = configuredAssetID, let activationHandler else { return false }
        activationHandler(assetID)
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadID = UUID()
        configuredAssetID = nil
        activationHandler = nil
        preview.image = nil
    }
}

/// 地图普通浏览时的定位点。坐标已经过 DisplayLocationFilter，
/// 不使用 MKUserLocation，否则系统会再次直接展示 raw GPS 抖动。
private final class StableLocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

private final class StableLocationAnnotationView: MKAnnotationView {
    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        backgroundColor = .clear
        isOpaque = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowPath = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let outer = rect.insetBy(dx: 3, dy: 3)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: outer)
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fillEllipse(in: outer.insetBy(dx: 3, dy: 3))
    }
}

private struct PresentedRouteGroup {
    let state: MapRoutePresentationState
    let overlay: GroupedRouteOverlay
    var visible: Bool
}

final class MapCoordinator: NSObject, MKMapViewDelegate {
    var parent: FootprintMapView
    var lastPresentationSystem: CoordinateReferenceSystem
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
    fileprivate var routeStates: [MapRoutePresentationState] = []
    fileprivate var routeGroupPresentations: [String: PresentedRouteGroup] = [:]
    fileprivate var routeGroupOrder: [String] = []
    fileprivate var pendingRouteGroupPresentations: [String: PresentedRouteGroup] = [:]
    fileprivate var pendingRouteGroupOverlayIDs: Set<ObjectIdentifier> = []
    var routePresentationGeneration = 0
    var routePresentationTask: Task<Void, Never>?
    /// 原生足迹点覆盖层，与 MapKit 底图共用变换。
    var dotsOverlay: FootprintDotsOverlay?
    /// 卫星图暗化蒙层
    var dimLayer: UIView?
    /// 当前自定义瓦片底图。
    var baseTileOverlay: MKTileOverlay?
    /// 静谧样式的底图压暗层；始终位于应用数据覆盖层之下。
    var quietWashOverlay: QuietMapWashOverlay?
    var lastMapConfigurationKey = ""
    private var reviewHighlight: ReviewPhotoHighlightAnnotation?
    private var stableLocationAnnotation: StableLocationAnnotation?
    let renderActivity = MapRenderActivity()
    private var lifecycleObservers: [NSObjectProtocol] = []
    #if DEBUG
    var diagnosticMutationCount = 0
    #endif

    init(_ parent: FootprintMapView) {
        self.parent = parent
        lastPresentationSystem = parent.presentationSystem
    }

    func setQuietWashVisible(_ visible: Bool, on mapView: MKMapView) {
        if !visible {
            if let quietWashOverlay {
                mapView.removeOverlay(quietWashOverlay)
                self.quietWashOverlay = nil
            }
            return
        }
        guard quietWashOverlay == nil else { return }

        let wash = QuietMapWashOverlay()
        let firstDataOverlay = mapView.overlays.first {
            $0 is FootprintDotsOverlay || $0 is GroupedRouteOverlay
                || $0 is ZoomAwareRouteOverlay
        }
        if let firstDataOverlay {
            mapView.insertOverlay(wash, below: firstDataOverlay)
        } else {
            mapView.addOverlay(wash, level: .aboveLabels)
        }
        quietWashOverlay = wash
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attachLifecycle(to mapView: MKMapView) {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let changed = self.renderActivity.setActive(false)
            #if DEBUG
            PerformanceDiagnostics.event(
                changed ? "MapRenderActivity.deactivate"
                    : "MapRenderActivity.deactivate.noop")
            #endif
        })
        let reactivate: @Sendable (Notification) -> Void = { [weak self, weak mapView] _ in
            MainActor.assumeIsolated {
                guard let self, let mapView else { return }
                guard self.renderActivity.setActive(true) else {
                    #if DEBUG
                    PerformanceDiagnostics.event("MapRenderActivity.reactivate.noop")
                    #endif
                    return
                }
                #if DEBUG
                PerformanceDiagnostics.event("MapRenderActivity.reactivate")
                PerformanceDiagnostics.count(
                    "MapRenderActivity.overlaysInvalidated",
                    by: mapView.overlays.count)
                #endif
                for overlay in mapView.overlays {
                    mapView.renderer(for: overlay)?.setNeedsDisplay()
                }
            }
        }
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main, using: reactivate))
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: reactivate))
    }

    func tag(of overlay: MKOverlay) -> Int {
        if let routeGroup = overlay as? GroupedRouteOverlay { return routeGroup.tag }
        return overlayStyles[ObjectIdentifier(overlay)]?.tag ?? -1
    }

    func cancelPendingRoutePresentation(on mapView: MKMapView) {
        routePresentationTask?.cancel()
        routePresentationTask = nil
        routePresentationGeneration += 1
        let overlays = pendingRouteGroupPresentations.values.map(\.overlay)
        if !overlays.isEmpty {
            mapView.removeOverlays(overlays)
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.overlays.remove", by: overlays.count)
            diagnosticMutationCount += overlays.count
            #endif
        }
        for overlay in overlays {
            let identifier = ObjectIdentifier(overlay)
            pendingRouteGroupOverlayIDs.remove(identifier)
        }
        pendingRouteGroupPresentations.removeAll()
    }

    /// 路线创建时即插入目标层级。所有锚点都在 aboveLabels，避免跨 level 的索引交换。
    fileprivate func insertRouteGroupOverlay(
        _ overlay: GroupedRouteOverlay, groupID: String,
        desiredGroupOrder: [String], on mapView: MKMapView
    ) {
        let followingGroupIDs = desiredGroupOrder.firstIndex(of: groupID).map {
            desiredGroupOrder.dropFirst($0 + 1)
        } ?? desiredGroupOrder.dropFirst(desiredGroupOrder.count)
        let nextRouteGroup = followingGroupIDs.lazy.compactMap { id in
            self.pendingRouteGroupPresentations[id]?.overlay
                ?? self.routeGroupPresentations[id]?.overlay
        }.first
        let foregroundData = mapView.overlays.first { candidate in
            tag(of: candidate) == 1 || tag(of: candidate) == 2
                || dotsOverlay.map {
                    ObjectIdentifier($0) == ObjectIdentifier(candidate)
                } == true
        }
        if let anchor = nextRouteGroup ?? foregroundData {
            mapView.insertOverlay(overlay, below: anchor)
        } else {
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    func updateReviewHighlight(on mapView: MKMapView, highlight: MapPhotoHighlight?,
                               coordinate: CLLocationCoordinate2D?) {
        guard let highlight, let coordinate else {
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
           old.assetID == highlight.assetID,
           abs(old.coordinate.latitude - coordinate.latitude) < 0.000001,
           abs(old.coordinate.longitude - coordinate.longitude) < 0.000001 { return }
        if let old = reviewHighlight {
            #if DEBUG
            PerformanceDiagnostics.count("MapKit.annotations.remove")
            diagnosticMutationCount += 1
            #endif
            mapView.removeAnnotation(old)
        }
        let annotation = ReviewPhotoHighlightAnnotation(
            coordinate: coordinate, assetID: highlight.assetID,
            thumbnailPath: highlight.thumbnailPath)
        reviewHighlight = annotation
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.annotations.add")
        diagnosticMutationCount += 1
        #endif
        mapView.addAnnotation(annotation)
        mapView.selectAnnotation(annotation, animated: true)
    }

    func updateStableLocation(on mapView: MKMapView,
                              coordinate: CLLocationCoordinate2D?) {
        let usesNativeUserLocation = mapView.userTrackingMode != .none
        mapView.showsUserLocation = usesNativeUserLocation

        guard !usesNativeUserLocation,
              let coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else {
            if let old = stableLocationAnnotation {
                mapView.removeAnnotation(old)
                stableLocationAnnotation = nil
                #if DEBUG
                PerformanceDiagnostics.count("MapKit.annotations.remove")
                diagnosticMutationCount += 1
                #endif
            }
            return
        }

        if let annotation = stableLocationAnnotation {
            guard abs(annotation.coordinate.latitude - coordinate.latitude) > 0.0000001
                    || abs(annotation.coordinate.longitude - coordinate.longitude) > 0.0000001
            else { return }
            annotation.coordinate = coordinate
            return
        }

        let annotation = StableLocationAnnotation(coordinate: coordinate)
        stableLocationAnnotation = annotation
        mapView.addAnnotation(annotation)
        #if DEBUG
        PerformanceDiagnostics.count("MapKit.annotations.add")
        diagnosticMutationCount += 1
        #endif
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if overlay is QuietMapWashOverlay {
            return QuietMapWashRenderer(overlay: overlay)
        }
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if let dots = overlay as? FootprintDotsOverlay {
            return FootprintDotsRenderer(
                overlay: dots, color: parent.themeColor,
                renderActivity: renderActivity)
        }
        if let routeGroup = overlay as? GroupedRouteOverlay {
            #if DEBUG
            PerformanceDiagnostics.count("GroupedRouteRenderer.create")
            #endif
            let renderer = GroupedRouteRenderer(
                overlay: routeGroup, themeColor: parent.themeColor,
                renderActivity: renderActivity)
            if pendingRouteGroupOverlayIDs.contains(ObjectIdentifier(overlay)) {
                renderer.alpha = 0
            } else if routeGroup.tag == 0 {
                renderer.alpha = parent.showLines ? 1 : 0
            } else if routeGroup.tag == 3 {
                renderer.alpha = parent.showWorkouts ? 1 : 0
            }
            return renderer
        }
        if let routeOverlay = overlay as? ZoomAwareRouteOverlay {
            let style = overlayStyles[ObjectIdentifier(overlay)]
                ?? .make(alpha: 0.6, width: 2, tag: 0)
            let renderer = ProfessionalPolylineRenderer(
                routeOverlay: routeOverlay, style: style,
                themeColor: parent.themeColor,
                renderActivity: renderActivity)
            if style.tag == 0 {
                renderer.alpha = parent.showLines ? 1 : 0
            } else if style.tag == 3 {
                renderer.alpha = parent.showWorkouts ? 1 : 0
            }
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation is StableLocationAnnotation {
            let reuseID = "StableLocation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                        as? StableLocationAnnotationView)
                ?? StableLocationAnnotationView(annotation: annotation,
                                                reuseIdentifier: reuseID)
            view.annotation = annotation
            return view
        }
        if let highlight = annotation as? ReviewPhotoHighlightAnnotation {
            let reuseID = "ReviewPhotoHighlight"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                        as? ReviewPhotoHighlightAnnotationView)
                ?? ReviewPhotoHighlightAnnotationView(annotation: highlight, reuseIdentifier: reuseID)
            view.configure(highlight, onActivate: { [weak self] assetID in
                self?.parent.onHighlightedPhotoTap(assetID)
            })
            return view
        }
        guard let photo = annotation as? PhotoClusterAnnotation else { return nil }
        let reuseID = "PhotoClusterAnnotation"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                    as? PhotoClusterAnnotationView)
            ?? PhotoClusterAnnotationView(annotation: photo, reuseIdentifier: reuseID)
        view.configure(
            annotation: photo,
            size: PhotoClusterAnnotationView.markerSize(for: mapView.region.span.latitudeDelta),
            onActivate: { [weak self] cluster in self?.parent.onMarkerTap(cluster) }
        )
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // MapKit 可能因焦点/标注刷新触发 didSelect；禁止从这里打开 Review。
        // 照片组只能由 handleTap 中确认的用户点击触发。
        guard view.annotation is PhotoClusterAnnotation else { return }
        mapView.deselectAnnotation(view.annotation, animated: false)
    }

    func updatePhotoMarkerSizes(on mapView: MKMapView) {
        let size = PhotoClusterAnnotationView.markerSize(for: mapView.region.span.latitudeDelta)
        for annotation in mapView.annotations {
            (mapView.view(for: annotation) as? PhotoClusterAnnotationView)?.setMarkerSize(size)
        }
    }

    /// 镜头变化：画布重画（标记跟随地图连续移动）+ 节流回调级别切换
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        updatePhotoMarkerSizes(on: mapView)
        // 朝向跨过阈值才回调，避免旋转动画期间逐帧触发 SwiftUI 状态更新。
        let rotated = abs(mapView.camera.heading) > 1.5
        if rotated != lastReportedRotated {
            lastReportedRotated = rotated
            parent.onHeadingChanged(rotated)
        }
        let now = Date()
        // 拖动期间只更新地理投影，不重新选择聚合层级或替换照片组。
        // 否则边拖边重新聚合，会让照片看起来相对路线自行移动。
        if !userInteracting, now.timeIntervalSince(lastRegionTime) > 0.25 {
            lastRegionTime = now
            parent.onRegionChanged(parent.canonicalRegion(mapView.region))
        }
    }

    // MARK: 旁观手势（记录用户是否正在操作地图）

    private(set) var userInteracting = false
    private var lastPanEndedAt = Date.distantPast
    private var activeGestures: Set<ObjectIdentifier> = []
    private var lastReportedRotated = false

    @objc func noteUserGesture(_ g: UIGestureRecognizer) {
        let gestureID = ObjectIdentifier(g)
        switch g.state {
        case .began, .changed:
            let wasInteracting = userInteracting
            activeGestures.insert(gestureID)
            userInteracting = !activeGestures.isEmpty
            if !wasInteracting, let mapView = g.view as? MKMapView {
                parent.onCameraMoved(parent.canonicalCoordinate(mapView.centerCoordinate))
            }
        case .ended, .cancelled, .failed:
            activeGestures.remove(gestureID)
            userInteracting = !activeGestures.isEmpty
            if !userInteracting, let mapView = g.view as? MKMapView {
                // 地图停止后一次性刷新可见聚合，锚点切换不会发生在手指拖动过程中。
                lastRegionTime = Date()
                parent.onCameraMoved(parent.canonicalCoordinate(mapView.centerCoordinate))
                parent.onRegionChanged(parent.canonicalRegion(mapView.region))
                updatePhotoMarkerSizes(on: mapView)
            }
            if g is UIPanGestureRecognizer {
                lastPanEndedAt = Date()
            }
        default: break
        }
    }

    // MARK: 两指点按（纯净模式快捷切换，替代与缩放冲突的双击）

    @objc func handleChromeShortcut(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        parent.onDoubleTap()
    }

    // MARK: 点击（命中聚合标记 → 标记回调；否则地图坐标 → 探索回调）

    @objc func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let mapView = g.view as? MKMapView else { return }
        // 独立旁观 pan 与 MapKit 手势同时识别，屏蔽拖动结束瞬间残留的 tap。
        guard Date().timeIntervalSince(lastPanEndedAt) > 0.12 else { return }
        let loc = g.location(in: mapView)
        if let highlight = reviewHighlight,
           let view = mapView.view(for: highlight),
           view.frame.contains(loc) {
            parent.onHighlightedPhotoTap(highlight.assetID)
            return
        }
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
        parent.onTap(parent.canonicalCoordinate(
            mapView.convert(loc, toCoordinateFrom: mapView)))
    }
}

extension MapCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
