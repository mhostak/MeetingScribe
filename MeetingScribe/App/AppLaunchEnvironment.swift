import Foundation

struct AppLaunchEnvironment: Sendable {
    let isUnitTestHost: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isUnitTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
