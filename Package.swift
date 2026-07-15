// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MeetingScribeCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MeetingScribe", targets: ["MeetingScribe"])
    ],
    dependencies: [
        .package(path: "Packages/WhisperBinary")
    ],
    targets: [
        .target(
            name: "MeetingScribe",
            dependencies: [
                .product(name: "whisper", package: "WhisperBinary")
            ],
            path: "MeetingScribe",
            exclude: [
                "MeetingScribe.entitlements",
                "Resources",
                "App/MeetingScribeApp.swift",
                "App/MenuBarView.swift",
                "App/CalendarEventPickerView.swift",
                "App/SettingsView.swift",
                "App/RecordingsWindow.swift",
                "App/RecordingsWindowModel.swift"
            ]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "MeetingScribeTests"
        )
    ]
)
