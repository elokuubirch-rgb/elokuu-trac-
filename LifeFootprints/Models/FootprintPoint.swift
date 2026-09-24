import Foundation
import SwiftData

/// SwiftData 持久化模型：导入地点或 Core Location 自动足迹。
/// 旧数据库可能仍含 source=photo 的兼容记录，但新照片只写入 PhotoRecord。
@Model
final class FootprintPoint {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var sourceRaw: String
    var trajectoryID: String?
    var sessionID: String?
    var segmentID: String?
    var altitude: Double?
    var horizontalAccuracy: Double?
    var speed: Double?
    var course: Double?
    /// Populated only when the stored WGS-84 value differs from the source value.
    var rawLatitude: Double?
    var rawLongitude: Double?
    /// nil in legacy databases means `.unknown`.
    var sourceCoordinateSystemRaw: String?
    var coordinateTransformVersion: Int?

    init(draft: FootprintDraft) {
        self.latitude = draft.latitude
        self.longitude = draft.longitude
        self.timestamp = draft.timestamp
        self.sourceRaw = draft.source
        self.trajectoryID = draft.trajectoryID
        self.sessionID = draft.sessionID
        self.segmentID = draft.segmentID
        self.altitude = draft.altitude
        self.horizontalAccuracy = draft.horizontalAccuracy
        self.speed = draft.speed
        self.course = draft.course
        self.rawLatitude = draft.wasCoordinateTransformed ? draft.rawLatitude : nil
        self.rawLongitude = draft.wasCoordinateTransformed ? draft.rawLongitude : nil
        self.sourceCoordinateSystemRaw = draft.sourceCoordinateSystem.rawValue
        self.coordinateTransformVersion = draft.coordinateTransformVersion
    }

    var source: FootprintSource {
        FootprintSource(rawValue: sourceRaw) ?? .manual
    }


    var sourceCoordinateSystem: CoordinateReferenceSystem {
        sourceCoordinateSystemRaw.flatMap(CoordinateReferenceSystem.init(rawValue:)) ?? .unknown
    }

    var originalLatitude: Double { rawLatitude ?? latitude }
    var originalLongitude: Double { rawLongitude ?? longitude }
}
