import XCTest

final class CSVImportIntegrityUITests: XCTestCase {
    private func launch(_ scenario: String, language: String = "zh-Hans") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_ISOLATED_REVIEW_STORE"] = "1"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_SKIP_HEALTH_RESTORE"] = "1"
        app.launchEnvironment["FP_TAB"] = "2"
        app.launchEnvironment["FP_LANGUAGE"] = language
        app.launchEnvironment["FP_CSV_MAPPING_TEST"] = scenario
        app.launch()
        let settings = app.buttons[language == "fr" ? "Réglages" : "设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        settings.tap()
        let importFile = app.buttons["import-csv"]
        XCTAssertTrue(importFile.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if importFile.isHittable { break }
            app.swipeUp()
        }
        importFile.tap()
        XCTAssertTrue(app.buttons["csv-import-submit"].waitForExistence(timeout: 5))
        return app
    }

    func testImportShowsInvalidRowsAndKeepsRevisitInsteadOfFiftyMeterDedupe() {
        let app = launch("mixed")
        let submit = app.buttons["csv-import-submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let summary = app.staticTexts["csv-import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(summary.label.contains("新增 2"), summary.label)
        XCTAssertTrue(summary.label.contains("重复 1"), summary.label)
        XCTAssertTrue(summary.label.contains("无效 1"), summary.label)
        XCTAssertTrue(app.staticTexts["数据第 3 行：时间缺失或无效"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CSV-import-complete-with-invalid-row"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if !submit.isHittable { app.swipeUp() }
        submit.tap()
        XCTAssertFalse(app.buttons["csv-import-submit"].exists)
    }

    func testMissingTimeDisablesImportAndNativePickerCanBeOpened() {
        let app = launch("missing-time")
        XCTAssertFalse(app.buttons["csv-import-submit"].isEnabled)
        XCTAssertTrue(app.staticTexts["请选择纬度、经度和时间列。缺失日期不会补成今天。"].exists)
        let time = app.descendants(matching: .any).matching(identifier: "csv-column-时间").firstMatch
        XCTAssertTrue(time.exists)
        time.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CSV-native-time-picker-open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["不使用"].exists || app.staticTexts["不使用"].exists)
    }
}
