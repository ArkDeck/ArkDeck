// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "ArkDeckKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArkDeckCore", targets: ["ArkDeckCore"]),
    .library(name: "ArkDeckProcess", targets: ["ArkDeckProcess"]),
    .library(name: "ArkDeckRuntime", targets: ["ArkDeckRuntime"]),
    .library(name: "ArkDeckOpenHarmony", targets: ["ArkDeckOpenHarmony"]),
    .library(name: "ArkDeckWorkflows", targets: ["ArkDeckWorkflows"]),
    .library(name: "ArkDeckStorage", targets: ["ArkDeckStorage"]),
    .executable(name: "arkdeck", targets: ["ArkDeckCLI"]),
    .library(name: "ArkDeckAgentDaemon", targets: ["ArkDeckAgentDaemon"]),
    .library(name: "ArkDeckAgentClient", targets: ["ArkDeckAgentClient"]),
    .library(name: "ArkDeckLaunchAgent", targets: ["ArkDeckLaunchAgent"]),
    .executable(name: "arkdeck-agentd", targets: ["ArkDeckAgentDaemonMain"]),
    .executable(name: "ArkDeckJournalCrashFixture", targets: ["ArkDeckJournalCrashFixture"]),
    .executable(name: "ArkDeckRuntimePortFixture", targets: ["ArkDeckRuntimePortFixture"]),
    .executable(name: "ArkDeckFakeHDCFixture", targets: ["ArkDeckFakeHDCFixture"]),
    .executable(name: "ArkDeckEngineCrashFixture", targets: ["ArkDeckEngineCrashFixture"]),
    .executable(name: "ArkDeckRuntimeSoakFixture", targets: ["ArkDeckRuntimeSoakFixture"]),
    .executable(name: "ArkDeckFakeHapSignerFixture", targets: ["ArkDeckFakeHapSignerFixture"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ArkDeck/ArkForge.git",
      revision: "3f5b48cd7247f7e4304bb4f9d8a158f4feda5a92")
  ],
  targets: [
    .target(
      name: "ArkDeckCore",
      swiftSettings: [.strictMemorySafety()]),
    .target(
      name: "ArkDeckProcess", dependencies: ["ArkDeckCore"],
      swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkDeckRuntime", dependencies: ["ArkDeckCore"]),
    .target(name: "ArkDeckOpenHarmony", dependencies: ["ArkDeckCore", "ArkDeckProcess"]),
    // The runtime control plane and providers. The harness plane was removed
    // by CHG-2026-064: decisions come from external agents through the
    // published caller surface, so no target may reintroduce an in-process
    // decision plane (see ArchitectureBoundaryContractTests).
    .target(
      name: "ArkDeckWorkflows",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckOpenHarmony",
        "ArkDeckStorage",
        .product(name: "ArkForgeProtocol", package: "ArkForge"),
        .product(name: "ArkForgeClient", package: "ArkForge"),
      ],
      exclude: ["AgentComposition"],
      resources: [
        .copy("Resources/OpenHarmonyNativeCodeSign")
      ],
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("LocalAuthentication"),
      ]),
    // Product composition above the runtime plane: the runtime-owned isolated
    // workspace machinery, the flash evolution campaign host, and the native
    // agent-chat composition. This target lives under
    // Sources/ArkDeckWorkflows/AgentComposition as a carve-out so
    // ArkDeckWorkflows itself never gains a composition edge.
    .target(
      name: "ArkDeckAgentComposition",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckStorage",
        "ArkDeckWorkflows", "ArkDeckAgentClient",
      ],
      path: "Sources/ArkDeckWorkflows/AgentComposition"),
    .target(
      name: "ArkDeckStorage",
      dependencies: ["ArkDeckCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "ArkDeckCLI",
      dependencies: [
        "ArkDeckCore", "ArkDeckRuntime", "ArkDeckWorkflows", "ArkDeckAgentComposition",
        "ArkDeckAgentClient", "ArkDeckLaunchAgent",
      ]
    ),
    .target(
      name: "ArkDeckAgentDaemon",
      dependencies: ["ArkDeckCore", "ArkDeckStorage", "ArkDeckWorkflows"]
    ),
    .target(
      name: "ArkDeckAgentClient",
      dependencies: ["ArkDeckCore"]
    ),
    .target(
      name: "ArkDeckLaunchAgent",
      dependencies: [
        "ArkDeckCore",
        .product(name: "ArkForgeClient", package: "ArkForge"),
      ],
      path: "LaunchAgents",
      exclude: ["README.md"],
      resources: [.copy("com.arkdeck.agentd.plist")],
      linkerSettings: [.linkedFramework("Security")]
    ),
    .executableTarget(
      name: "ArkDeckAgentDaemonMain",
      dependencies: [
        "ArkDeckAgentDaemon", "ArkDeckAgentComposition", "ArkDeckCore",
        "ArkDeckRuntime", "ArkDeckStorage", "ArkDeckWorkflows",
      ]
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
      name: "ArkDeckEngineCrashFixture",
      dependencies: ["ArkDeckCore", "ArkDeckOpenHarmony", "ArkDeckStorage", "ArkDeckWorkflows"],
      path: "Tests/ArkDeckEngineCrashFixture"
    ),
    .executableTarget(
      name: "ArkDeckRuntimeSoakFixture",
      dependencies: [
        "ArkDeckAgentClient", "ArkDeckAgentDaemon", "ArkDeckCore", "ArkDeckOpenHarmony",
        "ArkDeckStorage", "ArkDeckWorkflows",
      ],
      path: "Tests/ArkDeckRuntimeSoakFixture"
    ),
    .executableTarget(
      name: "ArkDeckFakeHapSignerFixture",
      path: "Tests/ArkDeckFakeHapSignerFixture"
    ),
    .testTarget(name: "ArkDeckCoreTests", dependencies: ["ArkDeckCore"]),
    .testTarget(
      name: "ArkDeckContractTests",
      dependencies: [
        "ArkDeckCore",
        "ArkDeckProcess",
        .product(name: "ArkForgeProtocol", package: "ArkForge"),
        .product(name: "ArkForgeClient", package: "ArkForge"),
        "ArkDeckRuntime",
        "ArkDeckOpenHarmony",
        "ArkDeckWorkflows",
        "ArkDeckAgentComposition",
        "ArkDeckStorage",
        "ArkDeckAgentDaemon",
        "ArkDeckAgentClient",
        "ArkDeckLaunchAgent",
        // The engine-lane campaign dispatcher lives in the CLI composition
        // root (it needs the campaign protocol and the daemon transport, and
        // ArkDeckWorkflows must not gain a client edge). Its mapping is
        // product behaviour, so it is contract-tested here.
        "ArkDeckCLI",
        "ArkDeckFakeHDCFixture",
        "ArkDeckFakeHapSignerFixture",
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
