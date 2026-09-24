import MapKit

/// 经用户授权，把有限数量的轨迹锚点发送给 Apple 路线服务获取道路几何。
/// 返回结果仍需经过 RoadMatchValidator；路线规划成功不等于匹配成功。
struct MapKitRoadGeometryProvider: RoadGeometryProvider {
    func roadGeometry(between start: RoadGeometryCoordinate,
                      and end: RoadGeometryCoordinate,
                      activityType: String?) async throws
        -> [RoadGeometryCoordinate] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(
            latitude: start.latitude, longitude: start.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(
            latitude: end.latitude, longitude: end.longitude)))
        request.requestsAlternateRoutes = false
        request.transportType = transportType(activityType)

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw RoadGeometryProviderError.noRoute
        }
        let polyline = route.polyline
        let mapPoints = polyline.points()
        return (0..<polyline.pointCount).map { index in
            let coordinate = mapPoints[index].coordinate
            return RoadGeometryCoordinate(
                latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    private func transportType(_ activityType: String?) -> MKDirectionsTransportType {
        guard let value = activityType?.lowercased() else { return .walking }
        if value.contains("drive") || value.contains("automotive")
            || value.contains("vehicle") {
            return .automobile
        }
        // MapKit 没有骑行类型；步行比机动车路线更适合步道与非机动车通行路段。
        return .walking
    }
}
