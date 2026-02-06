// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "InputShare",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "inputshare", targets: ["InputShareCLI"]),
        .library(name: "InputShareShared", targets: ["InputShareShared"]),
        .library(name: "InputShareTransport", targets: ["InputShareTransport"]),
        .library(name: "InputShareCapture", targets: ["InputShareCapture"]),
        .library(name: "InputShareInjection", targets: ["InputShareInjection"])
    ],
    targets: [
        .target(name: "InputShareShared"),
        .target(name: "InputShareTransport", dependencies: ["InputShareShared"]),
        .target(name: "InputShareCapture", dependencies: ["InputShareShared"]),
        .target(name: "InputShareInjection", dependencies: ["InputShareShared", "InputShareCapture"]),
        .executableTarget(
            name: "InputShareCLI",
            dependencies: [
                "InputShareShared",
                "InputShareTransport",
                "InputShareCapture",
                "InputShareInjection"
            ]
        )
    ]
)
