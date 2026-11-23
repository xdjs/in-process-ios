import XCTest

final class SignInUITests: XCTestCase {
    func testOTPBootstrapsOneKeyAndReachesAuthenticatedHome() {
        let app = keyApp("keySignIn")
        completeSignIn(app)
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["keyCreateCount"].value as? String, "1")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Artist key sign-in home"; shot.lifetime = .keepAlways; add(shot)
    }
    func testRejectedKeyShowsSignInAndReplacementResumesExistingAlbum() {
        let app = keyApp("keyRevoked")
        XCTAssertTrue(app.staticTexts["signInRecovery"].waitForExistence(timeout: 10))
        completeSignIn(app)
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["keyCreateCount"].value as? String, "1")
    }
    func testOfflineSignOutReportsPendingRemoteRemovalAndHidesAuthenticatedHome() {
        let app = keyApp("keySignOutOffline")
        // Sign out lives at the end of the Configuration sheet.
        XCTAssertTrue(app.buttons["uploadSettings"].waitForExistence(timeout: 10)); app.buttons["uploadSettings"].tap()
        let signOut = app.buttons["signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["uploadStatus"].exists)
        let status = app.staticTexts["signOutStatus"]
        for _ in 0..<3 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.label.contains("pending"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline sign-out pending remote removal"; shot.lifetime = .keepAlways; add(shot)
    }
    private func keyApp(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-automatic"]
        app.launchEnvironment["INPROCESS_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["INPROCESS_UI_TEST_SCENARIO"] = scenario; app.launch()
        XCTAssertTrue(app.staticTexts["automaticTestMode"].waitForExistence(timeout: 10))
        return app
    }
    private func completeSignIn(_ app: XCUIApplication) {
        let email = app.textFields["emailField"]; XCTAssertTrue(email.waitForExistence(timeout: 10))
        if email.value as? String != "fixture@example.invalid" {
            email.tap()
            if let existing = email.value as? String, existing.contains("@") {
                email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            email.typeText("fixture@example.invalid")
        }
        XCTAssertEqual(email.value as? String, "fixture@example.invalid")
        app.buttons["sendCode"].tap()
        let code = app.textFields["codeField"]; XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("123456") // The sixth digit submits; there is no second tap.
    }
    func testSignInScreenAndEmailValidationWithoutSendingEmail() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-automatic"]
        app.launchEnvironment["INPROCESS_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["INPROCESS_UI_TEST_SCENARIO"] = "signedOut"
        app.launch()
        XCTAssertTrue(app.staticTexts["automaticTestMode"].waitForExistence(timeout: 10))
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        let send = app.buttons["sendCode"]
        XCTAssertFalse(send.isEnabled)
        email.tap(); email.typeText("not-an-email")
        XCTAssertFalse(send.isEnabled)
        email.tap(); email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        email.typeText("test@example.invalid")
        XCTAssertTrue(send.isEnabled)
        // No button tap: the test never sends an email or calls the login service.
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Sign-in screen"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
