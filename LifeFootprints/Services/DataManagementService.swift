import Foundation
import SwiftData

extension Notification.Name {
    /// 完整清理提交后，让常驻的 Map / Review / Statistics 丢弃内存会话与派生状态。
    static let localDataReset = Notification.Name("localDataReset")
}

/// 只清理 Trace 自己保存的模型、索引、回顾状态和派生缓存。
/// 不向 PhotoKit 或 HealthKit 发送任何删除请求。
@MainActor
enum DataManagementService {
    static func resetAllLocalData(in context: ModelContext) async throws {
        let imports = LocalImportCoordinator.shared
        let resetToken = try imports.beginReset()
        defer { imports.finishReset(resetToken) }
        // 先停止可能继续写回本地数据库的后台生产者，再执行同一保存边界内的批量删除。
        await LocationService.shared.prepareForLocalDataReset()
        await HealthKitSyncCoordinator.shared.prepareForLocalDataReset()
        await imports.waitForActiveWrites()

        do {
            try context.delete(model: WorkoutRoutePoint.self)
            try context.delete(model: WorkoutRouteRecord.self)
            try context.delete(model: WorkoutRecord.self)
            try context.delete(model: PhotoRecord.self)
            try context.delete(model: FootprintPoint.self)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        ReviewHistoryStore.reset()
        ReviewSessionPersistence.reset()
        PhotoStore.resetLocalState()
        HealthKitService.resetLocalSyncState()
        MapSourceStore.reset()
        UserDefaults.standard.set("standard", forKey: "mapType")
        UserDefaults.standard.removeObject(forKey: "reviewGroupSize")

        PhotoThumbnailGenerator.clearLocalCache()
        PersistentTrajectoryCache.shared.clear()
        MapDisplaySnapshotStore.shared.clear()
        StatsSnapshotStore.shared.clear()
        PhotoTrajectoryAssociationStore.shared.clear()
        PersistentRouteLODCache.shared.clear()
        TrajectoryResolutionCache.shared.invalidate()
        SnapshotCache.reset()
        await StatsClusterRevisionCache.shared.reset()

        DataRevisionStore.commit([.trajectory, .photo, .place, .stats],
                                 reason: "DataManagementService.resetAllLocalData")
        NotificationCenter.default.post(name: .localDataReset, object: nil)
    }
}
