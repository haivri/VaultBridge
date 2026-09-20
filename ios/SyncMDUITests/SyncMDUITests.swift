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
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Guided settings review"; screenshot.lifetime = .keepAlways; add(screenshot)
        choose.tap()
        let finish = app.buttons["Save and finish syncing"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: finish)], timeout: 10) == .completed)
        finish.tap()
        XCTAssertTrue(app.staticTexts["All saved — you’re all set"].waitForExistence(timeout: 20))
        let completion = XCTAttachment(screenshot: app.screenshot())
        completion.name = "Verified saved status"; completion.lifetime = .keepAlways; add(completion)
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
