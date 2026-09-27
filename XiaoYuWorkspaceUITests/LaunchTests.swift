import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testWorkspaceLaunchesWithNativeNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["添加项目"].firstMatch.exists)
    }
}
