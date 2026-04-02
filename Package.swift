// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Last9RUM",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(
            name: "Last9RUM",
            targets: ["Last9RUM"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.3.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.3.0"),
    ],
    targets: [
        .target(
            name: "Last9RUM",
            dependencies: [
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift"),
                .product(name: "ResourceExtension", package: "opentelemetry-swift"),
                .product(name: "NetworkStatus", package: "opentelemetry-swift"),
            ],
            path: "Sources/Last9RUM"
        ),
        .testTarget(
            name: "Last9RUMTests",
            dependencies: ["Last9RUM"],
            path: "Tests/Last9RUMTests"
        ),
        .executableTarget(
            name: "Last9RUMTestApp",
            dependencies: ["Last9RUM"],
            path: "Sources/Last9RUMTestApp"
        ),
    ]
)
