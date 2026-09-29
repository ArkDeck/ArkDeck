// swift-tools-version: 6.3

import PackageDescription

// The App's side of ArkDeck. The Runtime (daemon, engine, storage, providers)
// and the CLI are Rust (CHG-2026-074); Swift carries no Runtime semantics, and
// ArchitectureBoundaryContractTests refuses any target that brings them back.
let package = Package(
  name: "ArkDeckKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArkDeckClientKit", targets: ["ArkDeckClientKit"]),
    .library(name: "ArkDeckCore", targets: ["ArkDeckCore"]),
    .library(name: "ArkDeckRuntime", targets: ["ArkDeckRuntime"]),
    .library(name: "ArkDeckTraceAdapter", targets: ["ArkDeckTraceAdapter"]),
    .library(name: "ArkDeckAgentClient", targets: ["ArkDeckAgentClient"]),
    .library(name: "ArkDeckBootstrap", targets: ["ArkDeckBootstrap"]),
    .executable(name: "ArkDeckFakeHDCFixture", targets: ["ArkDeckFakeHDCFixture"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/orlandos-nl/Citadel.git",
      exact: "0.12.1"),
    .package(
      url: "https://github.com/Wellz26/swift-nio-ssh.git",
      exact: "0.3.4"),
    .package(
      url: "https://github.com/apple/swift-nio.git",
      exact: "2.101.3"),
    .package(
      url: "https://github.com/apple/swift-crypto.git",
      exact: "3.15.1"),
    .package(
      url: "https://github.com/apple/swift-log.git",
      exact: "1.15.0"),
    .package(
      url: "https://github.com/ArkDeck/ArkTrace.git",
      revision: "9172c9525f954ec397e0555d7d03cd4367f3efcf"),
  ],
  targets: [
    // The App's client library. It carries the App-side SSH remote build
    // source, so the SSH stack is linked here.
    .target(
      name: "ArkDeckClientKit",
      dependencies: [
        "ArkDeckCore",
        .product(name: "Citadel", package: "Citadel"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "Logging", package: "swift-log"),
      ]),
    .target(
      name: "ArkDeckCore",
      swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkDeckRuntime", dependencies: ["ArkDeckCore"]),
    // ArkTrace owns every shared engine source. ArkDeck keeps only its fixed
    // product profile and app-bundle adapter in this target.
    .target(
      name: "ArkDeckTraceAdapter",
      dependencies: [
        .product(name: "ArkTraceAppSupport", package: "ArkTrace"),
        .product(name: "ArkTraceRuntime", package: "ArkTrace"),
      ]),
    .target(
      name: "ArkDeckAgentClient",
      dependencies: ["ArkDeckCore"]
    ),
    // Current-user, pre-daemon typed bundle/tool registry. It owns no launchd
    // command surface and grants no Runtime execution authority.
    .target(
      name: "ArkDeckBootstrap",
      dependencies: ["ArkDeckCore"],
      linkerSettings: [.linkedFramework("Security")]
    ),
    // The fake HDC the App UI tests point the App at.
    .executableTarget(
      name: "ArkDeckFakeHDCFixture",
      path: "Tests/ArkDeckFakeHDCFixture"
    ),
    .testTarget(name: "ArkDeckClientKitTests", dependencies: ["ArkDeckClientKit", "ArkDeckCore"]),
    .testTarget(name: "ArkDeckCoreTests", dependencies: ["ArkDeckCore"]),
    .testTarget(
      name: "ArkDeckTraceAdapterTests",
      dependencies: [
        "ArkDeckTraceAdapter",
        .product(name: "ArkTraceAppSupport", package: "ArkTrace"),
        .product(name: "ArkTraceRuntime", package: "ArkTrace"),
      ]),
    .testTarget(
      name: "ArkDeckContractTests",
      dependencies: [
        "ArkDeckClientKit",
        "ArkDeckCore",
        "ArkDeckRuntime",
        "ArkDeckAgentClient",
        "ArkDeckBootstrap",
        "ArkDeckFakeHDCFixture",
      ],
      resources: [
        // Golden resource declaration is owned by TASK-I5-001 (CHG-2026-005). `.copy` preserves
        // the versioned `Golden/<version>/...` directory tree inside Bundle.module so registry
        // paths stay valid and future pack versions cannot collide.
        .copy("Fixtures/HDC/Golden"),
        .copy("Fixtures/HDC/Probes"),
      ]
    ),
  ]
)
