import Foundation

/// 地图图层的数据语义。照片、轨迹与当前位置必须使用各自的数据源，
/// 旧数据库中的混合 FootprintPoint 只在这里被分类，不能由 UI 临时猜测。
public enum MapLayerSemantics {
    public static func isAutoTrajectory(_ snapshot: FootprintSnapshot,
                                        workoutSourceVisible: Bool = true) -> Bool {
        let isAutoSource = snapshot.source == FootprintSource.gps.rawValue
            || (snapshot.source == FootprintSource.csv.rawValue
                && snapshot.trajectoryID != nil)
        guard isAutoSource else { return false }
        if !snapshot.isSuppressedDuplicate { return true }
        return !workoutSourceVisible
            && snapshot.suppressedBySource == TrajectorySource.healthWorkout.rawValue
    }

    /// Core Location 自动轨迹。照片、CSV 和手动地点都不是轨迹采样点。
    public static func autoTrajectory(_ snapshots: [FootprintSnapshot],
                                      workoutSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            isAutoTrajectory($0, workoutSourceVisible: workoutSourceVisible)
        }
    }

    public static func isWorkoutTrajectory(_ snapshot: FootprintSnapshot,
                                           autoSourceVisible: Bool = true) -> Bool {
        guard snapshot.source == FootprintSource.health.rawValue else { return false }
        if !snapshot.isSuppressedDuplicate { return true }
        return !autoSourceVisible
            && (snapshot.suppressedBySource == TrajectorySource.coreLocation.rawValue
                || snapshot.suppressedBySource == TrajectorySource.imported.rawValue)
    }

    /// HealthKit 运动路线，边界与跨来源冲突已由领域解析结果标注。
    public static func workoutTrajectory(_ snapshots: [FootprintSnapshot],
                                         autoSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            isWorkoutTrajectory($0, autoSourceVisible: autoSourceVisible)
        }
    }

    public static func isFootprintDot(_ snapshot: FootprintSnapshot,
                                      workoutSourceVisible: Bool = true) -> Bool {
        guard snapshot.source != FootprintSource.photo.rawValue,
              snapshot.source != FootprintSource.health.rawValue else { return false }
        if !snapshot.isSuppressedDuplicate { return true }
        return !workoutSourceVisible
            && snapshot.suppressedBySource == TrajectorySource.healthWorkout.rawValue
    }

    /// 普通足迹点层不显示照片点，也不泄漏受“运动路线”开关控制的健康点。
    /// CSV 连续序列可同时属于 imported 轨迹；稀疏 CSV 与手动点仍是普通地点。
    public static func footprintDots(_ snapshots: [FootprintSnapshot],
                                     workoutSourceVisible: Bool = true) -> [FootprintSnapshot] {
        snapshots.filter {
            isFootprintDot($0, workoutSourceVisible: workoutSourceVisible)
        }
    }

    /// 只要任一点带有领域边界，trajectory/session/segment 任一变化都必须断线。
    public static func crossesTrajectoryBoundary(_ previous: FootprintSnapshot,
                                                  _ current: FootprintSnapshot) -> Bool {
        let hasBoundary = previous.trajectoryID != nil || current.trajectoryID != nil
            || previous.sessionID != nil || current.sessionID != nil
            || previous.segmentID != nil || current.segmentID != nil
        guard hasBoundary else { return false }
        return previous.trajectoryID != current.trajectoryID ||
            previous.sessionID != current.sessionID ||
            previous.segmentID != current.segmentID
    }

    public static func hasExplicitTrajectoryBoundary(_ previous: FootprintSnapshot,
                                                     _ current: FootprintSnapshot) -> Bool {
        previous.trajectoryID != nil || current.trajectoryID != nil
            || previous.sessionID != nil || current.sessionID != nil
            || previous.segmentID != nil || current.segmentID != nil
    }
}
