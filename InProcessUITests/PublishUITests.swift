import XCTest
import CoreFoundation

final class PublishUITests: XCTestCase {
    func testOneTapPublishesImmediatelyWithoutConfirmation() {
        continueAfterFailure = false
        let runID = UUID().uuidString
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-publish"]
        app.launchEnvironment["INPROCESS_UI_TEST_RUN_ID"] = runID
        app.launch()
        defer { app.terminate() }

        // Never tap Publish unless the app proves the isolated fixture was selected.
        XCTAssertTrue(app.staticTexts["uiTestMode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Publishing as UI Test Artist"].exists)
        XCTAssertEqual(app.staticTexts["uiTestCreateCount"].value as? String, "0")
        let publish = app.buttons["publishMoment"]
        for _ in 0..<3 where !publish.isHittable { app.swipeUp() }
        XCTAssertTrue(publish.isHittable)
        XCTAssertTrue(publish.isEnabled)
        publish.tap() // Exactly one user action. No confirmation or completion button tap.

        let held = app.staticTexts["uiTestCreateWaiting"]
        let progressOrDialog = NSPredicate { _, _ in
            (held.value as? String) == "true" || app.alerts.count > 0 || app.sheets.count > 0
                || app.buttons["confirmPublish"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: progressOrDialog, object: nil)], timeout: 10), .completed)
        assertNoConfirmation(app)
        XCTAssertEqual(held.value as? String, "true", "One tap must reach the fake create call without further interaction.")
        XCTAssertTrue(app.staticTexts["Publishing your Moment…"].exists)
        XCTAssertFalse(publish.isEnabled)
        XCTAssertFalse(app.staticTexts["publishedHeading"].exists, "Success must wait for the service response.")
        XCTAssertEqual(app.staticTexts["uiTestCreateCount"].value as? String, "1")
        XCTAssertEqual(app.staticTexts["uiTestUploadCount"].value as? String, "2")
        attach(app, name: "Single tap — create pending")

        // Cross-process notification releases the continuation, with no timing-based sleep
        // and no second interaction with the app's UI.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.xdjs.InProcess.ui-test.publish.\(runID)" as CFString), nil, nil, true)
        XCTAssertTrue(app.staticTexts["publishedHeading"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["uiTestCreateCount"].value as? String, "1", "Count create calls separately from the two uploads.")
        XCTAssertEqual(held.value as? String, "false")
        assertNoConfirmation(app)
        attach(app, name: "Single tap — published")
    }

    private func assertNoConfirmation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.alerts.count, 0, file: file, line: line)
        XCTAssertEqual(app.sheets.count, 0, file: file, line: line)
        XCTAssertFalse(app.buttons["confirmPublish"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Publish this Moment publicly?"].exists, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
