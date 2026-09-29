// swift-tools-version: 6.4

import PackageDescription

// The App's side of ArkDeck. The Runtime (daemon, engine, storage, providers)
// and the CLI are Rust (CHG-2026-074); Swift carries no Runtime semantics, and
// ArchitectureBoundaryContractTests refuses any target that brings them back.

// What Xcode 27 turns on for new Swift code. Approachable concurrency: a
// nonisolated async function runs on its caller's actor unless it is marked
// @concurrent, and a conformance takes the isolation of its type. It changes
// how those functions are called, so every target that links them compiles
// with it. Member import visibility: a file sees only the members of modules
// it imports itself.
let approachableConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]
let swiftSettings: [SwiftSetting] =
  approachableConcurrency + [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
  name: "ArkDeckKit",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "ArkDeckClientKit", targets: ["ArkDeckClientKit"]),
    .library(name: "ArkDeckCore", targets: ["ArkDeckCore"]),
    .library(name: "ArkDeckTraceAdapter", targets: ["ArkDeckTraceAdapter"]),
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
      ],
      swiftSettings: swiftSettings),
    .target(
      name: "ArkDeckCore",
      swiftSettings: swiftSettings + [.strictMemorySafety()]),
    // ArkTrace owns every shared engine source. ArkDeck keeps only its fixed
    // product profile and app-bundle adapter in this target.
    .target(
      name: "ArkDeckTraceAdapter",
      dependencies: [
        .product(name: "ArkTraceAppSupport", package: "ArkTrace"),
        .product(name: "ArkTraceCore", package: "ArkTrace"),
        .product(name: "ArkTraceRuntime", package: "ArkTrace"),
      ],
      swiftSettings: swiftSettings),
    // The fake HDC the App UI tests point the App at.
    .executableTarget(
      name: "ArkDeckFakeHDCFixture",
      path: "Tests/ArkDeckFakeHDCFixture",
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "ArkDeckClientKitTests", dependencies: ["ArkDeckClientKit", "ArkDeckCore"],
      swiftSettings: approachableConcurrency),
    .testTarget(
      name: "ArkDeckCoreTests", dependencies: ["ArkDeckCore"],
      swiftSettings: approachableConcurrency),
    .testTarget(
      name: "ArkDeckTraceAdapterTests",
      dependencies: [
        "ArkDeckTraceAdapter",
        .product(name: "ArkTraceAppSupport", package: "ArkTrace"),
        .product(name: "ArkTraceRuntime", package: "ArkTrace"),
      ],
      swiftSettings: approachableConcurrency),
    .testTarget(
      name: "ArkDeckContractTests",
      dependencies: [
        "ArkDeckClientKit",
        "ArkDeckCore",
        "ArkDeckFakeHDCFixture",
      ],
      // Recorded contract inputs the Rust replays read by path (rust/scripts);
      // no Swift test loads them as resources.
      exclude: [
        "Fixtures/CLI",
        "Fixtures/ControlFrames",
        "Fixtures/SessionStorage",
        "Fixtures/Unicode",
      ],
      resources: [
        // Golden resource declaration is owned by TASK-I5-001 (CHG-2026-005). `.copy` preserves
        // the versioned `Golden/<version>/...` directory tree inside Bundle.module so registry
        // paths stay valid and future pack versions cannot collide.
        .copy("Fixtures/HDC/Golden"),
        .copy("Fixtures/HDC/Probes"),
      ],
      swiftSettings: swiftSettings
    ),
  ]
)
