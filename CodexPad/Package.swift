// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexPad",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CodexPadDomain", targets: ["CodexPadDomain"]),
        .library(
            name: "CodexPadApplication",
            targets: ["CodexPadApplication"]
        ),
        .library(
            name: "CodexPadProtocolBridge",
            targets: ["CodexPadProtocolBridge"]
        ),
    ],
    targets: [
        .target(
            name: "CodexPadDomain",
            path: "CodexPad/Domain"
        ),
        .target(
            name: "CodexPadApplication",
            dependencies: [
                "CodexPadDomain",
                "CodexPadProtocolBridge",
            ],
            path: "CodexPad/Application"
        ),
        .target(
            name: "CodexPadProtocolBridge",
            dependencies: ["CodexPadDomain"],
            path: "CodexPad/ProtocolBridge"
        ),
        .testTarget(
            name: "CodexPadDomainTests",
            dependencies: [
                "CodexPadDomain",
                "CodexPadApplication",
                "CodexPadProtocolBridge",
            ],
            path: "Tests/CodexPadDomainTests"
        ),
    ]
)
