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
    // Points at the proposed fix (pinned to the exact reviewed commit, not a
    // mutable branch). `main` of this repo uses released 2.8.0 and reproduces
    // the bug.
    //   Branch: https://github.com/mAu888/swift-sharing/tree/fix/filestoragekey-immediate-scheduler-dropped-writes
    //   PR:     https://github.com/pointfreeco/swift-sharing/pull/213
    .package(url: "https://github.com/mAu888/swift-sharing.git", revision: "b0ac8081b841704d78e0be5f95c8fffcd209eaa4"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.0"),
]
