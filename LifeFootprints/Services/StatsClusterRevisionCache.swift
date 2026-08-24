import Foundation

struct StatsClusterCacheKey: Hashable, Sendable {
    let placeRevision: Int
    let trajectoryRevision: Int
    /// 区分同一持久 revision 在启动阶段尚未物化与已经物化的 snapshot。
    let snapshotGeneration: Int
}

struct StatsDenseArea: Equatable, Sendable {
    let lat: Double
    let lon: Double
    let count: Int
}

/// 同 revision 结果复用 + single-flight。页面激活次数不会再决定计算次数。
actor StatsClusterRevisionCache {
    static let shared = StatsClusterRevisionCache()

    private var completed: (key: StatsClusterCacheKey, value: [StatsDenseArea])?
    private var inFlight: [StatsClusterCacheKey: Task<[StatsDenseArea], Never>] = [:]
    private var latestRequestedKey: StatsClusterCacheKey?
    private var buildCount = 0

    func value(for key: StatsClusterCacheKey,
               snapshots: [FootprintSnapshot]) async -> [StatsDenseArea] {
        if let completed, completed.key == key {
            #if DEBUG
            PerformanceDiagnostics.count("StatsCluster.cache.hit")
            #endif
            return completed.value
        }
        latestRequestedKey = key
        if let task = inFlight[key] {
            #if DEBUG
            PerformanceDiagnostics.count("StatsCluster.singleFlight.join")
            #endif
            return await task.value
        }

        #if DEBUG
        PerformanceDiagnostics.count("StatsCluster.cache.miss")
        PerformanceDiagnostics.count("StatsCluster.rebuild.started")
        #endif
        buildCount += 1
        let task = Task.detached(priority: .utility) {
            #if DEBUG
            return PerformanceDiagnostics.measure(
                "StatsCluster.generation",
                metadata: "snapshots=\(snapshots.count) revision=\(key.placeRevision):\(key.trajectoryRevision):\(key.snapshotGeneration)") {
                    Self.build(snapshots)
                }
            #else
            return Self.build(snapshots)
            #endif
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        // 较旧 revision 即使稍后才完成，也不能挤掉更新 revision 的已完成缓存。
        if latestRequestedKey == key { completed = (key, value) }
        return value
    }

    func diagnosticBuildCount() -> Int { buildCount }

    private nonisolated static func build(_ snapshots: [FootprintSnapshot]) -> [StatsDenseArea] {
        let points = snapshots.map { (lat: $0.lat, lon: $0.lon) }
        return GeoMath.topClusters(points, topN: 5).map {
            StatsDenseArea(lat: $0.lat, lon: $0.lon, count: $0.count)
        }
    }
}
