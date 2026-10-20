// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownRendering",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MarkdownRendering", targets: ["MarkdownRendering"])
    ],
    dependencies: [
        .package(url: "https://github.com/brokenhandsio/cmark-gfm.git", from: "2.1.0")
    ],
    targets: [
        .target(
            name: "CMarkGFMBridge",
            dependencies: [
                .product(name: "cmark", package: "cmark-gfm")
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "MarkdownRendering",
            dependencies: ["CMarkGFMBridge"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MarkdownRenderingTests",
            dependencies: ["MarkdownRendering"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
