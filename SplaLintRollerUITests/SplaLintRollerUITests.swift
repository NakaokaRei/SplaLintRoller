import XCTest

final class SplaLintRollerUITests: XCTestCase {
    @MainActor
    func testSimulatorExplainsDeviceRequirement() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["ARを利用できません"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["unavailableMessage"].label.contains("LiDAR"))
        XCTAssertFalse(app.buttons["paintButton"].exists)
        #else
        throw XCTSkip("Simulator-specific unsupported-device screen")
        #endif
    }
}
