import XCTest

final class SettingsSmokeUITests: XCTestCase {
    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 6
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    func testSettingsUsesConfigurationOnlyInformationArchitecture() {
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_TAB"] = "2"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_LANGUAGE"] = "zh-Hans"
        app.launch()

        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 8))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.switches["health-auto-sync-toggle"].exists)
        XCTAssertTrue(app.staticTexts["自动记录"].exists)
        XCTAssertTrue(app.staticTexts["回顾"].exists)
        XCTAssertTrue(app.staticTexts["地图"].exists)
        XCTAssertFalse(app.staticTexts["数据来源"].exists)
        XCTAssertFalse(app.buttons["health-sync-now"].exists)
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["数据与备份"], in: app))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["缓存"], in: app))
        XCTAssertTrue(app.buttons["clear-trajectory-cache"].exists)
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["通用"], in: app))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["数据管理"], in: app))
        XCTAssertTrue(scrollUntilVisible(app.buttons["reset-all-local-data"], in: app))
    }
}
