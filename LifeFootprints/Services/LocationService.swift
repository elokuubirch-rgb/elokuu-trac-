import Foundation
import CoreLocation

enum BackgroundLocationRuntimeState {
    case disabled
    case permissionRequired
    case foreground
    case backgroundHighAccuracy
    case backgroundLowPower
    case recovering
}

/// Core Location 生命周期适配器。显示、轨迹质量和采样策略均委托给独立领域对象。
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let configuration = LocationFilterConfiguration()
    private var pipeline = CoreLocationPipeline()
    private var recorder = AutomaticTrajectoryRecorder()
    private var backgroundPolicy = BackgroundTrackingPolicy()
    private var altitudeSmoother = AltitudeSmoother(windowSize: 5)
    private var standardUpdatesActive = false
    private var appIsActive = true
    private var requestedAlwaysUpgrade = false
    private var backgroundAuthorizationRequestInProgress = false
    private var pendingAuthorizationCompletion: ((Bool) -> Void)?
    private var precisionBurstStopTask: Task<Void, Never>?

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    /// 兼容现有地图调用；该值现在只来自 DisplayLocationFilter，而非 raw GPS。
    private(set) var location: CLLocation?
    private(set) var smoothedAltitude: Double = 0
    private(set) var altitudeHistory: [Double] = []
    private(set) var trackingState: BackgroundTrackingState = .lowPower
    private(set) var backgroundEnabled = UserDefaults.standard.bool(forKey: "bgFootprints")
    private(set) var lastLocationCallbackAt: Date?
    private(set) var systemLocationPaused = false

    var isAuthorized: Bool {
        authorization == .authorizedAlways && backgroundEnabled
    }
    var hasFullAccuracy: Bool { accuracyAuthorization == .fullAccuracy }
    var isBackgroundLocationEnabled: Bool {
        authorization == .authorizedAlways && backgroundEnabled
    }
    var backgroundRuntimeState: BackgroundLocationRuntimeState {
        guard backgroundEnabled else { return .disabled }
        guard authorization == .authorizedAlways else { return .permissionRequired }
        if appIsActive { return .foreground }
        if systemLocationPaused || !standardUpdatesActive { return .recovering }
        switch trackingState {
        case .moving, .confirmingMovement: return .backgroundHighAccuracy
        case .stationary, .lowPower: return .backgroundLowPower
        }
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false
        configureForegroundDisplay()
        // 旧版曾持久化未经统一质量门处理的 raw last sample；升级后明确清除。
        for key in ["bgLastLat", "bgLastLon", "bgLastTime", "bgLastSpeed",
                    "bgLastAltitude", "bgLastAccuracy"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FP_SKIP_LOCATION"] == "1" {
            appLog.info("[Loc] 自动化测试跳过定位权限请求")
            return
        }
        #endif
        updateAuthorizationDiagnostics()
        if appIsActive, isBackgroundLocationEnabled {
            configureForegroundDisplay()
            startStandardUpdates()
        } else {
            stopStandardUpdates()
        }
        if isBackgroundLocationEnabled { startBackgroundMonitoring() }
        appLog.info("[Loc] start：授权=\(self.authorization.rawValue)，精确定位=\(self.hasFullAccuracy)")
    }

    func restoreBackgroundMonitoring() {
        backgroundEnabled = UserDefaults.standard.bool(forKey: "bgFootprints")
        updateAuthorizationDiagnostics()
        guard isBackgroundLocationEnabled else {
            if backgroundEnabled {
                backgroundEnabled = false
                UserDefaults.standard.set(false, forKey: "bgFootprints")
            }
            return
        }
        startBackgroundMonitoring()
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            configureForegroundDisplay()
            if isBackgroundLocationEnabled { startStandardUpdates() }
            else { stopStandardUpdates() }
        } else {
            flushCleanTrack(reason: "lifecycle")
            if !backgroundEnabled { stopStandardUpdates() }
            else {
                apply(.init(state: .lowPower, wantsStandardUpdates: true,
                            desiredAccuracy: kCLLocationAccuracyHundredMeters,
                            distanceFilter: 100))
            }
        }
        if isBackgroundLocationEnabled { startBackgroundMonitoring() }
    }

    private func configureForegroundDisplay() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 8
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
    }

    func setBackgroundFootprints(_ enabled: Bool) {
        if enabled {
            requestBackgroundLocationAuthorization(completion: nil)
        } else {
            disableBackgroundLocation()
        }
    }

    /// 产品只有“后台位置开启/关闭”两态。When In Use 与 Allow Once 都按关闭处理。
    func requestBackgroundLocationAuthorization(completion: ((Bool) -> Void)?) {
        updateAuthorizationDiagnostics()
        backgroundAuthorizationRequestInProgress = true
        pendingAuthorizationCompletion = completion
        switch authorization {
        case .authorizedAlways:
            enableBackgroundLocation()
            finishAuthorizationRequest(enabled: true)
        case .notDetermined:
            backgroundEnabled = false
            UserDefaults.standard.set(false, forKey: "bgFootprints")
            requestedAlwaysUpgrade = false
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            backgroundEnabled = false
            UserDefaults.standard.set(false, forKey: "bgFootprints")
            // 每次明确点击“开启后台位置”都允许重新尝试系统升级。
            requestedAlwaysUpgrade = false
            requestAlwaysAuthorizationIfNeeded()
            // “允许一次”会让 Always 请求被系统忽略；“保持仅使用期间”也不产生
            // 新状态回调。因此发起升级后即结束本次交互，最终是否开启只看 Always。
            finishAuthorizationRequest(enabled: false)
        case .denied, .restricted:
            disableBackgroundLocation()
            finishAuthorizationRequest(enabled: false)
        @unknown default:
            disableBackgroundLocation()
            finishAuthorizationRequest(enabled: false)
        }
    }

    func disableBackgroundLocation() {
        backgroundEnabled = false
        UserDefaults.standard.set(false, forKey: "bgFootprints")
        requestedAlwaysUpgrade = false
        backgroundAuthorizationRequestInProgress = false
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        stopStandardUpdates()
        flushCleanTrack(reason: "tracking-disabled", resetTrackState: true)
        appLog.info("[Loc] 后台位置已关闭")
    }

    private func enableBackgroundLocation() {
        backgroundEnabled = true
        UserDefaults.standard.set(true, forKey: "bgFootprints")
        requestedAlwaysUpgrade = false
        if appIsActive {
            configureForegroundDisplay()
            startStandardUpdates()
        }
        startBackgroundMonitoring()
        appLog.info("[Loc] 后台位置已开启")
    }

    private func finishAuthorizationRequest(enabled: Bool) {
        backgroundAuthorizationRequestInProgress = false
        let completion = pendingAuthorizationCompletion
        pendingAuthorizationCompletion = nil
        completion?(enabled)
    }

    func prepareForLocalDataReset() async {
        // 清空数据不是普通“关闭记录”：这里禁止 flush，避免删除后被在途批次写回。
        backgroundEnabled = false
        UserDefaults.standard.set(false, forKey: "bgFootprints")
        requestedAlwaysUpgrade = false
        backgroundAuthorizationRequestInProgress = false
        pendingAuthorizationCompletion = nil
        precisionBurstStopTask?.cancel()
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        if !appIsActive { stopStandardUpdates() }
        await TrackPointBatchWriter.shared.discardPendingAndWait()
        pipeline.reset()
        recorder.reset()
        location = nil
        altitudeHistory.removeAll()
    }

    private func startBackgroundMonitoring() {
        guard authorization == .authorizedAlways else { return }
        manager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        appLog.info("[Loc] 后台低功耗唤醒已开启（visit + significant-change）")
    }

    private func requestAlwaysAuthorizationIfNeeded() {
        guard authorization == .authorizedWhenInUse,
              !requestedAlwaysUpgrade else { return }
        requestedAlwaysUpgrade = true
        manager.requestAlwaysAuthorization()
    }

    private func startStandardUpdates() {
        guard !standardUpdatesActive else { return }
        manager.startUpdatingLocation()
        standardUpdatesActive = true
    }

    private func stopStandardUpdates() {
        guard standardUpdatesActive else { return }
        manager.stopUpdatingLocation()
        standardUpdatesActive = false
        manager.allowsBackgroundLocationUpdates = false
    }

    private func apply(_ directive: BackgroundSamplingDirective) {
        trackingState = directive.state
        manager.desiredAccuracy = directive.desiredAccuracy
        manager.distanceFilter = directive.distanceFilter
        manager.activityType = directive.state == .moving ? .fitness : .other
        let backgroundPrecision = !appIsActive && backgroundEnabled
            && authorization == .authorizedAlways && directive.wantsStandardUpdates
        manager.pausesLocationUpdatesAutomatically = !backgroundPrecision
        manager.allowsBackgroundLocationUpdates = backgroundPrecision
        if directive.wantsStandardUpdates { startStandardUpdates() }
        else if !appIsActive { stopStandardUpdates() }
        if directive.state == .confirmingMovement, !appIsActive {
            precisionBurstStopTask?.cancel()
            precisionBurstStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, let self,
                      !self.appIsActive, self.trackingState == .confirmingMovement else { return }
                self.apply(.init(state: .lowPower, wantsStandardUpdates: true,
                                 desiredAccuracy: kCLLocationAccuracyHundredMeters,
                                 distanceFilter: 100))
            }
        } else if directive.state != .confirmingMovement {
            precisionBurstStopTask?.cancel()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorizationDiagnostics()
        appLog.info("[Loc] 授权状态=\(self.authorization.rawValue)，精度授权=\(String(describing: self.accuracyAuthorization))")
        switch authorization {
        case .authorizedAlways:
            if pendingAuthorizationCompletion != nil || requestedAlwaysUpgrade {
                enableBackgroundLocation()
            } else if backgroundEnabled {
                startBackgroundMonitoring()
                if appIsActive { startStandardUpdates() }
            }
            finishAuthorizationRequest(enabled: isBackgroundLocationEnabled)
        case .authorizedWhenInUse:
            backgroundEnabled = false
            UserDefaults.standard.set(false, forKey: "bgFootprints")
            stopStandardUpdates()
            if backgroundAuthorizationRequestInProgress {
                requestAlwaysAuthorizationIfNeeded()
                finishAuthorizationRequest(enabled: false)
            }
        case .denied, .restricted:
            disableBackgroundLocation()
            finishAuthorizationRequest(enabled: false)
        case .notDetermined:
            break
        @unknown default:
            disableBackgroundLocation()
            finishAuthorizationRequest(enabled: false)
        }
    }

    private func updateAuthorizationDiagnostics() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocationCallbackAt = Date()
        systemLocationPaused = false
        // 同批回调可能包含缓存点；按时间顺序逐个进入质量门，不能只拿最后一个。
        for coreLocation in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let source: LocationSampleSource = standardUpdatesActive
                ? .standard : .significantChange
            process(RawLocationSample(coreLocation, source: source),
                    wantsDisplay: appIsActive)
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard backgroundEnabled else { return }
        lastLocationCallbackAt = Date()
        let timestamp: Date
        if visit.departureDate != .distantFuture { timestamp = visit.departureDate }
        else if visit.arrivalDate != .distantPast { timestamp = visit.arrivalDate }
        else { timestamp = Date() }
        let sample = RawLocationSample(
            latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
            timestamp: timestamp, horizontalAccuracy: visit.horizontalAccuracy, source: .visit)
        process(sample, wantsDisplay: false)
    }

    private func process(_ sample: RawLocationSample, wantsDisplay: Bool) {
        let output = pipeline.process(sample, wantsDisplay: wantsDisplay,
                                      wantsTrack: backgroundEnabled,
                                      configuration: configuration)
        if let display = output.displayLocation {
            let isFirst = location == nil
            location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: display.latitude,
                                                    longitude: display.longitude),
                altitude: display.altitude, horizontalAccuracy: display.horizontalAccuracy,
                verticalAccuracy: -1, course: -1, speed: -1,
                timestamp: display.timestamp)
            smoothedAltitude = altitudeSmoother.push(display.altitude)
            altitudeHistory.append(display.altitude)
            if altitudeHistory.count > 200 {
                altitudeHistory.removeFirst(altitudeHistory.count - 200)
            }
            appLog.info("[Loc.Display] ±\(Int(display.horizontalAccuracy))m\(isFirst ? " [首个]" : "")")
        }
        enqueueFinalized(output.finalizedTrackPoints)
        if let reason = output.segmentBreakReason {
            if reason == .sessionBoundary || reason == .locationRestart {
                TrackPointBatchWriter.shared.flush(reason: reason.rawValue)
            }
            recorder.beginNewSegment(reason)
        }
        if backgroundEnabled {
            let directive = backgroundPolicy.observe(
                source: sample.source, motion: output.motion?.state,
                now: sample.timestamp, appIsActive: appIsActive)
            apply(directive)
        }
        #if DEBUG
        appLog.debug("[Location.Raw] t=\(sample.timestamp.timeIntervalSince1970) lat=\(sample.latitude) lon=\(sample.longitude) acc=\(sample.horizontalAccuracy)m systemSpeed=\(sample.speed)m/s source=\(sample.source.rawValue)")
        if let reason = output.displayRejection {
            appLog.debug("[Loc.Display] reject=\(reason.rawValue)")
        } else if let decision = output.displayDecision {
            appLog.debug("[Loc.Display] decision=\(decision.rawValue)")
        }
        if let reason = output.trackQualityRejection {
            appLog.debug("[Loc.Track] qualityReject=\(reason.rawValue)")
        }
        if let decision = output.realtimeDecision {
            switch decision {
            case .reject(let reason):
                appLog.debug("[Loc.Realtime] reject=\(reason.rawValue) motion=\(output.motion?.state.rawValue ?? "none")")
            case .candidate(let point):
                appLog.debug("[Loc.Realtime] candidate=\(point.id) derivedSpeed=\(point.derivedSpeed)m/s acceleration=\(point.acceleration.map(String.init(describing:)) ?? "nil") motion=\(point.motionState.rawValue) confidence=\(point.realtimeConfidence)")
            case .newSegmentCandidate(let point, let reason):
                appLog.debug("[Loc.Realtime] newSegmentCandidate=\(reason.rawValue) id=\(point.id) derivedSpeed=\(point.derivedSpeed)m/s")
            }
        }
        if let correction = output.postFilterOutput {
            let removed = correction.removedCandidates
                .map { "\($0.candidateID):\($0.reason.rawValue)" }.joined(separator: ",")
            appLog.debug("[Loc.Post] finalized=\(correction.finalizedPoints.count) removed=[\(removed)]")
        }
        if !output.finalizedTrackPoints.isEmpty {
            appLog.debug("[Loc.Final] persistedCandidates=\(output.finalizedTrackPoints.map(\.candidateID))")
        }
        let metrics = pipeline.metrics
        if metrics.rawCount.isMultiple(of: 50) {
            appLog.info("[Loc.Metrics] raw=\(metrics.rawSampleCount) qualityReject=\(metrics.qualityRejectedCount) displayHeld=\(metrics.displayHeldCount) realtimeReject=\(metrics.realtimeRejectedCount) candidates=\(metrics.candidateCount) postTri=\(metrics.postTriSpikeRemovedCount) postQuad=\(metrics.postQuadSpikeRemovedCount) postIsolated=\(metrics.postIsolatedRemovedCount) postRedundant=\(metrics.postRedundantRemovedCount) finalized=\(metrics.finalizedCount) segments=\(metrics.newSegmentCount) stationaryTransitions=\(metrics.stationaryTransitionCount) movingTransitions=\(metrics.movingTransitionCount)")
        }
        #endif
    }

    private func enqueueFinalized(_ points: [FinalizedTrackPoint]) {
        for point in points {
            let draft = recorder.draft(for: point)
            TrackPointBatchWriter.shared.append(draft)
            #if DEBUG
            appLog.debug("[Location.Segment] session=\(draft.sessionID ?? "nil") segment=\(draft.segmentID ?? "nil") candidate=\(point.candidateID)")
            #endif
        }
    }

    private func flushCleanTrack(reason: String, resetTrackState: Bool = false) {
        enqueueFinalized(pipeline.flushTrack())
        TrackPointBatchWriter.shared.flush(reason: reason)
        if resetTrackState {
            pipeline.resetTrackState()
            recorder.reset()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        flushCleanTrack(reason: "location-restart")
        pipeline.resetTrackState()
        recorder.markLocationRestart()
        appLog.error("[Loc] 定位失败: \(error.localizedDescription)")
        if let locationError = error as? CLError, locationError.code == .denied { return }
        guard !appIsActive, isBackgroundLocationEnabled else { return }
        standardUpdatesActive = false
        apply(.init(state: .lowPower, wantsStandardUpdates: true,
                    desiredAccuracy: kCLLocationAccuracyHundredMeters,
                    distanceFilter: 100))
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        systemLocationPaused = true
        appLog.warning("[Loc] 系统暂停定位，尝试恢复低功耗后台采样")
        guard !appIsActive, isBackgroundLocationEnabled else { return }
        standardUpdatesActive = false
        apply(.init(state: .lowPower, wantsStandardUpdates: true,
                    desiredAccuracy: kCLLocationAccuracyHundredMeters,
                    distanceFilter: 100))
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        systemLocationPaused = false
        appLog.info("[Loc] 系统已恢复定位")
    }
}
