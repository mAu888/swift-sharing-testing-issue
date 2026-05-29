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
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ]
        )
    ]
)

package.dependencies = [
    // Points at the proposed fix on the fork branch to demonstrate the suite
    // passing. `main` of this repo uses the released swift-sharing 2.8.0, which
    // reproduces the bug.
    .package(
        url: "https://github.com/mAu888/swift-sharing.git",
        branch: "fix/filestoragekey-immediate-scheduler-dropped-writes"
    ),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.0"),
]
