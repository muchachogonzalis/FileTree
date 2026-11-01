// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileTree",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FileTree", targets: ["FileTree"]),
    ],
    targets: [
        // Scanning engine and data model, no UI. Tested by FileTreeCoreTests.
        .target(name: "FileTreeCore"),
        // The AppKit application. Tested by FileTreeTests, without windows on the screen.
        .executableTarget(name: "FileTree", dependencies: ["FileTreeCore"]),
        .testTarget(name: "FileTreeCoreTests", dependencies: ["FileTreeCore"]),
        .testTarget(name: "FileTreeTests", dependencies: ["FileTree"]),
    ]
)
