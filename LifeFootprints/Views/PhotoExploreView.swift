import SwiftUI
import UIKit
import Photos
import PhotosUI
import CoreLocation
import SwiftData

/// 页面级照片显示模式：Map 预览 / 回顾 / 全屏照片页共用同一组件，
/// 通过参数区分页面行为，避免「为某一页修复而意外改变另一页」。
enum PhotoDisplayMode {
    /// 完整显示照片（保持比例，不裁切）——所有“查看照片”入口的默认行为。
    case fit
    /// 铺满裁切——保留给未来需要沉浸铺满的入口。
    case fill
}

/// 照片浏览页只允许根 GeometryReader 计算一次布局。照片比例只参与 mediaRect 内的
/// Aspect Fit，不能反向改变顶部、底部或相邻卡片的位置。
private struct PhotoReviewLayoutMetrics {
    let screenSize: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let safeLeading: CGFloat
    let safeTrailing: CGFloat

    private let horizontalInset: CGFloat = 16
    private let controlSize: CGFloat = 44
    private let liveBadgeHeight: CGFloat = 34
    private let locationHeight: CGFloat = 54

    var topControlY: CGFloat { safeTop + (isLandscape ? 4 : 8) }
    var liveBadgeY: CGFloat { topControlY + controlSize + 12 }
    var locationBottomY: CGFloat { screenSize.height - safeBottom - (isLandscape ? 8 : 12) }
    var locationTopY: CGFloat { locationBottomY - locationHeight }
    var chromeWidth: CGFloat {
        max(0, screenSize.width - safeLeading - safeTrailing - horizontalInset * 2)
    }
    var mediaRect: CGRect {
        let top = liveBadgeY + liveBadgeHeight + (isLandscape ? 10 : 16)
        let bottom = locationTopY - (isLandscape ? 14 : 24)
        return CGRect(
            x: safeLeading + horizontalInset,
            y: top,
            width: chromeWidth,
            height: max(1, bottom - top)
        )
    }

    private var isLandscape: Bool { screenSize.width > screenSize.height }
}

/// 堆叠式照片卡牌探索视图（设计稿还原）
/// 背景 #101114 · 卡片 #1C1D20 · 强调 #FF7A45
/// 页面严格分为三个物理解耦层：
/// 1. Background Layer：全屏模糊氛围，永远铺满物理窗口，零 swipe 位移；
/// 2. Media Layer：固定全屏 media viewport，照片自身在 viewport 内 fit，换图 viewport 零跳动，上下绝对对称居中；
/// 3. Fixed Chrome Layer：返回按钮、进度条、底部地点胶囊绝对锚定在安全区导轨，常驻显示，与照片尺寸零耦合。
struct PhotoExploreView: View {
    private static var activeKeyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    @Bindable var session: ExploreSession
    let theme: AppTheme
    /// 常驻架构：探索页被其他 Tab 覆盖时保持挂载；置为 false 时立即停掉 Live 播放。
    var isActive = true
    var showsDismissButton = true
    /// 页面级显示模式（默认完整显示）
    var displayMode: PhotoDisplayMode = .fit
    var onShowLocation: ((PhotoRecord) -> Void)?
    var onFinishLocationReview: (() -> Void)?
    var onExitReview: (() -> Void)?
    var onDismissRequested: (() -> Void)?
    /// 全局三组回顾：「再来一组」直接切到 Session 下一组（由 ReviewTabView 提供）。
    var onNextGroup: (() -> Void)?
    /// 确认删除成功：Global Review 原子换到下一组；Map Review 由 session 自己换批。
    var onConfirmedDeletion: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 异步加载的卡片图（文件缺失时 PH 即时取图，key=localIdentifier）
    @State private var asyncImages: [String: UIImage] = [:]
    /// 背景只保存降采样版本，避免对屏幕级照片持续实时模糊。
    @State private var backgroundImages: [String: UIImage] = [:]
    /// 上一张已就绪的背景图：新照片背景未加载完时兜底，保证背景连续不闪黑。
    @State private var lastAmbientImage: UIImage?
    #if DEBUG
    /// 帧诊断节流：stage/photo/badge 帧信息变化时才写一次日志（供真机拉取 map_debug.txt 核对）。
    private static var lastPhotoFrameLog = ""
    #endif
    @State private var highResolutionIDs: Set<String> = []
    @State private var assetMetadata: [String: PhotoAssetMetadata] = [:]
    @State private var zoomScale: CGFloat = 1
    @State private var dailyPhotos: [PhotoRecord] = []
    @State private var showDailyPhotos = false
    @State private var aroundDayTransitionProgress: CGFloat = 0
    @State private var precisePlaces: [String: String] = [:]
    @State private var preparedLivePhotos: [String: PHLivePhoto] = [:]
    @State private var deletionInProgress = false
    @State private var deletionErrorMessage: String?
    @Namespace private var aroundDayNamespace

    // 设计稿色板
    private let screenBG = Color(red: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255)
    private let cardBG = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x20 / 255)
    private let textSecondary = Color(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAF / 255)
    private let accent = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x45 / 255)

    var body: some View {
        GeometryReader { geo in
            ZStack {
            // Layer 1: Background Layer（全屏铺满背景，不参与任何位移）
            ambientPhotoBackground()
                .id(session.batchID)
                .frame(width: geo.size.width, height: geo.size.height)
                .ignoresSafeArea()
                .reviewFrameProbe("BACKGROUND")
                .scaleEffect(isCompletion ? 1.04 : 1)
                .animation(.spring(response: 0.5, dampingFraction: 0.92), value: isCompletion)

            if isCompletion {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Layer 2 & 3 只共享同一个屏幕几何数据，彼此不参与布局分配。
            // GeometryReader 扩展到物理屏幕：media viewport 永远等于 screen bounds，
            // safeAreaInsets 只用来锚定 fixed chrome。
            Group {
                // X 轴只使用当前页面的 local width。不与 UIScreen 宽度混用，
                // 避免 fullScreenCover/旋转过渡期两个坐标系宽度不同而整层横移。
                let physicalBounds = UIScreen.main.bounds.size
                let screenSize = CGSize(
                    width: geo.size.width,
                    height: min(geo.size.height, physicalBounds.height)
                )
                let isLandscape = screenSize.width > screenSize.height

                // 安全区健壮兜底算法：若 GeometryReader 未能获取到正确的 safeAreaInsets，直接从 keyWindow 获取硬件真实安全区
                let resolvedSafeTop: CGFloat = {
                    if geo.safeAreaInsets.top > 0 { return geo.safeAreaInsets.top }
                    let top = Self.activeKeyWindow?.safeAreaInsets.top ?? 0
                    return top > 0 ? top : (isLandscape ? 0 : 54)
                }()

                let resolvedSafeBottom: CGFloat = {
                    if geo.safeAreaInsets.bottom > 0 { return geo.safeAreaInsets.bottom }
                    let bot = Self.activeKeyWindow?.safeAreaInsets.bottom ?? 0
                    return bot > 0 ? bot : (isLandscape ? 21 : 34)
                }()

                let resolvedSafeLeading: CGFloat = {
                    if geo.safeAreaInsets.leading > 0 { return geo.safeAreaInsets.leading }
                    return Self.activeKeyWindow?.safeAreaInsets.left ?? 0
                }()

                let resolvedSafeTrailing: CGFloat = {
                    if geo.safeAreaInsets.trailing > 0 { return geo.safeAreaInsets.trailing }
                    return Self.activeKeyWindow?.safeAreaInsets.right ?? 0
                }()

                let metrics = PhotoReviewLayoutMetrics(
                    screenSize: screenSize,
                    safeTop: resolvedSafeTop,
                    safeBottom: resolvedSafeBottom,
                    safeLeading: resolvedSafeLeading,
                    safeTrailing: resolvedSafeTrailing
                )
                let viewportSize = metrics.mediaRect.size

                ZStack {
                    // Layer 2: 唯一参与 swipe 的层。Previous / Current / Next 始终共用
                    // 同一 mediaSafeRect，照片和 Live Photo 只在其内做 Aspect Fit。
                    if !session.isTransitioningToNextBatch {
                        PhotoSwipeCardStack(
                            session: session,
                            isActive: isActive,
                            stage: viewportSize,
                            displayMode: displayMode,
                            asyncImages: asyncImages,
                            assetMetadata: assetMetadata,
                            highResolutionIDs: highResolutionIDs,
                            preparedLivePhotos: preparedLivePhotos,
                            aroundDayNamespace: aroundDayNamespace,
                            showDailyPhotos: showDailyPhotos,
                            aroundDayTransitionProgress: aroundDayTransitionProgress,
                            zoomScale: $zoomScale,
                            dailyPhotos: $dailyPhotos,
                            onTapCard: { },
                            onUserInteractionBegan: { },
                            onRequestThumbnail: { photo in
                                requestPhotoThumbnail(for: photo)
                            },
                            onPrepareLivePhoto: { photo, size in
                                Task {
                                    await prepareAdjacentLivePhotos(
                                        around: session.index, targetSize: size)
                                }
                            }
                        )
                        .id(session.batchID)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .reviewFrameProbe("MEDIA")
                        // mediaSafeRect 水平始终居中，只做不参与布局的垂直渲染位移。
                        .offset(y: metrics.mediaRect.midY - screenSize.height / 2)
                        .zIndex(0)
                    }
                }
                .frame(width: screenSize.width, height: screenSize.height)
                .reviewFrameProbe("FOREGROUND")
                // Layer 3: alignment overlay 由根屏幕直接锚定，子视图无法改变坐标原点。
                .overlay(alignment: .top) {
                    if !session.isTransitioningToNextBatch {
                        header(in: metrics.chromeWidth, screenWidth: screenSize.width)
                            .frame(width: metrics.chromeWidth, height: 44)
                            .reviewFrameProbe("HEADER")
                            .padding(.top, metrics.topControlY)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !session.isTransitioningToNextBatch, currentPhotoIsLive {
                        liveBadge
                            .padding(.leading, resolvedSafeLeading + 16)
                            .padding(.top, metrics.liveBadgeY)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !session.isTransitioningToNextBatch {
                        infoBlock
                            .reviewFrameProbe("LOCATION")
                            .padding(.bottom, max(0, screenSize.height - metrics.locationBottomY))
                    }
                }
                .clipped()
#if DEBUG
                .task(id: frameDiagnosticID(viewportSize: viewportSize,
                                            safeTop: resolvedSafeTop,
                                            safeBottom: resolvedSafeBottom,
                                            safeLeading: resolvedSafeLeading,
                                            safeTrailing: resolvedSafeTrailing,
                                            mediaRect: metrics.mediaRect)) {
                    logReviewFrames(viewportSize: viewportSize,
                                    mediaRect: metrics.mediaRect,
                                    safeTop: resolvedSafeTop,
                                    safeBottom: resolvedSafeBottom,
                                    safeLeading: resolvedSafeLeading,
                                    safeTrailing: resolvedSafeTrailing,
                                    headerWidth: metrics.chromeWidth,
                                    headerOffset: metrics.topControlY,
                                    locationBottomY: metrics.locationBottomY)
                }
#endif
            }

            // Overlays
            if aroundDayTransitionProgress > 0.01 || showDailyPhotos {
                DailyPhotoView(
                    photos: dailyPhotos,
                    theme: theme,
                    pendingIDs: session.pendingRemovalIDs,
                    transitionProgress: showDailyPhotos ? 1 : aroundDayTransitionProgress,
                    currentPhotoID: session.currentPhoto?.localIdentifier,
                    transitionNamespace: aroundDayNamespace,
                    onTogglePending: { session.togglePendingRemoval(id: $0) },
                    onDismiss: closeAroundDay
                )
                .opacity(showDailyPhotos ? 1 : aroundDayTransitionProgress)
                .scaleEffect(0.96 + (showDailyPhotos ? 1 : aroundDayTransitionProgress) * 0.04)
                .zIndex(20)
                .allowsHitTesting(showDailyPhotos)
            }

            if case .done = session.phase {
                doneOverlay
                    .zIndex(10)
            }
            if session.phase == .review || session.isTransitioningToNextBatch {
                reviewOverlay
                    .zIndex(10)
                    .allowsHitTesting(!session.isTransitioningToNextBatch)
            }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .reviewFrameProbe("ROOT")
        }
        .coordinateSpace(name: "reviewRoot")
        .frame(height: UIScreen.main.bounds.height)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: session.index) { oldIndex, newIndex in
            prefetch(from: newIndex)
            trimImageCaches(around: newIndex)
            loadPrecisePlaceForCurrentPhoto()
            ProgressTraceLogger.log(
                event: "currentIndexChanged(\(oldIndex)→\(newIndex))",
                index: newIndex,
                totalCount: session.photos.count,
                photo: session.currentPhoto,
                meta: session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] }
            )
        }
        .onChange(of: session.photos.count) { oldCount, newCount in
            ProgressTraceLogger.log(
                event: "photosCountChanged(\(oldCount)→\(newCount))",
                index: session.index,
                totalCount: newCount,
                photo: session.currentPhoto,
                meta: session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] }
            )
        }
        .onChange(of: session.currentPhoto?.localIdentifier) { oldID, newID in
            ProgressTraceLogger.log(
                event: "currentPhotoChanged(\(oldID ?? "nil")→\(newID ?? "nil"))",
                index: session.index,
                totalCount: session.photos.count,
                photo: session.currentPhoto,
                meta: session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] }
            )
        }
        .onChange(of: session.regionName) { _, _ in
            prefetch(from: session.index)
            trimImageCaches(around: session.index)
            loadPrecisePlaceForCurrentPhoto()
        }
        .onChange(of: session.id) { _, _ in
            // Global Review 会替换整个 session；先清空旧组瞬时状态，再加载新组首图。
            resetTransientStateForBatchTransition()
            prefetch(from: session.index)
            trimImageCaches(around: session.index)
            loadPrecisePlaceForCurrentPhoto()
        }
        .onChange(of: session.phase) { _, phase in
            if case .transitioningToNextBatch = phase {
                resetTransientStateForBatchTransition()
            } else if case .browsing = phase {
                prefetch(from: session.index)
                trimImageCaches(around: session.index)
                loadPrecisePlaceForCurrentPhoto()
            }
        }
        .onAppear {
            prefetch(from: session.index)
            loadPrecisePlaceForCurrentPhoto()
#if DEBUG
            if let count = TestHooks.consumeReviewDeletionCount() {
                session.showDeletionReviewForTesting(count: count)
            } else if TestHooks.reviewTest {
                session.showReviewForTesting()
            }
#endif
        }
        .alert("无法删除照片", isPresented: Binding(
            get: { deletionErrorMessage != nil },
            set: { if !$0 { deletionErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "请稍后重试。")
        }
    }

    /// 是否处于「回顾完毕」完成态（驱动背景退后 + 全屏暗色蒙层 + 完成卡出现）。
    private var isCompletion: Bool {
        if case .review = session.phase { return true }
        return false
    }

#if DEBUG
    /// 真机诊断只在屏幕几何、当前 asset 或图片实际比例变化时触发。
    /// 日志同时给出 viewport/card/image/fixed chrome，可直接对比横图、竖图和 Live Photo。
    private func frameDiagnosticID(viewportSize: CGSize,
                                   safeTop: CGFloat,
                                   safeBottom: CGFloat,
                                   safeLeading: CGFloat,
                                   safeTrailing: CGFloat,
                                   mediaRect: CGRect) -> String {
        let id = session.currentPhoto?.localIdentifier ?? "none"
        let aspect = currentPhotoAspect
        return "\(viewportSize.width)x\(viewportSize.height)|\(safeTop),\(safeBottom),\(safeLeading),\(safeTrailing)|\(mediaRect)|\(id)|\(aspect)|\(displayMode)"
    }

    private var currentPhotoAspect: CGFloat {
        guard let photo = session.currentPhoto else { return 0.75 }
        if let image = asyncImages[photo.localIdentifier], image.size.height > 0 {
            return image.size.width / image.size.height
        }
        if let meta = assetMetadata[photo.localIdentifier], meta.aspectRatio > 0 {
            return meta.aspectRatio
        }
        return 0.75
    }

    private func logReviewFrames(viewportSize: CGSize,
                                 mediaRect: CGRect,
                                 safeTop: CGFloat,
                                 safeBottom: CGFloat,
                                 safeLeading: CGFloat,
                                 safeTrailing: CGFloat,
                                 headerWidth: CGFloat,
                                 headerOffset: CGFloat,
                                 locationBottomY: CGFloat) {
        let screenFrame = CGRect(origin: .zero, size: UIScreen.main.bounds.size)
        let imageSize = displayMode == .fill
            ? viewportSize
            : Self.fittedImageSize(aspect: currentPhotoAspect, within: viewportSize)
        let imageFrame = CGRect(
            x: mediaRect.minX + (viewportSize.width - imageSize.width) / 2,
            y: mediaRect.minY + (viewportSize.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        let headerFrame = CGRect(
            x: (viewportSize.width - headerWidth) / 2,
            y: headerOffset,
            width: headerWidth,
            height: 44
        )
        let metadataGuideY = locationBottomY
        let photoID = session.currentPhoto?.localIdentifier ?? "none"
        let mediaType = session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] }?.isLivePhoto == true
            ? "LivePhoto" : "Photo"
        let message = "[REVIEW FRAME] photo=\(photoID) mediaType=\(mediaType) "
            + "screenBounds=\(screenFrame) safeAreaInsets=(top:\(safeTop),left:\(safeLeading),bottom:\(safeBottom),right:\(safeTrailing)) "
            + "mediaViewport.frame=\(mediaRect) currentCard.frame=\(mediaRect) image.frame=\(imageFrame) "
            + "fixedChrome.frame=\(screenFrame) header.frame=\(headerFrame) bottomMetadata.bottomGuideY=\(metadataGuideY)"
        guard Self.lastPhotoFrameLog != message else { return }
        Self.lastPhotoFrameLog = message
        MapDebugLog.log(message)
        print(message)
    }

    private static func fittedImageSize(aspect: CGFloat, within box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        let boxAspect = box.width / box.height
        if aspect > boxAspect {
            return CGSize(width: box.width, height: box.width / aspect)
        }
        return CGSize(width: box.height * aspect, height: box.height)
    }
#endif

    /// 当前照片的静态缩略图做低成本色彩延展；不解码/播放 Live Photo，减少切换卡顿。
    @ViewBuilder
    private func ambientPhotoBackground() -> some View {
        ZStack {
            // 底色：图片未就绪时的连续背景（与模糊层同属唯一主层，无接缝）
            screenBG.ignoresSafeArea()
            if let image = currentAmbientImage {
                ambientLayer(image)
                    .id(session.currentPhoto?.localIdentifier ?? "ambient-fallback")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: session.currentPhoto?.localIdentifier)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 当前照片的背景图；未就绪时退回上一张（保持背景连续，不闪黑）。
    private var currentAmbientImage: UIImage? {
        guard !session.isTransitioningToNextBatch else { return nil }
        let image = session.currentPhoto.flatMap { backgroundImage(for: $0) }
        return image ?? lastAmbientImage
    }

    private func ambientLayer(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(1.14)
            .blur(radius: 38, opaque: true)
            .saturation(0.82)
            .contrast(0.92)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(Color.white.opacity(0.14))
            .overlay(Color.black.opacity(0.08))
            .ignoresSafeArea()
    }

    private func backgroundImage(for photo: PhotoRecord) -> UIImage? {
        backgroundImages[photo.localIdentifier]
            ?? asyncImages[photo.localIdentifier]
            ?? photo.thumbnailPath.flatMap(UIImage.init(contentsOfFile:))
    }

    /// 静态 Preview 始终预取 previous/current/next；它独立于 Live 资源，确保滑动不等待播放资源。
    private func prefetch(from index: Int) {
        guard !session.photos.isEmpty else { return }
        let lower = max(0, index - 1)
        let upper = min(session.photos.count, index + 2)
        let neighbors = session.photos[lower..<upper].map {
            (id: $0.localIdentifier, path: $0.thumbnailPath)
        }
        let missingImages = neighbors.filter { asyncImages[$0.id] == nil }
        Task.detached(priority: .userInitiated) {
            let metadata = PhotoThumbnailGenerator.metadata(localIDs: neighbors.map(\.id))
            await MainActor.run { assetMetadata.merge(metadata) { _, new in new } }
            // 磁盘缩略图先快速上屏。
            for item in missingImages {
                if let path = item.path, let image = UIImage(contentsOfFile: path) {
                    let ambient = image.preparingThumbnail(
                        of: CGSize(width: 96, height: 96)
                    ) ?? image
                    await MainActor.run {
                        asyncImages[item.id] = image
                        backgroundImages[item.id] = ambient
                        if item.id == session.currentPhoto?.localIdentifier {
                            lastAmbientImage = ambient
                        }
                    }
                }
            }
            // Preview 可从 iCloud 获取，但不会等待 Live Photo 资源。
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for item in missingImages {
                    group.addTask {
                        (item.id, await PhotoThumbnailGenerator.previewImage(localID: item.id))
                    }
                }
                for await (id, image) in group {
                    if let image {
                        let ambient = image.preparingThumbnail(
                            of: CGSize(width: 96, height: 96)
                        ) ?? image
                        await MainActor.run {
                            asyncImages[id] = image
                            highResolutionIDs.insert(id)
                            backgroundImages[id] = ambient
                            // 当前照片的背景就绪 → 更新兜底（切组时背景连续）
                            if id == session.currentPhoto?.localIdentifier,
                               let bg = backgroundImages[id] {
                                lastAmbientImage = bg
                            }
                            ProgressTraceLogger.log(
                                event: "imageLoaded",
                                index: session.index,
                                totalCount: session.photos.count,
                                photo: session.photos.first(where: { $0.localIdentifier == id }),
                                meta: assetMetadata[id]
                            )
                        }
                    }
                }
            }
        }
    }

    private func requestPhotoThumbnail(for photo: PhotoRecord) {
        if assetMetadata[photo.localIdentifier] == nil {
            assetMetadata.merge(PhotoThumbnailGenerator.metadata(localIDs: [photo.localIdentifier])) { _, new in new }
        }
        guard asyncImages[photo.localIdentifier] == nil else { return }
        let localID = photo.localIdentifier
        if let path = photo.thumbnailPath,
           FileManager.default.fileExists(atPath: path) { return }
        Task {
            if let image = await PhotoThumbnailGenerator.previewImage(localID: localID) {
                await MainActor.run {
                    asyncImages[localID] = image
                    highResolutionIDs.insert(localID)
                    if localID == session.currentPhoto?.localIdentifier {
                        lastAmbientImage = image
                    }
                    ProgressTraceLogger.log(
                        event: "imageLoaded",
                        index: session.index,
                        totalCount: session.photos.count,
                        photo: photo,
                        meta: assetMetadata[localID]
                    )
                }
                return
            }
            let candidates = session.photos.map(\.localIdentifier)
                .filter { $0 != localID }.shuffled().prefix(3)
            for id in candidates {
                if let image = await PhotoThumbnailGenerator.image(localID: id) {
                    asyncImages[localID] = image
                    break
                }
            }
        }
    }

    /// 图片缓存只保留 current ± 2 窗口：长会话（大聚类「继续看看」/长时间浏览）不无限累积解码位图。
    private func trimImageCaches(around index: Int) {
        guard !session.photos.isEmpty else { return }
        let clamped = min(max(index, 0), session.photos.count - 1)
        let keepRange = max(0, clamped - 2)...min(session.photos.count - 1, clamped + 2)
        let keep = Set(session.photos[keepRange].map(\.localIdentifier))
        let threshold = 8
        if asyncImages.count > threshold {
            asyncImages = asyncImages.filter { keep.contains($0.key) }
        }
        if backgroundImages.count > threshold {
            backgroundImages = backgroundImages.filter { keep.contains($0.key) }
        }
        if highResolutionIDs.count > threshold {
            highResolutionIDs = highResolutionIDs.filter { keep.contains($0) }
        }
    }

    private func prepareLivePhoto(for photo: PhotoRecord, targetSize: CGSize) async {
        let id = photo.localIdentifier
        guard preparedLivePhotos[id] == nil else { return }
        let target = CGSize(width: max(targetSize.width * 1.5, 900),
                            height: max(targetSize.height * 1.5, 900))
        guard let result = await PhotoThumbnailGenerator.livePhoto(localID: id,
                                                                    targetSize: target),
              !Task.isCancelled,
              session.photos.contains(where: { $0.localIdentifier == id }) else { return }
        preparedLivePhotos[id] = result
        let keepRange = max(0, session.index - 1)...min(session.photos.count - 1, session.index + 1)
        let keep = Set(session.photos[keepRange].map(\.localIdentifier))
        preparedLivePhotos = preparedLivePhotos.filter { keep.contains($0.key) }
    }

    /// Live 资源只为 current ± 1 准备；即使资源在 iCloud，静态 Preview 也已可独立浏览。
    private func prepareAdjacentLivePhotos(around index: Int, targetSize: CGSize) async {
        guard session.photos.indices.contains(index) else { return }
        let priority = [index, index + 1, index - 1]
        for candidate in priority where session.photos.indices.contains(candidate) {
            guard !Task.isCancelled else { return }
            let photo = session.photos[candidate]
            guard assetMetadata[photo.localIdentifier]?.isLivePhoto == true else { continue }
            await prepareLivePhoto(for: photo, targetSize: targetSize)
        }
    }

    // MARK: - 顶栏（绝对几何解耦：左右按钮物理固定两端，中间进度条独立居中，零容器动画）

    private func header(in width: CGFloat, screenWidth: CGFloat) -> some View {
        let progressWidth = min(max(screenWidth * 0.40, 96), max(width - 120, 20))
        return ZStack {
            // 中间进度条：数据源唯一严格绑定 (session.index, session.photos.count)，
            // 屏蔽外部动画污染，纯 GPU scaleEffect 驱动
            PhotoProgressBar(index: max(0, session.progressIndex - 1), totalCount: session.progressCount)
                .frame(width: progressWidth)
                .reviewFrameProbe("PROGRESS")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("回顾进度")
                .accessibilityValue(session.progressText)
                .accessibilityIdentifier("review-progress")

            // 左右按钮：固定在 headerWidth 左右两端，绝对不受中间进度条/文字/照片切换影响
            HStack {
                if showsDismissButton {
                    Button {
                        if let onDismissRequested { onDismissRequested() }
                        else { dismiss() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }

                Spacer()

                Button {
                    shareCurrentPhoto()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: width, height: 44)
    }

    private var currentPhotoIsLive: Bool {
        guard let id = session.currentPhoto?.localIdentifier else { return false }
        return assetMetadata[id]?.isLivePhoto == true
    }

    /// Live 状态属于 Fixed Chrome：拖动期间不位移，只在 index commit 后更新。
    private var liveBadge: some View {
        Menu {
            Toggle("自动播放", isOn: Binding(
                get: { session.livePreferences.autoPlayEnabled },
                set: { session.livePreferences.autoPlayEnabled = $0 }
            ))
            Toggle("静音播放", isOn: Binding(
                get: { session.livePreferences.muted },
                set: { session.livePreferences.muted = $0 }
            ))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "livephoto")
                Text("实况")
                if session.livePreferences.autoPlayEnabled {
                    Circle().fill(.white.opacity(0.82)).frame(width: 4, height: 4)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.thinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
    }

    // MARK: - 底部信息区（卡外独立：地点白 + 时间灰，设计稿，底边绝对恒定）

    private var infoBlock: some View {
        Button {
            guard let photo = session.currentPhoto else { return }
            if let onShowLocation { onShowLocation(photo) }
            else {
                NotificationCenter.default.post(name: .reviewPhotoLocationRequested, object: nil,
                                                  userInfo: ["latitude": photo.latitude,
                                                             "longitude": photo.longitude,
                                                             "photoID": photo.localIdentifier])
            }
        } label: {
            HStack(alignment: .center, spacing: 9) {
                if let photo = session.currentPhoto,
                   locationTitle(photo) != nil {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                VStack(spacing: 3) {
                    if let photo = session.currentPhoto {
                    Text(photoDateString(photo))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(minHeight: 14)
                        Text(GeoMath.isValid(latitude: photo.latitude, longitude: photo.longitude) ?
                             LocalizedStringKey("照片原始位置") : LocalizedStringKey("暂无照片定位"))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.62))
                            .accessibilityIdentifier("review-location-origin")
                        if let title = locationTitle(photo) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1)
                                .frame(minHeight: 18)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(minHeight: 46)
            .background(.ultraThinMaterial.opacity(0.72), in: Capsule())
        }
        .buttonStyle(.plain)
        #if DEBUG
        .accessibilityIdentifier("review-current-photo")
        .accessibilityValue(session.currentPhoto?.localIdentifier ?? "none")
        #endif
    }

    private func photoDateString(_ photo: PhotoRecord) -> String {
        photo.timestamp.formatted(.relative(presentation: .named))
    }

    private func locationTitle(_ photo: PhotoRecord) -> String? {
        if let precise = precisePlaces[photo.localIdentifier], !precise.isEmpty { return precise }
        return photo.districtName ?? photo.cityName ?? photo.provinceName ?? photo.countryName
    }

    private func loadPrecisePlaceForCurrentPhoto() {
        guard let photo = session.currentPhoto, precisePlaces[photo.localIdentifier] == nil else { return }
        let id = photo.localIdentifier
        let latitude = photo.latitude
        let longitude = photo.longitude
        Task(priority: .utility) {
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
            let road = [mark.thoroughfare, mark.subThoroughfare]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let precise = mark.areasOfInterest?.first
                ?? (road.isEmpty ? nil : road)
                ?? mark.name
                ?? mark.subLocality
                ?? mark.locality
            if let precise, !precise.isEmpty {
                await MainActor.run { precisePlaces[id] = precise }
            }
        }
    }

    private func shareCurrentPhoto() {
        guard let photo = session.currentPhoto,
              let image = asyncImages[photo.localIdentifier]
                ?? photo.thumbnailPath.flatMap(UIImage.init(contentsOfFile:)) else { return }
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let shown = presenter.presentedViewController { presenter = shown }
        presenter.present(controller, animated: true)
    }

    private func closeAroundDay() {
        withAnimation(.easeOut(duration: 0.22)) {
            showDailyPhotos = false
            aroundDayTransitionProgress = 0
            zoomScale = 1
        }
        dailyPhotos.removeAll(keepingCapacity: true)
    }

    private func deletePendingPhotos() {
        guard !deletionInProgress else { return }
        let ids = session.beginConfirmedDeletionTransition()
        guard !ids.isEmpty else { return }
        deletionInProgress = true
        #if DEBUG
        if TestHooks.simulateReviewDeletionSuccess {
            finishSuccessfulDeletion(ids: ids)
            return
        }
        #endif
        Task {
            do {
                try await PhotoStore.deleteFromSystemLibrary(ids: ids)
                finishSuccessfulDeletion(ids: ids)
            } catch {
                session.restoreDeletionReviewAfterFailure()
                deletionInProgress = false
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func finishSuccessfulDeletion(ids: Set<String>) {
        PhotoStore.hide(ids: ids, in: context)
        let advance = session.completeConfirmedDeletionTransition()
        deletionInProgress = false
        switch advance {
        case .mapBatchReady:
            break
        case .mapClusterExhausted:
            onFinishLocationReview?()
            if onFinishLocationReview == nil { dismiss() }
        case .globalReviewNeedsNextGroup:
            if let onConfirmedDeletion { onConfirmedDeletion() }
            else if let onExitReview { onExitReview() }
            else { dismiss() }
        }
    }

    private func resetTransientStateForBatchTransition() {
        zoomScale = 1
        showDailyPhotos = false
        aroundDayTransitionProgress = 0
        dailyPhotos.removeAll(keepingCapacity: false)
        asyncImages.removeAll(keepingCapacity: false)
        backgroundImages.removeAll(keepingCapacity: false)
        highResolutionIDs.removeAll(keepingCapacity: false)
        lastAmbientImage = nil
        preparedLivePhotos.removeAll(keepingCapacity: false)
        precisePlaces.removeAll(keepingCapacity: false)
        assetMetadata.removeAll(keepingCapacity: false)
        deletionErrorMessage = nil
    }

    private var reviewOverlay: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(session.isLocationReview ? "这个地点看完了" : "回顾完毕")
                    .font(.system(size: 27, weight: .heavy))
                Text(session.pendingRemovalCount == 0
                     ? (session.isLocationReview ? "要继续看看吗？" : "要再来一组吗？")
                     : "请确认需要删除的照片")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Spacer(minLength: 26)

            if session.pendingRemovalPhotos.isEmpty {
                completionPhotoStack
            } else {
                deletionPreviewGrid
            }

            Spacer(minLength: 26)

            VStack(spacing: 12) {
                if session.pendingRemovalCount > 0 {
                    HStack(spacing: 10) {
                        Button("放弃，再来一组") {
                            if let onNextGroup { onNextGroup() }
                            else { session.abandonDeletionAndStartNextRound() }
                        }
                        .disabled(deletionInProgress)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.78))
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12)))

                        Button(role: .destructive) {
                            deletePendingPhotos()
                        } label: {
                            HStack(spacing: 7) {
                                if deletionInProgress { ProgressView().tint(.white) }
                                Text("确认删除")
                            }
                            .font(.system(size: 17, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                        }
                        .disabled(deletionInProgress)
                        .buttonStyle(.plain)
                        .background(Color.red.opacity(0.78), in: Capsule())
                    }
                } else if session.isLocationReview {
                    HStack(spacing: 10) {
                        completionButton("继续看看") { session.startNextRound() }
                        completionButton("返回地图") {
                            onFinishLocationReview?()
                            if onFinishLocationReview == nil { dismiss() }
                        }
                    }
                } else {
                    completionButton("再来一组") {
                        if let onNextGroup { onNextGroup() } else { session.startNextRound() }
                    }
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.32), radius: 26, y: 12)
        .padding(.horizontal, 26)
        .padding(.vertical, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var completionPhotoStack: some View {
        ZStack {
            ForEach(Array(session.completionPreviewPhotos.enumerated()), id: \.element.localIdentifier) { index, photo in
                completionPreviewCard(photo)
                    .rotationEffect(.degrees([-6.0, 5.0, 0.0][min(index, 2)]))
                    .offset(x: [-44.0, 44.0, 0.0][min(index, 2)],
                            y: [10.0, 12.0, -6.0][min(index, 2)])
                    .zIndex(index == session.completionPreviewPhotos.count - 1 ? 3 : Double(index))
            }
        }
        .frame(height: 250)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本轮回顾照片预览")
    }

    private func completionPreviewCard(_ photo: PhotoRecord) -> some View {
        Group {
            if let image = asyncImages[photo.localIdentifier] {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let path = photo.thumbnailPath, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08).overlay(ProgressView().tint(.white.opacity(0.7)))
            }
        }
        // The fixed preview window must be established before clipping. If the
        // frame is applied by the caller after this view's clipShape, a landscape
        // image's scaled-to-fill width becomes the clipping boundary and can
        // visibly escape the portrait completion card.
        .frame(width: 164, height: 210)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.22)))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 7)
        .task(id: photo.localIdentifier) {
            guard asyncImages[photo.localIdentifier] == nil,
                  let image = await PhotoThumbnailGenerator.previewImage(localID: photo.localIdentifier) else { return }
            asyncImages[photo.localIdentifier] = image
        }
    }

    private func completionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13)))
    }

    private var doneOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("当前级别暂无更多照片")
                .font(.system(size: 16, weight: .semibold))
            Text("所有同级区域都探索完毕")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                dismiss()
            } label: {
                Text("结束探索")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .foregroundStyle(accent)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
    }

    private var deletionPreviewGrid: some View {
        GeometryReader { geo in
            let photos = session.pendingRemovalPhotos
            let count = max(photos.count, 1)
            let columns = count == 1 ? 1 : count <= 4 ? 2 : count <= 9 ? 3 : 4
            let rows = Int(ceil(Double(count) / Double(columns)))
            let spacing: CGFloat = 7
            let cellWidth = (geo.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let cellHeight = (geo.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let side = max(36, min(cellWidth, cellHeight))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                spacing: spacing
            ) {
                ForEach(photos, id: \.persistentModelID) { photo in
                    Group {
                        if let image = asyncImages[photo.localIdentifier] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else if let path = photo.thumbnailPath,
                                  let image = UIImage(contentsOfFile: path) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                                .overlay(ProgressView().tint(.white.opacity(0.5)))
                        }
                    }
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: max(7, side * 0.12), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: max(7, side * 0.12), style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
                    .task(id: photo.localIdentifier) {
                        guard asyncImages[photo.localIdentifier] == nil,
                              photo.thumbnailPath == nil else { return }
                        guard let image = await PhotoThumbnailGenerator.previewImage(localID: photo.localIdentifier) else { return }
                        asyncImages[photo.localIdentifier] = image
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 300)
        .padding(.horizontal, 18)
    }
}

#if DEBUG
/// 回顾页坐标诊断：同时记录节点自身、reviewRoot 和窗口坐标，重点用于识别
/// “局部 x 正确、共同祖先 global x 错误”的整层位移。
private struct ReviewFrameProbe: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.overlay {
            // TimelineView 强制在动画 transaction 的每个显示帧重新读取坐标；
            // 仅 frame 真正变化时 task id 才变化并写日志，避免稳定态刷屏。
            TimelineView(.animation) { _ in
                GeometryReader { proxy in
                    let local = proxy.frame(in: .local)
                    let named = proxy.frame(in: .named("reviewRoot"))
                    let global = proxy.frame(in: .global)
                    let signature = "\(name)|\(local)|\(named)|\(global)"

                    Color.clear
                        .allowsHitTesting(false)
                        .task(id: signature) {
                            MapDebugLog.log(
                                "[REVIEW COORD] \(name) "
                                + "local=\(local) named=\(named) global=\(global) "
                                + "minX(local/named/global)=\(local.minX)/\(named.minX)/\(global.minX)"
                            )
                        }
                }
            }
        }
    }
}

private extension View {
    func reviewFrameProbe(_ name: String) -> some View {
        modifier(ReviewFrameProbe(name: name))
    }
}
#else
private extension View {
    func reviewFrameProbe(_ name: String) -> some View { self }
}
#endif

// MARK: - 独立卡片滑动容器（状态与手势隔离，让横向拖动达到纯 GPU Transform）

private struct PhotoSwipeCardStack: View {
    @Bindable var session: ExploreSession
    let isActive: Bool
    let stage: CGSize
    let displayMode: PhotoDisplayMode
    let asyncImages: [String: UIImage]
    let assetMetadata: [String: PhotoAssetMetadata]
    let highResolutionIDs: Set<String>
    let preparedLivePhotos: [String: PHLivePhoto]
    let aroundDayNamespace: Namespace.ID
    let showDailyPhotos: Bool
    let aroundDayTransitionProgress: CGFloat
    @Binding var zoomScale: CGFloat
    @Binding var dailyPhotos: [PhotoRecord]
    let onTapCard: () -> Void
    let onUserInteractionBegan: () -> Void
    let onRequestThumbnail: (PhotoRecord) -> Void
    let onPrepareLivePhoto: (PhotoRecord, CGSize) -> Void

    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var isTransitioning = false
    @State private var verticalFlyOut: CGFloat = 0
    @State private var horizontalDrag: Bool? = nil
    @State private var deletionThresholdReached = false
    @State private var gestureCancelledByResize = false
    @State private var livePhotoMounted = false
    @State private var livePhotoPlaying = false
    @State private var livePressHeld = false
    @State private var livePlaybackTask: Task<Void, Never>?
    @State private var activeLiveMuted = true
    #if DEBUG
    @State private var orientationRegressionStarted = false
    #endif
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack {
            if session.photos.indices.contains(session.index - 1) {
                neighborCard(session.photos[session.index - 1], direction: -1)
            }
            if session.photos.indices.contains(session.index + 1) {
                neighborCard(session.photos[session.index + 1], direction: 1)
            }
            if let photo = session.currentPhoto {
                frontCard(photo)
                    .frame(width: stage.width, height: stage.height)
                    .zIndex(3)
            }
        }
        .frame(width: stage.width, height: stage.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { onTapCard() }
        .onChange(of: stage) { _, _ in
            guard !isTransitioning else { return }
            if horizontalDrag != nil {
                gestureCancelledByResize = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    gestureCancelledByResize = false
                }
            }
            horizontalDrag = nil
            dragX = 0
            dragY = 0
            verticalFlyOut = 0
            deletionThresholdReached = false
        }
        .onChange(of: isActive) { _, active in
            if !active { stopLivePhoto() }
        }
        .onChange(of: session.livePreferences.autoPlayEnabled) { _, enabled in
            if !enabled { stopLivePhoto() }
        }
        .onDisappear { stopLivePhoto() }
        #if DEBUG
        .task {
            guard TestHooks.autoOrientationSwipe, !orientationRegressionStarted,
                  session.photos.count >= 2 else { return }
            orientationRegressionStarted = true
            try? await Task.sleep(for: .seconds(1))
            isTransitioning = true
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.90, blendDuration: 0)) {
                dragX = -stage.width
            } completion: {
                session.advance()
                dragX = 0
                isTransitioning = false
            }
        }
        #endif
    }

    private func neighborCard(_ photo: PhotoRecord, direction: CGFloat) -> some View {
        let x = direction * stage.width + dragX
        return photoCard(photo, front: false)
            .frame(width: stage.width, height: stage.height)
            .offset(x: x)
            .zIndex(2)
    }

    private func frontCard(_ photo: PhotoRecord) -> some View {
        let livePlaybackRequest = ReviewLivePlaybackRequest(
            assetID: photo.localIdentifier,
            autoPlayEnabled: session.livePreferences.autoPlayEnabled,
            isLivePhoto: assetMetadata[photo.localIdentifier]?.isLivePhoto == true,
            resourceReady: preparedLivePhotos[photo.localIdentifier] != nil,
            isActive: isActive)
        let currentY: CGFloat = verticalFlyOut != 0
            ? verticalFlyOut * stage.height * 1.35
            : (horizontalDrag == false ? dragY * 0.62 : 0)
        let upwardProgress = min(max(-dragY / max(stage.height * 0.18, 1), 0), 1)
        let cardScale = (1 - upwardProgress * 0.025) * zoomScale

        let cardContent = photoCard(photo, front: true)
            .scaleEffect(cardScale)
            .offset(x: dragX, y: currentY)
            .gesture(dragGesture)
            .simultaneousGesture(zoomGesture)
            .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 24) {
                beginLivePhoto(for: photo, requiresHold: true, muted: false)
            } onPressingChanged: { pressing in
                livePressHeld = pressing
                if !pressing, !session.livePreferences.autoPlayEnabled { pauseLivePhoto() }
            }

        return Group {
            if showDailyPhotos || aroundDayTransitionProgress > 0.01 {
                cardContent.matchedGeometryEffect(id: "around-day-\(photo.localIdentifier)",
                                                   in: aroundDayNamespace, isSource: true)
            } else {
                cardContent
            }
        }
        .task(id: livePlaybackRequest) {
            guard livePlaybackRequest.isLivePhoto else { return }
            onPrepareLivePhoto(photo, stage)
            scheduleAutoPlay(for: photo)
        }
        .onChange(of: session.livePreferences.muted) { _, muted in
            if livePhotoMounted { activeLiveMuted = muted }
        }
        .overlay {
            let marked = session.pendingRemovalIDs.contains(photo.localIdentifier)
            if upwardProgress > 0.30 || marked {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.red.opacity(marked ? 0.18 : max(0, upwardProgress - 0.3) * 0.28))
                    VStack(spacing: 7) {
                        Image(systemName: marked ? "trash.slash.fill" : "trash.fill")
                            .font(.system(size: 25, weight: .bold))
                        Text(marked ? "待移除" : "上滑加入待移除")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .opacity(marked ? 0.9 : max(0, (upwardProgress - 0.3) / 0.7))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func photoCard(_ photo: PhotoRecord, front: Bool) -> some View {
        let photoAspect: CGFloat = {
            if let image = asyncImages[photo.localIdentifier], image.size.height > 0 {
                return image.size.width / image.size.height
            } else if let meta = assetMetadata[photo.localIdentifier], meta.aspectRatio > 0 {
                return meta.aspectRatio
            } else { return 0.75 }
        }()
        let fitted = displayMode == .fill ? stage : Self.fittedSize(aspect: photoAspect, within: stage)

        return ZStack {
            // 实体照片只在固定 viewport 内做 fit/fill。这里不再叠加卡片圆角和阴影，
            // 避免把照片人为描成一块与氛围背景割裂的矩形。
            ZStack {
                if let image = asyncImages[photo.localIdentifier] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: displayMode == .fill ? .fill : .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .blur(radius: highResolutionIDs.contains(photo.localIdentifier) ? 0 : 1.6)
                        .animation(.easeOut(duration: 0.14),
                                   value: highResolutionIDs.contains(photo.localIdentifier))
                        .clipped()
                } else if let path = photo.thumbnailPath, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: displayMode == .fill ? .fill : .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .blur(radius: 1.2)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay {
                            DelayedPhotoLoadingIndicator()
                        }
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .overlay {
                // Live Photo 原生播放层与静态图片严格共用完全相同的 frame
                if front, livePhotoMounted, let livePhoto = preparedLivePhotos[photo.localIdentifier] {
                    LivePhotoPlaybackView(livePhoto: livePhoto, playing: livePhotoPlaying,
                                          muted: activeLiveMuted, onFinished: { livePhotoPlaying = false })
                        .frame(width: fitted.width, height: fitted.height)
                        .clipped()
                        .allowsHitTesting(false)
                        .opacity(livePhotoPlaying ? 1 : 0)
                }
            }
        }
        .frame(width: stage.width, height: stage.height)
        .background(Color.clear)
        .task(id: photo.localIdentifier) {
            onRequestThumbnail(photo)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !gestureCancelledByResize else { return }
                if horizontalDrag == nil, zoomScale > 1.02 {
                    zoomScale = 1
                }
                guard !isTransitioning, zoomScale <= 1.02 else { return }
                if livePhotoPlaying { pauseLivePhoto() }
                if horizontalDrag == nil {
                    let t = value.translation
                    guard abs(t.width) > 8 || abs(t.height) > 8 else { return }
                    horizontalDrag = abs(t.width) >= abs(t.height) * 0.8
                    onUserInteractionBegan()
                }

                if horizontalDrag == true {
                    dragX = value.translation.width
                    dragY = 0
                    ProgressTraceLogger.log(
                        event: "dragChanged",
                        index: session.index,
                        totalCount: session.photos.count,
                        photo: session.currentPhoto,
                        meta: session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] },
                        dragOffset: dragX,
                        throttleDrag: true
                    )
                } else if horizontalDrag == false {
                    dragX = 0
                    dragY = value.translation.height
                    let p = min(max(-value.translation.height / max(stage.height * 0.18, 1), 0), 1)
                    if p >= 0.72, !deletionThresholdReached {
                        deletionThresholdReached = true
                        haptic.impactOccurred()
                    } else if p < 0.68 {
                        deletionThresholdReached = false
                    }
                }
            }
            .onEnded { value in
                defer { horizontalDrag = nil }
                if gestureCancelledByResize {
                    gestureCancelledByResize = false
                    dragX = 0
                    dragY = 0
                    return
                }
                guard !isTransitioning, zoomScale <= 1.02 else { return }
                if horizontalDrag == true {
                    finishHorizontalDrag(value)
                } else if horizontalDrag == false {
                    finishVerticalDrag(value)
                }
            }
    }

    private func finishHorizontalDrag(_ value: DragGesture.Value) {
        guard !isTransitioning else { return }
        let threshold = stage.width * 0.16
        let translation = value.translation.width
        let absTranslation = abs(translation)

        guard absTranslation > 4 else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)) { dragX = 0 }
            return
        }

        let direction: CGFloat = translation >= 0 ? 1 : -1
        let sameDirectionVelocity = value.velocity.width * direction > 0 ? abs(value.velocity.width) : 0
        let effectiveDistance = abs(translation) + sameDirectionVelocity * 0.18

        guard effectiveDistance >= threshold else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)) { dragX = 0 }
            return
        }

        haptic.impactOccurred()
        let goingForward = direction < 0
        if !goingForward, !session.canGoToPreviousPhoto {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)) { dragX = 0 }
            return
        }

        isTransitioning = true
        ProgressTraceLogger.log(
            event: "swipeCommit(\(goingForward ? "forward" : "backward"))",
            index: session.index,
            totalCount: session.photos.count,
            photo: session.currentPhoto,
            meta: session.currentPhoto.flatMap { assetMetadata[$0.localIdentifier] },
            dragOffset: translation
        )
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.90, blendDuration: 0)) {
            dragX = direction * stage.width
        } completion: {
            stopLivePhoto()
            if goingForward { session.advance() }
            else { session.retreat() }
            dragX = 0
            isTransitioning = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard isTransitioning else { return }
            isTransitioning = false
            dragX = 0
        }
    }

    private func finishVerticalDrag(_ value: DragGesture.Value) {
        guard !isTransitioning else { return }
        let threshold = stage.height * 0.105
        let translation = value.translation.height
        let velocityBoost = max(-value.velocity.height * 0.16, 0)
        let magnitude = -translation + velocityBoost
        guard translation < 0,
              (-translation > threshold || magnitude > threshold * 1.1) else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)) { dragY = 0 }
            return
        }
        if !deletionThresholdReached { haptic.impactOccurred() }
        isTransitioning = true
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.90, blendDuration: 0)) {
            verticalFlyOut = -1
        } completion: {
            stopLivePhoto()
            session.togglePendingRemovalForCurrentPhoto()
            session.advance()
            dragY = 0
            verticalFlyOut = 0
            deletionThresholdReached = false
            isTransitioning = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard isTransitioning else { return }
            isTransitioning = false
            dragY = 0
            verticalFlyOut = 0
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.06)
            .onChanged { value in
                pauseLivePhoto()
                zoomScale = min(max(value, 0.72), 1.04)
                if value < 0.96 {
                    if dailyPhotos.isEmpty {
                        dailyPhotos = session.photosAroundCurrentDay(dayRadius: 5)
                    }
                }
            }
            .onEnded { value in
                if value <= 0.82 {
                    guard !dailyPhotos.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        zoomScale = 0.72
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    withAnimation(.easeOut(duration: 0.20)) {
                        zoomScale = 1
                    }
                }
            }
    }

    private func pauseLivePhoto() {
        livePhotoPlaying = false
    }

    private func beginLivePhoto(for photo: PhotoRecord, requiresHold: Bool, muted: Bool) {
        let id = photo.localIdentifier
        guard isActive else { return }
        guard preparedLivePhotos[id] != nil else { return }
        guard !requiresHold || livePressHeld else { return }
        guard session.currentPhoto?.localIdentifier == id else { return }
        activeLiveMuted = muted
        livePhotoMounted = true
        livePhotoPlaying = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func scheduleAutoPlay(for photo: PhotoRecord) {
        livePlaybackTask?.cancel()
        guard isActive, session.livePreferences.autoPlayEnabled else { return }
        let assetID = photo.localIdentifier
        livePlaybackTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let canStart = ReviewLivePlaybackLogic.shouldStart(
                requestedAssetID: assetID,
                currentAssetID: session.currentPhoto?.localIdentifier,
                autoPlayEnabled: session.livePreferences.autoPlayEnabled,
                resourceReady: preparedLivePhotos[assetID] != nil,
                isInteracting: dragX != 0,
                isActive: isActive
            )
            guard canStart else { return }
            beginLivePhoto(for: photo, requiresHold: false,
                           muted: session.livePreferences.muted)
        }
    }

    private func stopLivePhoto() {
        livePlaybackTask?.cancel()
        livePlaybackTask = nil
        livePhotoPlaying = false
        livePhotoMounted = false
    }

    private static func fittedSize(aspect: CGFloat, within box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        let boxAspect = box.width / box.height
        if aspect > boxAspect {
            return CGSize(width: box.width, height: box.width / aspect)
        } else {
            return CGSize(width: box.height * aspect, height: box.height)
        }
    }
}

/// UIKit Live Photo 播放器包装：长按时全幅播放，松手即停止。
private struct LivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let playing: Bool
    let muted: Bool
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onFinished = onFinished
        view.isMuted = muted
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            context.coordinator.isPlaying = false
        }
        if playing, !context.coordinator.isPlaying {
            context.coordinator.isPlaying = true
            view.startPlayback(with: .full)
        } else if !playing, context.coordinator.isPlaying {
            context.coordinator.isPlaying = false
            view.stopPlayback()
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var isPlaying = false
        var onFinished: () -> Void

        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        func livePhotoView(_ livePhotoView: PHLivePhotoView,
                           didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            isPlaying = false
            onFinished()
        }
    }
}

/// 双指放大进入的「当日」页面：只呈现同一自然日的照片，按拍摄时间排列。
private struct DailyPhotoView: View {
    let photos: [PhotoRecord]
    let theme: AppTheme
    let pendingIDs: Set<String>
    let transitionProgress: CGFloat
    let currentPhotoID: String?
    let transitionNamespace: Namespace.ID
    let onTogglePending: (String) -> Void
    let onDismiss: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(photos, id: \.persistentModelID) { photo in
                        DailyPhotoCell(photo: photo,
                                       pending: pendingIDs.contains(photo.localIdentifier),
                                       isTransitionTarget: photo.localIdentifier == currentPhotoID,
                                       transitionNamespace: transitionNamespace,
                                       onTogglePending: { onTogglePending(photo.localIdentifier) })
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("前后 5 天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.left")
                    }
                    .tint(theme.color)
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(Color.black.opacity(0.88 * transitionProgress).ignoresSafeArea())
    }
}

private struct DailyPhotoCell: View {
    let photo: PhotoRecord
    let pending: Bool
    let isTransitionTarget: Bool
    let transitionNamespace: Namespace.ID
    let onTogglePending: () -> Void
    @State private var image: UIImage?
    @State private var verticalOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().controlSize(.small).tint(.white.opacity(0.45))
            }
        }
        .frame(minHeight: 118)
        .aspectRatio(0.86, contentMode: .fit)
        .clipped()
        .matchedGeometryEffect(id: "around-day-\(photo.localIdentifier)",
                               in: transitionNamespace, isSource: false)
        .overlay {
            if pending {
                Color.red.opacity(0.28)
                Image(systemName: "trash.fill").foregroundStyle(.white)
            }
        }
        .offset(y: verticalOffset)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard value.translation.height < 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    verticalOffset = max(value.translation.height, -70)
                }
                .onEnded { value in
                    if value.translation.height < -44 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onTogglePending()
                    }
                    withAnimation(.easeOut(duration: 0.18)) { verticalOffset = 0 }
                }
        )
        .task(id: photo.localIdentifier) {
            if let path = photo.thumbnailPath, let cached = UIImage(contentsOfFile: path) {
                image = cached
            } else {
                image = await PhotoThumbnailGenerator.previewImage(localID: photo.localIdentifier)
            }
        }
    }
}

/// 快速加载时完全不出现；只有等待超过 180ms 才给出低存在感反馈。
private struct DelayedPhotoLoadingIndicator: View {
    @State private var visible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.white.opacity(0.48))
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
    }
}

/// Label 横排小样式
struct HStackLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

#if DEBUG
// MARK: - 诊断层（仅 DEBUG）：全局 frame 日志
extension View {
    func debugLayer(_ label: String, logFrame: Bool = true) -> some View {
        self
            .background {
                if logFrame {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.frame(in: .global)) { _, frame in
                                DebugFrameTracker.log(label, frame)
                            }
                    }
                }
            }
    }
}

/// 帧日志节流器：同一层最多 4Hz，且只在 frame 真正变化时写日志。
enum DebugFrameTracker {
    private static var lastFrame: [String: CGRect] = [:]
    private static var lastLoggedAt: [String: TimeInterval] = [:]

    static func log(_ label: String, _ frame: CGRect) {
        guard lastFrame[label] != frame else { return }
        lastFrame[label] = frame
        let now = Date().timeIntervalSince1970
        if let last = lastLoggedAt[label], now - last < 0.25 { return }
        lastLoggedAt[label] = now
        MapDebugLog.log("[FRAME] \(label): x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))")
    }
}
#endif


// MARK: - 独立顶部进度条（纯 GPU scale 驱动，绝对屏蔽外层动画事务污染）

private struct PhotoProgressBar: View {
    let index: Int
    let totalCount: Int

    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(index + 1) / Double(totalCount), 0), 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.13))
            Capsule()
                .fill(Color.white.opacity(0.72))
                .scaleEffect(x: max(0.001, progress), anchor: .leading)
                .animation(.easeOut(duration: 0.20), value: progress)
        }
        .frame(height: 3)
        // 关键防护：屏蔽任何外层传入的隐式动画事务（如异步图片加载、背景切换等），
        // 确保进度条动画纯粹且唯一地只随 progress 数值变更而单向平滑过渡！
        .transaction { transaction in
            if transaction.animation != nil {
                transaction.animation = .easeOut(duration: 0.20)
            }
        }
    }
}

// MARK: - 精准进度条诊断日志

enum ProgressTraceLogger {
    private static var lastLoggedDragOffset: CGFloat = -9999
    private static var lastLoggedTime: TimeInterval = 0

    static func log(
        event: String,
        index: Int,
        totalCount: Int,
        photo: PhotoRecord?,
        meta: PhotoAssetMetadata?,
        dragOffset: CGFloat = 0,
        throttleDrag: Bool = false
    ) {
        #if DEBUG
        let now = Date().timeIntervalSince1970
        if throttleDrag {
            if abs(dragOffset - lastLoggedDragOffset) < 20 && (now - lastLoggedTime) < 0.25 {
                return
            }
            lastLoggedDragOffset = dragOffset
            lastLoggedTime = now
        }
        let progress = totalCount > 0 ? Double(index + 1) / Double(totalCount) : 0
        let photoID = photo?.localIdentifier ?? "none"
        let mediaType = meta?.isLivePhoto == true ? "LivePhoto" : "Photo"
        let w = meta?.width ?? 0
        let h = meta?.height ?? 0
        let orientation = w > h ? "Landscape" : (w < h ? "Portrait" : (w > 0 ? "Square" : "Unknown"))
        let size = "\(w)x\(h)"
        let ts = String(format: "%.3f", now)
        let progressStr = String(format: "%.4f", progress)
        let offsetStr = String(format: "%.1f", dragOffset)
        let logMsg = "[PROGRESS TRACE] event=\(event) index=\(index) count=\(totalCount) progress=\(progressStr) photo=\(photoID) mediaType=\(mediaType) size=\(size) orientation=\(orientation) dragOffset=\(offsetStr) ts=\(ts)"
        MapDebugLog.log(logMsg)
        print(logMsg)
        #endif
    }
}
