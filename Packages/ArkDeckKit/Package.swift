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
    .library(name: "ArkDeckHarness", targets: ["ArkDeckHarness"]),
    .library(name: "ArkDeckWorkflows", targets: ["ArkDeckWorkflows"]),
    .library(name: "ArkDeckStorage", targets: ["ArkDeckStorage"]),
    .executable(name: "arkdeck", targets: ["ArkDeckCLI"]),
    .library(name: "ArkDeckAgentDaemon", targets: ["ArkDeckAgentDaemon"]),
    .library(name: "ArkDeckAgentClient", targets: ["ArkDeckAgentClient"]),
    .library(name: "ArkDeckLaunchAgent", targets: ["ArkDeckLaunchAgent"]),
    .executable(name: "arkdeck-agentd", targets: ["ArkDeckAgentDaemonMain"]),
    .executable(name: "ArkDeckEvolutionCandidate", targets: ["ArkDeckEvolutionCandidate"]),
    .executable(name: "ArkDeckJournalCrashFixture", targets: ["ArkDeckJournalCrashFixture"]),
    .executable(name: "ArkDeckRuntimePortFixture", targets: ["ArkDeckRuntimePortFixture"]),
    .executable(name: "ArkDeckFakeHDCFixture", targets: ["ArkDeckFakeHDCFixture"]),
    .executable(name: "ArkDeckFakeRockchipFixture", targets: ["ArkDeckFakeRockchipFixture"]),
    .executable(name: "ArkDeckEngineCrashFixture", targets: ["ArkDeckEngineCrashFixture"]),
    .executable(name: "ArkDeckRuntimeSoakFixture", targets: ["ArkDeckRuntimeSoakFixture"]),
    .executable(name: "ArkDeckFakeHapSignerFixture", targets: ["ArkDeckFakeHapSignerFixture"]),
  ],
  targets: [
    .target(name: "ArkDeckCore"),
    .target(name: "ArkDeckProcess", dependencies: ["ArkDeckCore"]),
    .target(name: "ArkDeckRuntime", dependencies: ["ArkDeckCore"]),
    .target(name: "ArkDeckOpenHarmony", dependencies: ["ArkDeckCore", "ArkDeckProcess"]),
    // Dependency direction is load-bearing (see ArchitectureBoundaryContractTests):
    // the harness plane decides, the runtime plane executes, and only
    // ArkDeckAgentComposition plus ArkDeckAgentDaemon may see both as library
    // targets. ArkDeckHarness deliberately does not depend on ArkDeckProcess —
    // the harness cannot spawn a process.
    .target(
      name: "ArkDeckHarness",
      dependencies: ["ArkDeckCore", "ArkDeckRuntime"],
      exclude: ["Candidate"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "ArkDeckEvolutionCandidate",
      path: "Sources/ArkDeckHarness/Candidate"),
    // The runtime control plane and providers. Deliberately does not depend on
    // ArkDeckHarness: the engine and providers must not understand the plane
    // that drives them.
    .target(
      name: "ArkDeckWorkflows",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckOpenHarmony",
        "ArkDeckStorage",
      ],
      exclude: ["AgentComposition"],
      resources: [
        .copy("Resources/OpenHarmonyNativeCodeSign")
      ],
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("LocalAuthentication"),
      ]),
    // Harness <-> runtime glue: harness port adapters, the evolution workspace
    // and campaign hosts, and the LLM gateway composition (including the
    // process-executing Codex CLI transport). This and ArkDeckAgentDaemon are
    // the two library composition points allowed to import both
    // ArkDeckHarness and ArkDeckWorkflows; the daemon owns the service-side
    // task-method adapter. This target lives under
    // Sources/ArkDeckWorkflows/AgentComposition (same carve-out pattern as
    // ArkDeckEvolutionCandidate inside ArkDeckHarness).
    .target(
      name: "ArkDeckAgentComposition",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckStorage",
        "ArkDeckHarness", "ArkDeckWorkflows", "ArkDeckAgentClient",
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
      dependencies: ["ArkDeckCore", "ArkDeckHarness", "ArkDeckStorage", "ArkDeckWorkflows"]
    ),
    .target(
      name: "ArkDeckAgentClient",
      dependencies: ["ArkDeckCore"]
    ),
    .target(
      name: "ArkDeckLaunchAgent",
      dependencies: ["ArkDeckCore"],
      path: "LaunchAgents",
      exclude: ["README.md"],
      resources: [.copy("com.arkdeck.agentd.plist")],
      linkerSettings: [.linkedFramework("Security")]
    ),
    .executableTarget(
      name: "ArkDeckAgentDaemonMain",
      dependencies: [
        "ArkDeckAgentDaemon", "ArkDeckAgentComposition", "ArkDeckCore", "ArkDeckHarness",
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
      name: "ArkDeckFakeRockchipFixture",
      path: "Tests/ArkDeckFakeRockchipFixture"
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
        "ArkDeckRuntime",
        "ArkDeckOpenHarmony",
        "ArkDeckHarness",
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
        "ArkDeckFakeRockchipFixture",
        "ArkDeckFakeHapSignerFixture",
      ],
      resources: [
        // Golden resource declaration is owned by TASK-I5-001 (CHG-2026-005). `.copy` preserves
        // the versioned `Golden/<version>/...` directory tree inside Bundle.module so registry
        // paths stay valid and future pack versions cannot collide.
        .copy("Fixtures/HDC/Golden"),
        .copy("Fixtures/HDC/Probes"),
        .copy("Fixtures/Rockchip"),
      ]
    ),
  ]
)
