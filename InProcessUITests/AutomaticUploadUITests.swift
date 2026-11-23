import XCTest
import CoreFoundation

final class AutomaticUploadUITests: XCTestCase {
    func app(_ scenario: String = "setup", route: String = "home") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-automatic"]
        app.launchEnvironment["INPROCESS_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["INPROCESS_UI_TEST_SCENARIO"] = scenario
        app.launchEnvironment["INPROCESS_UI_TEST_ROUTE"] = route
        app.launch()
        XCTAssertTrue(app.staticTexts["automaticTestMode"].waitForExistence(timeout: 10))
        return app
    }
    func testDevelopmentDiagnosticsExportsWithoutScanningOrPublishing() {
        let app = app("configuration")
        // Debug tools sit behind one Developer row at the bottom of the configuration sheet.
        openSettings(app)
        let developer = app.buttons["developmentTesting"]
        for _ in 0..<6 where !developer.isHittable { app.swipeUp() }
        developer.tap()
        let button = app.buttons["developmentDiagnostics"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable); button.tap()
        XCTAssertTrue(app.buttons["shareDiagnostics"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["diagnosticsSummary"].label.contains("retained events"))
        XCTAssertTrue(app.staticTexts["diagnosticsSummary"].label.contains("none observed in retained history"))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["closeDiagnostics"].tap()
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["uploadSettings"].waitForExistence(timeout: 5))
    }

    func testSecureSaveFailureCanRetryWithoutSignOut() {
        let app = app("secureSaveFailure")
        app.buttons["automaticSetup"].tap()
        finishSetup(app)
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setupError"].label.contains("-34018"))
        XCTAssertFalse(app.staticTexts["uploadStatus"].exists)
        XCTAssertTrue(app.buttons["retrySetup"].isEnabled)
        attach(app, name: "Secure save failure offers retry")
        app.buttons["retrySetup"].tap()
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        assertPublishing(app)
        XCTAssertFalse(app.textFields["emailField"].exists)
    }

    func testSetupStatusCellularPauseAndManualNavigation() {
        let app = app()
        app.buttons["automaticSetup"].tap()
        // Step 1 explains Photos access and the album; there is no album list and nothing to switch yet.
        XCTAssertTrue(app.staticTexts["setupIntro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setupIntro"].label.contains("full access to your photo library"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "create an album called In Process")).firstMatch.exists)
        XCTAssertEqual(app.staticTexts["setupStep"].label.lowercased(), "step 1 of 2") // Shown in capitals.
        XCTAssertEqual(app.switches.count, 0)
        XCTAssertFalse(app.buttons["enableAutomatic"].exists)
        attach(app, name: "Setup step 1, Photos access")
        allowPhotos(app)
        // Step 2 offers automatic uploading, off until chosen.
        XCTAssertTrue(app.buttons["enableAutomatic"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["setupStep"].label.lowercased(), "step 2 of 2")
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        XCTAssertTrue(app.staticTexts["automaticUploadsNote"].label.contains("nothing is uploaded until you approve"))
        // Fine print is collapsed until asked for.
        let finePrint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1 USDC collect price")).firstMatch
        XCTAssertFalse(finePrint.exists)
        reveal(app.buttons["setupDetails"], in: app); app.buttons["setupDetails"].tap()
        XCTAssertTrue(finePrint.waitForExistence(timeout: 5))
        app.switches["automaticUploads"].tap()
        XCTAssertTrue(app.staticTexts["automaticUploadsNote"].label.contains("with no further step"))
        attach(app, name: "Setup step 2, automatic uploading on")
        let enable = app.buttons["enableAutomatic"]
        reveal(enable, in: app); enable.tap()
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        assertPublishing(app)
        XCTAssertFalse(app.switches["cellularUploads"].exists, "Cellular lives in the configuration sheet")
        openSettings(app)
        app.switches["cellularUploads"].tap()
        app.buttons["closeSettings"].tap()
        // The connected home has three pieces: the automatic switch, the add button and the album. There is no pause switch.
        XCTAssertFalse(app.buttons["manualEntry"].exists)
        XCTAssertFalse(app.buttons["scanUploads"].exists)
        XCTAssertFalse(app.switches["pauseUploads"].exists)
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Queued")
        // Turning automatic off is the pause: the queued photo goes back to waiting.
        app.switches["automaticUploads"].tap()
        let waiting = NSPredicate(format: "label == %@", "0 uploaded · 0 queued · 1 waiting for approval")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: waiting, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        // Adding still works; the new photos wait too.
        app.buttons["addToAlbum"].tap()
        XCTAssertTrue(app.buttons["albumItem-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 3 waiting for approval")
        attach(app, name: "Connected home, automatic off with photos waiting")
        // Turning it back on is the resume: everything waiting is queued.
        app.switches["automaticUploads"].tap()
        // That publishes everything waiting, so it asks first.
        let confirm = app.buttons["confirmAutomatic"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Turn on and publish 3 photos")
        confirm.tap()
        let queued = NSPredicate(format: "label == %@", "0 uploaded · 3 queued")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: queued, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
    }
    func testExistingAlbumWithPhotosConnectsWithPhotosWaitingForApproval() {
        let app = app("albumWithPhotos")
        app.buttons["automaticSetup"].tap()
        allowPhotos(app)
        // Step 2 says the album's photos will wait, and automatic uploading cannot be chosen here.
        let warning = app.staticTexts["existingPhotosWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.contains("already has 1 photo"))
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        XCTAssertFalse(app.switches["automaticUploads"].isEnabled)
        XCTAssertFalse(app.buttons["recheckAlbum"].exists)
        attach(app, name: "Existing album with photos, step 2")
        reveal(app.buttons["enableAutomatic"], in: app); app.buttons["enableAutomatic"].tap()
        // Connected with nothing queued: the existing photo waits for approval.
        XCTAssertTrue(app.staticTexts["albumSummary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 1 waiting for approval")
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Waiting for approval")
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        // Turning automatic on asks before publishing it, and cancelling leaves it off.
        app.switches["automaticUploads"].tap()
        XCTAssertTrue(app.buttons["confirmAutomatic"].firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Confirm turning automatic on with photos waiting")
        // The dialog has no Cancel button; tapping outside dismisses it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(app.buttons["confirmAutomatic"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 1 waiting for approval")
    }
    func testExistingEmptyAlbumIsReused() {
        let app = app("emptyAlbum")
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.staticTexts["setupIntro"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["existingPhotosWarning"].exists)
        finishSetup(app)
        assertPublishing(app)
        // An empty album asks for photos instead of showing a blank grid.
        XCTAssertTrue(app.buttons["addFirstPhotos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["albumItem-0"].exists)
        attach(app, name: "Empty album call to action")
        app.buttons["addFirstPhotos"].tap()
        XCTAssertTrue(app.buttons["albumItem-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addFirstPhotos"].exists)
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 2 queued")
    }
    func testRemoveAllTakesOutWaitingAndFailedPhotosButNotUploadedOnes() {
        let app = app("albumGrid")
        XCTAssertTrue(app.staticTexts["albumSummary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "3 uploaded · 3 queued · 1 needs attention")
        app.buttons["removeAll"].tap()
        // Nothing is removed until the count is confirmed.
        let confirm = app.buttons["Remove 4 photos"].firstMatch // The system dialog lists its action twice in the hierarchy.
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Remove 4 pending photos from the In Process album?"].exists)
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "3 uploaded · 3 queued · 1 needs attention")
        attach(app, name: "Remove all confirmation")
        confirm.tap()
        let left = NSPredicate(format: "label == %@", "3 uploaded · 0 queued")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: left, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
        XCTAssertEqual(app.buttons["albumItem-2"].value as? String, "Uploaded")
        XCTAssertFalse(app.buttons["albumItem-3"].exists)
        // With only uploaded photos left there is nothing to remove.
        XCTAssertFalse(app.buttons["removeAll"].exists)
        XCTAssertFalse(app.staticTexts["overallStatus"].exists)
    }
    func testNewMomentNeverExistsWithoutAPhoto() {
        // Asking for New Moment with nothing chosen lands on home instead of an empty screen.
        let direct = app("setup", route: "manual")
        XCTAssertTrue(direct.buttons["manualEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(direct.buttons["choosePhoto"].exists)
        XCTAssertFalse(direct.buttons["publishMoment"].exists)
        direct.terminate()
        let app = app("setup")
        // The fixture supplies the picked photo, so New Moment opens complete.
        app.buttons["manualEntry"].tap()
        XCTAssertTrue(app.buttons["publishMoment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["titleField"].exists)
        XCTAssertTrue(app.buttons["removePhoto"].exists)
        attach(app, name: "New Moment opens with the chosen photo")
        // Removing the photo leaves New Moment for home.
        app.buttons["removePhoto"].tap()
        XCTAssertTrue(app.buttons["manualEntry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["automaticSetup"].exists)
        XCTAssertFalse(app.buttons["publishMoment"].exists)
        XCTAssertFalse(app.buttons["choosePhoto"].exists)
        XCTAssertFalse(app.buttons["home"].exists)
    }
    func testApprovingWhileTheAppIsOpenUploadsAtOnceAndShowsProgress() {
        let app = app("foregroundUpload")
        XCTAssertTrue(app.staticTexts["albumSummary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 2 waiting for approval")
        // Nothing uploads without an approval, even with the app open.
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Waiting for approval")
        app.buttons["albumItem-0"].tap()
        app.buttons["approvePhoto"].tap()
        app.buttons["closeAlbumItem"].tap()
        // The thumbnail shows the transfer, then the photo is uploaded with no wait for a background wake.
        let uploading = NSPredicate(format: "value == %@", "Uploading")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: uploading, object: app.buttons["albumItem-0"])], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["removeItem-0"].exists, "A photo mid-upload cannot be removed here")
        attach(app, name: "Thumbnail uploading in the foreground")
        let done = NSPredicate(format: "label == %@", "1 uploaded · 0 queued · 1 waiting for approval")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: app.staticTexts["albumSummary"])], timeout: 10), .completed)
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Uploaded")
        XCTAssertEqual(app.buttons["albumItem-1"].value as? String, "Waiting for approval")
    }
    func testConfiguredExpiredLaunchRequiresSignInBeforeStatus() {
        let app = app("expired")
        assertSignInOnly(app)
        XCTAssertTrue(app.staticTexts["signInRecovery"].exists)
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        app.buttons["sendCode"].tap()
        let code = app.textFields["codeField"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap(); code.typeText("123456") // The sixth digit submits; there is no second tap.
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        assertPublishing(app)
    }
    func testIncompatibleServerDoesNotClaimEnabled() {
        let app = app("incompatible")
        app.buttons["automaticSetup"].tap()
        finishSetup(app)
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["uploadStatus"].exists)
    }
    func testDeniedPhotosAccessLeavesSetupAndManualAvailable() {
        let app = app("denied")
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        app.buttons["home"].tap()
        app.buttons["manualEntry"].tap()
        XCTAssertTrue(app.buttons["choosePhoto"].waitForExistence(timeout: 5))
    }

    func testPreauthorizedSetupShowsConfirmWithoutEnablingAnything() {
        let app = app()
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.buttons["allowPhotos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["allowPhotos"].isEnabled)
        XCTAssertFalse(app.staticTexts["setupError"].exists)
        // Reaching step 2 still creates nothing.
        allowPhotos(app)
        XCTAssertTrue(app.buttons["enableAutomatic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["enableAutomatic"].isEnabled)
        attach(app, name: "Authorized access reaches step 2 without enabling anything")
        // Opening the screen creates nothing: leaving it returns to the unconfigured welcome.
        app.buttons["home"].tap()
        XCTAssertTrue(app.buttons["automaticSetup"].exists)
        XCTAssertFalse(app.switches["pauseUploads"].exists)
    }
    func testFirstPermissionGrantHappensOnTheConfirmTapAndEnables() {
        let app = app("firstGrant")
        app.buttons["automaticSetup"].tap()
        // The system prompt belongs to step 1's OK button, not to opening the screen.
        XCTAssertTrue(app.buttons["allowPhotos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setupError"].exists)
        finishSetup(app)
        assertPublishing(app)
        attach(app, name: "Initial full-access grant enables uploads")
    }
    func testLimitedAccessShowsRecoveryAndManualUpload() {
        let app = app("limited")
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setupError"].label.contains("Limited Photos access"))
        XCTAssertFalse(app.buttons["enableAutomatic"].exists)
        let settings = app.descendants(matching: .any)["photosSettings"]
        reveal(settings, in: app)
        XCTAssertTrue(settings.exists)
        attach(app, name: "Limited access explains recovery")
        // A Photos access problem is fixed in Settings: no retry and no manual-upload link here.
        XCTAssertFalse(app.buttons["retrySetup"].exists)
        XCTAssertFalse(app.buttons["setupManualEntry"].exists)
    }
    func testAlbumReadFailureShowsRetryInsteadOfAdvancing() {
        let app = app("albumReadFailure")
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setupError"].label.contains("Couldn’t read your Photos albums"))
        XCTAssertFalse(app.buttons["enableAutomatic"].exists)
        XCTAssertTrue(app.buttons["retrySetup"].isEnabled)
    }

    func testReturningFromSettingsRefreshesPermissionAndShowsConfirm() {
        let app = app("settingsGrant")
        app.buttons["automaticSetup"].tap()
        XCTAssertTrue(app.staticTexts["setupError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["enableAutomatic"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["allowPhotos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setupError"].exists)
        attach(app, name: "Return from Settings recognizes full access")
    }

    /// Step 1 of setup: accept the Photos access explanation.
    private func allowPhotos(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["allowPhotos"].waitForExistence(timeout: 5))
        app.buttons["allowPhotos"].tap()
    }
    /// Runs both setup steps. `automatic` turns the step-2 switch on, which is off by default.
    private func finishSetup(_ app: XCUIApplication, automatic: Bool = true) {
        allowPhotos(app)
        XCTAssertTrue(app.buttons["enableAutomatic"].waitForExistence(timeout: 5))
        if automatic { app.switches["automaticUploads"].tap() }
        reveal(app.buttons["enableAutomatic"], in: app); app.buttons["enableAutomatic"].tap()
    }
    func testAutomaticUploadingOffLeavesAlbumPhotosWaitingForApproval() {
        let app = app()
        app.buttons["automaticSetup"].tap()
        finishSetup(app, automatic: false)
        assertPublishing(app, automatic: false)
        // The album's photo is shown but not queued.
        XCTAssertTrue(app.buttons["albumItem-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Waiting for approval")
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 1 waiting for approval")
        attach(app, name: "Automatic uploading off, photo waiting for approval")
        // Approving one photo queues it while the switch stays off.
        app.buttons["albumItem-0"].tap()
        XCTAssertTrue(app.buttons["approvePhoto"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["unapprovePhoto"].exists)
        app.buttons["approvePhoto"].tap()
        let state = NSPredicate(format: "label == %@", "Queued")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: state, object: app.staticTexts["albumItemState"])], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["approvePhoto"].exists)
        // The approval can be taken back before the upload starts.
        XCTAssertTrue(app.buttons["unapprovePhoto"].exists)
        attach(app, name: "Approved photo offers un-approve")
        app.buttons["unapprovePhoto"].tap()
        let back = NSPredicate(format: "label == %@", "Waiting for approval")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: back, object: app.staticTexts["albumItemState"])], timeout: 5), .completed)
        app.buttons["closeAlbumItem"].tap()
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
        // Approve all asks first, then queues every waiting photo.
        app.buttons["addToAlbum"].tap()
        XCTAssertTrue(app.buttons["albumItem-2"].waitForExistence(timeout: 5))
        app.buttons["approveAll"].tap()
        let confirm = app.buttons["Publish 3 photos"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "0 uploaded · 0 queued · 3 waiting for approval")
        confirm.tap()
        let queued = NSPredicate(format: "label == %@", "0 uploaded · 3 queued")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: queued, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["approveAll"].exists)
        XCTAssertEqual(app.switches["automaticUploads"].value as? String, "0")
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    /// Sign out lives at the end of the Configuration sheet.
    private func signOut(_ app: XCUIApplication) {
        openSettings(app)
        reveal(app.buttons["signOut"], in: app); app.buttons["signOut"].tap()
    }
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["uploadSettings"].tap()
        XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout: 5))
    }
    func testConfigurationShowsActualPolicyAndPermissions() {
        let app = app("configuration")
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        app.switches["automaticUploads"].tap()
        XCTAssertFalse(app.staticTexts["configSession"].exists, "Details live in the configuration sheet")
        openSettings(app)
        app.switches["cellularUploads"].tap()
        reveal(app.staticTexts["configSession"], in: app)
        XCTAssertEqual(app.staticTexts["configAlbum"].label, "Photos album, Studio process")
        XCTAssertEqual(app.staticTexts["configMode"].label, "Automatic uploading, Off")
        XCTAssertEqual(app.staticTexts["configAutomatic"].label, "Background uploads, Enabled")
        XCTAssertEqual(app.staticTexts["configNetwork"].label, "Network, Wi-Fi only")
        XCTAssertEqual(app.staticTexts["configPhotos"].label, "Photos access, Full access")
        XCTAssertEqual(app.staticTexts["configNotifications"].label, "Notifications, Quiet delivery")
        XCTAssertEqual(app.staticTexts["configSession"].label, "Upload session, Valid")
        reveal(app.staticTexts["configDefaults"], in: app)
        XCTAssertEqual(app.staticTexts["configDefaults"].label, "Metadata, Defaults")
        let development = app.buttons["developmentTesting"]
        reveal(development, in: app); development.tap()
        let guidance = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Resource Upload Test Mode is managed")).firstMatch
        reveal(guidance, in: app)
        XCTAssertTrue(guidance.label.contains("can’t be read by this app"))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Upload configuration"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testConfigurationRefreshesOnReturnFromSettings() {
        let app = app("configuration")
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        openSettings(app)
        reveal(app.staticTexts["configNotifications"], in: app)
        XCTAssertEqual(app.staticTexts["configPhotos"].label, "Photos access, Full access")
        XCTAssertEqual(app.staticTexts["configNotifications"].label, "Notifications, Quiet delivery")
        XCUIDevice.shared.press(.home)
        app.activate()
        let updated = NSPredicate(format: "label == %@", "Notifications, Denied")
        expectation(for: updated, evaluatedWith: app.staticTexts["configNotifications"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["configPhotos"].label, "Photos access, Limited access")
        XCTAssertEqual(app.staticTexts["configAlbum"].label, "Photos album, Full Photos access needed")
        XCTAssertEqual(app.staticTexts["configAutomatic"].label, "Background uploads, Disabled")
    }
    private func assertSignInOnly(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.staticTexts["uploadStatus"].exists, file: file, line: line)
        for id in ["openUploadStatus", "home", "manualEntry", "automaticSetup", "choosePhoto", "allowPhotos", "enableAutomatic", "retrySetup", "uploadSettings", "addToAlbum", "addFirstPhotos", "albumItem-0", "signOut"] {
            XCTAssertFalse(app.buttons[id].exists, "Unauthenticated navigation: \(id)", file: file, line: line)
        }
        XCTAssertFalse(app.staticTexts["configSession"].exists, file: file, line: line)
        XCTAssertFalse(app.switches["automaticUploads"].exists, "Unauthenticated control: automaticUploads", file: file, line: line)
    }
    /// The album is connected and nothing needs attention: the automatic switch shows the chosen mode and no problem line is shown.
    private func assertPublishing(_ app: XCUIApplication, automatic: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches["automaticUploads"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(toggle.value as? String, automatic ? "1" : "0", file: file, line: line)
        XCTAssertFalse(app.staticTexts["overallStatus"].exists, file: file, line: line)
    }
    func testAlbumGridDistinguishesQueuedFromUploadedAndOpensDetails() {
        let app = app("albumGrid")
        XCTAssertTrue(app.staticTexts["albumSummary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumSummary"].label, "3 uploaded · 3 queued · 1 needs attention")
        // Newest first: three the scan just queued, the failed one, then three published.
        XCTAssertEqual(app.buttons["albumItem-0"].value as? String, "Queued")
        XCTAssertEqual(app.buttons["albumItem-3"].value as? String, "Needs attention")
        XCTAssertEqual(app.buttons["albumItem-6"].value as? String, "Uploaded")
        attach(app, name: "Album grid with queued, failed and uploaded photos")
        app.buttons["albumItem-3"].tap()
        XCTAssertTrue(app.buttons["retryUpload"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumItemReason"].label, "Fixture transfer failed.")
        app.buttons["closeAlbumItem"].tap()
        reveal(app.buttons["albumItem-6"], in: app); app.buttons["albumItem-6"].tap()
        XCTAssertTrue(app.staticTexts["albumItemState"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["albumItemState"].label, "Uploaded")
        XCTAssertTrue(app.links["viewMoment"].exists || app.buttons["viewMoment"].exists)
        XCTAssertFalse(app.buttons["retryUpload"].exists)
        XCTAssertFalse(app.buttons["removeFromAlbum"].exists)
        app.buttons["closeAlbumItem"].tap()
        // Pending and failed photos carry a remove X; uploaded ones do not.
        XCTAssertTrue(app.buttons["removeItem-0"].exists)
        XCTAssertTrue(app.buttons["removeItem-3"].exists)
        XCTAssertFalse(app.buttons["removeItem-6"].exists)
        // A pending photo can also be removed from its details, which then close.
        app.buttons["albumItem-0"].tap()
        XCTAssertTrue(app.buttons["removeFromAlbum"].waitForExistence(timeout: 5))
        attach(app, name: "Pending photo details with remove")
        app.buttons["removeFromAlbum"].tap()
        let fewer = NSPredicate(format: "label == %@", "3 uploaded · 2 queued · 1 needs attention")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["albumItem-6"].exists)
        // Removing the failed photo clears the problem line with it.
        XCTAssertEqual(app.buttons["albumItem-2"].value as? String, "Needs attention")
        app.buttons["removeItem-2"].tap()
        let cleared = NSPredicate(format: "label == %@", "3 uploaded · 2 queued")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: app.staticTexts["albumSummary"])], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["overallStatus"].exists)
        XCTAssertFalse(app.buttons["closeAlbumItem"].exists)
    }
    private func sendCode(_ app: XCUIApplication) {
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        if (email.value as? String)?.contains("@") != true { email.tap(); email.typeText("fixture@example.invalid") }
        app.buttons["sendCode"].tap()
        XCTAssertTrue(app.textFields["codeField"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
    }
    private func finishSignIn(_ app: XCUIApplication) {
        let code = app.textFields["codeField"]
        code.tap(); code.typeText("123456") // The sixth digit submits; there is no second tap.
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home"].exists)
    }
    private func event(_ event: String, app: XCUIApplication) {
        let count = Int(app.staticTexts["automaticTestMode"].value as? String ?? "0")!
        let run = app.launchEnvironment["INPROCESS_UI_TEST_RUN_ID"]!
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.xdjs.InProcess.ui-test.automatic.\(run).\(event)" as CFString), nil, nil, true)
        let handled = NSPredicate(format: "value == %@", String(count + 1))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: handled, object: app.staticTexts["automaticTestMode"])], timeout: 5), .completed)
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testSignedOutEmailAndCodeGateNotificationEntryThenLandOnStatus() {
        let app = app("signedOut")
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
        attach(app, name: "After — exclusive sign-in")
        event("status", app: app)
        sendCode(app)
        event("status", app: app)
        XCTAssertTrue(app.textFields["codeField"].exists)
        assertSignInOnly(app)
        attach(app, name: "After — exclusive code entry")
        finishSignIn(app)
        XCTAssertTrue(app.buttons["automaticSetup"].exists) // The welcome screen offers setup only when nothing is connected.
        XCTAssertTrue(app.buttons["Upload a single photo"].exists)
        XCTAssertTrue(app.buttons["Publish from an album"].exists)
        attach(app, name: "After — unconfigured Upload status home")
    }
    func testSignedOutCannotBypassGateWithManualOrSetupRoute() {
        for route in ["manual", "setup"] {
            let app = app("signedOut", route: route)
            XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
            assertSignInOnly(app)
            sendCode(app)
            assertSignInOnly(app)
            app.terminate()
        }
    }
    func testRestoredUnconfiguredAccountStartsAtStatusAndManualReturnsHome() {
        let app = app("restored")
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["automaticSetup"].exists) // The welcome screen offers setup only when nothing is connected.
        app.buttons["manualEntry"].tap()
        XCTAssertTrue(app.buttons["choosePhoto"].waitForExistence(timeout: 5))
        event("status", app: app)
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        signOut(app)
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
    }
    func testConfiguredSignOutGatesNotificationAndSignInRestoresStatus() {
        let app = app("restoredConfigured")
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["automaticUploads"].exists)
        attach(app, name: "After — configured Upload status home")
        signOut(app)
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
        event("status", app: app)
        sendCode(app); finishSignIn(app)
        XCTAssertTrue(app.switches["automaticUploads"].exists)
        assertPublishing(app)
    }
    func testExpiryWhileOpenReturnsToExclusiveSignInAndRecovers() {
        let app = app("restoredConfigured")
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addToAlbum"].exists)
        event("expire", app: app)
        XCTAssertTrue(app.textFields["emailField"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
        XCTAssertTrue(app.staticTexts["signInRecovery"].exists)
        attach(app, name: "After — expired session recovery")
        sendCode(app); finishSignIn(app)
        XCTAssertTrue(app.switches["automaticUploads"].exists)
    }
    func testAccountLoadingRecoveryCannotEnterApplication() {
        let app = app("accountRecovery")
        XCTAssertTrue(app.buttons["retryAccount"].waitForExistence(timeout: 5))
        assertSignInOnly(app)
        event("status", app: app)
        app.buttons["retryAccount"].tap()
        XCTAssertTrue(app.staticTexts["uploadStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["automaticSetup"].exists) // The welcome screen offers setup only when nothing is connected.
    }
}
