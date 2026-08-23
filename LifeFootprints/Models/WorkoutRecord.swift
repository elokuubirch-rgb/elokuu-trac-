import Foundation
import SwiftData

/// HealthKit 锻炼摘要。与后台足迹分表，避免两种路线在数据语义上混合。
@Model
final class WorkoutRecord {
    @Attribute(.unique) var healthKitUUID: String
    var workoutType: String
    var startDate: Date
    var endDate: Date
    var duration: Double
    var distanceMeters: Double
    var caloriesKCal: Double
    var elevationGain: Double
    var routeAvailable: Bool
    /// Optional 保证旧 SwiftData Store 可自动轻量迁移；nil 按 unknown 解释。
    var routeSyncStateRaw: String?
    var routeLastCheckedAt: Date?
    var routeRetryCount: Int?
    var routeLastError: String?

    init(healthKitUUID: String, workoutType: String, startDate: Date, endDate: Date,
         duration: Double, distanceMeters: Double, caloriesKCal: Double,
         elevationGain: Double, routeAvailable: Bool,
         routeSyncState: WorkoutRouteSyncState = .unknown) {
        self.healthKitUUID = healthKitUUID
        self.workoutType = workoutType
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.caloriesKCal = caloriesKCal
        self.elevationGain = elevationGain
        self.routeAvailable = routeAvailable
        self.routeSyncStateRaw = routeSyncState.rawValue
        self.routeRetryCount = 0
    }

    var routeSyncState: WorkoutRouteSyncState {
        get { WorkoutRouteSyncState(rawValue: routeSyncStateRaw ?? "") ?? .unknown }
        set { routeSyncStateRaw = newValue.rawValue }
    }
}

enum WorkoutRouteSyncState: String {
    case unknown
    case pending
    case available
    case noRoute
    case failed
}

/// 一个 HKWorkoutRoute 的持久边界。Route Query 的流式 chunk 不等于 Segment。
@Model
final class WorkoutRouteRecord {
    @Attribute(.unique) var routeID: String
    var workoutID: String
    var sourceIdentifier: String?
    var sourceName: String?
    var deviceIdentifier: String?
    var createdAt: Date

    init(routeID: String, workoutID: String, sourceIdentifier: String? = nil,
         sourceName: String? = nil, deviceIdentifier: String? = nil,
         createdAt: Date = Date()) {
        self.routeID = routeID
        self.workoutID = workoutID
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.deviceIdentifier = deviceIdentifier
        self.createdAt = createdAt
    }
}

/// Workout Route 原始点。只保存地图重建所需字段，不与普通 FootprintPoint 合并。
@Model
final class WorkoutRoutePoint {
    var workoutID: String
    var routeID: String?
    var segmentIndex: Int?
    var pointIndex: Int?
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    var speed: Double?
    var course: Double?
    var sourceIdentifier: String?

    init(workoutID: String, latitude: Double, longitude: Double,
         altitude: Double, timestamp: Date, routeID: String? = nil,
         segmentIndex: Int? = nil, pointIndex: Int? = nil,
         horizontalAccuracy: Double? = nil, verticalAccuracy: Double? = nil,
         speed: Double? = nil, course: Double? = nil,
         sourceIdentifier: String? = nil) {
        self.workoutID = workoutID
        self.routeID = routeID
        self.segmentIndex = segmentIndex
        self.pointIndex = pointIndex
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.sourceIdentifier = sourceIdentifier
    }
}
