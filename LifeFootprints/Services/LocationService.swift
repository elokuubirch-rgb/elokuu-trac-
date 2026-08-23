import Foundation
import CoreLocation

extension Notification.Name {
    /// 低功耗后台捕获到新足迹（object = FootprintDraft）
    static let footprintsCaptured = Notification.Name("footprintsCaptured")
}

/// 实时定位服务：当前位置 + 低功耗后台足迹（访问监测 + 重大位置变化）。
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()

    // MARK: - 状态

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    private(set) var smoothedAltitude: Double = 0
    private(set) var altitudeHistory: [Double] = []

    /// 低功耗后台足迹开关（访问监测 + 重大位置变化），启动时从持久设置恢复。
    private(set) var backgroundEnabled = UserDefaults.standard.bool(forKey: "bgFootprints")
    private var appIsActive = true
    private var lastBackgroundSample: BackgroundLocationSample?
    private var requestedAlwaysUpgrade = false

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    private var altitudeSmoother = AltitudeSmoother(windowSize: 5)

    private override init() {
        super.init()
        manager.delegate = self
        configurePassiveLocation()
        lastBackgroundSample = Self.loadLastBackgroundSample()
    }

    // MARK: - 启动

    func start() {
        #if DEBUG
        // 自动截图只验证地图 UI，不应被系统权限弹窗遮挡；正式包与普通 DEBUG 启动不受影响。
        if ProcessInfo.processInfo.environment["FP_SKIP_LOCATION"] == "1" {
            appLog.info("[Loc] 自动化测试跳过定位权限请求")
            return
        }
        #endif
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        authorization = manager.authorizationStatus
        if appIsActive, manager.authorizationStatus != .denied {
            configurePassiveLocation()
            manager.startUpdatingLocation()
        }
        if backgroundEnabled { startBackgroundMonitoring() }
        let status = manager.authorizationStatus
        appLog.info("[Loc] start：授权=\(status.rawValue)")
    }

    /// App 冷启动（包括系统因重大位置变化唤醒）时恢复后台监测。
    func restoreBackgroundMonitoring() {
        backgroundEnabled = UserDefaults.standard.bool(forKey: "bgFootprints")
        guard backgroundEnabled else { return }
        authorization = manager.authorizationStatus
        requestAlwaysAuthorizationIfNeeded()
        startBackgroundMonitoring()
    }

    /// 前台仅使用百米级定位；退到后台立即停止标准定位，仅保留系统低功耗服务。
    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            configurePassiveLocation()
            if manager.authorizationStatus != .denied { manager.startUpdatingLocation() }
        } else {
            manager.stopUpdatingLocation()
        }
        if backgroundEnabled { startBackgroundMonitoring() }
    }

    private func configurePassiveLocation() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - 低功耗后台足迹

    /// 开/关后台足迹（触发 Always 权限升级 + 访问监测 + 重大位置变化）
    func setBackgroundFootprints(_ enabled: Bool) {
        backgroundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "bgFootprints")
        if enabled {
            if authorization == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                requestAlwaysAuthorizationIfNeeded()
            }
            startBackgroundMonitoring()
        } else {
            requestedAlwaysUpgrade = false
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
            appLog.info("[Visit] 后台足迹已关闭")
        }
    }

    private func startBackgroundMonitoring() {
        // 访问与重大位置变化需要“始终允许”；权限升级完成后 delegate 会再次调用。
        guard authorization == .authorizedAlways else { return }
        manager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        appLog.info("[Visit] 后台足迹已开启（访问监测 + 重大位置变化）")
    }

    private func requestAlwaysAuthorizationIfNeeded() {
        guard backgroundEnabled,
              authorization == .authorizedWhenInUse,
              !requestedAlwaysUpgrade else { return }
        requestedAlwaysUpgrade = true
        manager.requestAlwaysAuthorization()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        appLog.info("[Loc] 授权状态变更: \(manager.authorizationStatus.rawValue)")
        if isAuthorized {
            if appIsActive { manager.startUpdatingLocation() }
            if backgroundEnabled {
                requestAlwaysAuthorizationIfNeeded()
                startBackgroundMonitoring()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let isFirst = location == nil
        location = latest
        smoothedAltitude = altitudeSmoother.push(latest.altitude)
        altitudeHistory.append(latest.altitude)
        // 距离门限改为 none 后回调更频繁，高度历史封顶，避免长时间记录无界增长。
        if altitudeHistory.count > 200 {
            altitudeHistory.removeFirst(altitudeHistory.count - 200)
        }

        // 后台自动足迹：系统低功耗更新经交通策略稀疏化后才入库。
        if backgroundEnabled {
            captureBackgroundLocation(latest)
        }

        let lat = String(format: "%.5f", latest.coordinate.latitude)
        let lon = String(format: "%.5f", latest.coordinate.longitude)
        let altitude = smoothedAltitude
        appLog.info("[Loc] \(lat),\(lon) 海拔\(Int(altitude))m(平滑) 精度±\(Int(latest.horizontalAccuracy))m\(isFirst ? " [首个定位]" : "")")
    }

    private func captureBackgroundLocation(_ location: CLLocation) {
        // 重大位置变化服务首次可能返回旧缓存，超过 15 分钟不作为新足迹。
        guard abs(location.timestamp.timeIntervalSinceNow) <= 15 * 60 else { return }
        let sample = BackgroundLocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp.timeIntervalSince1970,
            speedMPS: location.speed,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy)
        let decision = BackgroundTrackPolicy.evaluate(previous: lastBackgroundSample, current: sample)
        guard decision.shouldRecord else { return }
        lastBackgroundSample = sample
        Self.saveLastBackgroundSample(sample)
        switch decision.mode {
        case .airborne: manager.activityType = .airborne
        case .highSpeedRail: manager.activityType = .otherNavigation
        case .local: manager.activityType = .other
        }
        postBackgroundFootprint(latitude: sample.latitude, longitude: sample.longitude,
                                timestamp: location.timestamp)
        appLog.info("[Background] \(decision.mode.rawValue) 关键点，距上点 \(Int(decision.distanceMeters))m")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog.error("[Loc] 定位失败: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard backgroundEnabled else { return }
        let timestamp: Date
        if visit.departureDate != .distantFuture {
            timestamp = visit.departureDate
        } else if visit.arrivalDate != .distantPast {
            timestamp = visit.arrivalDate
        } else {
            timestamp = Date()
        }
        postBackgroundFootprint(latitude: visit.coordinate.latitude,
                                longitude: visit.coordinate.longitude,
                                timestamp: timestamp)
        appLog.info("[Visit] 后台捕获足迹 \(String(format: "%.4f", visit.coordinate.latitude)),\(String(format: "%.4f", visit.coordinate.longitude))")
    }

    private func postBackgroundFootprint(latitude: Double, longitude: Double, timestamp: Date) {
        let draft = FootprintDraft(latitude: latitude, longitude: longitude,
                                   timestamp: timestamp, source: FootprintSource.gps.rawValue)
        NotificationCenter.default.post(name: .footprintsCaptured, object: draft)
    }

    private static let backgroundKeys = (
        lat: "bgLastLat", lon: "bgLastLon", time: "bgLastTime",
        speed: "bgLastSpeed", altitude: "bgLastAltitude", accuracy: "bgLastAccuracy")

    private static func loadLastBackgroundSample() -> BackgroundLocationSample? {
        let defaults = UserDefaults.standard
        guard let lat = defaults.object(forKey: backgroundKeys.lat) as? Double,
              let lon = defaults.object(forKey: backgroundKeys.lon) as? Double,
              let time = defaults.object(forKey: backgroundKeys.time) as? Double else { return nil }
        return BackgroundLocationSample(
            latitude: lat, longitude: lon, timestamp: time,
            speedMPS: defaults.double(forKey: backgroundKeys.speed),
            altitude: defaults.double(forKey: backgroundKeys.altitude),
            horizontalAccuracy: defaults.double(forKey: backgroundKeys.accuracy))
    }

    private static func saveLastBackgroundSample(_ sample: BackgroundLocationSample) {
        let defaults = UserDefaults.standard
        defaults.set(sample.latitude, forKey: backgroundKeys.lat)
        defaults.set(sample.longitude, forKey: backgroundKeys.lon)
        defaults.set(sample.timestamp, forKey: backgroundKeys.time)
        defaults.set(sample.speedMPS, forKey: backgroundKeys.speed)
        defaults.set(sample.altitude, forKey: backgroundKeys.altitude)
        defaults.set(sample.horizontalAccuracy, forKey: backgroundKeys.accuracy)
    }
}
