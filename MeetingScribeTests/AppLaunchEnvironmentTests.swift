import XCTest
@testable import MeetingScribe

final class AppLaunchEnvironmentTests: XCTestCase {
    func testDetectsEachTestHostEnvironmentKey() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            for value in ["test-host-value", ""] {
                XCTAssertTrue(
                    AppLaunchEnvironment(environment: [key: value]).isUnitTestHost,
                    "Expected \(key) to identify a test host even when its value is empty"
                )
            }
        }
    }

    func testEmptyEnvironmentIsNotTestHost() {
        XCTAssertFalse(AppLaunchEnvironment(environment: [:]).isUnitTestHost)
    }

    func testNormalEnvironmentIsNotTestHost() {
        XCTAssertFalse(
            AppLaunchEnvironment(environment: ["HOME": "/Users/developer", "PATH": "/usr/bin"])
                .isUnitTestHost
        )
    }

    func testRunningTestProcessIsTestHost() {
        XCTAssertTrue(AppLaunchEnvironment().isUnitTestHost)
    }
}
