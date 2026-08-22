import Foundation
import SwiftData

/// 照片地理绑定：一张带 GPS 的照片 = 一个可探索的记忆点（文档 §9/§11）
/// regionState: 0=未逆地理 1=已完成 2=失败；thumbState: 0=未生成缩略图 1=已完成
@Model
final class PhotoRecord {
    var localIdentifier: String
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var altitude: Double

    var countryName: String?
    var provinceName: String?
    var cityName: String?
    var districtName: String?
    var regionState: Int

    var thumbnailPath: String?
    var thumbState: Int

    init(localIdentifier: String, latitude: Double, longitude: Double, timestamp: Date,
         altitude: Double = 0, thumbnailPath: String? = nil) {
        self.localIdentifier = localIdentifier
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.thumbnailPath = thumbnailPath
        self.regionState = 0
        self.thumbState = thumbnailPath == nil ? 0 : 1
    }

    /// 该照片在某层级下的区域名（nil = 尚未逆地理或无该级）
    func regionName(at level: String) -> String? {
        switch level {
        case RegionLevel.country: return countryName
        case RegionLevel.province: return provinceName
        case RegionLevel.city: return cityName
        case RegionLevel.district: return districtName
        default: return nil
        }
    }
}
