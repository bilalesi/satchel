// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vault",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
        .executable(name: "Vault", targets: ["Vault"]),
    ],
    dependencies: [
        // The only third-party dependency: Argon2id, XChaCha20-Poly1305, secure memory.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "VaultCore",
            // Raw C API on purpose: the Swift wrapper copies secrets into plain arrays
            // and has no secure allocator. We call libsodium on SecureBytes buffers directly.
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Vault",
            dependencies: ["VaultCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VaultCoreTests",
            dependencies: ["VaultCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
