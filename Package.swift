// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecureSSHTerminal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SecureSSHTerminal", targets: ["SecureSSHTerminal"]),
        .library(name: "SecureSSHCore", targets: ["SecureSSHCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "SecureSSHCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SecureSSHTerminal",
            dependencies: [
                "SecureSSHCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SecureSSHCoreTests",
            dependencies: ["SecureSSHCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
