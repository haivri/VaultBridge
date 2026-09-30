import XCTest

final class SyncMDUITests: XCTestCase {
    func testGuidedConflictReviewFinishesWithoutGitTools() {
        let app = XCUIApplication()
        app.launchArguments = ["-SyncSafetyUITest"]
        app.launch()
        let next = app.buttons["vault.nextAction"]
        if !next.waitForExistence(timeout: 5) {
            let open = app.buttons["Review"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            open.tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let choose = app.buttons["Use server version"]
        XCTAssertTrue(app.staticTexts["What’s different"].waitForExistence(timeout: 10))
        for _ in 0..<5 where !choose.exists { app.swipeUp() }
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Guided settings review"; screenshot.lifetime = .keepAlways; add(screenshot)
        choose.tap()
        let back = app.buttons["Go back to differences"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(choose.exists)
        choose.tap()
        app.buttons["Save server version"].tap()
        let finish = app.buttons["Save and finish syncing"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: finish)], timeout: 10) == .completed)
        finish.tap()
        XCTAssertTrue(app.staticTexts["All saved — you’re all set"].waitForExistence(timeout: 20))
        let completion = XCTAttachment(screenshot: app.screenshot())
        completion.name = "Verified saved status"; completion.lifetime = .keepAlways; add(completion)
    }

    func testPerChangeChoicesCanBeRevisedBeforeSavingAndRecoveredWithoutUpload() {
        let app = XCUIApplication()
        app.launchArguments = ["-SyncSafetyUITest"]
        app.launch()
        let next = app.buttons["vault.nextAction"]
        if !next.waitForExistence(timeout: 5) {
            let open = app.buttons["Review"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        let guided = app.buttons["Choose changes one by one"]
        for _ in 0..<5 where !guided.exists { app.swipeUp() }
        XCTAssertTrue(guided.waitForExistence(timeout: 10)); guided.tap()
        let phone = app.buttons["Keep iPhone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Save combined result"].exists)
        phone.tap()
        app.buttons["Keep Server"].tap()
        let save = app.buttons["Save combined result"]
        for _ in 0..<4 where !save.exists { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Per-change choices before saving"; screenshot.lifetime = .keepAlways; add(screenshot)
        save.tap()
        let local = app.buttons["Save locally and review recovery options"]
        XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap()
        let recover = app.buttons["merge.recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 10)); recover.tap()
        let latest = app.buttons["Recover a file from before the latest merge"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10)); latest.tap()
        let file = app.buttons[".obsidian/app.json"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        app.buttons["Restore iPhone original before merge"].tap()
        XCTAssertTrue(app.staticTexts["File restored on this iPhone. Sync when you’re ready to upload it."].waitForExistence(timeout: 10))
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
