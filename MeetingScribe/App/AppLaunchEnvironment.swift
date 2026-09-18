import Foundation

struct AppLaunchEnvironment: Sendable {
    let isUnitTestHost: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestLoaded: () -> Bool = { NSClassFromString("XCTestCase") != nil }
    ) {
        isUnitTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            // SwiftPM test hosts may not set any of the environment keys above.
            || isXCTestLoaded()
    }
}
