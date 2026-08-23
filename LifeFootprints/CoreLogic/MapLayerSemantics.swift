import Foundation

/// 地图图层的数据语义。照片、轨迹与当前位置必须使用各自的数据源，
/// 旧数据库中的混合 FootprintPoint 只在这里被分类，不能由 UI 临时猜测。
public enum MapLayerSemantics {
    /// Core Location 自动轨迹。照片、CSV 和手动地点都不是轨迹采样点。
    public static func autoTrajectory(_ snapshots: [FootprintSnapshot],
                                      workoutSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            let isAutoSource = $0.source == FootprintSource.gps.rawValue
                || ($0.source == FootprintSource.csv.rawValue && $0.trajectoryID != nil)
            guard isAutoSource else { return false }
            if !$0.isSuppressedDuplicate { return true }
            return !workoutSourceVisible
                && $0.suppressedBySource == TrajectorySource.healthWorkout.rawValue
        }
    }

    /// HealthKit 运动路线，边界与跨来源冲突已由领域解析结果标注。
    public static func workoutTrajectory(_ snapshots: [FootprintSnapshot],
                                         autoSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            guard $0.source == FootprintSource.health.rawValue else { return false }
            if !$0.isSuppressedDuplicate { return true }
            return !autoSourceVisible
                && ($0.suppressedBySource == TrajectorySource.coreLocation.rawValue
                    || $0.suppressedBySource == TrajectorySource.imported.rawValue)
        }
    }

    /// 普通足迹点层不显示照片点，也不泄漏受“运动路线”开关控制的健康点。
    /// CSV 连续序列可同时属于 imported 轨迹；稀疏 CSV 与手动点仍是普通地点。
    public static func footprintDots(_ snapshots: [FootprintSnapshot],
                                     workoutSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            guard $0.source != FootprintSource.photo.rawValue,
                  $0.source != FootprintSource.health.rawValue else { return false }
            if !$0.isSuppressedDuplicate { return true }
            return !workoutSourceVisible
                && $0.suppressedBySource == TrajectorySource.healthWorkout.rawValue
        }
    }

    /// 只要任一点带有领域边界，trajectory/session/segment 任一变化都必须断线。
    public static func crossesTrajectoryBoundary(_ previous: FootprintSnapshot,
                                                  _ current: FootprintSnapshot) -> Bool {
        guard previous.trajectoryID != nil || current.trajectoryID != nil else { return false }
        return previous.trajectoryID != current.trajectoryID ||
            previous.sessionID != current.sessionID ||
            previous.segmentID != current.segmentID
    }
}
