import Foundation
import UIKit
import Photos
import PhotosUI
import SwiftData

struct PhotoAssetMetadata: Sendable {
    let width: Int
    let height: Int
    let isLivePhoto: Bool

    var aspectRatio: CGFloat {
        guard height > 0 else { return 0.75 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// 照片缩略图：文件缓存优先，缺失时 PHImageManager 即时取图（后台线程安全）
@MainActor
enum PhotoThumbnailGenerator {

    /// 用 Photos 系统分类缩小候选池，不做尺寸猜测或人脸识别。
    nonisolated static func matchingIDs(_ localIDs: [String], filter: ReviewMediaFilter) -> [String] {
        guard filter != .all, !localIDs.isEmpty else { return localIDs }
        let requested = Set(localIDs)
        if filter == .selfie {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil
            )
            guard let album = collections.firstObject else { return [] }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var result: [String] = []
            assets.enumerateObjects { asset, _, _ in
                if requested.contains(asset.localIdentifier) { result.append(asset.localIdentifier) }
            }
            return result
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil)
        var result: [String] = []
        assets.enumerateObjects { asset, _, _ in
            let matches = filter == .livePhoto
                ? asset.mediaSubtypes.contains(.photoLive)
                : asset.mediaSubtypes.contains(.photoScreenshot)
            if matches { result.append(asset.localIdentifier) }
        }
        return result
    }

    /// 不解码图片即可获取横竖比例和 Live Photo 标记，供卡堆预布局。
    nonisolated static func metadata(localIDs: [String]) -> [String: PhotoAssetMetadata] {
        guard !localIDs.isEmpty else { return [:] }
        #if DEBUG
        // Simulator seed assets live in the app cache rather than Photos. Avoid asking
        // Photos for these synthetic identifiers so orientation regression tests remain
        // deterministic and do not trigger the system library permission sheet.
        var result = Dictionary(uniqueKeysWithValues: localIDs.compactMap { id -> (String, PhotoAssetMetadata)? in
            guard id.hasPrefix("seed-"), let index = Int(id.dropFirst(5)) else { return nil }
            let size: (Int, Int) = switch index % 3 {
            case 0: (420, 236)
            case 1: (236, 420)
            default: (300, 300)
            }
            return (id, PhotoAssetMetadata(width: size.0, height: size.1, isLivePhoto: false))
        })
        let photosIDs = localIDs.filter { result[$0] == nil }
        guard !photosIDs.isEmpty else { return result }
        #else
        let photosIDs = localIDs
        var result: [String: PhotoAssetMetadata] = [:]
        #endif
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: photosIDs, options: nil)
        assets.enumerateObjects { asset, _, _ in
            result[asset.localIdentifier] = PhotoAssetMetadata(
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
            )
        }
        return result
    }

    /// 循环生成全部待生成缩略图（每 200 张一批，可中断续跑；App 生命周期内常驻）
    static func generateAllPending(in context: ModelContext) async {
        while true {
            let pending = PhotoStore.pendingThumbnails(in: context)
            guard !pending.isEmpty else { return }
            await generateBatch(pending, in: context)
        }
    }

    /// 单批生成（旧入口保留：扫描后立即跑一批）
    static func generateForPending(in context: ModelContext, progress: (Int, Int) -> Void) async {
        let pending = PhotoStore.pendingThumbnails(in: context)
        guard !pending.isEmpty else {
            appLog.info("[Thumb] 无待生成缩略图的照片")
            return
        }
        await generateBatch(pending, in: context)
    }

    private static func generateBatch(_ pending: [PhotoRecord], in context: ModelContext) async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var done = 0
        for record in pending {
            // 批量生成：仅本地（iCloud 原图不触发下载，避免后台海量流量）
            if let image = await fetchThumbnail(localID: record.localIdentifier, allowNetwork: false) {
                let url = dir.appendingPathComponent("\(record.localIdentifier).jpg")
                if let data = image.jpegData(compressionQuality: 0.75) {
                    try? data.write(to: url)
                    record.thumbnailPath = url.path
                }
            }
            // 无论本地是否有原图，都更新状态，避免死循环重试打爆内存与 CPU
            record.thumbState = 1
            try? context.save()
            done += 1
        }
        appLog.info("[Thumb] 缩略图生成批次：\(done) / \(pending.count)")
    }

    /// 取一张照片的缩略图：文件缓存优先；缺失时 PHImageManager 即时请求
    /// （nonisolated：供照片架等后台线程调用，避免主线程解码；允许网络取 iCloud 缩略图）
    nonisolated static func thumbnailImage(for record: PhotoRecord) async -> UIImage? {
        if let path = record.thumbnailPath, let image = UIImage(contentsOfFile: path) {
            return image
        }
        return await fetchThumbnail(localID: record.localIdentifier, allowNetwork: true)
    }

    /// 按 id 直接取图（聚合标记/探索卡牌缩略图后备）。
    /// 先查缓存文件（localIdentifier 命名，不依赖记录路径）；成功后顺手写缓存——
    /// 随用户浏览节奏写入，避免全量生成导致磁盘写入超限被杀。
    nonisolated static func image(localID: String) async -> UIImage? {
        let url = cacheURL(localID: localID)
        if let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        guard let img = await fetchThumbnail(localID: localID, allowNetwork: true) else { return nil }
        if let data = img.jpegData(compressionQuality: 0.75) {
            try? data.write(to: url)
        }
        return img
    }

    /// 探索页高清预览：保留横竖图完整比例，原子化单次回调保护，避免内存暴涨与 Continuation 崩溃
    nonisolated static func previewImage(localID: String) async -> UIImage? {
        #if DEBUG
        if localID.hasPrefix("seed-"), let image = UIImage(contentsOfFile: cacheURL(localID: localID).path) {
            return image
        }
        #endif
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let lock = NSLock()
            var hasResumed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1_200, height: 1_200),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let isError = info?[PHImageErrorKey] != nil
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true

                lock.lock()
                defer { lock.unlock() }

                guard !hasResumed else { return }

                if isCancelled || isError {
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                if !isDegraded {
                    hasResumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Live Photo 按需请求；普通照片直接返回 nil，原子化回调保护
    nonisolated static func livePhoto(localID: String, targetSize: CGSize) async -> PHLivePhoto? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject,
              asset.mediaSubtypes.contains(.photoLive) else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            let lock = NSLock()
            var hasResumed = false

            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let isError = info?[PHImageErrorKey] != nil
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true

                lock.lock()
                defer { lock.unlock() }

                guard !hasResumed else { return }

                if isCancelled || isError {
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                if !isDegraded {
                    hasResumed = true
                    continuation.resume(returning: livePhoto)
                }
            }
        }
    }

    nonisolated private static func cacheURL(localID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
            .appendingPathComponent("\(localID).jpg")
    }

    nonisolated private static func fetchThumbnail(localID: String, allowNetwork: Bool) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowNetwork
            options.isSynchronous = false

            let lock = NSLock()
            var hasResumed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 500, height: 500),
                contentMode: .aspectFill,
                options: options) { image, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let isError = info?[PHImageErrorKey] != nil
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true

                lock.lock()
                defer { lock.unlock() }

                guard !hasResumed else { return }

                if isCancelled || isError {
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                if !isDegraded {
                    hasResumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
