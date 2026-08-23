import Foundation
import CoreLocation

/// 地理计算（纯函数，可单测）
public enum GeoMath {

    /// 两点间距离（米），Haversine 公式
    public static func distanceMeters(from a: (lat: Double, lon: Double), to b: (lat: Double, lon: Double)) -> Double {
        let radius = 6371000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let la1 = a.lat * .pi / 180
        let la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    public static func isValid(latitude: Double, longitude: Double) -> Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// 网格聚簇：把坐标按固定网格聚合，返回点最多的 topN 个簇（中心 + 数量）
    public static func topClusters(
        _ pts: [(lat: Double, lon: Double)],
        cellDegrees: Double = 0.005,
        topN: Int = 5
    ) -> [(lat: Double, lon: Double, count: Int)] {
        var cells: [String: (latSum: Double, lonSum: Double, count: Int)] = [:]
        for p in pts {
            let key = "\(Int((p.lat / cellDegrees).rounded()))_\(Int((p.lon / cellDegrees).rounded()))"
            var c = cells[key, default: (0, 0, 0)]
            c.latSum += p.lat
            c.lonSum += p.lon
            c.count += 1
            cells[key] = c
        }
        return cells.values
            .sorted { $0.count > $1.count }
            .prefix(topN)
            .map { (lat: $0.latSum / Double($0.count), lon: $0.lonSum / Double($0.count), count: $0.count) }
    }
}

/// 按「天 + 附近距离」去重的索引（网格分桶，O(1) 查询）
public struct DedupeIndex {
    private var grid: [String: [(Double, Double)]] = [:]
    private let cell = 0.001 // ~110m 一格

    public init() {}

    private func key(_ day: Int, _ lat: Double, _ lon: Double) -> String {
        "\(day)_\(Int((lat / cell).rounded()))_\(Int((lon / cell).rounded()))"
    }

    public mutating func add(day: Int, lat: Double, lon: Double) {
        grid[key(day, lat, lon), default: []].append((lat, lon))
    }

    public func hasNearby(day: Int, lat: Double, lon: Double, withinMeters: Double) -> Bool {
        let range = Int(ceil(withinMeters / 110_000 / cell))
        for dx in -range...range {
            for dy in -range...range {
                if let bucket = grid[key(day, lat + Double(dx) * cell, lon + Double(dy) * cell)] {
                    for (blat, blon) in bucket
                    where GeoMath.distanceMeters(from: (lat, lon), to: (blat, blon)) <= withinMeters {
                        return true
                    }
                }
            }
        }
        return false
    }
}

/// Catmull-Rom 采样点（t∈[0,1]，四点插值）
public func catmullRom(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                       c: CLLocationCoordinate2D, d: CLLocationCoordinate2D,
                       t: Double) -> CLLocationCoordinate2D {
    let t2 = t * t
    let t3 = t2 * t
    let lat = 0.5 * ((2 * b.latitude) + (-a.latitude + c.latitude) * t
        + (2 * a.latitude - 5 * b.latitude + 4 * c.latitude - d.latitude) * t2
        + (-a.latitude + 3 * b.latitude - 3 * c.latitude + d.latitude) * t3)
    let lon = 0.5 * ((2 * b.longitude) + (-a.longitude + c.longitude) * t
        + (2 * a.longitude - 5 * b.longitude + 4 * c.longitude - d.longitude) * t2
        + (-a.longitude + 3 * b.longitude - 3 * c.longitude + d.longitude) * t3)
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

/// 轨迹平滑（Spatiotemporal Trail 视觉表达）：
/// 相邻点距离 > 20km 的跨城/跨省长段用 Catmull-Rom 插值出平滑曲线，
/// 短距离段保持原样（精度优先）；返回插值后的点序列。
public func smoothTrail(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard coords.count > 2 else { return coords }
    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(coords.count * 2)
    result.append(coords[0])
    for i in 0..<(coords.count - 1) {
        let b = coords[i]
        let c = coords[i + 1]
        let a = coords[max(i - 1, 0)]
        let d = coords[min(i + 2, coords.count - 1)]
        let dist = GeoMath.distanceMeters(from: (b.latitude, b.longitude),
                                          to: (c.latitude, c.longitude))
        if dist > 20_000 {
            // 跨城长段：插 5 个采样点形成曲线
            for k in 1...5 {
                result.append(catmullRom(a: a, b: b, c: c, d: d, t: Double(k) / 6))
            }
        }
        result.append(c)
    }
    return result
}

// MARK: - 轨迹索引（照片绑定轨迹：精确匹配 / 轨迹吸附 / 时间插值）

/// TrailIndex v2 输入点：保留来源、轨迹、会话和分段边界。
public struct TrailPoint: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let t: TimeInterval   // Unix 秒
    public let source: TrajectorySource
    public let trajectoryID: String?
    public let sessionID: String?
    public let segmentID: String?
    public let horizontalAccuracy: Double?
    public let confidence: Double
    public let originalPointID: String?

    public init(lat: Double, lon: Double, t: TimeInterval,
                source: TrajectorySource = .inferred,
                trajectoryID: String? = nil, sessionID: String? = nil,
                segmentID: String? = nil, horizontalAccuracy: Double? = nil,
                confidence: Double = 0.5, originalPointID: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.t = t
        self.source = source
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.horizontalAccuracy = horizontalAccuracy
        self.confidence = min(1, max(0, confidence))
        self.originalPointID = originalPointID
    }

    fileprivate func sharesBoundary(with other: TrailPoint) -> Bool {
        let hasBoundary = trajectoryID != nil || other.trajectoryID != nil ||
            sessionID != nil || other.sessionID != nil ||
            segmentID != nil || other.segmentID != nil
        guard hasBoundary else { return true }
        return trajectoryID == other.trajectoryID &&
            sessionID == other.sessionID && segmentID == other.segmentID
    }
}

private struct TrailSegment {
    let a: TrailPoint
    let b: TrailPoint
}

fileprivate struct TrailLocationMatch {
    let lat: Double
    let lon: Double
    let time: TimeInterval
    let source: TrajectorySource
    let trajectoryID: String?
    let sessionID: String?
    let segmentID: String?
    let confidence: Double
}

/// 轨迹空间+时间索引：
/// - 网格哈希（0.002°≈220m）找最近轨迹点（精确 <50m / 吸附 ≤300m）
/// - 时间序列二分插值（无 GPS 照片按拍摄时间定位）
public struct TrailIndex {
    public let points: [TrailPoint]
    private let grid: [String: [Int]]
    private let segments: [TrailSegment]
    private let segmentGrid: [String: [Int]]

    public init(points: [TrailPoint]) {
        self.points = points.sorted { $0.t < $1.t }
        var grid: [String: [Int]] = [:]
        for (i, p) in self.points.enumerated() {
            grid[Self.key(p.lat, p.lon), default: []].append(i)
        }
        self.grid = grid

        // 先按领域边界分组，再连接组内相邻点；全局时间相邻不能覆盖 Session/Segment。
        var builtSegments: [TrailSegment] = []
        var builtGrid: [String: [Int]] = [:]
        let boundaryGroups = Dictionary(grouping: self.points) { point in
            if point.trajectoryID == nil && point.sessionID == nil && point.segmentID == nil {
                return "legacy"
            }
            return "\(point.trajectoryID ?? "-")|\(point.sessionID ?? "-")|\(point.segmentID ?? "-")"
        }
        for group in boundaryGroups.values {
            let ordered = group.sorted { $0.t < $1.t }
            if ordered.count > 1 {
                for i in 0..<(ordered.count - 1) {
                    let a = ordered[i], b = ordered[i + 1]
                    guard a.sharesBoundary(with: b) else { continue }
                    let dt = b.t - a.t
                    guard dt > 0, dt <= 7200 else { continue }
                    let distance = GeoMath.distanceMeters(from: (a.lat, a.lon), to: (b.lat, b.lon))
                    let plausibleDistance = min(20_000, max(2_000, dt * 15))
                    guard distance <= plausibleDistance else { continue }
                    let segmentIndex = builtSegments.count
                    builtSegments.append(TrailSegment(a: a, b: b))
                    let samples = max(1, Int(ceil(distance / 150)))
                    var inserted = Set<String>()
                    for step in 0...samples {
                        let k = Double(step) / Double(samples)
                        let lat = a.lat + (b.lat - a.lat) * k
                        let lon = a.lon + (b.lon - a.lon) * k
                        let key = Self.key(lat, lon)
                        if inserted.insert(key).inserted {
                            builtGrid[key, default: []].append(segmentIndex)
                        }
                    }
                }
            }
        }
        self.segments = builtSegments
        self.segmentGrid = builtGrid
    }

    /// 0.002° 网格 key
    private static func key(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.3f_%.3f", (lat * 500).rounded() / 500, (lon * 500).rounded() / 500)
    }

    /// 最近轨迹点：先查 3×3 邻居网格，返回 (lat, lon, 距离米)，无则 nil
    public func nearest(to lat: Double, lon: Double, within maxMeters: Double) -> (lat: Double, lon: Double, distance: Double)? {
        var best: (Double, Double, Double)?
        let cell = 0.002
        // 额外一圈覆盖四舍五入网格边界，避免路段恰好落在相邻 cell 时漏检。
        let range = Int(ceil(maxMeters / 111_000 / cell)) + 1
        for dx in -range...range {
            for dy in -range...range {
                guard let idxs = grid[Self.key(lat + Double(dx) * cell, lon + Double(dy) * cell)] else { continue }
                for i in idxs {
                    let p = points[i]
                    let d = GeoMath.distanceMeters(from: (lat, lon), to: (p.lat, p.lon))
                    if d <= maxMeters, best == nil || d < best!.2 {
                        best = (p.lat, p.lon, d)
                    }
                }
            }
        }
        return best
    }

    /// 投影到最近的真实路段，而不是吸附到离散采样点。
    /// 这会让路线附近照片沿线分布，避免在 GPS 点上堆叠。
    public func nearestOnRoute(to lat: Double, lon: Double, within maxMeters: Double)
        -> (lat: Double, lon: Double, distance: Double, time: TimeInterval)? {
        guard let detailed = nearestOnRouteMatch(to: lat, lon: lon, within: maxMeters) else { return nil }
        return (detailed.match.lat, detailed.match.lon, detailed.distance, detailed.match.time)
    }

    fileprivate func nearestOnRouteMatch(to lat: Double, lon: Double, within maxMeters: Double)
        -> (match: TrailLocationMatch, distance: Double)? {
        guard !segments.isEmpty else { return nil }
        let cell = 0.002
        let range = Int(ceil(maxMeters / 111_000 / cell)) + 1
        var candidates = Set<Int>()
        for dx in -range...range {
            for dy in -range...range {
                if let ids = segmentGrid[Self.key(lat + Double(dx) * cell,
                                                  lon + Double(dy) * cell)] {
                    candidates.formUnion(ids)
                }
            }
        }
        var best: (match: TrailLocationMatch, distance: Double)?
        for id in candidates {
            let segment = segments[id]
            let meanLat = (lat + segment.a.lat + segment.b.lat) / 3 * .pi / 180
            let metersPerLon = max(1, 111_320 * cos(meanLat))
            let ax = (segment.a.lon - lon) * metersPerLon
            let ay = (segment.a.lat - lat) * 111_320
            let bx = (segment.b.lon - lon) * metersPerLon
            let by = (segment.b.lat - lat) * 111_320
            let vx = bx - ax, vy = by - ay
            let lengthSquared = vx * vx + vy * vy
            let fraction = lengthSquared > 0
                ? min(1, max(0, -(ax * vx + ay * vy) / lengthSquared)) : 0
            let projectedLat = segment.a.lat + (segment.b.lat - segment.a.lat) * fraction
            let projectedLon = segment.a.lon + (segment.b.lon - segment.a.lon) * fraction
            let distance = GeoMath.distanceMeters(from: (lat, lon),
                                                  to: (projectedLat, projectedLon))
            if distance <= maxMeters, best == nil || distance < best!.distance {
                let projectedTime = segment.a.t + (segment.b.t - segment.a.t) * fraction
                best = (TrailLocationMatch(
                    lat: projectedLat, lon: projectedLon, time: projectedTime,
                    source: segment.a.source,
                    trajectoryID: segment.a.trajectoryID,
                    sessionID: segment.a.sessionID,
                    segmentID: segment.a.segmentID,
                    confidence: min(segment.a.confidence, segment.b.confidence)), distance)
            }
        }
        return best
    }

    /// 时间插值：照片时间在轨迹时间范围内 → 前后两点线性插值。
    /// 前后点时间间隔 > 2h（跨线路/跨天间隙）视为无轨迹 → nil（避免跨间隙错误定位）
    public func interpolate(at time: TimeInterval) -> (lat: Double, lon: Double)? {
        guard let match = interpolateMatch(at: time) else { return nil }
        return (match.lat, match.lon)
    }

    fileprivate func interpolateMatch(at time: TimeInterval) -> TrailLocationMatch? {
        guard points.count >= 2 else { return nil }
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.t { return locationMatch(at: first) }
        if time >= last.t { return locationMatch(at: last) }

        // 多条轨迹可在时间上重叠。只在同一领域 Segment 内插值，优先高置信度候选。
        let candidates = segments.filter { $0.a.t <= time && time <= $0.b.t }
        guard let segment = candidates.max(by: {
            min($0.a.confidence, $0.b.confidence) < min($1.a.confidence, $1.b.confidence)
        }) else { return nil }
        guard segment.a.sharesBoundary(with: segment.b) else { return nil }
        let span = segment.b.t - segment.a.t
        guard span > 0, span <= 7200 else { return nil }
        let k = (time - segment.a.t) / span
        return TrailLocationMatch(
            lat: segment.a.lat + (segment.b.lat - segment.a.lat) * k,
            lon: segment.a.lon + (segment.b.lon - segment.a.lon) * k,
            time: time, source: segment.a.source,
            trajectoryID: segment.a.trajectoryID,
            sessionID: segment.a.sessionID,
            segmentID: segment.a.segmentID,
            confidence: min(segment.a.confidence, segment.b.confidence))
    }

    private func locationMatch(at point: TrailPoint) -> TrailLocationMatch {
        TrailLocationMatch(lat: point.lat, lon: point.lon, time: point.t,
                           source: point.source, trajectoryID: point.trajectoryID,
                           sessionID: point.sessionID, segmentID: point.segmentID,
                           confidence: point.confidence)
    }
}

public enum TrailMatchKind: Equatable, Sendable {
    case exact
    case snapped
    case interpolated
    case kept
}

/// 照片匹配结果不再只有坐标；下游可追溯到实际采用的轨迹来源与分段。
public struct TrailSnapResult: Equatable, Sendable {
    public let kind: TrailMatchKind
    public let lat: Double
    public let lon: Double
    public let trajectoryID: String?
    public let sessionID: String?
    public let segmentID: String?
    public let source: TrajectorySource?
    public let confidence: Double
    public let distance: Double?
    public let timeDelta: TimeInterval?

    public init(kind: TrailMatchKind, lat: Double, lon: Double,
                trajectoryID: String? = nil, sessionID: String? = nil,
                segmentID: String? = nil, source: TrajectorySource? = nil,
                confidence: Double = 0, distance: Double? = nil,
                timeDelta: TimeInterval? = nil) {
        self.kind = kind
        self.lat = lat
        self.lon = lon
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.distance = distance
        self.timeDelta = timeDelta
    }
}

/// 照片绑定轨迹（方案 §4 徒步模式定位规则；时间优先保证沿线均匀分布）：
/// 1) 精确匹配：拍摄时间对应轨迹位置 <60m → 绑定该位置
/// 2) 轨迹吸附：拍摄时间对应轨迹位置 60-500m → 吸附（照片沿线路按时间展开）
/// 3) 回退：时间位置过远 → 投影到空间最近路段（≤500m）
/// 4) 时间插值：无有效 GPS → 按拍摄时间在轨迹上插值（带 2h 间隙保护）
public func snapPhotoToTrailResult(lat: Double, lon: Double, time: TimeInterval,
                                   trails: TrailIndex?) -> TrailSnapResult {
    guard let trails else { return TrailSnapResult(kind: .kept, lat: lat, lon: lon) }
    let valid = GeoMath.isValid(latitude: lat, longitude: lon)
    if valid {
        // 按拍摄时间取轨迹位置：同一段线路上不同时刻的照片落在不同位置
        if let p = trails.interpolateMatch(at: time) {
            let d = GeoMath.distanceMeters(from: (lat, lon), to: (p.lat, p.lon))
            if d <= 60 { return matchResult(.exact, p, distance: d, photoTime: time) }
            if d <= 500 { return matchResult(.snapped, p, distance: d, photoTime: time) }
        }
        // 回退到最近路段的投影点，让标记真正落在路线上。
        if let near = trails.nearestOnRouteMatch(to: lat, lon: lon, within: 60) {
            return matchResult(.exact, near.match, distance: near.distance, photoTime: time)
        }
        if let near = trails.nearestOnRouteMatch(to: lat, lon: lon, within: 500) {
            return matchResult(.snapped, near.match, distance: near.distance, photoTime: time)
        }
        return TrailSnapResult(kind: .kept, lat: lat, lon: lon)
    }
    // 无有效 GPS → 时间插值（间隙保护：跨线路不定位）
    if let p = trails.interpolateMatch(at: time) {
        return matchResult(.interpolated, p, distance: nil, photoTime: time)
    }
    return TrailSnapResult(kind: .kept, lat: lat, lon: lon)
}

private func matchResult(_ kind: TrailMatchKind, _ match: TrailLocationMatch,
                         distance: Double?, photoTime: TimeInterval) -> TrailSnapResult {
    TrailSnapResult(kind: kind, lat: match.lat, lon: match.lon,
                    trajectoryID: match.trajectoryID, sessionID: match.sessionID,
                    segmentID: match.segmentID, source: match.source,
                    confidence: match.confidence, distance: distance,
                    timeDelta: abs(photoTime - match.time))
}

/// 返回吸附后的 (lat, lon)；无轨迹或超距返回原坐标
public func snapPhotoToTrail(lat: Double, lon: Double, time: TimeInterval,
                             trails: TrailIndex?) -> (lat: Double, lon: Double) {
    let result = snapPhotoToTrailResult(lat: lat, lon: lon, time: time, trails: trails)
    return (result.lat, result.lon)
}
