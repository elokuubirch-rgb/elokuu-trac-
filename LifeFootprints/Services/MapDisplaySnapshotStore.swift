import Foundation
import MapKit

/// A bounded launch preview. Never used as the raw source or for statistics.
struct MapDisplaySnapshot: Codable {
    struct Point: Codable {
        let lat: Double
        let lon: Double
        let time: Date
        let source: String
        let trajectory: String?
        let session: String?
        let segment: String?
        let suppressed: Bool
        let suppressor: String?

        init(_ point: FootprintSnapshot) {
            lat = point.lat; lon = point.lon; time = point.t; source = point.source
            trajectory = point.trajectoryID; session = point.sessionID
            segment = point.segmentID; suppressed = point.isSuppressedDuplicate
            suppressor = point.suppressedBySource
        }
        var snapshot: FootprintSnapshot {
            FootprintSnapshot(lat: lat, lon: lon, t: time, source: source,
                trajectoryID: trajectory, sessionID: session, segmentID: segment,
                isSuppressedDuplicate: suppressed, suppressedBySource: suppressor)
        }
    }

    let schema: Int
    let geometryPolicy: Int
    let trajectoryRevision: Int
    let placeRevision: Int
    let safetyRevision: Int
    let generatedAt: Date
    let points: [Point]
    let months: [Date]
    let latitude: Double
    let longitude: Double
    let latitudeSpan: Double
    let longitudeSpan: Double
    let pointCount: Int
    let distanceKM: Double
    let activeDays: Int
    let firstDate: Date?
    let lastDate: Date?
    let perYear: [String: Int]

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude),
            span: .init(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan))
    }
    var stats: FootprintStats {
        var result = FootprintStats()
        result.pointCount = pointCount; result.distanceKM = distanceKM
        result.activeDays = activeDays; result.firstDate = firstDate; result.lastDate = lastDate
        result.perYear = perYear.compactMap { key, value in
            Int(key).map { (year: $0, count: value) }
        }.sorted { $0.year < $1.year }
        return result
    }

    func replacingPoints(_ replacement: [Point]) -> MapDisplaySnapshot {
        MapDisplaySnapshot(
            schema: schema, geometryPolicy: geometryPolicy,
            trajectoryRevision: trajectoryRevision, placeRevision: placeRevision,
            safetyRevision: safetyRevision, generatedAt: generatedAt,
            points: replacement, months: months,
            latitude: latitude, longitude: longitude,
            latitudeSpan: latitudeSpan, longitudeSpan: longitudeSpan,
            pointCount: pointCount, distanceKM: distanceKM,
            activeDays: activeDays, firstDate: firstDate, lastDate: lastDate,
            perYear: perYear)
    }
}

final class MapDisplaySnapshotStore: @unchecked Sendable {
    static let shared = MapDisplaySnapshotStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("map-display-preview-v1.plist"))
    /// The preview only needs enough geometry to preserve the shape of a world or
    /// regional view. Exact source points remain in SwiftData and trajectory chunks.
    static let targetPointCount = 12_000
    static let maximumPoints = 24_000
    /// Read the previous release's larger preview once, then bound it in memory.
    static let maximumReadablePoints = 60_000
    static let maximumBytes = 32 * 1_024 * 1_024
    private let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func load(revision: DataRevisionSnapshot,
              safetyRevision: Int = DataRevisionStore.displaySafetyRevision()) -> MapDisplaySnapshot? {
        lock.withLock {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumBytes,
                  let data = try? Data(contentsOf: url),
                  let value = try? PropertyListDecoder().decode(MapDisplaySnapshot.self, from: data),
                  value.schema == 2,
                  value.geometryPolicy == PersistentTrajectoryCache.geometryPresentationVersion,
                  value.safetyRevision == safetyRevision,
                  value.trajectoryRevision <= revision.trajectory,
                  value.placeRevision <= revision.place,
                  value.points.count <= Self.maximumReadablePoints,
                  value.points.allSatisfy({ $0.lat.isFinite && $0.lon.isFinite
                      && abs($0.lat) <= 90 && abs($0.lon) <= 180 }),
                  value.latitude.isFinite, value.longitude.isFinite,
                  abs(value.latitude) <= 90, abs(value.longitude) <= 180,
                  value.latitudeSpan.isFinite, value.longitudeSpan.isFinite,
                  value.latitudeSpan > 0, value.longitudeSpan > 0 else { return nil }
            guard value.points.count > Self.maximumPoints else { return value }
            guard let bounded = Self.previewPoints(value.points.map(\.snapshot)) else {
                return value
            }
            return value.replacingPoints(bounded)
        }
    }

    /// Retain both ends of every explicit route/segment plus legacy inferred boundaries.
    /// Health workouts can overlap in time, so adjacency in the globally sorted array is
    /// not a route boundary: track each explicit identity independently instead.
    /// Uniform samples only consume the budget left after mandatory boundary points.
    static func previewPoints(_ points: [FootprintSnapshot]) -> [MapDisplaySnapshot.Point]? {
        guard !points.isEmpty else { return [] }
        var retained = Set<Int>()
        retained.reserveCapacity(min(points.count, Self.maximumPoints))
        var monthCursor = CalendarMonthCursor()

        struct RouteKey: Hashable {
            let layer: UInt8
            let identity: String
        }
        func key(for point: FootprintSnapshot, layer: UInt8) -> RouteKey? {
            guard let identity = point.segmentID ?? point.trajectoryID ?? point.sessionID else {
                return nil
            }
            return RouteKey(layer: layer, identity: identity)
        }

        var firstByRoute: [RouteKey: Int] = [:]
        var lastByRoute: [RouteKey: Int] = [:]
        var previousAuto: Int?
        var previousWorkout: Int?
        for i in points.indices {
            let monthChanged = monthCursor.advance(to: points[i].t)
            if i > 0, monthChanged {
                retained.insert(i - 1)
                retained.insert(i)
            }
            if MapLayerSemantics.isAutoTrajectory(
                points[i], workoutSourceVisible: false) {
                if let routeKey = key(for: points[i], layer: 0) {
                    firstByRoute[routeKey] = firstByRoute[routeKey] ?? i
                    if let previous = lastByRoute[routeKey],
                       points[previous].isSuppressedDuplicate != points[i].isSuppressedDuplicate
                        || points[previous].suppressedBySource != points[i].suppressedBySource {
                        retained.insert(previous)
                        retained.insert(i)
                    }
                    lastByRoute[routeKey] = i
                } else {
                    retainLegacyBoundary(from: previousAuto, to: i,
                                         points: points, retained: &retained)
                    previousAuto = i
                }
            }
            if MapLayerSemantics.isWorkoutTrajectory(
                points[i], autoSourceVisible: false) {
                if let routeKey = key(for: points[i], layer: 1) {
                    firstByRoute[routeKey] = firstByRoute[routeKey] ?? i
                    if let previous = lastByRoute[routeKey],
                       points[previous].isSuppressedDuplicate != points[i].isSuppressedDuplicate
                        || points[previous].suppressedBySource != points[i].suppressedBySource {
                        retained.insert(previous)
                        retained.insert(i)
                    }
                    lastByRoute[routeKey] = i
                } else {
                    retainLegacyBoundary(from: previousWorkout, to: i,
                                         points: points, retained: &retained)
                    previousWorkout = i
                }
            }
        }
        retained.insert(points.startIndex)
        retained.insert(points.index(before: points.endIndex))
        retained.formUnion(firstByRoute.values)
        retained.formUnion(lastByRoute.values)
        if let previousAuto { retained.insert(previousAuto) }
        if let previousWorkout { retained.insert(previousWorkout) }
        guard retained.count <= maximumPoints else { return nil }

        let desiredCount = min(Self.targetPointCount, Self.maximumPoints)
        let remainingSlots = max(0, desiredCount - retained.count)
        if remainingSlots > 0 {
            let step = max(1, (points.count + remainingSlots - 1) / remainingSlots)
            var index = 0
            while index < points.count, retained.count < desiredCount {
                retained.insert(index)
                index += step
            }
        }
        return retained.sorted().map { MapDisplaySnapshot.Point(points[$0]) }
    }

    private static func retainLegacyBoundary(
        from previous: Int?, to current: Int,
        points: [FootprintSnapshot], retained: inout Set<Int>
    ) {
        guard let previous else { return }
        let a = points[previous]
        let b = points[current]
        let suppressionChanged = a.isSuppressedDuplicate != b.isSuppressedDuplicate
            || a.suppressedBySource != b.suppressedBySource
        let inferredBreak = b.t.timeIntervalSince(a.t) > 45 * 60
            || GeoMath.distanceMeters(from: (a.lat, a.lon), to: (b.lat, b.lon)) > 3000
        guard a.source != b.source || suppressionChanged || inferredBreak else { return }
        retained.insert(previous)
        retained.insert(current)
    }

    @discardableResult
    func save(points: [FootprintSnapshot], months: [Date], region: MKCoordinateRegion,
              stats: FootprintStats, revision: DataRevisionSnapshot,
              safetyRevision: Int = DataRevisionStore.displaySafetyRevision()) -> Bool {
        guard let preview = Self.previewPoints(points) else {
            #if DEBUG
            PerformanceDiagnostics.event("MapDisplaySnapshot.saveRejected",
                                         metadata: "reason=pointBudget input=\(points.count)")
            PerformanceDiagnostics.count("MapDisplaySnapshot.saveRejected.pointBudget")
            #endif
            return false
        }
        let value = MapDisplaySnapshot(schema: 2,
            geometryPolicy: PersistentTrajectoryCache.geometryPresentationVersion,
            trajectoryRevision: revision.trajectory, placeRevision: revision.place,
            safetyRevision: safetyRevision,
            generatedAt: Date(), points: preview, months: months,
            latitude: region.center.latitude, longitude: region.center.longitude,
            latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta,
            pointCount: stats.pointCount, distanceKM: stats.distanceKM, activeDays: stats.activeDays,
            firstDate: stats.firstDate, lastDate: stats.lastDate,
            perYear: Dictionary(uniqueKeysWithValues: stats.perYear.map { (String($0.year), $0.count) }))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value) else {
            #if DEBUG
            PerformanceDiagnostics.event("MapDisplaySnapshot.saveRejected",
                                         metadata: "reason=encode preview=\(preview.count)")
            PerformanceDiagnostics.count("MapDisplaySnapshot.saveRejected.encode")
            #endif
            return false
        }
        guard data.count <= Self.maximumBytes else {
            #if DEBUG
            PerformanceDiagnostics.event("MapDisplaySnapshot.saveRejected",
                                         metadata: "reason=byteBudget bytes=\(data.count) preview=\(preview.count)")
            PerformanceDiagnostics.count("MapDisplaySnapshot.saveRejected.byteBudget")
            #endif
            return false
        }
        return lock.withLock {
            let current = DataRevisionStore.snapshot()
            guard current.trajectory >= revision.trajectory,
                  current.place >= revision.place,
                  DataRevisionStore.displaySafetyRevision() == safetyRevision else {
                #if DEBUG
                PerformanceDiagnostics.event("MapDisplaySnapshot.saveRejected",
                                             metadata: "reason=revision")
                PerformanceDiagnostics.count("MapDisplaySnapshot.saveRejected.revision")
                #endif
                return false
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var persistedURL = url
                try? persistedURL.setResourceValues(values)
                #if DEBUG
                PerformanceDiagnostics.event("MapDisplaySnapshot.saved",
                                             metadata: "bytes=\(data.count) preview=\(preview.count)")
                #endif
                return true
            } catch {
                #if DEBUG
                PerformanceDiagnostics.event("MapDisplaySnapshot.saveRejected",
                                             metadata: "reason=write error=\(error.localizedDescription)")
                PerformanceDiagnostics.count("MapDisplaySnapshot.saveRejected.write")
                #endif
                return false
            }
        }
    }

    func clear() { lock.withLock { try? FileManager.default.removeItem(at: url) } }
}
