import XCTest

final class NotificationEntityColdLaunchE2ETests: XCTestCase {
    private enum Timeout {
        static let app: TimeInterval = 30
        static let frontend: TimeInterval = 90
        static let notification: TimeInterval = 30
    }

    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The app must be stopped before the tap")
    }

    func testEntityNotificationColdLaunch() {
        let expectedMoreInfo = ProcessInfo.processInfo.environment["EXPECTED_MORE_INFO"] == "true"
        let variant = ProcessInfo.processInfo.environment["TEST_VARIANT"] ?? "unknown"

        XCUIDevice.shared.press(.home)
        _ = springboard.wait(for: .runningForeground, timeout: 10)

        let title = springboard.staticTexts["HA PR 5964 entity test"].firstMatch
        if !title.waitForExistence(timeout: Timeout.notification) {
            openNotificationCenter()
        }

        XCTAssertTrue(title.waitForExistence(timeout: Timeout.notification), springboard.debugDescription)
        tapNotification(title: title)

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Timeout.app),
            "Tapping the notification did not cold-launch Home Assistant"
        )

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: Timeout.frontend), "The Home Assistant frontend did not appear")

        let observedMoreInfo = waitForMoreInfo(in: webView, timeout: expectedMoreInfo ? Timeout.frontend : 45)
        print("PR5964_OBSERVED_MORE_INFO=\(observedMoreInfo)")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(variant)-5964-final"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(
            observedMoreInfo,
            expectedMoreInfo,
            expectedMoreInfo
                ? "The requested CITest More Info dialog did not appear"
                : "The baseline unexpectedly opened the CITest More Info dialog"
        )
    }

    private func openNotificationCenter() {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func tapNotification(title: XCUIElement) {
        let shortLook = springboard.otherElements["NotificationShortLookView"].firstMatch
        if shortLook.waitForExistence(timeout: 2) {
            shortLook.tap()
        } else {
            title.tap()
        }

        guard !app.wait(for: .runningForeground, timeout: 5) else { return }

        let open = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] 'Open' OR identifier ==[c] 'Open' OR value ==[c] 'Open'")
        ).firstMatch
        if open.waitForExistence(timeout: 2) {
            open.tap()
        }
    }

    private func waitForMoreInfo(in webView: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let titlePredicate = NSPredicate(format: "label ==[c] 'CITest' OR value ==[c] 'CITest'")

        repeat {
            let dialog = webView.dialogs.firstMatch
            if dialog.exists,
               dialog.descendants(matching: .any).matching(titlePredicate).firstMatch.exists {
                return true
            }

            let title = webView.descendants(matching: .any).matching(titlePredicate).firstMatch
            let close = webView.buttons.matching(NSPredicate(format: "label ==[c] 'Close'")).firstMatch
            if title.exists, close.exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return false
    }
}
