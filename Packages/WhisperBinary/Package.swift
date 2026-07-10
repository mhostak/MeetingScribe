// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhisperBinary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.1/whisper-v1.8.1-xcframework.zip",
            checksum: "fc02a7efe6ede7a73c032ee2e67027766e49e3ff8cb35aa8651519ec1ab97cb7"
        )
    ]
)
