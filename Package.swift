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
    targets: [
        .target(
            name: "MeetingScribe",
            path: "MeetingScribe",
            exclude: [
                "App/MeetingScribeApp.swift",
                "App/MenuBarView.swift"
            ]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "MeetingScribeTests"
        )
    ]
)
