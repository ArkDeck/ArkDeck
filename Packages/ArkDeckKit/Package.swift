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
    .executable(name: "ArkDeckEvolutionCandidate", targets: ["ArkDeckEvolutionCandidate"]),
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
    // Dependency direction is load-bearing (see ArchitectureBoundaryContractTests):
    // the harness plane decides, the runtime plane executes, and only the
    // composition target below may see both. ArkDeckHarness deliberately does
    // not depend on ArkDeckProcess — the harness cannot spawn a process.
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
      ]),
    // Harness <-> runtime glue: harness port adapters, the evolution workspace
    // and campaign hosts, and the LLM gateway composition (including the
    // process-executing Codex CLI transport). This is the only library target
    // allowed to import both ArkDeckHarness and ArkDeckWorkflows. It lives
    // under Sources/ArkDeckWorkflows/AgentComposition (same carve-out pattern
    // as ArkDeckEvolutionCandidate inside ArkDeckHarness).
    .target(
      name: "ArkDeckAgentComposition",
      dependencies: [
        "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckStorage",
        "ArkDeckHarness", "ArkDeckWorkflows",
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
        "ArkDeckAgentClient",
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
    .executableTarget(
      name: "ArkDeckAgentDaemonMain",
      dependencies: [
        "ArkDeckAgentDaemon", "ArkDeckAgentComposition", "ArkDeckHarness", "ArkDeckRuntime",
        "ArkDeckStorage", "ArkDeckWorkflows",
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
        // The engine-lane campaign dispatcher lives in the CLI composition
        // root (it needs the campaign protocol and the daemon transport, and
        // ArkDeckWorkflows must not gain a client edge). Its mapping is
        // product behaviour, so it is contract-tested here.
        "ArkDeckCLI",
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
