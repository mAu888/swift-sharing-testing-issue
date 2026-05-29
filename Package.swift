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
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.8.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.0"),
]
