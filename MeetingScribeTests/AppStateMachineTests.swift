import XCTest
@testable import MeetingScribe

final class AppStateMachineTests: XCTestCase {
    func testHappyPathForPhaseOne() throws {
        var machine = AppStateMachine()

        try machine.transition(to: .preparing)
        try machine.transition(to: .recording)
        try machine.transition(to: .stopping)
        try machine.transition(to: .completed)

        XCTAssertEqual(machine.status, .completed)
    }

    func testSecondRecordingCannotStartWhileRecording() throws {
        var machine = AppStateMachine(status: .recording)

        XCTAssertThrowsError(try machine.transition(to: .preparing)) { error in
            XCTAssertEqual(
                error as? AppStateTransitionError,
                .invalidTransition(from: .recording, to: .preparing)
            )
        }
        XCTAssertEqual(machine.status, .recording)
    }

    func testFullProcessingPathIsAvailableForLaterPhases() throws {
        var machine = AppStateMachine(status: .stopping)

        try machine.transition(to: .transcribing)
        try machine.transition(to: .analyzing)
        try machine.transition(to: .exporting)
        try machine.transition(to: .completed)

        XCTAssertEqual(machine.status, .completed)
    }
}
