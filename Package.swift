// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ohayo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Ohayo",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Ohayo",
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "OhayoTests",
            dependencies: ["Ohayo"],
            path: "Tests/OhayoTests"
        ),
    ]
)
