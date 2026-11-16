import XCTest

/// Real taps, by screen coordinate, on the release card's update control and
/// Learn More link inside their shared Form row.
final class ZagUpdateCardTapUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ state: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ZAG_CARD_STATE"] = state
        app.launch()
    }

    private var events: String { app.staticTexts["events"].label }

    private func reset() {
        app.buttons["reset"].tap()
        XCTAssertEqual(events, "none")
    }

    /// Frame of the capsule: the element carrying the control's accessibility label.
    private func capsule(_ title: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(title) missing")
        return element
    }

    private var learnMore: XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Learn More'")).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Learn More missing")
        return element
    }

    /// Taps a window coordinate.
    private func tap(at point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    private func settle(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(events, expected, message, file: file, line: line)
    }

    private func capsulePoints(_ frame: CGRect) -> [(String, CGPoint)] {
        [("centre", CGPoint(x: frame.midX, y: frame.midY)),
         ("left edge", CGPoint(x: frame.minX + 8, y: frame.midY)),
         ("right edge", CGPoint(x: frame.maxX - 8, y: frame.midY))]
    }

    func testSuccessCapsuleTapsNeverOpenLearnMore() {
        launch("handedOff")
        let frame = capsule("Restart to Complete...").frame
        let link = learnMore.frame
        XCTAssertFalse(frame.intersects(link), "capsule \(frame) and Learn More \(link) must not overlap")
        XCTAssertGreaterThanOrEqual(link.minY - frame.maxY, 8, "capsule and Learn More keep separate frames with a gap")
        for (name, point) in capsulePoints(frame) {
            reset(); tap(at: point)
            settle("none", "tapping the success capsule's \(name) must do nothing")
        }
        // Exactly the two approved strings; no instruction, popup or sheet.
        XCTAssertTrue(app.staticTexts["Update successful. Reopen Zag Store to complete."].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'App Switcher'")).count, 0)
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(capsule("Restart to Complete...").frame, frame, "the capsule does not move or resize after taps")
    }

    func testLearnMoreStillOpensItsDestination() {
        launch("handedOff")
        reset(); tap(at: CGPoint(x: learnMore.frame.midX, y: learnMore.frame.midY))
        settle("learnMore", "Learn More opens its release page")
    }

    func testRowBackgroundAroundTheControlsDoesNothing() {
        launch("handedOff")
        let frame = capsule("Restart to Complete...").frame
        reset(); tap(at: CGPoint(x: frame.midX, y: frame.minY - 12))
        settle("none", "tapping the card between its controls does not open Learn More")
    }

    func testBusyBarTapsNeverOpenLearnMore() {
        launch("progress")
        let frame = capsule("Transferring signed IPA...").frame
        for (name, point) in capsulePoints(frame) {
            reset(); tap(at: point)
            settle("none", "tapping the progress bar's \(name) must do nothing")
        }
    }

    func testUpdateNowStillStartsTheUpdateOnly() {
        launch("idle")
        let frame = capsule("Update Now").frame
        for (name, point) in capsulePoints(frame) {
            reset(); tap(at: point)
            settle("update", "Update Now's \(name) starts the update once and never opens Learn More")
        }
    }
}
