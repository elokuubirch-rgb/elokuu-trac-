import Foundation

/// 路线边界和来源在同一 segment 的大量点之间完全相同。把这部分不可变语义
/// 独立出来共享，避免每个点都内联保存五个 16-byte String / Optional<String>。
/// 所有公开读取属性仍返回原值，值相等语义不变。
final class FootprintSnapshotMetadata: Sendable {
    let source: String
    let trajectoryID: String?
    let sessionID: String?
    let segmentID: String?
    let isSuppressedDuplicate: Bool
    let suppressedBySource: String?

    init(source: String, trajectoryID: String?, sessionID: String?, segmentID: String?,
         isSuppressedDuplicate: Bool, suppressedBySource: String?) {
        self.source = source
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.isSuppressedDuplicate = isSuppressedDuplicate
        self.suppressedBySource = suppressedBySource
    }

    static let photo = simple(FootprintSource.photo.rawValue)
    static let csv = simple(FootprintSource.csv.rawValue)
    static let manual = simple(FootprintSource.manual.rawValue)
    static let gps = simple(FootprintSource.gps.rawValue)
    static let health = simple(FootprintSource.health.rawValue)

    private static func simple(_ source: String) -> FootprintSnapshotMetadata {
        FootprintSnapshotMetadata(
            source: source, trajectoryID: nil, sessionID: nil, segmentID: nil,
            isSuppressedDuplicate: false, suppressedBySource: nil)
    }

    static func standardIfAvailable(
        source: String, trajectoryID: String?, sessionID: String?, segmentID: String?,
        isSuppressedDuplicate: Bool, suppressedBySource: String?
    ) -> FootprintSnapshotMetadata? {
        guard trajectoryID == nil, sessionID == nil, segmentID == nil,
              !isSuppressedDuplicate, suppressedBySource == nil else { return nil }
        switch source {
        case FootprintSource.photo.rawValue: return .photo
        case FootprintSource.csv.rawValue: return .csv
        case FootprintSource.manual.rawValue: return .manual
        case FootprintSource.gps.rawValue: return .gps
        case FootprintSource.health.rawValue: return .health
        default: return nil
        }
    }
}

struct FootprintSnapshotMetadataKey: Hashable, Sendable {
    let source: String
    let trajectoryID: String?
    let sessionID: String?
    let segmentID: String?
    let isSuppressedDuplicate: Bool
    let suppressedBySource: String?
}

/// 单次 snapshot materialization 使用的局部驻留池；生命周期不超过构建任务，
/// 但已生成的快照会继续强持有实际使用到的少量 metadata。
struct FootprintSnapshotMetadataPool {
    private var values: [FootprintSnapshotMetadataKey: FootprintSnapshotMetadata] = [:]

    var count: Int { values.count }

    mutating func metadata(
        source: String, trajectoryID: String?, sessionID: String?, segmentID: String?,
        isSuppressedDuplicate: Bool, suppressedBySource: String?
    ) -> FootprintSnapshotMetadata {
        if let standard = FootprintSnapshotMetadata.standardIfAvailable(
            source: source, trajectoryID: trajectoryID, sessionID: sessionID,
            segmentID: segmentID, isSuppressedDuplicate: isSuppressedDuplicate,
            suppressedBySource: suppressedBySource) {
            return standard
        }
        let key = FootprintSnapshotMetadataKey(
            source: source, trajectoryID: trajectoryID, sessionID: sessionID,
            segmentID: segmentID, isSuppressedDuplicate: isSuppressedDuplicate,
            suppressedBySource: suppressedBySource)
        if let existing = values[key] { return existing }
        let value = FootprintSnapshotMetadata(
            source: source, trajectoryID: trajectoryID, sessionID: sessionID,
            segmentID: segmentID, isSuppressedDuplicate: isSuppressedDuplicate,
            suppressedBySource: suppressedBySource)
        values[key] = value
        return value
    }
}

/// 足迹点轻量快照：后台线程一次性物化，UI 只消费值类型（避免 SwiftData 主线程逐行 fault）。
/// 坐标和时间仍内联；重复的来源/路线边界通过不可变 metadata 共享。
public struct FootprintSnapshot: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let t: Date
    private let metadata: FootprintSnapshotMetadata

    /// 数据来源（health/gps 为路线点，线层全量保留——线路优先级）
    public var source: String { metadata.source }
    public var trajectoryID: String? { metadata.trajectoryID }
    public var sessionID: String? { metadata.sessionID }
    public var segmentID: String? { metadata.segmentID }
    /// 原始点仍保留在统计中；重复来源只从点/线显示层排除。
    public var isSuppressedDuplicate: Bool { metadata.isSuppressedDuplicate }
    public var suppressedBySource: String? { metadata.suppressedBySource }

    public init(lat: Double, lon: Double, t: Date, source: String = "csv",
                trajectoryID: String? = nil, sessionID: String? = nil,
                segmentID: String? = nil, isSuppressedDuplicate: Bool = false,
                suppressedBySource: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.t = t
        self.metadata = FootprintSnapshotMetadata.standardIfAvailable(
            source: source, trajectoryID: trajectoryID, sessionID: sessionID,
            segmentID: segmentID, isSuppressedDuplicate: isSuppressedDuplicate,
            suppressedBySource: suppressedBySource) ?? FootprintSnapshotMetadata(
                source: source, trajectoryID: trajectoryID, sessionID: sessionID,
                segmentID: segmentID, isSuppressedDuplicate: isSuppressedDuplicate,
                suppressedBySource: suppressedBySource)
    }

    init(lat: Double, lon: Double, t: Date, metadata: FootprintSnapshotMetadata) {
        self.lat = lat
        self.lon = lon
        self.t = t
        self.metadata = metadata
    }

    public static func == (lhs: FootprintSnapshot, rhs: FootprintSnapshot) -> Bool {
        if lhs.lat != rhs.lat || lhs.lon != rhs.lon || lhs.t != rhs.t { return false }
        if lhs.metadata === rhs.metadata { return true }
        return lhs.source == rhs.source
            && lhs.trajectoryID == rhs.trajectoryID
            && lhs.sessionID == rhs.sessionID
            && lhs.segmentID == rhs.segmentID
            && lhs.isSuppressedDuplicate == rhs.isSuppressedDuplicate
            && lhs.suppressedBySource == rhs.suppressedBySource
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
