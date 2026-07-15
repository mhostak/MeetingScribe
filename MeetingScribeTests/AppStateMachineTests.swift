import AppKit
import XCTest
@testable import MeetingScribe

final class AppStateMachineTests: XCTestCase {
    private let allowedTransitions: [AppStatus: Set<AppStatus>] = [
        .idle: [.preparing, .failed],
        .preparing: [.recording, .failed],
        .recording: [.stopping, .failed],
        .stopping: [.transcribing, .analyzing, .exporting, .completed, .failed],
        .transcribing: [.analyzing, .exporting, .failed],
        .analyzing: [.exporting, .failed],
        .exporting: [.completed, .failed],
        .completed: [.idle, .preparing, .failed],
        .failed: [.idle, .preparing],
    ]

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

    func testEveryDocumentedTransitionIsAccepted() throws {
        for (source, destinations) in allowedTransitions {
            for destination in destinations {
                var machine = AppStateMachine(status: source)
                try machine.transition(to: destination)
                XCTAssertEqual(machine.status, destination, "\(source) -> \(destination)")
            }
        }
    }

    func testEveryOtherTransitionIsRejectedWithoutChangingState() {
        for source in AppStatus.allCases {
            let allowed = allowedTransitions[source, default: []]
            for destination in AppStatus.allCases where !allowed.contains(destination) {
                var machine = AppStateMachine(status: source)
                XCTAssertThrowsError(try machine.transition(to: destination)) { error in
                    XCTAssertEqual(
                        error as? AppStateTransitionError,
                        .invalidTransition(from: source, to: destination)
                    )
                }
                XCTAssertEqual(machine.status, source, "\(source) -> \(destination)")
            }
        }
    }

    func testMenuBarIconStateTracksRecordingProcessingAndAttention() {
        XCTAssertEqual(MenuBarIconState(status: .idle, hasRecovery: false), .idle)
        XCTAssertEqual(MenuBarIconState(status: .recording, hasRecovery: false), .recording)

        for status in AppStatus.allCases where status.isProcessing {
            XCTAssertEqual(MenuBarIconState(status: status, hasRecovery: false), .processing)
        }

        XCTAssertEqual(MenuBarIconState(status: .failed, hasRecovery: false), .attention)
        XCTAssertEqual(MenuBarIconState(status: .idle, hasRecovery: true), .attention)

        let idleImage = MenuBarIconRenderer.image(for: .idle, colorScheme: .dark)
        XCTAssertEqual(idleImage.size, NSSize(width: 18, height: 18))
    }

    func testActiveMenuBarStatesTakePriorityOverRecoveryBadge() {
        XCTAssertEqual(MenuBarIconState(status: .recording, hasRecovery: true), .recording)
        XCTAssertEqual(MenuBarIconState(status: .transcribing, hasRecovery: true), .processing)
    }
}
