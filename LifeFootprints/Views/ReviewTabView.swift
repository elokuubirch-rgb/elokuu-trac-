import SwiftUI
import SwiftData
import UIKit

private enum PhotoScreenMode: Equatable {
    case overview
    case group(String)
}

/// 一组回顾（三卡之一）。id 用封面照片 id 保证稳定；completed 只表示“整组完整刷完”。
struct ReviewOverviewGroup: Identifiable, Codable {
    var id: String { previewID }
    let title: String
    var photoIDs: [String]
    let previewID: String
    var completed: Bool = false

    init(title: String, photoIDs: [String], previewID: String, completed: Bool = false) {
        self.title = title
        self.photoIDs = photoIDs
        self.previewID = previewID
        self.completed = completed
    }
}

private enum OverviewMotion {
    static let cardSize = CGSize(width: 224, height: 310)
    static let sideOffset: CGFloat = 92
    static let sideScale: CGFloat = 0.91
    static let rotation = 7.0
    static let radius: CGFloat = 20
}

/// Review 状态模型（规格：LOAD ≠ REVIEWED，PRELOAD ≠ REVIEWED，COVER ≠ REVIEWED）：
/// - 三组属于同一个稳定 Session（持久化到 UserDefaults，切 Tab / 重启不重建）；
/// - “再来一组” = 留在 Viewer 内直接切到 Session 下一组（A→B→C），无总览闪现；
/// - 只有照片真正成为 Viewer 当前展示才更新 lastReviewedAt / reviewCount；
/// - 组只有完整刷到最后一页才 completed；三组全部完成后生成下一轮 Session。
struct ReviewTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("theme") private var themeRaw = AppTheme.crimson.rawValue
    @AppStorage("reviewGroupSize") private var reviewGroupSize = 20
    @AppStorage("reviewRecentDedupEnabled") private var reviewRecentDedupEnabled = true
    @Binding var session: ExploreSession?
    @Binding var groups: [ReviewOverviewGroup]
    /// 常驻架构：回顾页即使被其他 Tab 覆盖也保持挂载；isActive 只影响子页面行为。
    let isActive: Bool
    let onShowLocation: (PhotoRecord, ExploreSession) -> Void
    let onReturnToMap: () -> Void
    let onImmersiveChanged: (Bool) -> Void

    @State private var mode: PhotoScreenMode = .overview
    @State private var openedGroupID: String?
    @State private var mediaFilter: ReviewMediaFilter = .all
    @State private var menuPresented = false
    @State private var previewImages: [String: UIImage] = [:]
    @State private var overviewLoadGeneration = 0
    /// 当前 Session 里正在/最后浏览的组索引（持久化，重启可恢复）
    @State private var currentGroupIndex: Int? = nil

    private static let sessionKey = "reviewSessionGroupsV2"
    private static let sessionIndexKey = "reviewSessionCurrentIndexV2"

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .crimson }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch mode {
            case .overview:
                overview
            case .group:
                if let session {
                    PhotoExploreView(
                        session: session,
                        theme: theme,
                        isActive: isActive,
                        showsDismissButton: true,
                        onShowLocation: { onShowLocation($0, session) },
                        onExitReview: returnToOverview,
                        onDismissRequested: returnToOverview,
                        onNextGroup: advanceToNextGroup
                    )
                    // 只做透明度过渡。scale transition 会在 PhotoExploreView 的共同祖先
                    // 上改变 global frame，使 ROOT/HEADER/MEDIA/LOCATION 同时产生 X 位移。
                    .transition(.opacity)
                } else {
                    overview
                }
            }
        }
        .task {
            await refreshOverviewWhenDataIsReady()
            #if DEBUG
            if TestHooks.autoReviewGroup {
                // 等 onAppear 的中性态重置完成后再走真实 openGroup 路径。
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<24 {
                    if let first = groups.first {
                        if TestHooks.autoOrientationSwipe,
                           let pair = orientationPairForTesting() {
                            openGroup(pair)
                        } else {
                            openGroup(first)
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    prepareSessionIfNeeded()
                }
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            MapDebugLog.log("ReviewTabView onAppear（挂载）")
            #endif
            // 即使根协调器保留了旧 session，初始界面也始终是中性总览。
            mode = .overview
            openedGroupID = nil
            session = nil
            onImmersiveChanged(false)
            prepareSessionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataImported)) { _ in
            // 数据入库只在总览态幂等刷新；正在浏览照片组时绝不打断，也不重洗当前 Session。
            guard case .overview = mode else { return }
            prepareSessionIfNeeded()
        }
    }

    private var overview: some View {
        // 外层 GeometryReader 不忽略安全区，用于正确读取状态栏高度；
        // 内层 ignoresSafeArea 保持背景与三卡全屏居中（卡片位置不因筛选器调整而位移）。
        GeometryReader { safe in
            let topInset = max(safe.safeAreaInsets.top, 20)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    overviewBackground
                    Color.black.opacity(0.20).ignoresSafeArea()

                    // 空白处点击收起菜单：放在卡片层之下，不与卡片 Button 竞争命中。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if menuPresented { withAnimation(.easeOut(duration: 0.16)) { menuPresented = false } }
                        }

                    ReviewGroupStack(groups: groups, images: previewImages,
                                     reduceMotion: reduceMotion,
                                     onTap: openGroup)
                        // 所有卡片共享同一个屏幕中心原点。
                        .frame(width: geo.size.width,
                               height: max(0, geo.size.height - 54),
                               alignment: .center)
                        .position(x: geo.size.width / 2,
                                  y: (geo.size.height - 54) / 2)

                    filterControl
                        .padding(.leading, 16)
                        .padding(.top, topInset + 16)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { onImmersiveChanged(false) }
    }

    @ViewBuilder private var overviewBackground: some View {
        let centerID = groups.indices.contains(1) ? groups[1].previewID : groups.first?.previewID
        if let centerID, let image = previewImages[centerID] {
            Image(uiImage: image).resizable().scaledToFill().scaleEffect(1.18)
                .blur(radius: 44, opaque: true).overlay(Color.black.opacity(0.58)).ignoresSafeArea()
        } else {
            Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()
        }
    }

    private var filterControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { menuPresented.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: menuPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(mediaFilter.title).font(.system(size: 14, weight: .semibold))
                    Text("\(groups.reduce(0) { $0 + $1.photoIDs.count })")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13).frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.13)))
            }
            .buttonStyle(.plain)

            if menuPresented {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ReviewMediaFilter.allCases, id: \.self) { filter in
                        Button { selectFilter(filter) } label: {
                            HStack {
                                Image(systemName: mediaFilter == filter ? "checkmark" : "").frame(width: 18)
                                Text(filter.title)
                                Spacer(minLength: 22)
                            }
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 39)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6).frame(width: 176)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .onTapGesture { }
    }

    // MARK: - Session 生命周期（幂等，切 Tab / onAppear 不重建）

    /// 需要新 Session：没有组，或三组全部完成（准备下一轮）。
    private var needsNewSession: Bool {
        groups.isEmpty || groups.allSatisfy { $0.completed }
    }

    private func prepareSessionIfNeeded() {
        guard needsNewSession else { return }
        buildNewSession()
    }

    /// 生成新一轮 Session：
    /// 候选池(当前筛选) → 排除当前 Session 已用 → 近期去重分层排序 → 按 reviewGroupSize 分三组。
    private func buildNewSession() {
        let records = PhotoStore.all(in: context)
        let allowed = Set(PhotoThumbnailGenerator.matchingIDs(records.map(\.localIdentifier), filter: mediaFilter))
        let candidates = records.filter { allowed.contains($0.localIdentifier) }
        guard !candidates.isEmpty else {
            withAnimation(.easeInOut(duration: 0.35)) { groups = [] }
            currentGroupIndex = nil
            saveSession()
            return
        }
        let exclude = Set(groups.flatMap(\.photoIDs))   // 当前（已完成）Session 已用的照片
        let history = ReviewHistoryStore.history()
        let ordered = ReviewSessionLogic.orderedCandidates(
            candidates: candidates.map(\.localIdentifier),
            history: history,
            excludeIDs: exclude,
            recentInterval: reviewRecentDedupEnabled ? ReviewHistoryStore.recentDedupInterval : nil,
            now: Date().timeIntervalSince1970)
        let size = ReviewSessionLogic.clampedGroupSize(reviewGroupSize)
        let plans = ReviewSessionLogic.buildGroups(orderedIDs: ordered, groupSize: size)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.localIdentifier, $0) })
        withAnimation(.easeInOut(duration: 0.35)) {
            groups = plans.compactMap { plan in
                let ids = plan.photoIDs.filter { byID[$0] != nil }
                guard let first = ids.first else { return nil }
                return ReviewOverviewGroup(title: plan.title, photoIDs: ids, previewID: first, completed: false)
            }
        }
        currentGroupIndex = nil
        saveSession()
        loadPreviewImages()
    }

    /// 冷启动恢复上一轮 Session（过滤已不存在的照片；空组丢弃）。
    private func restoreSessionIfNeeded() {
        guard groups.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let saved = try? JSONDecoder().decode([ReviewOverviewGroup].self, from: data),
              !saved.isEmpty else { return }
        let validGroups: [ReviewOverviewGroup] = saved.compactMap { savedGroup in
            let existing = savedGroup.photoIDs.filter { !PhotoStore.records(ids: [$0], in: context).isEmpty }
            guard !existing.isEmpty else { return nil }
            return ReviewOverviewGroup(title: savedGroup.title,
                                       photoIDs: existing,
                                       previewID: existing.first ?? "",
                                       completed: savedGroup.completed)
        }
        if !validGroups.isEmpty {
            groups = validGroups
            currentGroupIndex = UserDefaults.standard.object(forKey: Self.sessionIndexKey) as? Int
            loadPreviewImages()
        }
    }

    private func saveSession() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
        if let index = currentGroupIndex {
            UserDefaults.standard.set(index, forKey: Self.sessionIndexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionIndexKey)
        }
    }

    // MARK: - 组内导航

    /// 唯一允许进入组内 Review 的路径：单张组卡 Button 的用户 tap。
    private func openGroup(_ group: ReviewOverviewGroup) {
        guard case .overview = mode,
              openedGroupID == nil,
              !group.photoIDs.isEmpty else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            currentGroupIndex = idx
            saveSession()
        }
        let next = ExploreSession(level: RegionLevel.country, regionName: group.title,
                                  context: context, source: .global)
        // 概览封面就是组内第一张；这里不能再次洗牌，否则用户点击后会“封面变图”。
        next.loadPhotos(ids: group.photoIDs, preservingOrder: true)
        session = next
        openedGroupID = group.id
        onImmersiveChanged(true)
        withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.20)) { mode = .group(group.id) }
        preloadNextGroup(after: group.id)
    }

    #if DEBUG
    /// 确定性构造 portrait → landscape 顺序，只用于根/背景逐帧回归。
    private func orientationPairForTesting() -> ReviewOverviewGroup? {
        let records = PhotoStore.all(in: context)
        let portrait = records.first { record in
            guard let path = record.thumbnailPath,
                  let size = UIImage(contentsOfFile: path)?.size else { return false }
            return size.height > size.width
        }
        let landscape = records.first { record in
            guard let path = record.thumbnailPath,
                  let size = UIImage(contentsOfFile: path)?.size else { return false }
            return size.width > size.height
        }
        guard let portrait, let landscape else { return nil }
        return ReviewOverviewGroup(title: "Orientation Regression",
                                   photoIDs: [portrait.localIdentifier, landscape.localIdentifier],
                                   previewID: portrait.localIdentifier)
    }
    #endif

    /// “再来一组”：当前组完整刷完 → 标记完成 → 留在 Viewer 内直接切到 Session 下一组。
    private func advanceToNextGroup() {
        if let opened = openedGroupID, let idx = groups.firstIndex(where: { $0.id == opened }) {
            groups[idx].completed = true
            saveSession()
        }
        guard let idx = currentGroupIndex, idx + 1 < groups.count else {
            // 当前轮次全部刷完：从最新 PhotoStore 自动构建新一轮 Session
            buildNewSession()
            if let firstGroup = groups.first, !firstGroup.photoIDs.isEmpty {
                currentGroupIndex = 0
                saveSession()
                let next = ExploreSession(level: RegionLevel.country, regionName: firstGroup.title,
                                          context: context, source: .global)
                next.loadPhotos(ids: firstGroup.photoIDs, preservingOrder: true)
                session = next
                openedGroupID = firstGroup.id
                onImmersiveChanged(true)
                withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.20)) { mode = .group(firstGroup.id) }
                preloadNextGroup(after: firstGroup.id)
            } else {
                returnToOverview()
            }
            return
        }
        let nextGroup = groups[idx + 1]
        currentGroupIndex = idx + 1
        saveSession()
        let next = ExploreSession(level: RegionLevel.country, regionName: nextGroup.title,
                                  context: context, source: .global)
        next.loadPhotos(ids: nextGroup.photoIDs, preservingOrder: true)
        session = next
        openedGroupID = nextGroup.id
        onImmersiveChanged(true)
        withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.20)) { mode = .group(nextGroup.id) }
        preloadNextGroup(after: nextGroup.id)
    }

    /// 当前组浏览期间预热下一组（Prepared ≠ Reviewed，不计回顾历史）。
    private func preloadNextGroup(after id: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }), idx + 1 < groups.count else { return }
        let nextIDs = Array(groups[idx + 1].photoIDs.prefix(3))
        guard !nextIDs.isEmpty else { return }
        Task.detached(priority: .utility) {
            _ = PhotoThumbnailGenerator.metadata(localIDs: nextIDs)
            for photoID in nextIDs {
                _ = await PhotoThumbnailGenerator.image(localID: photoID)
            }
        }
    }

    private func returnToOverview() {
        withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.20)) { mode = .overview }
        openedGroupID = nil
        session = nil
        onImmersiveChanged(false)
        // 三组全部完成 → 生成下一轮；否则保持当前 Session 稳定。
        prepareSessionIfNeeded()
    }

    private func selectFilter(_ filter: ReviewMediaFilter) {
        UISelectionFeedbackGenerator().selectionChanged()
        mediaFilter = filter
        menuPresented = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.14 : 0.20)) { mode = .overview }
        openedGroupID = nil
        session = nil
        onImmersiveChanged(false)
        // 筛选变化 = 新候选池 → 显式生成新 Session（用户主动操作）。
        buildNewSession()
    }

    // MARK: - 封面图

    private func loadPreviewImages() {
        let records = PhotoStore.all(in: context)
        overviewLoadGeneration += 1
        let generation = overviewLoadGeneration
        let missing = groups.compactMap { group in
            records.first(where: { $0.localIdentifier == group.previewID })
        }.filter { previewImages[$0.localIdentifier] == nil }
        Task {
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for record in missing {
                    group.addTask {
                        (record.localIdentifier, await PhotoThumbnailGenerator.thumbnailImage(for: record))
                    }
                }
                for await (id, image) in group {
                    guard generation == overviewLoadGeneration else { return }
                    previewImages[id] = image ?? Self.neutralPreviewImage()
                }
            }
        }
    }

    /// 加载失败时的中性占位，避免卡片一直显示 ProgressView。
    private static func neutralPreviewImage() -> UIImage {
        let size = OverviewMotion.cardSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.16, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 冷启动时 SwiftData/相册扫描可能比 Tab 首次渲染稍晚。恢复 Session + 幂等生成，绝不创建组内会话。
    private func refreshOverviewWhenDataIsReady() async {
        restoreSessionIfNeeded()
        prepareSessionIfNeeded()
        guard groups.isEmpty else { return }
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            restoreSessionIfNeeded()
            prepareSessionIfNeeded()
            if !groups.isEmpty { return }
        }
    }
}

private struct ReviewGroupStack: View {
    let groups: [ReviewOverviewGroup]
    let images: [String: UIImage]
    let reduceMotion: Bool
    let onTap: (ReviewOverviewGroup) -> Void

    var body: some View {
        ZStack {
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light))
                    Text("没有符合条件的照片").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
            ForEach(Array(groups.prefix(3).enumerated()), id: \.element.id) { index, group in
                // 按整组卡片的包围盒居中：1 张=0，2 张=-0.5/+0.5，3 张=-1/0/+1。
                let visualPosition = CGFloat(index) - CGFloat(min(groups.count, 3) - 1) / 2
                let isFront = abs(visualPosition) < 0.1
                Button { onTap(group) } label: { card(group) }
                    .buttonStyle(OverviewCardPressStyle())
                    .frame(width: OverviewMotion.cardSize.width, height: OverviewMotion.cardSize.height)
                    // 显式命中区：与卡片视觉圆角一致，旋转后点边角也可靠命中。
                    .contentShape(RoundedRectangle(cornerRadius: OverviewMotion.radius, style: .continuous))
                    .transition(reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .offset(x: 28).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                    removal: .offset(x: -28).combined(with: .opacity).combined(with: .scale(scale: 0.96))))
                    .scaleEffect(isFront ? 1 : OverviewMotion.sideScale)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(visualPosition) * OverviewMotion.rotation))
                    .offset(x: visualPosition * OverviewMotion.sideOffset,
                            y: isFront ? -4 : 14)
                    .zIndex(isFront ? 3 : (visualPosition < 0 ? 1 : 2))
                    .accessibilityLabel("\(group.title)，\(group.photoIDs.count) 张照片\(group.completed ? "，已回顾" : "")")
            }
        }
    }

    private func card(_ group: ReviewOverviewGroup) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = images[group.previewID] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08).overlay(ProgressView().tint(.white.opacity(0.7)))
                }
            }
            .frame(width: OverviewMotion.cardSize.width, height: OverviewMotion.cardSize.height)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.58)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.title).font(.system(size: 15, weight: .bold))
                    if group.completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(group.photoIDs.count) 张").font(.system(size: 11, weight: .medium)).opacity(0.72)
            }
            .padding(14).foregroundStyle(.white)
        }
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: OverviewMotion.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OverviewMotion.radius).stroke(.white.opacity(0.72), lineWidth: 2))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 7)
    }
}

private struct OverviewCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
