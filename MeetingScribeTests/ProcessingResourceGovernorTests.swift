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
        // Inside the hysteresis band the hold still names the reason, so the UI
        // can explain an otherwise indefinite pause.
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, availableStorageBytes: 125),
                workerIsRunning: false
            ),
            .hold([.storageReserve])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, availableStorageBytes: 150),
                workerIsRunning: false
            ),
            .allow
        )
    }

    /// The background reserve stays its own value but must never sit below the
    /// reserve capture itself refuses to start on.
    func testBackgroundReserveRespectsCaptureMinimumAndKeepsHysteresis() {
        let defaults = ProcessingResourceLimits()
        let unchanged = ProcessingResourceLimits.backgroundReserve(captureMinimumBytes: 1)
        XCTAssertEqual(unchanged.pauseBelowStorageBytes, defaults.pauseBelowStorageBytes)
        XCTAssertEqual(unchanged.resumeAboveStorageBytes, defaults.resumeAboveStorageBytes)

        let raised = ProcessingResourceLimits.backgroundReserve(
            captureMinimumBytes: 10 * 1_073_741_824
        )
        XCTAssertEqual(raised.pauseBelowStorageBytes, 10 * 1_073_741_824)
        XCTAssertGreaterThan(raised.resumeAboveStorageBytes, raised.pauseBelowStorageBytes)
    }

    /// A repeated hold has to keep naming its reason; an empty reason list used
    /// to make an indefinite pause unexplainable in the UI.
    func testHoldInsideResumeBandStillReportsTheBlockingReason() {
        var governor = ProcessingResourceGovernor()
        let pressured = ProcessingResourceSnapshot(
            captureLifecycle: .idle,
            memoryPressure: .critical
        )

        XCTAssertEqual(
            governor.decision(for: pressured, workerIsRunning: false),
            .hold([.memoryPressure(.critical)])
        )
        XCTAssertEqual(
            governor.decision(for: pressured, workerIsRunning: false),
            .hold([.memoryPressure(.critical)])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, memoryPressure: .normal),
                workerIsRunning: false
            ),
            .allow
        )
    }

    /// `warning` pressure and `serious` thermals are the steady state of a
    /// passively cooled Mac. Stopping background work there left the queue
    /// permanently paused with nothing recording.
    func testOrdinaryPressureDoesNotWithholdWorkWhileCaptureIsIdle() {
        var governor = ProcessingResourceGovernor()

        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, memoryPressure: .warning,
                           thermalState: .serious),
                workerIsRunning: false
            ),
            .allow
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .recording, captureIsHealthy: true,
                           memoryPressure: .warning),
                workerIsRunning: false
            ),
            .hold([.memoryPressure(.warning)])
        )
        // Stopping the capture removes the only thing that pause protected.
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, memoryPressure: .warning),
                workerIsRunning: false
            ),
            .allow
        )
    }

    func testCriticalLevelsWithholdWorkEvenWithoutCapture() {
        var governor = ProcessingResourceGovernor()

        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, thermalState: .critical),
                workerIsRunning: true
            ),
            .cancelRunning([.thermal(.critical)])
        )
        XCTAssertEqual(
            governor.decision(
                for: .init(captureLifecycle: .idle, memoryPressure: .critical),
                workerIsRunning: false
            ),
            .hold([.memoryPressure(.critical)])
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
