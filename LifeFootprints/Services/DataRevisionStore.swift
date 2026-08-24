import Foundation

extension Notification.Name {
    /// 仅在已提交、会改变用户可见数据的事务后发送。
    static let dataRevisionChanged = Notification.Name("dataRevisionChanged")
}

struct DataRevisionDomains: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let trajectory = Self(rawValue: 1 << 0)
    static let photo = Self(rawValue: 1 << 1)
    static let place = Self(rawValue: 1 << 2)
    static let stats = Self(rawValue: 1 << 3)
}

struct DataRevisionSnapshot: Equatable, Sendable {
    let trajectory: Int
    let photo: Int
    let place: Int
    let stats: Int
}

struct DataRevisionChange: Sendable {
    let domains: DataRevisionDomains
    let previous: DataRevisionSnapshot
    let current: DataRevisionSnapshot
    let reason: String
}

/// 持久、分域的数据版本。Service 执行完成不等于数据改变；只有成功提交可见数据后才递增。
enum DataRevisionStore {
    private static let lock = NSLock()
    private static let trajectoryKey = "dataRevision.trajectory.v1"
    private static let photoKey = "dataRevision.photo.v1"
    private static let placeKey = "dataRevision.place.v1"
    private static let statsKey = "dataRevision.stats.v1"

    static func snapshot(defaults: UserDefaults = .standard) -> DataRevisionSnapshot {
        lock.withLock { snapshotUnlocked(defaults: defaults) }
    }

    @discardableResult
    static func commit(_ domains: DataRevisionDomains, reason: String,
                       defaults: UserDefaults = .standard,
                       publish: Bool = true) -> DataRevisionChange? {
        guard !domains.isEmpty else { return nil }
        let change = lock.withLock { () -> DataRevisionChange in
            let previous = snapshotUnlocked(defaults: defaults)
            if domains.contains(.trajectory) {
                defaults.set(previous.trajectory + 1, forKey: trajectoryKey)
            }
            if domains.contains(.photo) { defaults.set(previous.photo + 1, forKey: photoKey) }
            if domains.contains(.place) { defaults.set(previous.place + 1, forKey: placeKey) }
            if domains.contains(.stats) { defaults.set(previous.stats + 1, forKey: statsKey) }
            return DataRevisionChange(
                domains: domains, previous: previous,
                current: snapshotUnlocked(defaults: defaults), reason: reason)
        }
        guard publish else { return change }

        let post = {
            #if DEBUG
            PerformanceDiagnostics.event(
                "DataRevision.changed",
                metadata: "reason=\(reason) domains=\(domains.rawValue) trajectory=\(change.current.trajectory)")
            PerformanceDiagnostics.count("dataImported.post.total")
            #endif
            NotificationCenter.default.post(name: .dataRevisionChanged, object: change)
            // 兼容仍依赖旧通知的非性能关键路径；性能消费者只监听 dataRevisionChanged。
            NotificationCenter.default.post(name: .dataImported, object: change)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
        return change
    }

    private static func snapshotUnlocked(defaults: UserDefaults) -> DataRevisionSnapshot {
        DataRevisionSnapshot(
            trajectory: defaults.integer(forKey: trajectoryKey),
            photo: defaults.integer(forKey: photoKey),
            place: defaults.integer(forKey: placeKey),
            stats: defaults.integer(forKey: statsKey))
    }
}

/// HealthKit 的同步完成与轨迹可见数据改变必须是两个独立语义。
enum HealthSyncInvalidationPolicy {
    static func domains(workoutInsertedOrUpdated: Bool, workoutDeleted: Bool,
                        routeInsertedOrUpdated: Bool, routeDeleted: Bool)
        -> DataRevisionDomains {
        var result: DataRevisionDomains = []
        if workoutInsertedOrUpdated || workoutDeleted { result.insert(.stats) }
        if routeInsertedOrUpdated || routeDeleted {
            result.formUnion([.trajectory, .stats])
        }
        return result
    }
}
