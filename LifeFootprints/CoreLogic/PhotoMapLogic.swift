import Foundation

/// 照片地图的纯逻辑缩放层级。与 UI 层解耦，便于单测缩放边界。
public enum PhotoMapZoomLevel: Int, CaseIterable, Equatable {
    case province, city, district, town, block, spot, single
}

public enum PhotoMapLogic {
    public static func preferredLevel(latitudeSpan span: Double) -> PhotoMapZoomLevel {
        switch max(span, 0) {
        case let value where value > 8: return .province
        case let value where value > 1.2: return .city
        case let value where value > 0.1: return .district
        case let value where value > 0.03: return .town
        case let value where value > 0.015: return .block
        case let value where value > 0.005: return .spot
        default: return .single
        }
    }

    /// 在层级边界加入迟滞，避免捏合手势在阈值附近来回闪烁。
    public static func stableLevel(latitudeSpan span: Double,
                                   current: PhotoMapZoomLevel,
                                   margin: Double = 0.16) -> PhotoMapZoomLevel {
        let target = preferredLevel(latitudeSpan: span)
        guard target != current else { return current }
        let boundaries = [8.0, 1.2, 0.1, 0.03, 0.015, 0.005]
        if target.rawValue > current.rawValue {
            let boundary = boundaries[current.rawValue]
            return span < boundary * (1 - margin) ? target : current
        } else {
            let boundary = boundaries[target.rawValue]
            return span > boundary * (1 + margin) ? target : current
        }
    }

    /// 判断坐标是否在地图视野内，包含跨越 ±180° 日期变更线的情况。
    public static func contains(latitude: Double, longitude: Double,
                                centerLatitude: Double, centerLongitude: Double,
                                latitudeSpan: Double, longitudeSpan: Double,
                                padding: Double = 0.30) -> Bool {
        let latHalf = latitudeSpan * (1 + padding) / 2
        guard latitude >= centerLatitude - latHalf,
              latitude <= centerLatitude + latHalf else { return false }
        guard longitudeSpan < 360 else { return true }
        let lonHalf = longitudeSpan * (1 + padding) / 2
        var delta = longitude - centerLongitude
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return abs(delta) <= lonHalf
    }

    /// 聚合路线照片时，算术中心常落在弯道/环线内部。若组内至少一半照片
    /// 已吸附到轨迹，就从真实路线锚点中选择最接近组中心的一点作为标记锚点。
    /// 返回值因此仍在实际轨迹上，而不是路线外的几何质心。
    public static func routeAwareAnchor(
        meanLatitude: Double,
        meanLongitude: Double,
        routeAnchors: [(latitude: Double, longitude: Double)],
        totalCount: Int
    ) -> (latitude: Double, longitude: Double) {
        guard !routeAnchors.isEmpty,
              routeAnchors.count * 2 >= max(totalCount, 1) else {
            return (meanLatitude, meanLongitude)
        }
        return routeAnchors.min {
            GeoMath.distanceMeters(from: (meanLatitude, meanLongitude),
                                    to: ($0.latitude, $0.longitude))
            < GeoMath.distanceMeters(from: (meanLatitude, meanLongitude),
                                      to: ($1.latitude, $1.longitude))
        } ?? (meanLatitude, meanLongitude)
    }
}
