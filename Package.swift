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
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .target(
            name: "MeetingScribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "MeetingScribe",
            exclude: [
                "Info.plist",
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
