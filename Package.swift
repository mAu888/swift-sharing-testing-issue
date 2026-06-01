// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedIsolationRepro",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .testTarget(
            name: "SharedIsolationReproTests",
            dependencies: [
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ]
        )
    ]
)

package.dependencies = [
    // Pins against swift-sharing's `main` branch to show the latest development
    // changes still do not fix the bug. CI runs `swift package update` so each
    // run resolves main's current HEAD (it will turn green if/when the fix lands).
    .package(url: "https://github.com/pointfreeco/swift-sharing.git", branch: "main"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.0"),
]
