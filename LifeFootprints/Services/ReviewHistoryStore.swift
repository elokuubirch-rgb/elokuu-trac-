import Foundation

/// 回顾历史持久化：photoID → lastReviewedAt / reviewCount。
/// 只有照片真正在 Viewer 展示（didPresentPhoto）才更新；预加载/封面/生成组都不算。
@MainActor
enum ReviewHistoryStore {
    private static let key = "reviewPhotoHistoryV1"

    /// 近期不重复回顾的固定间隔（v1：30 天）。
    static let recentDedupInterval: TimeInterval = 30 * 86_400

    static func history() -> [String: ReviewHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: ReviewHistoryEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// 批量记录“真正看过”（追加 reviewCount，更新 lastReviewedAt）。
    static func recordReviewed(photoIDs: [String], at date: Date) {
        guard !photoIDs.isEmpty else { return }
        var dict = history()
        let timestamp = date.timeIntervalSince1970
        for id in photoIDs {
            var entry = dict[id] ?? ReviewHistoryEntry()
            entry.lastReviewedAt = timestamp
            entry.reviewCount += 1
            dict[id] = entry
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Global Review 的三组概览属于本地回顾状态，完整 Reset 后不可恢复旧 Model ID。
enum ReviewSessionPersistence {
    static let groupsKey = "reviewSessionGroupsV2"
    static let currentIndexKey = "reviewSessionCurrentIndexV2"

    @MainActor
    static func save<T: Encodable>(_ groups: [T], currentIndex: Int?) {
        guard LocalImportCoordinator.shared.capture() != nil else { return }
        // No session is absence, not an encoded empty array recreated after reset.
        guard !groups.isEmpty else { reset(); return }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: groupsKey)
        if let currentIndex { UserDefaults.standard.set(currentIndex, forKey: currentIndexKey) }
        else { UserDefaults.standard.removeObject(forKey: currentIndexKey) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: groupsKey)
        UserDefaults.standard.removeObject(forKey: currentIndexKey)
    }
}
