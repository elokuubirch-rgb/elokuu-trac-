import Foundation

/// 未入库的足迹点（纯值类型，可被解析器 / 扫描器生成，与 UI 无关）
public struct FootprintDraft: Equatable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var source: String
    public var city: String?

    public init(latitude: Double, longitude: Double, timestamp: Date, source: String, city: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.source = source
        self.city = city
    }
}

/// 数据来源标识（rawValue 作为持久化字符串）
public enum FootprintSource: String {
    case photo
    case csv
    case manual
    case gps
    case health
}
