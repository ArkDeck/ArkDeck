// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ArkDeckKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ArkDeckCore", targets: ["ArkDeckCore"]),
    .library(name: "ArkDeckProcess", targets: ["ArkDeckProcess"]),
    .library(name: "ArkDeckRuntime", targets: ["ArkDeckRuntime"]),
    .library(name: "ArkDeckOpenHarmony", targets: ["ArkDeckOpenHarmony"]),
    .library(name: "ArkDeckHarness", targets: ["ArkDeckHarness"]),
    .library(name: "ArkDeckWorkflows", targets: ["ArkDeckWorkflows"]),
    .library(name: "ArkDeckStorage", targets: ["ArkDeckStorage"]),
    .executable(name: "arkdeck", targets: ["ArkDeckCLI"]),
    .library(name: "ArkDeckAgentDaemon", targets: ["ArkDeckAgentDaemon"]),
    .library(name: "ArkDeckAgentClient", targets: ["ArkDeckAgentClient"]),
    .executable(name: "arkdeck-agentd", targets: ["ArkDeckAgentDaemonMain"]),
    .executable(name: "ArkDeckJournalCrashFixture", targets: ["ArkDeckJournalCrashFixture"]),
    .executable(name: "ArkDeckRuntimePortFixture", targets: ["ArkDeckRuntimePortFixture"]),
    .executable(name: "ArkDeckFakeHDCFixture", targets: ["ArkDeckFakeHDCFixture"]),
    .executable(name: "ArkDeckFakeRockchipFixture", targets: ["ArkDeckFakeRockchipFixture"]),
    .executable(name: "ArkDeckEngineCrashFixture", targets: ["ArkDeckEngineCrashFixture"]),
  ],
  targets: [
    .target(name: "ArkDeckCore"),
    .target(name: "ArkDeckProcess", dependencies: ["ArkDeckCore"]),
    .target(name: "ArkDeckRuntime", dependencies: ["ArkDeckCore"]),
    .target(name: "ArkDeckOpenHarmony", dependencies: ["ArkDeckCore", "ArkDeckProcess"]),
    .target(
      name: "ArkDeckHarness",
      dependencies: ["ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "ArkDeckWorkflows",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckOpenHarmony",
        "ArkDeckStorage", "ArkDeckHarness",
      ],
      resources: [
        .copy("Resources/OpenHarmonyNativeCodeSign")
      ]),
    .target(name: "ArkDeckStorage", dependencies: ["ArkDeckCore"]),
    .executableTarget(
      name: "ArkDeckCLI",
      dependencies: ["ArkDeckCore", "ArkDeckRuntime", "ArkDeckWorkflows", "ArkDeckAgentClient"]
    ),
    .target(
      name: "ArkDeckAgentDaemon",
      dependencies: ["ArkDeckCore", "ArkDeckHarness", "ArkDeckStorage", "ArkDeckWorkflows"]
    ),
    .target(
      name: "ArkDeckAgentClient",
      dependencies: ["ArkDeckCore"]
    ),
    .executableTarget(
      name: "ArkDeckAgentDaemonMain",
      dependencies: ["ArkDeckAgentDaemon", "ArkDeckHarness", "ArkDeckStorage", "ArkDeckWorkflows"]
    ),
    .executableTarget(
      name: "ArkDeckJournalCrashFixture",
      dependencies: ["ArkDeckCore", "ArkDeckStorage"],
      path: "Tests/ArkDeckJournalCrashFixture"
    ),
    .executableTarget(
      name: "ArkDeckRuntimePortFixture",
      dependencies: ["ArkDeckRuntime"],
      path: "Tests/ArkDeckRuntimePortFixture"
    ),
    .executableTarget(
      name: "ArkDeckFakeHDCFixture",
      path: "Tests/ArkDeckFakeHDCFixture"
    ),
    .executableTarget(
      name: "ArkDeckFakeRockchipFixture",
      path: "Tests/ArkDeckFakeRockchipFixture"
    ),
    .executableTarget(
      name: "ArkDeckEngineCrashFixture",
      dependencies: ["ArkDeckCore", "ArkDeckOpenHarmony", "ArkDeckStorage", "ArkDeckWorkflows"],
      path: "Tests/ArkDeckEngineCrashFixture"
    ),
    .testTarget(name: "ArkDeckCoreTests", dependencies: ["ArkDeckCore"]),
    .testTarget(
      name: "ArkDeckContractTests",
      dependencies: [
        "ArkDeckCore",
        "ArkDeckProcess",
        "ArkDeckRuntime",
        "ArkDeckOpenHarmony",
        "ArkDeckHarness",
        "ArkDeckWorkflows",
        "ArkDeckStorage",
        "ArkDeckAgentDaemon",
        "ArkDeckAgentClient",
        "ArkDeckFakeHDCFixture",
        "ArkDeckFakeRockchipFixture",
      ],
      resources: [
        // Golden resource declaration is owned by TASK-I5-001 (CHG-2026-005). `.copy` preserves
        // the versioned `Golden/<version>/...` directory tree inside Bundle.module so registry
        // paths stay valid and future pack versions cannot collide.
        .copy("Fixtures/HDC/Golden"),
        .copy("Fixtures/HDC/Probes"),
        .copy("Fixtures/Rockchip"),
        // Privacy-reviewed subset of a real HFA-005 harness directory. HFA-012
        // migrates this checked-in historical payload in its crash/reentry contract matrix.
        .copy("Fixtures/Harness/HFA012"),
      ]
    ),
  ]
)
