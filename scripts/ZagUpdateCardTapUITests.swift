import XCTest

/// Real taps, by screen coordinate, on the release card's update control and
/// Learn More link inside their shared Form row.
final class ZagUpdateCardTapUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ state: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["ZAG_CARD_STATE": state]
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

    func testSuccessCapsuleCompletesOnceAcrossItsBoundsAndNeverOpensLearnMore() {
        for index in 0..<3 {
            launch("handedOff")
            let frame = capsule("Restart to Complete...").frame
            let link = learnMore.frame
            XCTAssertFalse(frame.intersects(link), "capsule \(frame) and Learn More \(link) must not overlap")
            XCTAssertGreaterThanOrEqual(link.minY - frame.maxY, 8, "capsule and Learn More keep separate frames with a gap")
            let (name, point) = capsulePoints(frame)[index]
            reset(); tap(at: point)
            settle("complete", "the success capsule's \(name) invokes the completion action")
            // Repeated taps never invoke it again, and never reach Learn More.
            for (_, again) in capsulePoints(frame) { tap(at: again) }
            settle("complete", "the completion action runs exactly once")
            // Exactly the two approved strings; no instruction, popup or sheet.
            XCTAssertTrue(app.staticTexts["Update successful. Reopen Zag Store to complete."].exists)
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'App Switcher'")).count, 0)
            XCTAssertEqual(app.alerts.count, 0)
            XCTAssertEqual(app.sheets.count, 0)
            XCTAssertEqual(capsule("Restart to Complete...").frame, frame, "the capsule does not move or resize after taps")
            app.terminate()
        }
    }

    /// The production path: `ZagUpdateCompletion.complete` → `exit(0)`.
    func testRestartToCompleteEndsTheProcessAndKeepsPreferences() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["ZAG_CARD_STATE": "handedOff", "ZAG_CARD_TERMINATE": "1", "ZAG_CARD_CLEAR_MARKER": "1"]
        app.launch()
        XCTAssertEqual(app.staticTexts["marker"].label, "no marker")
        let frame = capsule("Restart to Complete...").frame
        tap(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "the process ends after Restart to Complete...")
        // Relaunch without clearing: the preference written just before exit(0) survived.
        app.launchEnvironment = ["ZAG_CARD_STATE": "handedOff"]
        app.launch()
        XCTAssertEqual(app.staticTexts["marker"].label, "written before exit")
    }

    func testLearnMoreStillOpensItsDestination() {
        launch("handedOff")
        reset(); tap(at: CGPoint(x: learnMore.frame.midX, y: learnMore.frame.midY))
        settle("learnMore", "Learn More opens its release page")
    }

    /// Empty card space well away from both controls. (Within a few points of
    /// an active button iOS's usual touch tolerance applies, as it always has
    /// for Update Now; see the next test.)
    func testEmptyCardSpaceDoesNothing() {
        for state in ["handedOff", "idle"] {
            launch(state)
            let header = app.staticTexts["Zag Store 1.0.0"].frame
            let capsuleFrame = capsule(state == "idle" ? "Update Now" : "Restart to Complete...").frame
            reset(); tap(at: CGPoint(x: capsuleFrame.maxX - 24, y: header.midY))
            settle("none", "tapping empty card space in \(state) does nothing and never opens Learn More")
            app.terminate()
        }
    }

    /// The success capsule's tap tolerance matches Update Now's: same button,
    /// same shape, so a near-miss behaves identically in both states.
    func testSuccessCapsuleToleranceMatchesUpdateNow() {
        var results: [String] = []
        for (state, title) in [("idle", "Update Now"), ("handedOff", "Restart to Complete...")] {
            launch(state)
            let frame = capsule(title).frame
            reset(); tap(at: CGPoint(x: frame.midX, y: frame.minY - 12))
            Thread.sleep(forTimeInterval: 0.6)
            results.append(events == "none" ? "miss" : "hit")
            app.terminate()
        }
        XCTAssertEqual(results[0], results[1], "Update Now and the success capsule share one tap tolerance: \(results)")
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
