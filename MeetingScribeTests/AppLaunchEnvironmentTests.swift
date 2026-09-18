import XCTest
@testable import MeetingScribe

final class AppLaunchEnvironmentTests: XCTestCase {
    func testDetectsEachTestHostEnvironmentKey() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            for value in ["test-host-value", ""] {
                XCTAssertTrue(
                    AppLaunchEnvironment(environment: [key: value], isXCTestLoaded: { false })
                        .isUnitTestHost,
                    "Expected \(key) to identify a test host even when its value is empty"
                )
            }
        }
    }

    func testEmptyEnvironmentIsNotTestHost() {
        XCTAssertFalse(
            AppLaunchEnvironment(environment: [:], isXCTestLoaded: { false }).isUnitTestHost
        )
    }

    func testEmptyEnvironmentWithXCTestLoadedIsTestHost() {
        XCTAssertTrue(
            AppLaunchEnvironment(environment: [:], isXCTestLoaded: { true }).isUnitTestHost
        )
    }

    func testNormalEnvironmentIsNotTestHost() {
        XCTAssertFalse(
            AppLaunchEnvironment(
                environment: ["HOME": "/Users/developer", "PATH": "/usr/bin"],
                isXCTestLoaded: { false }
            ).isUnitTestHost
        )
    }

    func testRunningTestProcessIsTestHost() {
        XCTAssertTrue(AppLaunchEnvironment().isUnitTestHost)
    }
}
