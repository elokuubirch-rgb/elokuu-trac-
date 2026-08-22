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

    init(healthKitUUID: String, workoutType: String, startDate: Date, endDate: Date,
         duration: Double, distanceMeters: Double, caloriesKCal: Double,
         elevationGain: Double, routeAvailable: Bool) {
        self.healthKitUUID = healthKitUUID
        self.workoutType = workoutType
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.caloriesKCal = caloriesKCal
        self.elevationGain = elevationGain
        self.routeAvailable = routeAvailable
    }
}

/// Workout Route 原始点。只保存地图重建所需字段，不与普通 FootprintPoint 合并。
@Model
final class WorkoutRoutePoint {
    var workoutID: String
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date

    init(workoutID: String, latitude: Double, longitude: Double,
         altitude: Double, timestamp: Date) {
        self.workoutID = workoutID
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}
