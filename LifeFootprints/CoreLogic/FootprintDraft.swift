import Foundation

/// 未入库的足迹点（纯值类型，可被解析器 / 扫描器生成，与 UI 无关）
public struct FootprintDraft: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var source: String
    public var city: String?
    public var trajectoryID: String?
    public var sessionID: String?
    public var segmentID: String?
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var speed: Double?
    public var course: Double?
    /// Coordinate values exactly as supplied by the source before normalization.
    public var rawLatitude: Double
    public var rawLongitude: Double
    public var sourceCoordinateSystem: CoordinateReferenceSystem
    public var coordinateTransformVersion: Int?

    public init(latitude: Double, longitude: Double, timestamp: Date, source: String,
                city: String? = nil, trajectoryID: String? = nil,
                sessionID: String? = nil, segmentID: String? = nil,
                altitude: Double? = nil, horizontalAccuracy: Double? = nil,
                speed: Double? = nil, course: Double? = nil,
                rawLatitude: Double? = nil, rawLongitude: Double? = nil,
                sourceCoordinateSystem: CoordinateReferenceSystem = .unknown,
                coordinateTransformVersion: Int? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.source = source
        self.city = city
        self.trajectoryID = trajectoryID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.rawLatitude = rawLatitude ?? latitude
        self.rawLongitude = rawLongitude ?? longitude
        self.sourceCoordinateSystem = sourceCoordinateSystem
        self.coordinateTransformVersion = coordinateTransformVersion
    }

    public var wasCoordinateTransformed: Bool { coordinateTransformVersion != nil }
}

/// 数据来源标识（rawValue 作为持久化字符串）
public enum FootprintSource: String {
    case photo
    case csv
    case manual
    case gps
    case health
}
