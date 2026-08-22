import Foundation

public enum ReviewDisplayState: Equatable, Sendable {
    case browsing
    case refreshing
    case completion
    case finished
}

public enum ReviewCompletionKind: Equatable, Sendable {
    case global
    case location(hasUnseenPhotos: Bool)
}

public enum ReviewMediaFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case livePhoto
    case selfie
    case screenshot

    public var title: String {
        switch self {
        case .all: return "全部照片"
        case .livePhoto: return "实况"
        case .selfie: return "自拍"
        case .screenshot: return "截屏"
        }
    }
}

public enum ReviewCompletionLogic {
    public static func primaryTitle(for kind: ReviewCompletionKind) -> String {
        switch kind {
        case .global: return "再来一组"
        case .location(let hasUnseen): return hasUnseen ? "继续看看" : "返回地图"
        }
    }
}

/// V2 地图统一时间范围。地图的足迹、运动与照片必须消费同一个选择结果。
public enum MapTimeScope: Hashable, Sendable {
    case all
    case year(Int)

    public static func choices(currentYear: Int) -> [MapTimeScope] {
        [.all, .year(currentYear), .year(currentYear - 1), .year(currentYear - 2)]
    }

    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        switch self {
        case .all: return true
        case .year(let year): return calendar.component(.year, from: date) == year
        }
    }
}

/// 与 PhotoKit/SwiftData 解耦的候选快照，便于后台 Actor 计算及单元测试。
public struct ReviewCandidate: Equatable, Sendable {
    public let id: String
    public let date: Date
    public let latitude: Double?
    public let longitude: Double?
    public let lastReviewedAt: Date?
    public let reviewCount: Int

    public init(id: String, date: Date, latitude: Double? = nil, longitude: Double? = nil,
                lastReviewedAt: Date? = nil, reviewCount: Int = 0) {
        self.id = id
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.lastReviewedAt = lastReviewedAt
        self.reviewCount = reviewCount
    }
}

/// 第一阶段的可解释回顾抽样：时间分层、地点分散、连续拍摄降权、最近曝光降权。
/// 不读取图片，也不依赖 UI；后续可在相同接口下增加感知哈希和人生事件加权。
public enum ReviewSelectionLogic {
    public static func select(_ source: [ReviewCandidate], limit: Int = 20,
                              now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [ReviewCandidate] {
        guard limit > 0, !source.isEmpty else { return [] }
        var remaining = source.sorted {
            score($0, now: now) == score($1, now: now) ? $0.id < $1.id : score($0, now: now) > score($1, now: now)
        }
        var result: [ReviewCandidate] = []
        var monthUse: [Int: Int] = [:]
        var placeUse: [String: Int] = [:]

        while result.count < min(limit, source.count), !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (index, candidate) in remaining.enumerated() {
                let month = monthKey(candidate.date, calendar: calendar)
                let place = placeKey(candidate)
                var value = score(candidate, now: now)
                value /= pow(2.4, Double(monthUse[month, default: 0]))
                value /= pow(2.0, Double(placeUse[place, default: 0]))
                if let last = result.last,
                   abs(candidate.date.timeIntervalSince(last.date)) < 90 { value *= 0.18 }
                if value > bestScore { bestScore = value; bestIndex = index }
            }
            let chosen = remaining.remove(at: bestIndex)
            result.append(chosen)
            monthUse[monthKey(chosen.date, calendar: calendar), default: 0] += 1
            placeUse[placeKey(chosen), default: 0] += 1
        }
        return result
    }

    private static func score(_ item: ReviewCandidate, now: Date) -> Double {
        let daysSinceReview = item.lastReviewedAt.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 3650
        let freshness = min(4, 0.35 + daysSinceReview / 120)
        return freshness / (1 + Double(max(0, item.reviewCount)) * 0.4)
    }

    private static func monthKey(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 100 + (c.month ?? 0)
    }

    private static func placeKey(_ item: ReviewCandidate) -> String {
        guard let lat = item.latitude, let lon = item.longitude else { return "none:\(item.id)" }
        return "\(Int((lat * 50).rounded())):\(Int((lon * 50).rounded()))"
    }
}

/// Live Photo 自动播放的纯状态门控。异步资源返回时必须再次通过此判断，避免快速滑动串图。
public enum ReviewLivePlaybackLogic {
    public static func shouldStart(
        requestedAssetID: String,
        currentAssetID: String?,
        autoPlayEnabled: Bool,
        resourceReady: Bool,
        isInteracting: Bool
    ) -> Bool {
        autoPlayEnabled
            && resourceReady
            && !isInteracting
            && currentAssetID == requestedAssetID
    }
}
