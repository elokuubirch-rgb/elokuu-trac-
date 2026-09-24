import XCTest

final class ReviewDeletionFlowUITests: XCTestCase {
    func testReviewPhotoLocationShowsDedicatedMapMarkerWithoutZoom() {
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_ISOLATED_REVIEW_STORE"] = "1"
        app.launchEnvironment["FP_TAB"] = "1"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_SKIP_HEALTH_RESTORE"] = "1"
        app.launchEnvironment["FP_SEED_PHOTOS"] = "1"
        app.launchEnvironment["FP_AUTO_REVIEW_GROUP"] = "1"
        app.launch()

        let location = app.buttons["review-current-photo"]
        XCTAssertTrue(location.waitForExistence(timeout: 15))
        location.tap()
        XCTAssertTrue(app.buttons["回到回顾"].waitForExistence(timeout: 8))
        let selectedMarker = app.descendants(matching: .any)["map-selected-review-photo"]
        XCTAssertTrue(selectedMarker.waitForExistence(timeout: 8),
                      "不手动缩放也应看到原始位置的照片标记")
        selectedMarker.tap()
        XCTAssertTrue(app.otherElements["review-progress"].waitForExistence(timeout: 8),
                      "点击专属标记应直接查看这张照片")
    }

    func testConfirmedDeletionSkipsCompletionAndStartsNextGroupAtFirstPhoto() {
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_TEST"] = "1"
        app.launchEnvironment["FP_ISOLATED_REVIEW_STORE"] = "1"
        app.launchEnvironment["FP_TAB"] = "1"
        app.launchEnvironment["FP_SKIP_LOCATION"] = "1"
        app.launchEnvironment["FP_SKIP_HEALTH_RESTORE"] = "1"
        app.launchEnvironment["FP_SEED_PHOTOS"] = "1"
        app.launchEnvironment["FP_AUTO_REVIEW_GROUP"] = "1"
        app.launchEnvironment["FP_REVIEW_DELETE_COUNT"] = "1"
        app.launchEnvironment["FP_REVIEW_SIMULATE_DELETE_SUCCESS"] = "1"
        app.launch()

        let confirmDelete = app.buttons["确认删除"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 12))

        let progress = app.otherElements["review-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        let oldProgress = progress.value as? String ?? ""
        let oldProgressParts = oldProgress.split(separator: "/").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(oldProgressParts.count, 2)
        XCTAssertEqual(oldProgressParts.first, oldProgressParts.last,
                       "测试必须从旧组最后一张开始，不能再从 index=0 制造假阳性")

        let currentPhoto = app.buttons["review-current-photo"]
        XCTAssertTrue(currentPhoto.waitForExistence(timeout: 4))
        let oldPhotoID = currentPhoto.value as? String ?? ""
        XCTAssertFalse(oldPhotoID.isEmpty)
        XCTAssertNotEqual(oldPhotoID, "none")

        confirmDelete.tap()

        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        let firstPhotoPredicate = NSPredicate(format: "value BEGINSWITH '1 / '")
        expectation(for: firstPhotoPredicate, evaluatedWith: progress)
        waitForExpectations(timeout: 8)

        XCTAssertTrue(currentPhoto.waitForExistence(timeout: 8))
        let newPhotoPredicate = NSPredicate(format: "value != %@ AND value != 'none'", oldPhotoID)
        expectation(for: newPhotoPredicate, evaluatedWith: currentPhoto)
        waitForExpectations(timeout: 8)
        XCTAssertNotEqual(currentPhoto.value as? String, oldPhotoID,
                          "确认删除后不得重新显示旧组最后一张")
        XCTAssertFalse(app.staticTexts["正在洗牌"].exists)
        XCTAssertFalse(app.staticTexts["下一组"].exists)
        XCTAssertFalse(app.staticTexts["回顾完毕"].exists)
        XCTAssertFalse(app.buttons["确认删除"].exists)
    }
}
