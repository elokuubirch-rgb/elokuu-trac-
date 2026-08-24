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

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 5)
        attachScreenshot(app, name: "map-reference-fit")

        map.pinch(withScale: 2.5, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(app, name: "map-reference-near")

        map.pinch(withScale: 0.32, velocity: -1)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(app, name: "map-reference-far")
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
}
