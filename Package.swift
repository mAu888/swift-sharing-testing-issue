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
    // Points at the proposed fix to demonstrate the suite passing. `main` of
    // this repo uses the released swift-sharing 2.8.0, which reproduces the bug.
    //
    // Pinned to the exact reviewed commit (immutable) rather than a mutable
    // branch ref, so this build can't silently drift if the branch moves.
    //   Branch: https://github.com/mAu888/swift-sharing/tree/fix/filestoragekey-immediate-scheduler-dropped-writes
    //   PR:     https://github.com/pointfreeco/swift-sharing/pull/213
    .package(
        url: "https://github.com/mAu888/swift-sharing.git",
        revision: "b0ac8081b841704d78e0be5f95c8fffcd209eaa4"
    ),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.0"),
]
