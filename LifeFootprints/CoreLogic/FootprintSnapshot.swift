import Foundation

/// 足迹点轻量快照：后台线程一次性物化，UI 只消费值类型（避免 SwiftData 主线程逐行 fault）
public struct FootprintSnapshot: Equatable {
    public let lat: Double
    public let lon: Double
    public let t: Date
    /// 数据来源（health/gps 为路线点，线层全量保留——线路优先级）
    public let source: String
    public let trajectoryID: String?
    public let sessionID: String?
    public let segmentID: String?

    public init(lat: Double, lon: Double, t: Date, source: String = "csv",
                trajectoryID: String? = nil, sessionID: String? = nil,
                segmentID: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.t = t
        self.source = source
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.segmentID = segmentID
    }
}

/// 快照版统计（纯整数运算，可在后台线程安全执行）
public func snapshotStats(_ snaps: [FootprintSnapshot]) -> (count: Int, distanceKM: Double, activeDays: Int, first: Date?, last: Date?) {
    let sorted = snaps.sorted { $0.t < $1.t }
    var days = Set<Int>()
    var distance = 0.0
    let avgMonthSec = 2_629_800.0
    _ = avgMonthSec
    var prev: (lat: Double, lon: Double, t: Double)?
    for s in sorted {
        let t = s.t.timeIntervalSince1970
        days.insert(Int(t / 86_400))
        if let p = prev, t - p.t < 43_200 {
            distance += GeoMath.distanceMeters(from: (p.lat, p.lon), to: (s.lat, s.lon)) / 1000
        }
        prev = (lat: s.lat, lon: s.lon, t: t)
    }
    return (sorted.count, distance, days.count, sorted.first?.t, sorted.last?.t)
}
