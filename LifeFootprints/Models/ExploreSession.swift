import Foundation
import SwiftData

enum ReviewSource: Equatable {
    case globalReview
    case mapCluster(clusterID: String)
}

/// 用户的 Live Photo 偏好跨所有回顾组和地图照片会话共享；播放中的资源仍由页面单独管理。
@MainActor
@Observable
final class ReviewLivePlaybackPreferences {
    static let shared = ReviewLivePlaybackPreferences()

    private enum Key {
        static let autoPlay = "reviewLiveAutoPlayEnabled"
        static let muted = "reviewLiveMuted"
    }

    @ObservationIgnored private let defaults: UserDefaults
    var autoPlayEnabled: Bool {
        didSet { defaults.set(autoPlayEnabled, forKey: Key.autoPlay) }
    }
    var muted: Bool {
        didSet { defaults.set(muted, forKey: Key.muted) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoPlayEnabled = defaults.bool(forKey: Key.autoPlay)
        muted = defaults.object(forKey: Key.muted) as? Bool ?? true
    }
}

/// 区域照片探索会话：状态机驱动「当前区域浏览 → 同级随机跳转 → 无限探索」
/// （文档 §17/§18/§19/§21/§23/§24）
@MainActor
@Observable
final class ExploreSession: Identifiable {
    let id = UUID()
    let source: ReviewSource

    /// 当前浏览的行政层级（同级跳转的核心约束）
    let level: String
    private(set) var regionName: String
    private(set) var photos: [PhotoRecord] = []
    private(set) var index = 0
    /// 每次原子替换照片批次时更新。UI 用它切断旧卡片、旧背景和手势状态的视图身份。
    private(set) var batchID = UUID()
    private(set) var pendingRemovalIDs: Set<String> = []
    /// 新组和地图会话均使用同一份用户偏好，而非重置为会话默认值。
    let livePreferences: ReviewLivePlaybackPreferences
    var liveAutoPlayEnabled: Bool {
        get { livePreferences.autoPlayEnabled }
        set { livePreferences.autoPlayEnabled = newValue }
    }
    var liveMuted: Bool {
        get { livePreferences.muted }
        set { livePreferences.muted = newValue }
    }
    /// Location Review 的完整候选数及本会话已展示集合。
    private(set) var sourcePhotoCount = 0
    private(set) var displayedPhotoIDs: Set<String> = []
    private(set) var allCandidatePhotoIDs: [String] = []
    /// 最近浏览过的区域（防重复随机，上限 4）
    private(set) var recent: [String] = []
    /// 照片 id 集合会话（点分组进入）：翻完循环回第一张，不跳去其他区域
    private(set) var isPlaceCollection = false
    private var preparedNextPhotos: [PhotoRecord]?
    /// 地点纵向导航历史：下滑可回到上一个地点。
    private struct PlaceHistoryEntry {
        let name: String
        let photoIDs: [String]?
    }
    private var placeHistory: [PlaceHistoryEntry] = []
    private var placeHistoryIndex = -1
    private var pendingHistoryIndex: Int?

    enum NavigationDirection: Equatable {
        case next
        case previous
    }
    private(set) var navigationDirection: NavigationDirection = .next

    enum Phase: Equatable {
        case browsing
        case transitioning(String)   // 正在前往下一个区域
        case transitioningToNextBatch // 确认删除后冻结旧组，等待原子切换
        case review                  // 当前组浏览完成，复核待移除照片或进入下一组
        case done                    // 当前级别暂无更多照片
    }
    private(set) var phase: Phase = .browsing

    private let context: ModelContext

    init(level: String, regionName: String, context: ModelContext,
         source: ReviewSource = .globalReview,
         livePreferences: ReviewLivePlaybackPreferences? = nil) {
        self.level = level
        self.regionName = regionName
        self.context = context
        self.source = source
        self.livePreferences = livePreferences ?? .shared
    }

    /// 当前照片
    var currentPhoto: PhotoRecord? {
        guard !isTransitioningToNextBatch else { return nil }
        return photos.indices.contains(index) ? photos[index] : nil
    }

    /// 浏览进度 "12 / 48"
    var progressText: String {
        "\(progressIndex) / \(progressCount)"
    }

    var progressIndex: Int { isTransitioningToNextBatch || photos.isEmpty ? 0 : index + 1 }
    var progressCount: Int { isTransitioningToNextBatch ? 0 : photos.count }
    var isTransitioningToNextBatch: Bool {
        if case .transitioningToNextBatch = phase { return true }
        return false
    }

    var canGoToPreviousPlace: Bool { placeHistoryIndex > 0 }
    var canGoToPreviousPhoto: Bool { index > 0 || (isPlaceCollection && photos.count > 1) }
    var pendingRemovalCount: Int { pendingRemovalIDs.count }
    var pendingRemovalPhotos: [PhotoRecord] {
        photos.filter { pendingRemovalIDs.contains($0.localIdentifier) }
    }

    /// 完成页始终使用同一组确定性代表照片，避免视图重算时“预览乱跳”。
    var completionPreviewPhotos: [PhotoRecord] {
        guard photos.count > 3 else { return photos }
        return [photos[0], photos[photos.count / 2], photos[photos.count - 1]]
    }

    var isLocationReview: Bool {
        if case .mapCluster = source { return true }
        return false
    }

    var hasUnseenPhotos: Bool { sourcePhotoCount > displayedPhotoIDs.count }

    var completionKind: ReviewCompletionKind {
        isLocationReview ? .location(hasUnseenPhotos: hasUnseenPhotos) : .global
    }

    /// 随机起点定位：限制在开头到「倒数第 4 张」之间——
    /// 保证首屏至少 3 张背卡可见（堆叠效果），同时每次进入从不同位置开始看
    private func clampedStart(_ startAt: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(startAt, 0), max(0, count - 4))
    }

    /// 加载某区域照片（进入新区域时调用；startAt 指定起始照片索引）
    func loadPhotos(for name: String, startAt: Int = 0) {
        let sourcePhotos = PhotoStore.photos(level: level, regionName: name, in: context)
        photos = timeStratifiedSample(sourcePhotos)
        batchID = UUID()
        sourcePhotoCount = sourcePhotos.count
        allCandidatePhotoIDs = sourcePhotos.map(\.localIdentifier)
        displayedPhotoIDs.formUnion(photos.map(\.localIdentifier))
        regionName = name
        isPlaceCollection = false
        index = 0
        pendingRemovalIDs.removeAll()
        phase = .browsing
        recordHistory(PlaceHistoryEntry(name: name, photoIDs: nil))
        noteCurrentPhotoPresented()
        scheduleNextRoundPreparation()
        let count = photos.count
        let currentLevel = level
        let startIndex = index
        appLog.info("[Explore] 开始浏览「\(name)」\(count) 张照片（\(currentLevel)级，从第\(startIndex + 1)张）")
    }

    /// 按照片 id 集合加载（地点级网格聚合：网格内全部照片，随机洗牌——
    /// 用户要求：点进一组照片后随机刷取，每次进入顺序不同）
    func loadPhotos(ids: [String], startAt: Int = 0, preservingOrder: Bool = false) {
        let sourcePhotos = PhotoStore.records(ids: ids, in: context)
        if preservingOrder {
            let byID = Dictionary(uniqueKeysWithValues: sourcePhotos.map { ($0.localIdentifier, $0) })
            photos = ids.compactMap { byID[$0] }
        } else {
            photos = timeStratifiedSample(sourcePhotos)
        }
        batchID = UUID()
        sourcePhotoCount = sourcePhotos.count
        allCandidatePhotoIDs = ids
        displayedPhotoIDs.formUnion(photos.map(\.localIdentifier))
        regionName = "此地"
        isPlaceCollection = true
        index = 0
        pendingRemovalIDs.removeAll()
        phase = .browsing
        recordHistory(PlaceHistoryEntry(name: regionName, photoIDs: ids))
        noteCurrentPhotoPresented()
        scheduleNextRoundPreparation()
        let count = photos.count
        let startIndex = index
        appLog.info("[Explore] 开始浏览地点聚合 \(count) 张照片（随机顺序，从第\(startIndex + 1)张）")
    }

    /// 地图内删除可能发生在常驻回顾页之外。返回前只剔除已不存在的照片，
    /// 保留原顺序与当前张；若当前张被删，优先接着看下一张，末尾则回到上一张。
    func reconcileAvailablePhotos() {
        let oldPhotos = photos
        guard !oldPhotos.isEmpty else { return }
        let available = Set(PhotoStore.records(ids: oldPhotos.map(\.localIdentifier), in: context)
            .map(\.localIdentifier))
        guard available.count != oldPhotos.count else { return }
        let oldIndex = min(index, oldPhotos.count - 1)
        let oldID = oldPhotos[oldIndex].localIdentifier
        let removedBefore = oldPhotos.prefix(oldIndex).filter { !available.contains($0.localIdentifier) }.count
        photos = oldPhotos.filter { available.contains($0.localIdentifier) }
        index = photos.isEmpty ? 0 : min(oldIndex - removedBefore, photos.count - 1)
        allCandidatePhotoIDs.removeAll { !available.contains($0) }
        displayedPhotoIDs.formIntersection(available)
        pendingRemovalIDs.formIntersection(available)
        sourcePhotoCount = allCandidatePhotoIDs.count
        batchID = UUID()
        if photos.isEmpty {
            phase = .done
        } else if photos[index].localIdentifier != oldID {
            noteCurrentPhotoPresented()
        }
    }

    func availablePhotoIDs(from ids: [String]) -> [String] {
        let available = Set(PhotoStore.records(ids: ids, in: context).map(\.localIdentifier))
        return ids.filter { available.contains($0) }
    }

    /// 手动重新洗牌（探索页右上角按钮）：本组照片顺序打乱，回到第一张
    func reshuffle() {
        guard photos.count > 1 else { return }
        photos.shuffle()
        batchID = UUID()
        index = 0
        phase = .browsing
        noteCurrentPhotoPresented()
        let count = photos.count
        appLog.info("[Explore] 重新洗牌：\(count) 张照片")
    }

    /// 下一张（左滑/右滑均进入下一张；照片组会话循环回第一张，区域会话滑完自动跳转）
    func advance() {
        guard !photos.isEmpty else { return }
        if index + 1 < photos.count {
            index += 1
            noteCurrentPhotoPresented()
        } else {
            phase = .review
        }
    }

    /// 右滑返回上一张；地点照片组在第一张时循环到最后一张。
    func retreat() {
        guard !photos.isEmpty else { return }
        if index > 0 {
            index -= 1
            noteCurrentPhotoPresented()
        }
    }

    func togglePendingRemovalForCurrentPhoto() {
        guard let photo = currentPhoto else { return }
        togglePendingRemoval(id: photo.localIdentifier)
    }

    func togglePendingRemoval(id: String) {
        if pendingRemovalIDs.contains(id) { pendingRemovalIDs.remove(id) }
        else { pendingRemovalIDs.insert(id) }
    }

    /// 只有照片真正成为 Viewer 当前展示才更新回顾历史（LOAD / PRELOAD / COVER ≠ REVIEWED）。
    func noteCurrentPhotoPresented() {
        guard let photo = currentPhoto else { return }
        ReviewHistoryStore.recordReviewed(photoIDs: [photo.localIdentifier], at: Date())
    }

    func cancelPendingRemovals() {
        pendingRemovalIDs.removeAll()
        phase = .browsing
    }

    func reviewAgain() {
        index = 0
        phase = .browsing
        noteCurrentPhotoPresented()
    }

    /// 结束页“再来一组”：留在当前地点，从完整来源重新随机抽取最多 20 张。
    func startNextRound() {
        guard phase == .review else { return }
        pendingRemovalIDs.removeAll()
        replaceWithNextRound()
    }

    func abandonDeletionAndStartNextRound() {
        guard phase == .review else { return }
        pendingRemovalIDs.removeAll()
        replaceWithNextRound()
    }

    /// 确认删除按钮提交后立即冻结旧 batch。此时 currentPhoto/progress 都不再读取旧数组。
    @discardableResult
    func beginConfirmedDeletionTransition() -> Set<String> {
        guard phase == .review, !pendingRemovalIDs.isEmpty else { return [] }
        phase = .transitioningToNextBatch
        return pendingRemovalIDs
    }

    /// PhotoKit 删除失败时恢复原确认页；旧 batch 从未被局部修改。
    func restoreDeletionReviewAfterFailure() {
        guard isTransitioningToNextBatch else { return }
        phase = .review
    }

    enum ConfirmedDeletionAdvance: Equatable {
        case mapBatchReady
        case mapClusterExhausted
        case globalReviewNeedsNextGroup
    }

    /// 删除成功后的唯一提交点。Map Review 在锁定的 Cluster 候选中原子换组；
    /// Global Review 先清空旧组，再交给 ReviewTabView 沿用现有全局选组算法。
    @discardableResult
    func completeConfirmedDeletionTransition() -> ConfirmedDeletionAdvance {
        guard isTransitioningToNextBatch else {
            return isLocationReview ? .mapClusterExhausted : .globalReviewNeedsNextGroup
        }
        pendingRemovalIDs.removeAll()
        preparedNextPhotos = nil

        guard isLocationReview else {
            photos = []
            batchID = UUID()
            index = 0
            return .globalReviewNeedsNextGroup
        }

        let completeSource = completeSourcePhotos()
        sourcePhotoCount = completeSource.count
        let unseen = completeSource.filter { !displayedPhotoIDs.contains($0.localIdentifier) }
        let next = timeStratifiedSample(unseen)
        photos = next
        batchID = UUID()
        index = 0
        guard !next.isEmpty else {
            // 维持冻结态直到 Viewer 退出；删除成功路径不能重新落回完成页。
            return .mapClusterExhausted
        }
        displayedPhotoIDs.formUnion(next.map(\.localIdentifier))
        phase = .browsing
        noteCurrentPhotoPresented()
        scheduleNextRoundPreparation()
        return .mapBatchReady
    }

    /// 下一组优先消费浏览期间准备好的数据；没有预备组时在同一事务中直接生成并替换。
    /// 这里没有视觉 loading phase，也没有人为延时。
    private func replaceWithNextRound() {
        if let prepared = preparedNextPhotos, !prepared.isEmpty {
            preparedNextPhotos = nil
            photos = prepared
            batchID = UUID()
            displayedPhotoIDs.formUnion(prepared.map(\.localIdentifier))
            index = 0
            phase = .browsing
            noteCurrentPhotoPresented()
            scheduleNextRoundPreparation()
            return
        }

        let completeSource = completeSourcePhotos()
        guard !completeSource.isEmpty else { return }
        var candidates = completeSource.filter {
            !displayedPhotoIDs.contains($0.localIdentifier)
        }
        if candidates.isEmpty {
            // “继续看看”允许在当前 Cluster 全部看完后重置本 Session 随机池。
            // 删除成功路径不经过这里，仍会在无剩余时直接结束地图回顾。
            displayedPhotoIDs.removeAll()
            candidates = completeSource
        }
        photos = timeStratifiedSample(candidates)
        batchID = UUID()
        displayedPhotoIDs.formUnion(photos.map(\.localIdentifier))
        index = 0
        phase = .browsing
        noteCurrentPhotoPresented()
        scheduleNextRoundPreparation()
        appLog.info("[Explore] 再来一组：留在「\(self.regionName)」重新抽取 \(self.photos.count) 张")
    }

    private func scheduleNextRoundPreparation() {
        preparedNextPhotos = nil
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.phase == .browsing else { return }
            let completeSource = self.completeSourcePhotos()
            let unseen = completeSource.filter { !self.displayedPhotoIDs.contains($0.localIdentifier) }
            guard !unseen.isEmpty else { return }
            let next = self.timeStratifiedSample(unseen)
            self.preparedNextPhotos = next
            let warmIDs = Array(next.prefix(3).map(\.localIdentifier))
            Task.detached(priority: .utility) {
                for id in warmIDs { _ = await PhotoThumbnailGenerator.image(localID: id) }
            }
        }
    }

#if DEBUG
    /// 仅供模拟器截图回归；正式构建不会暴露此入口。
    func showReviewForTesting() {
        pendingRemovalIDs.removeAll()
        phase = .review
    }

    func showDeletionReviewForTesting(count: Int) {
        pendingRemovalIDs = Set(photos.prefix(max(1, count)).map(\.localIdentifier))
        // 必须模拟真实路径：用户已完整浏览到旧 batch 最后一张后才看到删除确认页。
        index = max(0, photos.count - 1)
        phase = .review
    }
#endif

    func photosOnCurrentLocalDay() -> [PhotoRecord] {
        guard let currentPhoto else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        return PhotoStore.all(in: context)
            .filter { calendar.isDate($0.timestamp, inSameDayAs: currentPhoto.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Around Day 只读取当前日期前后指定天数，避免把整个相册带进布局层。
    func photosAroundCurrentDay(dayRadius: Int) -> [PhotoRecord] {
        guard let currentPhoto else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: currentPhoto.timestamp)
        guard let lower = calendar.date(byAdding: .day, value: -dayRadius, to: day),
              let upperStart = calendar.date(byAdding: .day, value: dayRadius + 1, to: day) else { return [] }
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.timestamp >= lower && $0.timestamp < upperStart },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 上滑：前往下一个地点。若用户曾下滑回退，优先沿历史向前。
    func requestNextPlace() {
        guard phase == .browsing else { return }
        if placeHistory.indices.contains(placeHistoryIndex + 1) {
            pendingHistoryIndex = placeHistoryIndex + 1
            navigationDirection = .next
            phase = .transitioning(placeHistory[placeHistoryIndex + 1].name)
            return
        }
        let current = regionName
        let exclusions = recent + Array(placeHistory.map(\.name).suffix(4))
        guard let next = PhotoStore.randomRegion(level: level, excluding: current,
                                                   recent: Array(exclusions), in: context) else {
            phase = .review
            return
        }
        pendingHistoryIndex = nil
        navigationDirection = .next
        phase = .transitioning(next)
    }

    /// 下滑：回到上一个浏览过的地点。
    func requestPreviousPlace() {
        guard phase == .browsing, placeHistory.indices.contains(placeHistoryIndex - 1) else { return }
        pendingHistoryIndex = placeHistoryIndex - 1
        navigationDirection = .previous
        phase = .transitioning(placeHistory[placeHistoryIndex - 1].name)
    }

    /// 地图相机飞行完成后由 MapScreen 调用，保留正确的前进/后退指针。
    func completePlaceTransition(to name: String) {
        if let target = pendingHistoryIndex, placeHistory.indices.contains(target) {
            placeHistoryIndex = target
            loadHistoryEntry(placeHistory[target])
        } else {
            let entry = PlaceHistoryEntry(name: name, photoIDs: nil)
            if placeHistoryIndex + 1 < placeHistory.count {
                placeHistory.removeSubrange((placeHistoryIndex + 1)..<placeHistory.count)
            }
            placeHistory.append(entry)
            placeHistoryIndex = placeHistory.count - 1
            loadHistoryEntry(entry)
        }
        pendingHistoryIndex = nil
    }

    private func recordHistory(_ entry: PlaceHistoryEntry) {
        if placeHistory.indices.contains(placeHistoryIndex),
           placeHistory[placeHistoryIndex].name == entry.name { return }
        if placeHistoryIndex + 1 < placeHistory.count {
            placeHistory.removeSubrange((placeHistoryIndex + 1)..<placeHistory.count)
        }
        placeHistory.append(entry)
        placeHistoryIndex = placeHistory.count - 1
    }

    private func loadHistoryEntry(_ entry: PlaceHistoryEntry) {
        if let ids = entry.photoIDs {
            photos = timeStratifiedSample(PhotoStore.records(ids: ids, in: context))
            allCandidatePhotoIDs = ids
            isPlaceCollection = true
        } else {
            let sourcePhotos = PhotoStore.photos(level: level, regionName: entry.name, in: context)
            photos = timeStratifiedSample(sourcePhotos)
            allCandidatePhotoIDs = sourcePhotos.map(\.localIdentifier)
            isPlaceCollection = false
        }
        batchID = UUID()
        regionName = entry.name
        index = 0
        pendingRemovalIDs.removeAll()
        phase = .browsing
        noteCurrentPhotoPresented()
    }

    /// 先覆盖尽可能多的月份，再洗牌；避免简单随机仍连续命中同一天/同一趟行程。
    private func timeStratifiedSample(_ source: [PhotoRecord], limit: Int = 20) -> [PhotoRecord] {
        #if DEBUG
        if let mode = TestHooks.photoLayoutMode {
            let wantedRemainder = mode == "portrait" ? 1 : 0
            return Array(source.sorted { lhs, rhs in
                func rank(_ photo: PhotoRecord) -> Int {
                    let number = Int(photo.localIdentifier.split(separator: "-").last ?? "-1") ?? -1
                    return number >= 0 && number % 3 == wantedRemainder ? 0 : 1
                }
                return rank(lhs) < rank(rhs)
            }.prefix(limit))
        }
        #endif
        guard source.count > limit else { return spreadAdjacentDays(source.shuffled()) }
        let calendar = Calendar.autoupdatingCurrent
        var buckets = Dictionary(grouping: source) { photo in
            let c = calendar.dateComponents([.year, .month], from: photo.timestamp)
            return (c.year ?? 0) * 100 + (c.month ?? 0)
        }.mapValues { $0.shuffled() }
        var keys = Array(buckets.keys).shuffled()
        var result: [PhotoRecord] = []
        while result.count < limit, !keys.isEmpty {
            keys.shuffle()
            for key in keys where result.count < limit {
                if let photo = buckets[key]?.popLast() { result.append(photo) }
            }
            keys.removeAll { buckets[$0]?.isEmpty != false }
        }
        return spreadAdjacentDays(result.shuffled())
    }

    private func spreadAdjacentDays(_ source: [PhotoRecord]) -> [PhotoRecord] {
        var remaining = source
        var result: [PhotoRecord] = []
        let calendar = Calendar.autoupdatingCurrent
        while !remaining.isEmpty {
            let candidate = remaining.firstIndex { photo in
                guard let last = result.last else { return true }
                return !calendar.isDate(photo.timestamp, inSameDayAs: last.timestamp)
            } ?? 0
            result.append(remaining.remove(at: candidate))
        }
        return result
    }

    /// Map Cluster 使用进入时锁定的完整 ID 集合；普通区域探索才按行政区重新查询。
    private func completeSourcePhotos() -> [PhotoRecord] {
        PhotoStore.records(ids: allCandidatePhotoIDs, in: context)
    }

    /// 当前区域照片全部浏览完成 → 查询同级其他有照片区域并随机选择
    private func finishCurrentRegion() {
        recent.append(regionName)
        if recent.count > 4 {
            recent.removeFirst()
        }
        let currentLevel = level
        let currentRegion = regionName
        requestNextPlace()
        if case .transitioning(let next) = phase {
            appLog.info("[Explore] 「\(currentRegion)」浏览完成 → 前往「\(next)」")
        } else {
            appLog.info("[Explore] 当前级别（\(currentLevel)）暂无更多照片 → 退出探索")
        }
    }
}
