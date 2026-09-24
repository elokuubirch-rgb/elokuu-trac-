import Foundation

/// 接受测量点不等于有连续路径证据。只决定断线，不删除点或生成坐标。
public enum TrackConnectionPolicy {
    public static let maximumContinuousInterval: TimeInterval = 30
    public static let maximumContinuousDistance: Double = 5_000
    public static let maximumPhotoInterpolationInterval: TimeInterval = 120

    public static func permitsConnection(source: LocationSampleSource,
                                         elapsed: TimeInterval, distance: Double) -> Bool {
        source == .standard && elapsed > 0 && elapsed <= maximumContinuousInterval
            && distance.isFinite && distance >= 0 && distance <= maximumContinuousDistance
    }
}
