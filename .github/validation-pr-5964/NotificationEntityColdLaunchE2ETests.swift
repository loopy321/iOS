import Darwin
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

    func testPrepareForNotification() {
        app.launch()

        let declineLocation = app.buttons["Do not share my location"].firstMatch
        if declineLocation.waitForExistence(timeout: 15) {
            declineLocation.tap()

            let lessSecure = app.buttons["onboarding.localAccess.option.lessSecure"].firstMatch
            XCTAssertTrue(lessSecure.waitForExistence(timeout: 15), "The local access choice did not appear")
            lessSecure.tap()

            let next = app.buttons["onboarding.localAccess.next"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 5), "The local access next button did not appear")
            next.tap()

            let denyLocation = springboard.buttons["Don’t Allow"].firstMatch
            if denyLocation.waitForExistence(timeout: 10) {
                denyLocation.tap()
            }
        }

        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'Close'")).firstMatch
        if close.waitForExistence(timeout: 5) {
            close.tap()
        }

        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: Timeout.frontend),
            "The frontend was not unobstructed before the notification test"
        )
        XCTAssertFalse(declineLocation.exists, "The permissions flow remained over the frontend")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))

        app.launch()
        XCTAssertFalse(
            declineLocation.waitForExistence(timeout: 10),
            "The permissions flow returned after relaunch"
        )
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    func testEntityNotificationColdLaunch() {
        let expectedMoreInfo = ProcessInfo.processInfo.environment["EXPECTED_MORE_INFO"] == "true"
        let variant = ProcessInfo.processInfo.environment["TEST_VARIANT"] ?? "unknown"

        let lockReady = lockSimulator()
        print("PR5964_LOCK_SCREEN_READY=\(lockReady)")
        XCTAssertTrue(lockReady, "SpringBoardServices could not lock the simulator")
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

    private func lockSimulator() -> Bool {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }

        guard let portSymbol = dlsym(handle, "SBSSpringBoardServerPort"),
              let lockSymbol = dlsym(handle, "SBSLockDevice"),
              let statusSymbol = dlsym(handle, "SBSGetScreenLockStatus") else { return false }

        typealias ServerPort = @convention(c) () -> UInt32
        typealias LockDevice = @convention(c) (UInt32) -> Int32
        typealias GetScreenLockStatus = @convention(c) (
            UInt32,
            UnsafeMutablePointer<ObjCBool>,
            UnsafeMutablePointer<ObjCBool>
        ) -> Int32
        let serverPort = unsafeBitCast(portSymbol, to: ServerPort.self)
        let lockDevice = unsafeBitCast(lockSymbol, to: LockDevice.self)
        let getScreenLockStatus = unsafeBitCast(statusSymbol, to: GetScreenLockStatus.self)
        let port = serverPort()
        let lockResult = lockDevice(port)
        Thread.sleep(forTimeInterval: 1)
        var locked: ObjCBool = false
        var passcodeEnabled: ObjCBool = false
        let statusResult = getScreenLockStatus(port, &locked, &passcodeEnabled)
        print("PR5964_LOCK_STATUS=\(locked.boolValue) passcode=\(passcodeEnabled.boolValue)")
        return lockResult == 0 && statusResult == 0 && locked.boolValue
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
