import Foundation

final class ReadinessAnalysisStatusStore: ReadinessAnalysisStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var status: AnalysisToolStatus

    init(status: AnalysisToolStatus = .unknown) {
        self.status = status
    }

    func update(_ status: AnalysisToolStatus) {
        lock.withLock {
            self.status = status
        }
    }

    func status() async -> AnalysisToolStatus {
        lock.withLock {
            status
        }
    }
}
