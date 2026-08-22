import Foundation

/// 行政区域层级（与文档 §4 一致）
public enum RegionLevel {
    public static let country = "country"
    public static let province = "province"
    public static let city = "city"
    public static let district = "district"

    public static let all = [country, province, city, district]
}

/// 逆地理编码结果：四级行政区 + 层级判断（纯值类型，可单测）
public struct RegionInfo: Equatable {
    public var country: String?
    public var province: String?
    public var city: String?
    public var district: String?

    public init(country: String? = nil, province: String? = nil, city: String? = nil, district: String? = nil) {
        self.country = country
        self.province = province
        self.city = city
        self.district = district
    }

    /// 当前可达的最细层级
    public var finestLevel: String {
        if district != nil { return RegionLevel.district }
        if city != nil { return RegionLevel.city }
        if province != nil { return RegionLevel.province }
        return RegionLevel.country
    }

    /// 取某一层级的区域名（无则返回 nil）
    public func name(at level: String) -> String? {
        switch level {
        case RegionLevel.country: return country
        case RegionLevel.province: return province
        case RegionLevel.city: return city
        case RegionLevel.district: return district
        default: return nil
        }
    }
}

/// 时间轴年份筛选：月份数组中某年的起始下标。
/// 该年无数据 → 回退到最后一个月下标（"全部"语义）。
public func yearStartIndex(months: [Date], year: Int) -> Int {
    guard let index = months.firstIndex(where: { Calendar.current.component(.year, from: $0) == year }) else {
        return max(0, months.count - 1)
    }
    return index
}

/// 同级随机选择：排除当前区域与最近浏览过的区域。
/// 无候选返回 nil（此时应退出自动探索，不跨级跳转——文档 §19/§24）。
public func randomCandidate<T: Hashable>(_ candidates: [T], excluding: T, recent: [T]) -> T? {
    var pool = Set(candidates)
    pool.remove(excluding)
    for r in recent {
        pool.remove(r)
    }
    guard !pool.isEmpty else { return nil }
    return Array(pool).randomElement()
}

/// 海拔平滑：最近 N 次有效数据的移动平均，避免 GPS 误差导致的海拔跳变（文档 §6）
public struct AltitudeSmoother {
    public let windowSize: Int
    private var history: [Double] = []

    public init(windowSize: Int = 5) {
        self.windowSize = max(1, windowSize)
    }

    /// 推入一个原始值，返回平滑后的海拔
    public mutating func push(_ value: Double) -> Double {
        history.append(value)
        if history.count > windowSize {
            history.removeFirst()
        }
        return history.reduce(0, +) / Double(history.count)
    }

    public var smoothed: Double? {
        history.isEmpty ? nil : history.reduce(0, +) / Double(history.count)
    }
}
