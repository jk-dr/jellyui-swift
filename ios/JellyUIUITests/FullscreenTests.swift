import XCTest

/// Drives the full-screen player with real touches: every control must respond (nothing may sit on top of it).
final class FullscreenTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ route: String) -> XCUIApplication {
        let a = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        for k in ["JUI_SERVER", "JUI_USER", "JUI_PASS"] { a.launchEnvironment[k] = env[k] ?? "" }
        a.launchEnvironment["JUI_ROUTE"] = route
        a.launch()
        return a
    }

    private func shot(_ a: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: a.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }

    func testFullscreenControlsRespond() {
        let a = launch("nowplaying")
        let pause = a.buttons["fs-Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 40), "full-screen player did not open playing")
        sleep(4)
        shot(a, "fs-1-open")

        // a lyric line takes the tap (seeks there)
        let row = a.descendants(matching: .any)["lyric-2"]
        if row.waitForExistence(timeout: 8) {
            XCTAssertTrue(row.isHittable, "lyric row is covered by another view")
            row.tap()
            sleep(2)
            shot(a, "fs-2-lyric-tapped")
        }

        // play / pause: the tap must actually change the state (a covered button "passes" isHittable but does nothing)
        pause.tap(); sleep(1); shot(a, "fs-3-paused")
        XCTAssertTrue(a.buttons["fs-Play"].waitForExistence(timeout: 3), "tapping Pause did not pause — the button is covered")
        a.buttons["fs-Play"].tap(); sleep(1)
        XCTAssertTrue(a.buttons["fs-Pause"].waitForExistence(timeout: 5), "tapping Play did not resume — the button is covered")

        // cover only, then back to lyrics
        let lyr = a.buttons["Lyrics"]
        if lyr.exists && lyr.isHittable { lyr.tap(); sleep(1); shot(a, "fs-4-cover"); lyr.tap(); sleep(1) }

        // queue opens and closes
        let q = a.buttons["fs-Open queue"]
        XCTAssertTrue(q.isHittable, "queue button is covered")
        q.tap(); sleep(2); shot(a, "fs-5-queue")
        let qTitle = a.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Queue ('")).firstMatch
        XCTAssertTrue(qTitle.waitForExistence(timeout: 3) && qTitle.isHittable, "tapping the queue button did not open the queue — the button is covered")
        a.swipeDown(); sleep(2); shot(a, "fs-6-queue-closed")

        // swipe down closes the player; the player bar is then tappable
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        start.press(forDuration: 0.05, thenDragTo: a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        sleep(2)
        shot(a, "fs-7-closed")
        XCTAssertFalse(a.buttons["fs-Open queue"].exists, "player did not close on swipe down")
    }

    func testTabsAndBack() {
        let a = launch("home")
        let tabs = a.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 40), "native tab bar missing")
        sleep(3)
        tabs.buttons["Libraries"].tap(); sleep(3); shot(a, "tab-libraries")
        tabs.buttons["Settings"].tap(); sleep(2); shot(a, "tab-settings")
        tabs.buttons["Home"].tap(); sleep(2); shot(a, "tab-home")
    }
}
