// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "InputShare",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "inputshare", targets: ["InputShareCLI"]),
        .executable(name: "MouseApp", targets: ["MouseApp"]),
        .library(name: "InputShareShared", targets: ["InputShareShared"]),
        .library(name: "InputShareTransport", targets: ["InputShareTransport"]),
        .library(name: "InputShareCapture", targets: ["InputShareCapture"]),
        .library(name: "InputShareInjection", targets: ["InputShareInjection"]),
        .library(name: "InputShareEdge", targets: ["InputShareEdge"]),
        .library(name: "InputShareDiscovery", targets: ["InputShareDiscovery"])
    ],
    targets: [
        .target(name: "InputShareShared"),
        .target(name: "InputShareTransport", dependencies: ["InputShareShared"]),
        .target(name: "InputShareCapture", dependencies: ["InputShareShared"]),
        .target(name: "InputShareInjection", dependencies: ["InputShareShared", "InputShareCapture"]),
        .target(name: "InputShareEdge", dependencies: ["InputShareShared", "InputShareCapture"]),
        .target(name: "InputShareDiscovery", dependencies: ["InputShareShared"]),
        .executableTarget(
            name: "InputShareCLI",
            dependencies: [
                "InputShareShared",
                "InputShareTransport",
                "InputShareCapture",
                "InputShareInjection",
                "InputShareEdge"
            ]
        ),
        .executableTarget(
            name: "MouseApp",
            dependencies: [
                "InputShareShared",
                "InputShareTransport",
                "InputShareCapture",
                "InputShareInjection",
                "InputShareEdge",
                "InputShareDiscovery"
            ]
        )
    ]
)
