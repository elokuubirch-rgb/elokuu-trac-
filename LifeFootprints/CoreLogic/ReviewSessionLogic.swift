import Foundation

/// 单张照片的回顾历史（LOAD / PRELOAD / COVER 不算“看过”，只有真正在 Viewer 展示才更新）。
public struct ReviewHistoryEntry: Codable, Equatable {
    public var lastReviewedAt: TimeInterval?
    public var reviewCount: Int

    public init(lastReviewedAt: TimeInterval? = nil, reviewCount: Int = 0) {
        self.lastReviewedAt = lastReviewedAt
        self.reviewCount = reviewCount
    }
}

/// 一组回顾的生成计划（纯值类型，可单测）。
public struct ReviewGroupPlan: Equatable {
    public let title: String
    public let photoIDs: [String]

    public init(title: String, photoIDs: [String]) {
        self.title = title
        self.photoIDs = photoIDs
    }
}

/// 回顾 Session 生成逻辑（纯函数，无 iOS 依赖）。
///
/// 状态模型（核心原则）：
/// - candidatePhotoIDs  只表示“符合筛选条件”
/// - preparedPhotoIDs   只表示“性能层预热”
/// - lastReviewedAt/reviewCount 只表示“用户真正看过”
/// - completedGroupIDs  只表示“整组完整刷完”
/// 四者不能互相替代；LOAD ≠ REVIEWED，PRELOAD ≠ REVIEWED，COVER ≠ REVIEWED。
public enum ReviewSessionLogic {

    /// 每组照片数量 clamp：1...100（Store/Model 层也必须限制，不能只靠 UI）。
    public static func clampedGroupSize(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    /// 分层优先级排序：
    /// 第一优先级：从未回顾过
    /// 第二优先级：超过近期去重间隔
    /// 第三优先级：最近回顾过（按 lastReviewedAt 从最久到最近）
    ///
    /// - excludeIDs：当前 Session 已使用的照片（同一轮 Session 内绝不重复）。
    /// - recentInterval：nil = 不启用近期去重；非 nil = 近 N 秒内看过的照片排到末尾
    ///   （候选充足时自然不出现 = 等效“排除”；候选不足时作为回填，不会“断粮”）。
    /// - 层级内 never/stale 打乱增加变化；recent 固定按最久未回顾优先（规格要求）。
    public static func orderedCandidates(
        candidates: [String],
        history: [String: ReviewHistoryEntry],
        excludeIDs: Set<String>,
        recentInterval: TimeInterval?,
        now: TimeInterval
    ) -> [String] {
        var never: [String] = []
        var stale: [String] = []
        var recent: [String] = []
        for id in candidates where !excludeIDs.contains(id) {
            guard let entry = history[id], let last = entry.lastReviewedAt else {
                never.append(id)
                continue
            }
            if let interval = recentInterval, now - last < interval {
                recent.append(id)
            } else {
                stale.append(id)
            }
        }
        recent.sort {
            (history[$0]?.lastReviewedAt ?? 0) < (history[$1]?.lastReviewedAt ?? 0)
        }
        return never.shuffled() + stale.shuffled() + recent
    }

    /// 按 groupSize 分桶：最多 groupCount 组，最后一组可不足；
    /// 不为了凑数重复照片（入参需已去重，同一 Session 内 ID 唯一）。
    public static func buildGroups(
        orderedIDs: [String],
        groupSize: Int,
        groupCount: Int = 3,
        titles: [String] = ["回顾一", "回顾二", "回顾三"]
    ) -> [ReviewGroupPlan] {
        let size = max(groupSize, 1)
        var groups: [ReviewGroupPlan] = []
        var index = 0
        for title in titles.prefix(groupCount) {
            guard index < orderedIDs.count else { break }
            let end = min(index + size, orderedIDs.count)
            groups.append(ReviewGroupPlan(title: title, photoIDs: Array(orderedIDs[index..<end])))
            index = end
        }
        return groups
    }
}
