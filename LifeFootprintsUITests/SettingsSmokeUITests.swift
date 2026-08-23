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

    func testHealthSyncControlsAreReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_TAB"] = "2"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 8))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.switches["health-auto-sync-toggle"].exists)
        XCTAssertTrue(scrollUntilVisible(app.buttons["health-sync-now"], in: app))
    }
}
