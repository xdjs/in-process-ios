import XCTest

// Opt-in manual validation driver. Never runs during normal tests. All actions
// operate the real app's UI; no app state, identity, or network is substituted.
final class AuthorizedLiveDriver: XCTestCase {
    func testManuallyAuthorizedFlow() throws {
        guard let directory = ProcessInfo.processInfo.environment["INPROCESS_LIVE_DRIVER_DIRECTORY"] else {
            throw XCTSkip("Live account validation requires explicit operator authorization.")
        }
        continueAfterFailure = false
        let folder = URL(fileURLWithPath: directory)
        let app = XCUIApplication(); app.launch()
        func output(_ value: String) throws {
            try value.write(to: folder.appendingPathComponent("response.txt"), atomically: true, encoding: .utf8)
        }
        try output("READY\n" + app.debugDescription)
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            let input = folder.appendingPathComponent("command.json")
            guard let data = try? Data(contentsOf: input),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                Thread.sleep(forTimeInterval: 0.2); continue
            }
            try FileManager.default.removeItem(at: input)
            let action = command["action"] ?? ""
            let value = command["value"] ?? ""
            switch action {
            case "finish": try output("FINISHED"); return
            case "type":
                let field = app.textFields[value]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                field.tap(); field.typeText(command["text"] ?? "")
            case "tap":
                let element = app.descendants(matching: .any).matching(identifier: value).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5)); element.tap()
            case "tapLabel":
                let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", value)).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5)); element.tap()
            case "tapPoint":
                let x = Double(command["x"] ?? "0") ?? 0
                let y = Double(command["y"] ?? "0") ?? 0
                app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
            case "swipeUp": app.swipeUp()
            case "snapshot": break
            case "screenshot": try app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("screen.png"))
            default: XCTFail("Unknown live driver action")
            }
            Thread.sleep(forTimeInterval: 0.5)
            try output("DONE\n" + app.debugDescription)
        }
        XCTFail("Live validation timed out")
    }
}
