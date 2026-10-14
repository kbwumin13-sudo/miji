// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Miji",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MijiCore", targets: ["MijiCore"]), .executable(name: "Miji", targets: ["MijiApp"]), .executable(name: "miji-cli", targets: ["MijiCLI"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CContentIndex", dependencies: ["CSQLite"]),
        .target(name: "COilFind", path: "Vendor/OilFind/Sources/COilFind", publicHeadersPath: "include"),
        .target(name: "OilFindCore", dependencies: ["COilFind"], path: "Vendor/OilFind/Sources/OilFindCore"),
        .target(name: "MijiCore", dependencies: ["CSQLite", "OilFindCore", "CContentIndex"]),
        .executableTarget(name: "MijiApp", dependencies: ["MijiCore"]),
        .executableTarget(name: "MijiCLI", dependencies: ["MijiCore"]),
        .testTarget(name: "MijiCoreTests", dependencies: ["MijiCore"]),
        .testTarget(name: "MijiAppTests", dependencies: ["MijiApp", "MijiCore"])
    ],
    swiftLanguageVersions: [.v5]
)
