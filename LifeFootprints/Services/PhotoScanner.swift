import Foundation
import Photos

/// 扫描结果：足迹草稿 + 照片地理元数据
struct PhotoScanResult {
    var drafts: [FootprintDraft]
    var photoInfos: [PhotoInfo]
}

/// 相册扫描：读取照片中的 GPS 位置
enum PhotoScanner {

    /// 请求相册权限（支持「选中的照片」受限模式）。
    /// 先同步查询当前状态：已授权时直接返回，避免系统异步回调挂起。
    static func requestAccess() async -> PHAuthorizationStatus {
        appLog.info("[Perm] 进入 requestAccess")
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        appLog.info("[Perm] 当前状态: \(current.rawValue)")
        if current == .authorized || current == .limited {
            return current
        }
        appLog.info("[Perm] 发起系统请求")
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                appLog.info("[Perm] 系统回调: \(status.rawValue)")
                continuation.resume(returning: status)
            }
        }
    }

    /// 扫描相册中带 GPS 位置的照片（仅读取元数据，不解码图片），
    /// 同时产出足迹草稿与照片地理元数据
    static func scanWithPhotos(progress: @escaping (Int, Int) -> Void) -> PhotoScanResult {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count
        appLog.info("[Scan] 相册照片总数: \(total)")
        var drafts: [FootprintDraft] = []
        var infos: [PhotoInfo] = []
        drafts.reserveCapacity(total)
        infos.reserveCapacity(total)
        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location, let date = asset.creationDate else { return }
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            drafts.append(FootprintDraft(latitude: lat, longitude: lon, timestamp: date, source: FootprintSource.photo.rawValue))
            infos.append(PhotoInfo(localIdentifier: asset.localIdentifier, latitude: lat, longitude: lon, timestamp: date))
            if drafts.count % 300 == 0 {
                progress(drafts.count, total)
            }
        }
        appLog.info("[Scan] 含位置照片数: \(drafts.count)")
        return PhotoScanResult(drafts: drafts, photoInfos: infos)
    }

    /// 扫描相册中带 GPS 位置的照片，返回足迹草稿（兼容旧调用）
    static func scan(progress: @escaping (Int, Int) -> Void) -> [FootprintDraft] {
        scanWithPhotos(progress: progress).drafts
    }
}
