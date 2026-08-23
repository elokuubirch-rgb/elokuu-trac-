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

    init(draft: FootprintDraft) {
        self.latitude = draft.latitude
        self.longitude = draft.longitude
        self.timestamp = draft.timestamp
        self.sourceRaw = draft.source
    }

    var source: FootprintSource {
        FootprintSource(rawValue: sourceRaw) ?? .manual
    }
}
