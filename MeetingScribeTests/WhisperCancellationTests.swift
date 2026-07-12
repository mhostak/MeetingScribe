import XCTest
@testable import MeetingScribe

final class WhisperCancellationTests: XCTestCase {
    func testAbortCallbackReadsCancellationTokenThroughCUserData() {
        let token = WhisperCancellationToken()
        let userData = Unmanaged.passUnretained(token).toOpaque()

        XCTAssertFalse(whisperCancellationCallback(userData))
        token.cancel()
        XCTAssertTrue(whisperCancellationCallback(userData))
    }

    func testAbortCallbackWithoutUserDataDoesNotAbort() {
        XCTAssertFalse(whisperCancellationCallback(nil))
    }
}
