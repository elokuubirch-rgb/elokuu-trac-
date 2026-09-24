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
    private struct GridKey: Hashable {
        let day: Int
        let latitudeCell: Int
        let longitudeCell: Int
    }

    private var grid: [GridKey: [(Double, Double)]] = [:]
    private let cell = 0.001 // ~110m 一格

    public init() {}

    private func key(_ day: Int, _ lat: Double, _ lon: Double) -> GridKey {
        GridKey(day: day,
                latitudeCell: Int((lat / cell).rounded()),
                longitudeCell: Int((lon / cell).rounded()))
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
    // Keep only indices into TrailIndex.points.  A TrailPoint contains several
    // optional Strings; storing two full values per segment doubled their ARC
    // traffic and retained another copy of every route point at large scale.
    let aIndex: Int
    let bIndex: Int
}

public struct TrailIndexQueryStats: Equatable, Sendable {
    public let totalSegmentCount: Int
    public let indexedCandidateCount: Int
    public let containingCandidateCount: Int
}

/// 时间有序 interval lookup。所有可插值 segment 的跨度都不超过 maxSpan，
/// 因此包含 timestamp 的 segment 必然从 [timestamp - maxSpan, timestamp] 开始。
/// 两次二分后只检查这个有界窗口，不再为每张照片扫描全部 segment。
private struct TrailSegmentTimeIndex {
    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let segmentIndex: Int
    }

    private static let bucketWidth: TimeInterval = 300
    private static let maximumBucketedSpan: TimeInterval = 1_200

    private let buckets: [Int64: [Entry]]
    private let longEntries: [Entry]
    private let maximumSpan: TimeInterval

    init(segments: [TrailSegment], points: [TrailPoint], maximumSpan: TimeInterval) {
        self.maximumSpan = maximumSpan
        var builtBuckets: [Int64: [Entry]] = [:]
        var builtLongEntries: [Entry] = []
        for (segmentIndex, segment) in segments.enumerated() {
            let start = points[segment.aIndex].t
            let end = points[segment.bIndex].t
            let entry = Entry(start: start, end: end, segmentIndex: segmentIndex)
            if end - start <= Self.maximumBucketedSpan {
                let startBucket = Self.bucket(for: start)
                let endBucket = Self.bucket(for: end)
                for bucket in startBucket...endBucket {
                    builtBuckets[bucket, default: []].append(entry)
                }
            } else {
                builtLongEntries.append(entry)
            }
        }
        buckets = builtBuckets
        longEntries = builtLongEntries.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.segmentIndex < $1.segmentIndex
        }
    }

    func candidates(containing time: TimeInterval) -> (indices: [Int], indexedCount: Int) {
        let bucketEntries = buckets[Self.bucket(for: time)] ?? []
        var indices: [Int] = []
        indices.reserveCapacity(bucketEntries.count + 4)
        // 短 segment 已按覆盖时间桶写入；边界仍需精确过滤。
        for entry in bucketEntries where entry.start <= time && entry.end >= time {
            indices.append(entry.segmentIndex)
        }

        let lower = lowerBound(for: time - maximumSpan)
        let upper = upperBound(for: time)
        if lower < upper {
            for entry in longEntries[lower..<upper] where entry.end >= time {
                indices.append(entry.segmentIndex)
            }
        }
        return (indices, bucketEntries.count + max(0, upper - lower))
    }

    private static func bucket(for time: TimeInterval) -> Int64 {
        Int64(floor(time / bucketWidth))
    }

    private func lowerBound(for time: TimeInterval) -> Int {
        var low = 0
        var high = longEntries.count
        while low < high {
            let mid = low + (high - low) / 2
            if longEntries[mid].start < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func upperBound(for time: TimeInterval) -> Int {
        var low = 0
        var high = longEntries.count
        while low < high {
            let mid = low + (high - low) / 2
            if longEntries[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }
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

/// 单次照片聚合批次内的精确空间查询缓存。键使用 Double 原始位模式，
/// 不合并“附近”坐标；仅复用经纬度完全相同的空间投影。
struct TrailSnapQueryContext {
    fileprivate struct SpatialKey: Hashable {
        let latitudeBits: UInt64
        let longitudeBits: UInt64
    }

    fileprivate enum CachedSpatialMatch {
        case match(TrailLocationMatch, Double)
        case noMatch
    }

    fileprivate var spatialMatches: [SpatialKey: CachedSpatialMatch] = [:]
    private(set) var spatialCacheHits = 0
    private(set) var spatialCacheMisses = 0

    fileprivate mutating func cachedSpatialMatch(
        lat: Double, lon: Double,
        build: () -> (match: TrailLocationMatch, distance: Double)?
    ) -> (match: TrailLocationMatch, distance: Double)? {
        let key = SpatialKey(latitudeBits: lat.bitPattern, longitudeBits: lon.bitPattern)
        if let cached = spatialMatches[key] {
            spatialCacheHits += 1
            switch cached {
            case let .match(match, distance): return (match, distance)
            case .noMatch: return nil
            }
        }
        spatialCacheMisses += 1
        let result = build()
        // 约 0.5MB 级的有界缓存；达到上限后清空只影响性能，不影响结果。
        if spatialMatches.count >= 4_096 { spatialMatches.removeAll(keepingCapacity: true) }
        if let result {
            spatialMatches[key] = .match(result.match, result.distance)
        } else {
            spatialMatches[key] = .noMatch
        }
        return result
    }
}

/// 轨迹空间+时间索引：
/// - 路段边界网格找最近投影点（精确 ≤60m / 吸附 ≤500m）
/// - 时间桶 + 长路段索引做拍摄时间插值（无 GPS 照片按时间定位）
public struct TrailIndex {
    private static let maximumInterpolationSpan: TimeInterval = 7_200
    private static let segmentSpatialCell = 0.0005
    private static let maximumSegmentSpatialCells = 512

    /// 与旧 `String(format: "%.3f_%.3f", ...)` 完全同构的值类型网格键。
    /// 旧格式会区分 `-0.000` 与 `0.000`；保留负零位可避免赤道和本初
    /// 子午线附近的候选集合发生变化，同时消除照片匹配热路径中的字符串分配。
    private struct GridKey: Hashable {
        let latitudeCell: Int
        let longitudeCell: Int
        let latitudeNegativeZero: Bool
        let longitudeNegativeZero: Bool
    }

    /// 路段包围盒索引使用更细的 floor 网格。查询只返回包围盒可能与
    /// 60/500m 搜索圆相交的路段，最终命中仍由原投影与球面距离公式决定。
    private struct SegmentSpatialKey: Hashable {
        let latitudeCell: Int
        let longitudeCell: Int
    }

    public let points: [TrailPoint]
    private let grid: [GridKey: [Int]]
    private let segments: [TrailSegment]
    private let segmentSpatialGrid: [SegmentSpatialKey: [Int]]
    private let largeSpatialSegments: [Int]
    private let polarSpatialSegments: [Int]
    private let segmentTimeIndex: TrailSegmentTimeIndex

    public init(points: [TrailPoint]) {
        self.points = points.sorted { $0.t < $1.t }
        var grid: [GridKey: [Int]] = [:]
        for (i, p) in self.points.enumerated() {
            grid[Self.key(p.lat, p.lon), default: []].append(i)
        }
        self.grid = grid

        // 先按领域边界分组，再连接组内相邻点；全局时间相邻不能覆盖 Session/Segment。
        let indexedPoints = self.points
        var builtSegments: [TrailSegment] = []
        var builtSpatialGrid: [SegmentSpatialKey: [Int]] = [:]
        var builtLargeSpatialSegments: [Int] = []
        var builtPolarSpatialSegments: [Int] = []
        let boundaryGroups = Dictionary(grouping: indexedPoints.indices) { index in
            let point = indexedPoints[index]
            if point.trajectoryID == nil && point.sessionID == nil && point.segmentID == nil {
                return "legacy"
            }
            return "\(point.trajectoryID ?? "-")|\(point.sessionID ?? "-")|\(point.segmentID ?? "-")"
        }
        for group in boundaryGroups.values {
            let ordered = group.sorted { indexedPoints[$0].t < indexedPoints[$1].t }
            if ordered.count > 1 {
                for i in 0..<(ordered.count - 1) {
                    let aIndex = ordered[i], bIndex = ordered[i + 1]
                    let a = indexedPoints[aIndex], b = indexedPoints[bIndex]
                    guard a.sharesBoundary(with: b) else { continue }
                    let dt = b.t - a.t
                    guard dt > 0, dt <= Self.maximumInterpolationSpan else { continue }
                    let distance = GeoMath.distanceMeters(from: (a.lat, a.lon), to: (b.lat, b.lon))
                    let plausibleDistance = min(20_000, max(2_000, dt * 15))
                    guard distance <= plausibleDistance else { continue }
                    let segmentIndex = builtSegments.count
                    builtSegments.append(TrailSegment(aIndex: aIndex, bIndex: bIndex))
                    if max(abs(a.lat), abs(b.lat)) >= 85 {
                        builtPolarSpatialSegments.append(segmentIndex)
                    }
                    let latitudeCells = Self.spatialCellRange(a.lat, b.lat)
                    let longitudeCells = Self.spatialCellRange(a.lon, b.lon)
                    let cellCount = latitudeCells.count * longitudeCells.count
                    if cellCount <= Self.maximumSegmentSpatialCells {
                        for latitudeCell in latitudeCells {
                            for longitudeCell in longitudeCells {
                                builtSpatialGrid[SegmentSpatialKey(
                                    latitudeCell: latitudeCell,
                                    longitudeCell: longitudeCell), default: []]
                                    .append(segmentIndex)
                            }
                        }
                    } else {
                        // 极少数长对角线段避免扩张成巨型矩形；查询时始终纳入，
                        // 最终仍走同一距离判断，因此不会遗漏或改变结果。
                        builtLargeSpatialSegments.append(segmentIndex)
                    }
                }
            }
        }
        self.segments = builtSegments
        self.segmentSpatialGrid = builtSpatialGrid
        self.largeSpatialSegments = builtLargeSpatialSegments
        self.polarSpatialSegments = builtPolarSpatialSegments
        self.segmentTimeIndex = TrailSegmentTimeIndex(
            segments: builtSegments, points: indexedPoints,
            maximumSpan: Self.maximumInterpolationSpan)
    }

    /// 0.002° 网格 key
    private static func key(_ lat: Double, _ lon: Double) -> GridKey {
        let latitudeCell = (lat * 500).rounded()
        let longitudeCell = (lon * 500).rounded()
        return GridKey(
            latitudeCell: Int(latitudeCell),
            longitudeCell: Int(longitudeCell),
            latitudeNegativeZero: latitudeCell == 0 && latitudeCell.sign == .minus,
            longitudeNegativeZero: longitudeCell == 0 && longitudeCell.sign == .minus)
    }

    private static func spatialCellRange(_ first: Double, _ second: Double)
        -> ClosedRange<Int> {
        let lower = Int(floor(min(first, second) / segmentSpatialCell))
        let upper = Int(floor(max(first, second) / segmentSpatialCell))
        return lower...upper
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
        // 110,000m/degree is deliberately conservative for latitude. Longitude
        // uses the smallest scale across the latitude search band, so every
        // segment that could pass the exact distance check remains a candidate.
        let latitudeDelta = maxMeters / 110_000
        let maximumAbsoluteLatitude = min(
            89.999_999,
            max(abs(lat - latitudeDelta), abs(lat + latitudeDelta)))
        let longitudeMetersPerDegree = max(
            1, 110_000 * cos(maximumAbsoluteLatitude * .pi / 180))
        let longitudeDelta = maxMeters / longitudeMetersPerDegree
        let latitudeCells = Self.spatialCellRange(lat - latitudeDelta, lat + latitudeDelta)
        let longitudeCells = Self.spatialCellRange(lon - longitudeDelta, lon + longitudeDelta)
        var candidates = Set<Int>(minimumCapacity: 256)
        let (queryCellCount, overflow) = latitudeCells.count.multipliedReportingOverflow(
            by: longitudeCells.count)
        if overflow || queryCellCount > 65_536 {
            // 接近极点时 500m 可能横跨大量经度 cell。若整个纬度搜索带都在
            // 极区，只扫极区 segment；否则退回全 segment。两条路径都只扩大
            // 候选集合，最终投影与球面距离判断不变。
            if abs(lat) - latitudeDelta >= 85 {
                candidates.formUnion(polarSpatialSegments)
            } else {
                candidates.formUnion(segments.indices)
            }
        } else {
            for latitudeCell in latitudeCells {
                for longitudeCell in longitudeCells {
                    if let ids = segmentSpatialGrid[SegmentSpatialKey(
                        latitudeCell: latitudeCell, longitudeCell: longitudeCell)] {
                        candidates.formUnion(ids)
                    }
                }
            }
        }
        candidates.formUnion(largeSpatialSegments)
        // Keep only scalar projection data while scanning. Constructing a
        // TrailLocationMatch for each successively closer candidate retains
        // and releases trajectory/session/segment Strings in the hottest loop.
        var best: (segmentIndex: Int, lat: Double, lon: Double,
                   time: TimeInterval, distance: Double)?
        for id in candidates {
            let segment = segments[id]
            // Read scalar fields directly so an unoptimised diagnostic build
            // does not copy the full TrailPoint (including optional Strings)
            // twice for every spatial candidate.
            let aLat = points[segment.aIndex].lat
            let aLon = points[segment.aIndex].lon
            let aTime = points[segment.aIndex].t
            let bLat = points[segment.bIndex].lat
            let bLon = points[segment.bIndex].lon
            let bTime = points[segment.bIndex].t
            let meanLat = (lat + aLat + bLat) / 3 * .pi / 180
            let metersPerLon = max(1, 111_320 * cos(meanLat))
            let ax = (aLon - lon) * metersPerLon
            let ay = (aLat - lat) * 111_320
            let bx = (bLon - lon) * metersPerLon
            let by = (bLat - lat) * 111_320
            let vx = bx - ax, vy = by - ay
            let lengthSquared = vx * vx + vy * vy
            let fraction = lengthSquared > 0
                ? min(1, max(0, -(ax * vx + ay * vy) / lengthSquared)) : 0
            let projectedLat = aLat + (bLat - aLat) * fraction
            let projectedLon = aLon + (bLon - aLon) * fraction
            let distance = GeoMath.distanceMeters(from: (lat, lon),
                                                  to: (projectedLat, projectedLon))
            if distance <= maxMeters, best == nil || distance < best!.distance {
                best = (id, projectedLat, projectedLon,
                        aTime + (bTime - aTime) * fraction, distance)
            }
        }
        guard let best else { return nil }
        let segment = segments[best.segmentIndex]
        let a = points[segment.aIndex]
        return (TrailLocationMatch(
            lat: best.lat, lon: best.lon, time: best.time,
            source: a.source,
            trajectoryID: a.trajectoryID,
            sessionID: a.sessionID,
            segmentID: a.segmentID,
            confidence: min(a.confidence, points[segment.bIndex].confidence)), best.distance)
    }

    /// 时间插值：照片时间在轨迹时间范围内 → 前后两点线性插值。
    /// 仅在两分钟内的同段记录之间推断，不向轨迹时间范围外延伸。
    public func interpolate(at time: TimeInterval) -> (lat: Double, lon: Double)? {
        guard let match = interpolateMatch(at: time) else { return nil }
        return (match.lat, match.lon)
    }

    fileprivate func interpolateMatch(
        at time: TimeInterval,
        onQuery: ((TrailIndexQueryStats) -> Void)? = nil
    ) -> TrailLocationMatch? {
        guard points.count >= 2 else { return nil }
        guard let first = points.first, let last = points.last else { return nil }
        guard time >= first.t, time <= last.t else { return nil }
        if time == first.t { return locationMatch(at: first) }
        if time == last.t { return locationMatch(at: last) }

        // 多条轨迹可在时间上重叠。只在同一领域 Segment 内插值，优先高置信度候选；
        // 置信度相同时继续选择原 segments 中最早的候选，保持旧 filter + max 语义。
        let query = segmentTimeIndex.candidates(containing: time)
        onQuery?(TrailIndexQueryStats(
            totalSegmentCount: segments.count,
            indexedCandidateCount: query.indexedCount,
            containingCandidateCount: query.indices.count))
        let candidates = query.indices
        var selectedIndex: Int?
        var selectedConfidence = -Double.infinity
        for index in candidates {
            let segment = segments[index]
            guard points[segment.bIndex].t - points[segment.aIndex].t <=
                    TrackConnectionPolicy.maximumPhotoInterpolationInterval else { continue }
            let confidence = min(points[segment.aIndex].confidence,
                                 points[segment.bIndex].confidence)
            if confidence > selectedConfidence ||
                (confidence == selectedConfidence && index < (selectedIndex ?? .max)) {
                selectedIndex = index
                selectedConfidence = confidence
            }
        }
        guard let selectedIndex else { return nil }
        let segment = segments[selectedIndex]
        let a = points[segment.aIndex]
        let b = points[segment.bIndex]
        guard a.sharesBoundary(with: b) else { return nil }
        let span = b.t - a.t
        guard span > 0, span <= TrackConnectionPolicy.maximumPhotoInterpolationInterval else { return nil }
        let k = (time - a.t) / span
        return TrailLocationMatch(
            lat: a.lat + (b.lat - a.lat) * k,
            lon: a.lon + (b.lon - a.lon) * k,
            time: time, source: a.source,
            trajectoryID: a.trajectoryID,
            sessionID: a.sessionID,
            segmentID: a.segmentID,
            confidence: min(a.confidence, b.confidence))
    }

    /// 供性能回归与 signpost 汇总使用；不会改变匹配结果。
    public func interpolationQueryStats(at time: TimeInterval) -> TrailIndexQueryStats {
        let query = segmentTimeIndex.candidates(containing: time)
        return TrailIndexQueryStats(
            totalSegmentCount: segments.count,
            indexedCandidateCount: query.indexedCount,
            containingCandidateCount: query.indices.count)
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
                                   trails: TrailIndex?,
                                   onTemporalQuery: ((TrailIndexQueryStats) -> Void)? = nil)
    -> TrailSnapResult {
    var queryContext = TrailSnapQueryContext()
    return snapPhotoToTrailResult(
        lat: lat, lon: lon, time: time, trails: trails,
        queryContext: &queryContext, onTemporalQuery: onTemporalQuery)
}

func snapPhotoToTrailResult(lat: Double, lon: Double, time: TimeInterval,
                            trails: TrailIndex?,
                            queryContext: inout TrailSnapQueryContext,
                            onTemporalQuery: ((TrailIndexQueryStats) -> Void)? = nil)
    -> TrailSnapResult {
    guard let trails else { return TrailSnapResult(kind: .kept, lat: lat, lon: lon) }
    let valid = GeoMath.isValid(latitude: lat, longitude: lon)
    if valid {
        // 按拍摄时间取轨迹位置：同一段线路上不同时刻的照片落在不同位置
        if let p = trails.interpolateMatch(at: time, onQuery: onTemporalQuery) {
            let d = GeoMath.distanceMeters(from: (lat, lon), to: (p.lat, p.lon))
            if d <= 60 { return matchResult(.exact, p, distance: d, photoTime: time) }
            if d <= 500 { return matchResult(.snapped, p, distance: d, photoTime: time) }
        }
        // 回退到最近路段的投影点，让标记真正落在路线上。
        let near = queryContext.cachedSpatialMatch(lat: lat, lon: lon) {
            if let exact = trails.nearestOnRouteMatch(to: lat, lon: lon, within: 60) {
                return exact
            }
            // 仍然是同一个 ≤500m 最近路段规则。渐进半径只避免路线实际很近时
            // 扫描整个 1km 直径范围；较小半径命中后外圈不可能产生更近结果。
            for radius in [125.0, 250.0, 500.0] {
                if let snapped = trails.nearestOnRouteMatch(
                    to: lat, lon: lon, within: radius) {
                    return snapped
                }
            }
            return nil
        }
        if let near {
            let kind: TrailMatchKind = near.distance <= 60 ? .exact : .snapped
            return matchResult(kind, near.match, distance: near.distance, photoTime: time)
        }
        return TrailSnapResult(kind: .kept, lat: lat, lon: lon)
    }
    // 无有效 GPS → 时间插值（间隙保护：跨线路不定位）
    if let p = trails.interpolateMatch(at: time, onQuery: onTemporalQuery) {
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
