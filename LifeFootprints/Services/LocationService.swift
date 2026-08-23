import Foundation
import CoreLocation

extension Notification.Name {
    /// 低功耗后台捕获到新足迹（object = FootprintDraft）
    static let footprintsCaptured = Notification.Name("footprintsCaptured")
}

/// 实时定位服务：GPS 位置、海拔、精度、时间戳 +
/// 主动轨迹记录 + 低功耗后台足迹（访问监测 + 重大位置变化）。
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()

    // MARK: - 状态

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    private(set) var smoothedAltitude: Double = 0
    private(set) var altitudeHistory: [Double] = []

    /// 主动轨迹记录
    private(set) var isRecording = false
    private(set) var recordingStart: Date?
    private(set) var recordingDrafts: [FootprintDraft] = []

    // MARK: - 轨迹记录诊断统计（每次 startRecording 重置）
    /// 收到的原始 GPS 回调数（每次 didUpdateLocations 的最新点计 1）
    private(set) var receivedLocationCount = 0
    /// 通过过滤流水线、进入草稿的点数
    private(set) var acceptedLocationCount = 0
    /// 被过滤流水线拒绝的点数
    private(set) var rejectedLocationCount = 0
    /// 实际写入数据库的点数（由调用方 stop 后回填）
    private(set) var storedLocationCount = 0
    /// 按 summaryCategory 归类的拒绝计数（Poor accuracy / Stationary / Duplicate / Impossible jump / Other）
    private(set) var rejectionCounts: [String: Int] = [:]
    /// 最近若干条被拒绝点明细（诊断用，封顶避免长期记录占用内存）
    private(set) var rejectionLog: [TrackRejectionRecord] = []
    private var recordingFilter = TrackPointFilter()
    private let rejectionLogLimit = 500

    /// 低功耗后台足迹开关（访问监测 + 重大位置变化），启动时从持久设置恢复。
    private(set) var backgroundEnabled = UserDefaults.standard.bool(forKey: "bgFootprints")
    private var appIsActive = true
    private var lastBackgroundSample: BackgroundLocationSample?
    private var requestedAlwaysUpgrade = false

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var recordingDuration: TimeInterval {
        recordingStart.map { Date().timeIntervalSince($0) } ?? 0
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
            if !isRecording { configurePassiveLocation() }
            if manager.authorizationStatus != .denied { manager.startUpdatingLocation() }
        } else if !isRecording {
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

    // MARK: - 主动轨迹记录

    func startRecording() {
        isRecording = true
        recordingStart = Date()
        recordingDrafts = []
        resetRecordingStats()

        let status = manager.authorizationStatus
        authorization = status

        manager.desiredAccuracy = kCLLocationAccuracyBest
        // 不再用系统 distanceFilter 预先砍点：把原始回调交给过滤流水线，
        // 由 距离+时间+速度+转向+精度 联合决定，保证步行 3–8m 密度与时间兜底。
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        // 锁屏/后台期间必须保持连续定位，绝不自动暂停。
        manager.pausesLocationUpdatesAutomatically = false
        // 标准 GPS 后台运行需要 Always；记录期间无论当前状态都先打开，权限到位即生效。
        manager.allowsBackgroundLocationUpdates = (status == .authorizedAlways
                                                    || status == .authorizedWhenInUse)
        if status == .authorizedWhenInUse {
            // 只有「始终允许」才能在锁屏后继续回调；请求升级是 16 点问题的关键修复。
            manager.requestAlwaysAuthorization()
        } else if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        appLog.info("[Rec] 开始轨迹记录（后台定位=\(status == .authorizedAlways)，distanceFilter=none）")
    }

    private func resetRecordingStats() {
        receivedLocationCount = 0
        acceptedLocationCount = 0
        rejectedLocationCount = 0
        storedLocationCount = 0
        rejectionCounts = [:]
        rejectionLog = []
        recordingFilter.reset()
    }

    /// 停止记录，返回本次轨迹草稿（供调用方融合入库）
    func stopRecording() -> [FootprintDraft] {
        let drafts = recordingDrafts
        isRecording = false
        recordingStart = nil
        recordingDrafts = []
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        if appIsActive {
            configurePassiveLocation()
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        appLog.info("[Rec] 结束记录：\(drafts.count) 点")
        let summary = diagnosticSummary()
        appLog.info("[Rec] 诊断摘要：\n\(summary)")
        return drafts
    }

    /// 记录完成后由入库方回填实际写库数量。
    func noteStoredCount(_ count: Int) {
        storedLocationCount += count
    }

    /// 人类可读的诊断摘要（与需求中的示例格式一致）。
    func diagnosticSummary() -> String {
        var lines: [String] = []
        lines.append("Received GPS locations: \(receivedLocationCount)")
        lines.append("Accepted: \(acceptedLocationCount)")
        lines.append("Rejected: \(rejectedLocationCount)")
        lines.append("Stored: \(storedLocationCount)")
        lines.append("")
        lines.append("Rejected:")
        let order = ["Poor accuracy", "Stationary", "Duplicate", "Impossible jump", "Other"]
        for key in order {
            lines.append("\(key): \(rejectionCounts[key] ?? 0)")
        }
        return lines.joined(separator: "\n")
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
            if appIsActive || isRecording { manager.startUpdatingLocation() }
            if isRecording {
                // 记录期间用户升级到 Always 后，立即开启后台连续定位（锁屏继续记录）。
                manager.allowsBackgroundLocationUpdates = true
                manager.pausesLocationUpdatesAutomatically = false
            }
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
        if backgroundEnabled, !isRecording {
            captureBackgroundLocation(latest)
        }

        // 主动轨迹记录：完整过滤流水线（距离+时间+速度+转向+精度）+ 统计
        if isRecording {
            recordLocation(latest)
        }

        let lat = String(format: "%.5f", latest.coordinate.latitude)
        let lon = String(format: "%.5f", latest.coordinate.longitude)
        let altitude = smoothedAltitude
        appLog.info("[Loc] \(lat),\(lon) 海拔\(Int(altitude))m(平滑) 精度±\(Int(latest.horizontalAccuracy))m\(isFirst ? " [首个定位]" : "")")
    }

    /// 主动轨迹记录：把一个原始点送入过滤流水线，更新统计并把通过的点转成草稿。
    private func recordLocation(_ latest: CLLocation) {
        receivedLocationCount += 1
        let sample = TrackSample(latitude: latest.coordinate.latitude,
                                 longitude: latest.coordinate.longitude,
                                 timestamp: latest.timestamp.timeIntervalSince1970,
                                 speedMPS: latest.speed,
                                 course: latest.course,
                                 horizontalAccuracy: latest.horizontalAccuracy)
        let decision = recordingFilter.evaluate(sample)

        if decision.accept {
            acceptedLocationCount += 1
            recordingDrafts.append(FootprintDraft(latitude: sample.latitude,
                                                  longitude: sample.longitude,
                                                  timestamp: latest.timestamp,
                                                  source: FootprintSource.gps.rawValue))
        } else {
            rejectedLocationCount += 1
            let reason = decision.reason ?? .other
            rejectionCounts[reason.summaryCategory, default: 0] += 1
            if rejectionLog.count < rejectionLogLimit {
                rejectionLog.append(TrackRejectionRecord(
                    reason: reason,
                    timestamp: sample.timestamp,
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    horizontalAccuracy: sample.horizontalAccuracy,
                    distanceToLastMeters: decision.distanceMeters))
            }
        }

        // 周期性诊断日志（每 60 个原始点输出一次，避免刷屏）
        if receivedLocationCount % 60 == 0 {
            let summary = diagnosticSummary()
            appLog.info("[Rec] 进行中摘要：\n\(summary)")
        }
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
