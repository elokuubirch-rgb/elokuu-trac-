import XCTest

final class PerformanceAuditUITests: XCTestCase {
    private var rows: [String] = ["scenario,iteration,transition,milliseconds"]

    func testTwentyCycleNavigationAudit() throws {
        guard ProcessInfo.processInfo.environment["FP_RUN_PERF_AUDIT"] == "1" else {
            throw XCTSkip("仅在显式性能审计时运行")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_PERF_DIAGNOSTICS"] = "1"
        app.launchEnvironment["FP_TAB"] = "0"
        app.launchEnvironment["FP_LANGUAGE"] = "zh-Hans"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launch()

        let mapTab = app.buttons["地图"]
        let statsTab = app.buttons["统计"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 12))
        XCTAssertTrue(statsTab.waitForExistence(timeout: 4))

        for iteration in 1...20 {
            transition("map_stats_map", iteration, "Map->Stats") {
                statsTab.tap()
                XCTAssertTrue(self.waitUntilSelected(statsTab))
                XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 4))
            }
            transition("map_stats_map", iteration, "Stats->Map") {
                mapTab.tap()
                XCTAssertTrue(self.waitUntilSelected(mapTab))
            }
        }

        for iteration in 1...20 {
            let roundTripStarted = CFAbsoluteTimeGetCurrent()
            transition("map_settings_map", iteration, "Map->Stats") {
                statsTab.tap()
                XCTAssertTrue(self.waitUntilSelected(statsTab))
            }
            transition("map_settings_map", iteration, "Stats->Settings") {
                app.buttons["设置"].tap()
                XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
            }
            transition("map_settings_map", iteration, "Settings->Stats") {
                app.navigationBars["设置"].buttons.firstMatch.tap()
                XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 4))
            }
            transition("map_settings_map", iteration, "Stats->Map") {
                mapTab.tap()
                XCTAssertTrue(self.waitUntilSelected(mapTab))
            }
            append(scenario: "map_settings_map", iteration: iteration,
                   transition: "Map->Settings->Map.total",
                   milliseconds: (CFAbsoluteTimeGetCurrent() - roundTripStarted) * 1_000)
        }

        statsTab.tap()
        XCTAssertTrue(waitUntilSelected(statsTab))
        for iteration in 1...20 {
            transition("stats_settings_stats", iteration, "Stats->Settings") {
                app.buttons["设置"].tap()
                XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
            }
            transition("stats_settings_stats", iteration, "Settings->Stats") {
                app.navigationBars["设置"].buttons.firstMatch.tap()
                XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 4))
            }
        }

        // 等待 App 内诊断聚合器完成原子写入。
        Thread.sleep(forTimeInterval: 2.5)
        let attachment = XCTAttachment(
            data: rows.joined(separator: "\n").data(using: .utf8)!,
            uniformTypeIdentifier: "public.comma-separated-values")
        attachment.name = "navigation-transition-times.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMapVisualRegressionReference() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_PERF_VISUAL_SEED"] = "1"
        app.launchEnvironment["FP_TAB"] = "0"
        app.launchEnvironment["FP_LANGUAGE"] = "zh-Hans"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launch()
        allowFullPhotoAccessIfRequested(in: app)

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        denyLocationAccessIfRequested(in: app)
        Thread.sleep(forTimeInterval: 5)
        attachScreenshot(app, name: "map-reference-fit")

        map.pinch(withScale: 2.5, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(app, name: "map-reference-near")

        map.pinch(withScale: 0.32, velocity: -1)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(app, name: "map-reference-far")
    }

    func testMapSurvivesBackgroundSceneTransition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_PERF_VISUAL_SEED"] = "1"
        app.launchEnvironment["FP_TAB"] = "0"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launch()

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 5)

        XCUIDevice.shared.press(.home)
        // 原真机报告的 scene-update watchdog allowance 为 10 秒。
        Thread.sleep(forTimeInterval: 12)
        app.activate()

        XCTAssertTrue(map.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 只由显式真机审计命令运行；不注入夹具、不清库、不改用户偏好。
    /// 把截图、稳态页面切换和原 10 秒 watchdog 场景放在同一个受 XCUITest
    /// usage assertion 保护的会话里，避免 devicectl 裸启动结束被误判为闪退。
    func testRealDataFinalPerformanceAndVisualAudit() throws {
        guard ProcessInfo.processInfo.environment["FP_RUN_REAL_DATA_AUDIT"] == "1" else {
            throw XCTSkip("仅在显式真机真实数据审计时运行")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_PRESERVE_USER_PREFERENCES"] = "1"
        app.launchEnvironment["FP_PERF_DIAGNOSTICS"] = "1"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_TAB"] = "0"
        app.launch()
        allowFullPhotoAccessIfRequested(in: app)

        let map = app.maps.firstMatch
        let mapTab = app.buttons["地图"]
        let statsTab = app.buttons["统计"]
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        XCTAssertTrue(mapTab.waitForExistence(timeout: 4))
        XCTAssertTrue(statsTab.waitForExistence(timeout: 4))
        // 等待真实路线 overlay 与照片索引进入稳态。
        let settleSeconds = ProcessInfo.processInfo.environment[
            "FP_REAL_DATA_AUDIT_SETTLE_SECONDS"
        ].flatMap(Double.init) ?? 20
        Thread.sleep(forTimeInterval: settleSeconds)

        attachScreenshot(app, name: "real-data-map-fit")
        map.pinch(withScale: 2.5, velocity: 1)
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(app, name: "real-data-map-near")
        map.pinch(withScale: 0.32, velocity: -1)
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(app, name: "real-data-map-far")

        for _ in 1...20 {
            statsTab.tap()
            XCTAssertTrue(waitUntilSelected(statsTab))
            mapTab.tap()
            XCTAssertTrue(waitUntilSelected(mapTab))
        }

        for iteration in 1...10 {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 12)
            app.activate()
            XCTAssertTrue(
                map.waitForExistence(timeout: 20),
                "第 \(iteration) 次后台恢复后地图未出现")
            XCTAssertEqual(
                app.state, .runningForeground,
                "第 \(iteration) 次后台恢复后 App 未回到前台")
        }
        attachScreenshot(app, name: "real-data-map-after-background")
        Thread.sleep(forTimeInterval: 2)
    }

    func testRealDataPersistentCacheAudit() throws {
        guard ProcessInfo.processInfo.environment["FP_RUN_CACHE_AUDIT"] == "1" else {
            throw XCTSkip("仅在显式轨迹缓存审计时运行")
        }
        continueAfterFailure = false
        let settleSeconds = ProcessInfo.processInfo.environment["FP_CACHE_AUDIT_SETTLE_SECONDS"]
            .flatMap(Double.init) ?? 75
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_PRESERVE_USER_PREFERENCES"] = "1"
        app.launchEnvironment["FP_PERF_DIAGNOSTICS"] = "1"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_TAB"] = "0"
        app.launch()
        allowFullPhotoAccessIfRequested(in: app)

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: settleSeconds)
        XCTAssertTrue(map.exists)
    }

    /// xctrace 设备注册异常时的官方 XCTest 备援测量。只在显式命令下运行，
    /// 使用真机现有数据和 Release 产品行为，不注入夹具、不修改用户偏好。
    func testReleaseRealDataMemoryMetric() throws {
        guard ProcessInfo.processInfo.environment["FP_RUN_RELEASE_MEMORY_AUDIT"] == "1" else {
            throw XCTSkip("仅在显式 Release 真机内存审计时运行")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        let settleSeconds = ProcessInfo.processInfo.environment[
            "FP_RELEASE_MEMORY_SETTLE_SECONDS"
        ].flatMap(Double.init) ?? 75
        let options = XCTMeasureOptions()
        options.iterationCount = 1

        app.terminate()
        measure(
            metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)],
            options: options
        ) {
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
            Thread.sleep(forTimeInterval: settleSeconds)
            XCTAssertEqual(app.state, .runningForeground)
            app.terminate()
        }
    }

    private func transition(_ scenario: String, _ iteration: Int, _ name: String,
                            operation: () -> Void) {
        let started = CFAbsoluteTimeGetCurrent()
        operation()
        append(scenario: scenario, iteration: iteration, transition: name,
               milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1_000)
    }

    private func append(scenario: String, iteration: Int, transition: String,
                        milliseconds: Double) {
        rows.append("\(scenario),\(iteration),\(transition),\(String(format: "%.3f", milliseconds))")
    }

    private func waitUntilSelected(_ button: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", "已选择")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func allowFullPhotoAccessIfRequested(in app: XCUIApplication) {
        let labels = ["允许完全访问", "Allow Full Access"]
        for label in labels {
            let appButton = app.buttons[label]
            if appButton.waitForExistence(timeout: 2) {
                appButton.tap()
                return
            }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let systemButton = springboard.buttons[label]
            if systemButton.waitForExistence(timeout: 1) {
                systemButton.tap()
                return
            }
        }
    }

    private func denyLocationAccessIfRequested(in app: XCUIApplication) {
        let labels = ["不允许", "Don’t Allow", "Don't Allow"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in labels {
            let systemButton = springboard.buttons[label]
            if systemButton.waitForExistence(timeout: 1) {
                systemButton.tap()
                return
            }
            let appButton = app.buttons[label]
            if appButton.waitForExistence(timeout: 1) {
                appButton.tap()
                return
            }
        }
    }
}
