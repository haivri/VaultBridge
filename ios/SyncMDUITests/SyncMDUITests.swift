import XCTest

final class SyncMDUITests: XCTestCase {
    func testOneFileDefaultAndSavedSeparateFilesPreference() {
        let app = XCUIApplication()
        app.launchArguments = ["-SyncSafetyUITest", "-SyncNoteConflictUITest"]
        app.launch()
        let next = app.buttons["vault.nextAction"]
        if !next.waitForExistence(timeout: 5) {
            let open = app.buttons["Review"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        let merge = app.buttons["conflict.mergeOneFile"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["conflict.keepSeparateFiles"].exists)
        app.buttons["Done for now"].tap()

        app.buttons["vault.settings"].tap()
        let picker = app.buttons["settings.conflictFilePreference"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["Keep two separate files"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.buttons["vault.settings"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.label.contains("Keep two separate files"))
        app.buttons["Cancel"].tap()
        next.tap()
        let separate = app.buttons["conflict.keepSeparateFiles"]
        XCTAssertTrue(separate.waitForExistence(timeout: 10))
        XCTAssertTrue(merge.exists)
        XCTAssertLessThan(separate.frame.minY, merge.frame.minY)
        separate.tap()
        XCTAssertTrue(app.staticTexts["Your choices are saved"].waitForExistence(timeout: 10))
    }

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
        let guided = app.buttons["conflict.mergeOneFile"]
        for _ in 0..<5 where !guided.exists { app.swipeUp() }
        XCTAssertTrue(guided.waitForExistence(timeout: 10)); guided.tap()
        let phone = app.buttons["Keep iPhone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Save merged file"].exists)
        phone.tap()
        app.buttons["Keep Server"].tap()
        let save = app.buttons["Save merged file"]
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

    func testMissingTimestampReviewAndSelectiveRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-SyncSafetyUITest", "-SyncRecoveryUITest"]
        app.launch()
        let next = app.buttons["vault.nextAction"]
        if !next.waitForExistence(timeout: 5) {
            let open = app.buttons["Review"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        let choose = app.buttons["Choose text to restore"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); choose.tap()
        let version = app.buttons["recovery.version.0"]
        XCTAssertTrue(version.waitForExistence(timeout: 10)); version.tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'recovery.change.'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", "The timestamp change must be selected before restoring")
        let preview = app.staticTexts["recovery.result"]
        for _ in 0..<5 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.label.contains("Time 12:00"))
        XCTAssertTrue(preview.label.contains("[x] shower"))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Selective timestamp recovery"; attachment.lifetime = .keepAlways; add(attachment)
        let restore = app.buttons["Restore selected changes"]
        for _ in 0..<4 where !restore.isHittable { app.swipeUp() }
        restore.tap()
        XCTAssertTrue(app.staticTexts["Restored locally. Your previous file is protected. Sync when ready to upload."].waitForExistence(timeout: 10))
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
