// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkAndPlay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WorkAndPlay", targets: ["WorkAndPlay"]),
        .executable(name: "ChromeNativeHost", targets: ["ChromeNativeHost"]),
        .executable(name: "WorkAndPlayReport", targets: ["WorkAndPlayReport"]),
        .library(name: "TimeCore", targets: ["TimeCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TimeCore"),
        .target(name: "TimeStore", dependencies: ["TimeCore", "CSQLite"]),
        .target(name: "ChromeBridge"),
        .executableTarget(name: "ChromeNativeHost", dependencies: ["ChromeBridge"]),
        .executableTarget(name: "WorkAndPlay", dependencies: ["TimeCore", "TimeStore", "ChromeBridge"]),
        .executableTarget(name: "WorkAndPlayReport", dependencies: ["TimeStore"]),
        .executableTarget(name: "Verification", dependencies: ["TimeCore", "TimeStore", "ChromeBridge"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
