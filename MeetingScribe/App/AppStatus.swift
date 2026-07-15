import AppKit
import Foundation
import SwiftUI

enum AppStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case transcribing
    case analyzing
    case exporting
    case completed
    case failed

    var menuBarSystemImage: String {
        "waveform"
    }

    var isProcessing: Bool {
        switch self {
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            return true
        case .idle, .recording, .completed, .failed:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .transcribing: return "Transcribing"
        case .analyzing: return "Analyzing"
        case .exporting: return "Exporting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

enum MenuBarIconState: String, Equatable, Sendable {
    case idle
    case recording
    case processing
    case attention

    init(status: AppStatus, hasRecovery: Bool) {
        if status == .recording {
            self = .recording
        } else if status.isProcessing {
            self = .processing
        } else if status == .failed || hasRecovery {
            self = .attention
        } else {
            self = .idle
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "MeetingScribe ready"
        case .recording: return "MeetingScribe recording"
        case .processing: return "MeetingScribe processing"
        case .attention: return "MeetingScribe needs attention"
        }
    }
}

enum MenuBarIconRenderer {
    static func image(for state: MenuBarIconState, colorScheme: ColorScheme) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            let baseColor: NSColor = colorScheme == .dark ? .white : .black
            drawWaveform(in: rect, color: baseColor)
            drawBadge(state, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawWaveform(in rect: NSRect, color: NSColor) {
        let heights: [CGFloat] = [6, 11, 16, 10, 6]
        color.setFill()
        for (index, height) in heights.enumerated() {
            let x = rect.minX + 1 + CGFloat(index) * 3.1
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: 2.1, height: height)
            NSBezierPath(roundedRect: bar, xRadius: 1.05, yRadius: 1.05).fill()
        }
    }

    private static func drawBadge(_ state: MenuBarIconState, in rect: NSRect) {
        let center = NSPoint(x: rect.maxX - 3.8, y: rect.maxY - 4.6)
        switch state {
        case .idle:
            break
        case .recording:
            drawDot(center: center, color: .systemRed)
        case .attention:
            drawDot(center: center, color: .systemOrange)
        case .processing:
            let ringRect = NSRect(x: center.x - 3.2, y: center.y - 3.2, width: 6.4, height: 6.4)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: 3.2, startAngle: 35, endAngle: 305)
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            NSColor.systemBlue.setStroke()
            ring.stroke()
            NSColor.systemBlue.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: ringRect.midX - 0.8,
                    y: ringRect.midY - 0.8,
                    width: 1.6,
                    height: 1.6
                )
            ).fill()
        }
    }

    private static func drawDot(center: NSPoint, color: NSColor) {
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        ).fill()
    }
}

struct AppStateMachine: Sendable {
    private(set) var status: AppStatus

    init(status: AppStatus = .idle) {
        self.status = status
    }

    mutating func transition(to nextStatus: AppStatus) throws {
        guard Self.allowedTransitions[status, default: []].contains(nextStatus) else {
            throw AppStateTransitionError.invalidTransition(from: status, to: nextStatus)
        }

        status = nextStatus
    }

    private static let allowedTransitions: [AppStatus: Set<AppStatus>] = [
        .idle: [.preparing, .failed],
        .preparing: [.recording, .failed],
        .recording: [.stopping, .failed],
        .stopping: [.transcribing, .analyzing, .exporting, .completed, .failed],
        .transcribing: [.analyzing, .exporting, .failed],
        .analyzing: [.exporting, .failed],
        .exporting: [.completed, .failed],
        .completed: [.idle, .preparing, .failed],
        .failed: [.idle, .preparing]
    ]
}

enum AppStateTransitionError: Error, Equatable, LocalizedError {
    case invalidTransition(from: AppStatus, to: AppStatus)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, to):
            return "Invalid application state transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
