import Foundation
import SwiftData

/// SwiftData 持久化模型：一张带 GPS 的照片 = 一个点
/// （FootprintSource 定义在 CoreLogic，rawValue 作为持久化字符串）
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
