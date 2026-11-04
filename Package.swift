// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenQuotaKit",
    // Only the platforms the CI workflow builds: Linux (both modules' logic), macOS and the iOS Simulator.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TokenQuota", targets: ["TokenQuota"]),
        .library(name: "TokenQuotaUI", targets: ["TokenQuotaUI"]),
    ],
    targets: [
        .target(name: "TokenQuota"),
        // Scenario engine (portable) + SwiftUI console (compiled only where SwiftUI exists).
        .target(name: "TokenQuotaUI", dependencies: ["TokenQuota"]),
        .testTarget(name: "TokenQuotaTests", dependencies: ["TokenQuota"]),
        // Compiles against the public API only (no @testable), the way an app's transport would.
        .testTarget(name: "TokenQuotaPublicAPITests", dependencies: ["TokenQuota"]),
        // Runs every demo scenario and asserts the outcome its README promises.
        .testTarget(name: "TokenQuotaUITests", dependencies: ["TokenQuotaUI", "TokenQuota"]),
    ]
)
