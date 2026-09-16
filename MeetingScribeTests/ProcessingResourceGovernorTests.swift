import XCTest
@testable import MeetingScribe

final class ProcessingResourceGovernorTests: XCTestCase {
    func testHealthyCaptureCanRunSingleWorker() {
        var governor = ProcessingResourceGovernor(limits: .init(
            pauseBelowStorageBytes: 100,
            resumeAboveStorageBytes: 150
        ))

        let decision = governor.decision(
            for: .init(
                captureLifecycle: .recording,
                captureIsHealthy: true,
                availableStorageBytes: 200
            ),
            workerIsRunning: false
        )

        XCTAssertEqual(decision, .allow)
    }

    func testPressureCancelsRunningWorkerAndRequiresHealthyResume() {
        var governor = ProcessingResourceGovernor()
        let pressured = ProcessingResourceSnapshot(
            captureLifecycle: .recording,
            captureIsHealthy: true,
            memoryPressure: .warning
        )

        XCTAssertEqual(
            governor.decision(for: pressured, workerIsRunning: true),
            .cancelRunning([.memoryPressure(.warning)])
        )
        XCTAssertEqual(
            governor.decision(for: pressured, workerIsRunning: false),
            .hold([.memoryPressure(.warning)])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .recording, captureIsHealthy: true),
                workerIsRunning: false
            ),
            .allow
        )
    }

    func testStoragePauseUsesHysteresisBeforeResuming() {
        var governor = ProcessingResourceGovernor(limits: .init(
            pauseBelowStorageBytes: 100,
            resumeAboveStorageBytes: 150
        ))

        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, availableStorageBytes: 99),
                workerIsRunning: false
            ),
            .hold([.storageReserve])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, availableStorageBytes: 125),
                workerIsRunning: false
            ),
            .hold([])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, availableStorageBytes: 150),
                workerIsRunning: false
            ),
            .allow
        )
    }

    func testUnhealthyCaptureCancelsBackgroundWorker() {
        var governor = ProcessingResourceGovernor()

        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .recording, captureIsHealthy: false),
                workerIsRunning: true
            ),
            .cancelRunning([.captureUnhealthy])
        )
    }
}
