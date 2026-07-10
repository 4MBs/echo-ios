// swift-tools-version:5.9
// Thin C shim over libopus. Exists because opus_encoder_ctl() is a true
// variadic C function, which Swift cannot call portably; the shim exposes
// plain-C wrappers instead. libopus itself is built from source by the
// alta/swift-opus package (Copus product).
import PackageDescription

let package = Package(
    name: "OpusShim",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "OpusShim", targets: ["OpusShim"])
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus", exact: "0.0.2")
    ],
    targets: [
        .target(
            name: "OpusShim",
            dependencies: [.product(name: "Copus", package: "swift-opus")]
        )
    ]
)
