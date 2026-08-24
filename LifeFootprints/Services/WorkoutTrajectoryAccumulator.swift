import Foundation

/// SwiftData batch 与轨迹领域之间的轻量值，确保 @Model 生命周期止于单个 fetch page。
struct WorkoutRoutePointValue {
    let workoutID: String
    let routeID: String?
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double?
    let speed: Double?
    let course: Double?
}

/// 输入必须按 timestamp 全局升序。它直接构造最终 TrajectoryPoint，避免同时常驻
/// 623k SwiftData models + 623k TrajectorySample + 623k TrajectoryPoint。
final class WorkoutTrajectoryAccumulator {
    private let configuration: TrajectoryBuilderConfiguration
    private let activityByWorkout: [String: String]
    private var sessions: [String: SessionState] = [:]

    init(activityByWorkout: [String: String],
         configuration: TrajectoryBuilderConfiguration = .init()) {
        self.activityByWorkout = activityByWorkout
        self.configuration = configuration
    }

    func append(_ value: WorkoutRoutePointValue, globalIndex: Int) {
        guard GeoMath.isValid(latitude: value.latitude, longitude: value.longitude) else { return }
        let session = sessions[value.workoutID]
            ?? SessionState(id: value.workoutID, activityType: activityByWorkout[value.workoutID])
        sessions[value.workoutID] = session
        let routeID = value.routeID ?? "legacy-route:\(value.workoutID)"
        let route = session.routes[routeID] ?? RouteState()
        session.routes[routeID] = route
        let point = TrajectoryPoint(
            id: "workout:\(value.workoutID):\(millis(value.timestamp)):\(globalIndex)",
            latitude: value.latitude, longitude: value.longitude,
            timestamp: value.timestamp, altitude: value.altitude,
            horizontalAccuracy: value.horizontalAccuracy,
            speed: value.speed, course: value.course, source: .healthWorkout)

        if let previous = route.segments.last?.points.last {
            let timeGap = point.timestamp.timeIntervalSince(previous.timestamp)
            let distance = GeoMath.distanceMeters(
                from: (previous.latitude, previous.longitude),
                to: (point.latitude, point.longitude))
            if timeGap > configuration.maximumTimeGap
                || distance > configuration.maximumDistanceGapMeters {
                route.segments.append(SegmentState())
            }
        }
        if route.segments.isEmpty { route.segments.append(SegmentState()) }
        route.segments[route.segments.count - 1].append(
            point, acceptableAccuracy: configuration.acceptableHorizontalAccuracy)
        session.stats.append(
            point, acceptableAccuracy: configuration.acceptableHorizontalAccuracy)
    }

    func finish() -> [Trajectory] {
        sessions.keys.sorted().compactMap { sessionID in
            guard let session = sessions[sessionID],
                  let start = session.stats.firstTime,
                  let end = session.stats.lastTime else { return nil }
            let trajectoryID = "\(TrajectorySource.healthWorkout.rawValue):\(sessionID)"
            var segments: [TrajectorySegment] = []
            for routeID in session.routes.keys.sorted() {
                guard let route = session.routes[routeID] else { continue }
                for (index, state) in route.segments.enumerated() {
                    guard let segmentStart = state.stats.firstTime,
                          let segmentEnd = state.stats.lastTime else { continue }
                    segments.append(TrajectorySegment(
                        id: "\(trajectoryID):\(routeID):segment:\(index)",
                        trajectoryID: trajectoryID, sessionID: sessionID,
                        source: .healthWorkout, points: state.points,
                        startTime: segmentStart, endTime: segmentEnd,
                        quality: state.stats.quality(configuration: configuration)))
                }
            }
            let quality = session.stats.quality(configuration: configuration)
            return Trajectory(
                id: trajectoryID, source: .healthWorkout,
                sourceIdentifier: sessionID, sessionID: sessionID,
                startTime: start, endTime: end, activityType: session.activityType,
                segments: segments, quality: quality, confidence: quality.confidence,
                displayPriority: 200)
        }.sorted { $0.startTime < $1.startTime }
    }

    private final class SessionState {
        let id: String
        let activityType: String?
        var routes: [String: RouteState] = [:]
        var stats = PointStats()
        init(id: String, activityType: String?) {
            self.id = id
            self.activityType = activityType
        }
    }

    private final class RouteState {
        var segments: [SegmentState] = []
    }

    private final class SegmentState {
        var points: [TrajectoryPoint] = []
        var stats = PointStats()
        func append(_ point: TrajectoryPoint, acceptableAccuracy: Double) {
            points.append(point)
            stats.append(point, acceptableAccuracy: acceptableAccuracy)
        }
    }

    private struct PointStats {
        var count = 0
        var firstTime: Date?
        var lastTime: Date?
        var maximumGap: TimeInterval = 0
        var measuredAccuracyCount = 0
        var accuratePointCount = 0

        mutating func append(_ point: TrajectoryPoint, acceptableAccuracy: Double) {
            if let lastTime {
                maximumGap = max(maximumGap, point.timestamp.timeIntervalSince(lastTime))
            } else {
                firstTime = point.timestamp
            }
            lastTime = point.timestamp
            count += 1
            if let accuracy = point.horizontalAccuracy, accuracy >= 0 {
                measuredAccuracyCount += 1
                if accuracy <= acceptableAccuracy { accuratePointCount += 1 }
            }
        }

        func quality(configuration: TrajectoryBuilderConfiguration) -> TrajectoryQuality {
            let ratio = measuredAccuracyCount == 0 ? 0.5
                : Double(accuratePointCount) / Double(measuredAccuracyCount)
            let pointScore = min(1, Double(count) / 20)
            let confidence = min(1, max(0, pointScore * 0.55 + ratio * 0.45))
            return TrajectoryQuality(
                pointCount: count,
                duration: max(0, (lastTime ?? .distantPast)
                    .timeIntervalSince(firstTime ?? .distantPast)),
                maximumGap: maximumGap, accuratePointRatio: ratio,
                confidence: confidence)
        }
    }

    private func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
