// Shared Swift oracle for the Rust port of what the daemon publishes about its
// workspace composition (TASK-XPA-015, M3): `operation.list`'s workspace rows,
// `workspace.project.list/show` and `workspace.preset.list/show`, over three
// starts of the daemon's own composition of the registered projects.
//
// Each start composes what `ArkDeckAgentDaemonMain` composes from the
// registration owner: every registered project whose root still is the one it
// pinned, resolved to its OpenHarmony profile with its registered presets (a
// symbol preset through the configured symbolizer; a Hvigor preset through the
// DevEco registry, which here holds no toolchain, so its resolution fails as a
// daemon's does), the isolation manager over the resolved profiles, the
// publications `WorkspaceProjectPublication.make` derives per project, the
// dispatcher chain and the applied generations. Only the signing dispatcher
// wrapper is left out: it forwards `unavailableReason` unchanged.
//
// Start 1 has no project: the rows are the unavailable provider's and the
// refusing dispatcher's. Two projects are registered, with a symbol preset each
// and a Hvigor test preset on the first, all awaiting a restart. Start 2 (an
// inspector configured) resolves both: the rows, both projects active with
// their publications, the symbol presets active and the test preset
// unresolved; the symbolizer then drifts — the rows name the drift, the
// publications keep what the start published — and is restored; a second
// symbol preset, a removed one and an updated project await a restart again.
// Start 3 (no inspector), after the second project's root was removed:
// the second project active but unresolved, the new preset active, and the
// second project's preset removed. (Its registration is not removed: a
// removed preset's record still names its project, and a store whose preset
// names no registered project no longer reads — Swift's and Rust's alike.)
//
// Host-local only: fabricated projects under a fixed root, no device, no
// daemon process, nothing run. `inspector.sh` and `symbolizer.sh` stand in for
// a configured inspector and the daemon's `--symbolize-crash` mode. Record with
// `ARKDECK_RUST_WORKSPACE_AVAILABILITY_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The daemon's dispatcher when no workspace profile resolved
/// (`ArkDeckAgentDaemonMain`'s `RefusingDispatcher`).
private struct AvailabilityRefusingDispatcher: RuntimeProcessDispatching {
  let reason: String

  func unavailableReason(providerID: String) -> String? { reason }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed(reason)
  }
}

final class WorkspaceAvailabilityOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-availability-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_AVAILABILITY_RECORD"
  /// The recording's fixed root: the publications and rows name nothing
  /// below it, and the registrations pin its projects' roots by path.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-availability-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-25T00:00:00Z"
  private static let sourceMap = "entry/build/default/outputs/default/mapping/sourceMaps.map"
  private static let otherSourceMap = "entry/build/release/outputs/default/mapping/sourceMaps.map"
  private static let toolchain = "toolchain:sha256:" + String(repeating: "7", count: 64)
  /// The running test's root, emptied first and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: The host

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// An OpenHarmony-shaped project: what `waterFlowDemo` requires of a root,
  /// a source inside its scope and the map a release build wrote.
  private func project(_ name: String, in root: URL) throws -> URL {
    let project = root.appending(path: name, directoryHint: .isDirectory)
    let files = [
      "build-profile.json5": "{ app: {}, modules: [{ name: 'entry', srcPath: './entry' }] }\n",
      "entry/src/main/module.json5": "{ module: { name: 'entry' } }\n",
      "entry/src/main/ets/pages/Index.ets": "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
      Self.sourceMap: "{}\n",
    ]
    for (path, text) in files {
      let url = project.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    return try physical(project)
  }

  /// The fixture's stand-in tools, with their checked-in bytes.
  private func tools(in root: URL) throws -> (inspector: URL, symbolizer: URL) {
    let tools = root.appending(path: "tools", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    for name in ["inspector", "symbolizer"] {
      let url = tools.appending(path: name)
      try Data(contentsOf: Self.oracle.appending(path: "\(name).sh")).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let directory = try physical(tools)
    return (directory.appending(path: "inspector"), directory.appending(path: "symbolizer"))
  }

  /// One start of the daemon's workspace composition over `state`, as
  /// `ArkDeckAgentDaemonMain` composes it from the registration owner.
  private func start(
    state: URL, inspector: URL?, symbolizer: URL
  ) throws -> RuntimeControlPlaneHandler {
    // The owner keeps its document in `<state>/workspace-projects`.
    let store = try RuntimeWorkspaceProjectStore(
      rootURL: state,
      toolchainPinning: RuntimeWorkspaceToolchainPinning(
        acquire: { _, _, _ in }, release: { _, _ in }),
      nowUTC: { Self.timestamp })
    let startup = try store.startupRecords()
    let registered = startup.map(\.resource)
    var resolvedPresetsByProject: [String: [RuntimeWorkspaceResolvedPreset]] = [:]
    var presetFailures: [String: String] = [:]
    for composition in try store.presetCompositionRecords() {
      let resource = composition.resource
      switch resource.kind {
      case "symbol":
        resolvedPresetsByProject[resource.projectRef, default: []].append(
          RuntimeWorkspaceResolvedPreset(resource: resource))
      case "build", "test", "signing":
        // The daemon resolves the pin through its DevEco registry, which
        // holds no toolchain on this host: the resolution fails.
        presetFailures[resource.presetRef] =
          "workspace.presetResolutionFailed:the DevEco toolchain is not registered"
      default:
        presetFailures[resource.presetRef] = "workspace.presetKindUnsupported"
      }
    }
    var failures: [String: String] = [:]
    var roots: [String: String] = [:]
    for record in startup {
      if let composition = record.composition {
        roots[record.resource.projectRef] = composition.rootPath
      } else if let failure = record.failure {
        failures[record.resource.projectRef] =
          "workspace.projectRootUnavailable:\(failure.message)"
      }
    }
    var profiles: [WorkspaceProjectProfile] = []
    for projectRef in roots.keys.sorted() {
      do {
        profiles.append(
          try WorkspaceProjectProfile.waterFlowDemo(
            rootURL: URL(filePath: roots[projectRef]!, directoryHint: .isDirectory),
            projectRef: projectRef, symbolizerPath: symbolizer.path,
            registeredPresets: resolvedPresetsByProject[projectRef] ?? []))
      } catch {
        failures[projectRef] = "workspace.projectProfileUnavailable:\(error)"
      }
    }
    var tool: WorkspaceInspectorTool?
    var inspectorExecutable: ResolvedExecutable?
    if let inspector {
      let resolved = try FixedExecutableResolver.hashing(
        path: inspector.path, providerID: "workspace"
      ).resolveExecutable(providerID: "workspace")
      inspectorExecutable = resolved
      tool = WorkspaceInspectorTool(
        executablePath: resolved.path, executableSHA256: resolved.sha256)
    }
    var publications: [WorkspaceProjectPublication] = []
    let operations: any DeviceProvider
    var dispatcher: any RuntimeProcessDispatching = AvailabilityRefusingDispatcher(
      reason: "no workspace ProjectProfile is configured")
    if let primary = profiles.first {
      let attempts = try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory))
      let registry = try WorkspaceProjectProfileRegistry(profiles: profiles)
      let evolution = try EvolutionWorkspaceManager(
        rootURL: state.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
        profileRegistry: registry, patchLineage: attempts)
      XCTAssertEqual(evolution.adoptRuntimeWorkspaces(), [])
      operations = WorkspaceOperationsProvider(
        profile: primary, profileRegistry: registry, attemptStore: attempts,
        isolationManager: evolution, availabilityProfiles: profiles, nowUTC: { Self.timestamp })
      for profile in profiles {
        let provider = WorkspaceOperationsProvider(
          profile: profile, profileRegistry: registry, attemptStore: attempts,
          isolationManager: evolution, nowUTC: { Self.timestamp })
        publications.append(
          WorkspaceProjectPublication.make(
            profile: profile, availability: { provider.runtimeAvailability(for: $0) }))
      }
      dispatcher = RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: CombinedWorkspaceExecutableResolver(
            inspector: inspectorExecutable,
            operations: WorkspaceActionExecutableResolver(profiles: profiles))),
        manager: evolution, sweeper: evolution)
    } else {
      let reason = failures.keys.sorted().compactMap { failures[$0] }.joined(separator: "; ")
      operations = UnavailableWorkspaceOperationsProvider(
        reason: reason.isEmpty
          ? "workspace.projectProfileUnavailable: no registered project profile resolved"
          : reason)
      if let inspectorExecutable {
        dispatcher = DescriptorBoundProcessDispatcher(
          resolver: FixedExecutableResolver(table: ["workspace": inspectorExecutable]))
      }
    }
    for projectRef in registered.map(\.projectRef).sorted()
    where !publications.contains(where: { $0.projectRef == projectRef }) {
      publications.append(
        .unresolved(
          projectRef: projectRef,
          reason: failures[projectRef] ?? "this project profile could not be derived"))
    }
    let resolvedRefs = Set(profiles.map(\.projectRef))
    let appliedPresets = try store.presetCompositionRecords().compactMap {
      composition -> (String, UInt64)? in
      let resource = composition.resource
      guard resolvedRefs.contains(resource.projectRef),
        resolvedPresetsByProject[resource.projectRef]?.contains(where: {
          $0.resource.presetRef == resource.presetRef
        }) == true,
        presetFailures[resource.presetRef] == nil
      else { return nil }
      return (resource.presetRef, resource.generation)
    }
    store.markApplied(
      projects: Dictionary(uniqueKeysWithValues: registered.map { ($0.projectRef, $0.generation) }),
      presets: Dictionary(uniqueKeysWithValues: appliedPresets),
      presetResolutionFailures: presetFailures)
    let provider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: roots), tool: tool, operations: operations)
    let providers = DeviceProviderRegistry(providers: [provider])
    let refusing = AvailabilityRefusingDispatcher(reason: "no HDC executable is configured")
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifacts = try RuntimeArtifactStore(
      rootURL: state.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { Self.timestamp })
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers,
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: refusing, rockchip: refusing, workspace: dispatcher),
      capabilityStore: capabilities, artifactStore: artifacts,
      workspaceProjectStore: store, nowUTC: { Self.timestamp })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities,
      providerIDs: providers.registeredProviderIDs, nowUTC: { Self.timestamp },
      targetStore: nil, bootstrap: nil, targetObservations: nil,
      hdcRuntimeDiagnostics: nil, artifactStore: artifacts, historyFilterStore: nil,
      flashBundleImportDirectory: state.appending(
        path: "flash-bundle-imports", directoryHint: .isDirectory),
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: nil, flashLanePlanPreviewer: nil,
      rockchipBootloaderStatusObserver: nil, rockchipDeviceAccessObserver: nil,
      rockchipLoaderBindingCoordinator: nil, rockchipPostFlashAliasReconciler: nil,
      workspaceProjects: publications, methodObserver: nil)
  }

  // MARK: The exchanges

  /// Every exchange, as the control-frame recorder spells it.
  private final class Frames: @unchecked Sendable {
    var lines: [Data] = []
  }

  @discardableResult
  private func send(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue] = [:]
  ) async throws -> AgentWireProtocol.Response {
    let request = AgentWireProtocol.Request(
      id: UUID().uuidString, method: method, params: params)
    let response = await handler.handleFrame(try JSONEncoder().encode(request))
    frames.lines.append(
      try ControlFrameRecord(request: request, response: response).encodedLine())
    XCTAssertTrue(response.ok, "\(method): \(String(describing: response.error))")
    return response
  }

  /// One exchange whose answer names a reference later exchanges use.
  private func reference(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue], field: String
  ) async throws -> String {
    let response = try await send(handler, frames, method, params)
    return try XCTUnwrap(Self.field(response, field), "\(method) names its \(field)")
  }

  private static func field(_ response: AgentWireProtocol.Response, _ name: String) -> String? {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields[name]
    else { return nil }
    return value
  }

  private static func symbolPreset(
    _ request: String, project: String, map: String
  ) -> [String: JSONValue] {
    [
      "registrationRequestId": .string(request), "projectRef": .string(project),
      "kind": .string("symbol"), "templateRef": .string("openharmony.arkts-symbol@1"),
      "timeoutSeconds": .string("300"), "relativeSourceMap": .string(map),
    ]
  }

  // MARK: The recording

  func testTheDaemonPublishesItsWorkspaceCompositionAsRecorded() async throws {
    let root = Self.oracleRoot
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let alphaRoot = try project("alpha", in: root)
    let betaRoot = try project("beta", in: root)
    let tools = try tools(in: root)
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    let frames = Frames()

    // 1. No project: the unavailable provider and the refusing dispatcher.
    // Two projects registered, a symbol preset each and a Hvigor test
    // preset on the first: each awaits a restart.
    var daemon = try start(state: state, inspector: nil, symbolizer: tools.symbolizer)
    try await send(daemon, frames, "operation.list")
    try await send(daemon, frames, "workspace.project.list")
    let alpha = try await reference(
      daemon, frames, "workspace.project.register",
      [
        "registrationRequestId": .string("oracle-alpha"), "kind": .string("openharmony"),
        "root": .string(alphaRoot.path),
      ], field: "projectRef")
    let beta = try await reference(
      daemon, frames, "workspace.project.register",
      [
        "registrationRequestId": .string("oracle-beta"), "kind": .string("openharmony"),
        "root": .string(betaRoot.path),
      ], field: "projectRef")
    let alphaSymbol = try await reference(
      daemon, frames, "workspace.preset.register",
      Self.symbolPreset("oracle-alpha-symbol", project: alpha, map: Self.sourceMap),
      field: "presetRef")
    let alphaTests = try await reference(
      daemon, frames, "workspace.preset.register",
      [
        "registrationRequestId": .string("oracle-alpha-tests"), "projectRef": .string(alpha),
        "kind": .string("test"), "templateRef": .string("openharmony.hvigor-test@1"),
        "timeoutSeconds": .string("600"), "toolchainRef": .string(Self.toolchain),
        "toolchainGeneration": .string("1"), "module": .string("entry"),
        "product": .string("default"), "buildMode": .string("debug"),
      ], field: "presetRef")
    let betaSymbol = try await reference(
      daemon, frames, "workspace.preset.register",
      Self.symbolPreset("oracle-beta-symbol", project: beta, map: Self.sourceMap),
      field: "presetRef")
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(alpha)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(alpha)])
    try await send(
      daemon, frames, "workspace.preset.show",
      ["projectRef": .string(alpha), "presetRef": .string(alphaSymbol)])

    // 2. Both projects composed, an inspector configured.
    daemon = try start(state: state, inspector: tools.inspector, symbolizer: tools.symbolizer)
    try await send(daemon, frames, "operation.list")
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(alpha)])
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(beta)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(alpha)])
    try await send(
      daemon, frames, "workspace.preset.show",
      ["projectRef": .string(alpha), "presetRef": .string(alphaTests)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(beta)])
    // The symbolizer drifts, then is restored.
    let symbolizerBytes = try Data(contentsOf: tools.symbolizer)
    try (symbolizerBytes + Data("# drifted\n".utf8)).write(to: tools.symbolizer)
    try await send(daemon, frames, "operation.list")
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(alpha)])
    try symbolizerBytes.write(to: tools.symbolizer)
    // A second symbol preset, a removed one and an updated project.
    let alphaSymbolAgain = try await reference(
      daemon, frames, "workspace.preset.register",
      Self.symbolPreset("oracle-alpha-symbol-2", project: alpha, map: Self.otherSourceMap),
      field: "presetRef")
    try await send(
      daemon, frames, "workspace.preset.remove",
      [
        "mutationRequestId": .string("oracle-alpha-symbol-remove"), "projectRef": .string(alpha),
        "presetRef": .string(alphaSymbol), "expectedGeneration": .string("1"),
      ])
    try await send(
      daemon, frames, "workspace.project.update",
      [
        "projectRef": .string(alpha), "expectedGeneration": .string("1"),
        "kind": .string("openharmony"), "root": .string(alphaRoot.path),
      ])
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(alpha)])

    // 3. The second project's root is gone; no inspector.
    try FileManager.default.removeItem(at: betaRoot)
    daemon = try start(state: state, inspector: nil, symbolizer: tools.symbolizer)
    try await send(daemon, frames, "operation.list")
    try await send(daemon, frames, "workspace.project.list")
    try await send(daemon, frames, "workspace.project.show", ["projectRef": .string(beta)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(alpha)])
    try await send(
      daemon, frames, "workspace.preset.show",
      ["projectRef": .string(alpha), "presetRef": .string(alphaSymbolAgain)])
    try await send(daemon, frames, "workspace.preset.list", ["projectRef": .string(beta)])
    try await send(
      daemon, frames, "workspace.preset.remove",
      [
        "mutationRequestId": .string("oracle-beta-symbol-remove"), "projectRef": .string(beta),
        "presetRef": .string(betaSymbol), "expectedGeneration": .string("1"),
      ])
    try await send(daemon, frames, "workspace.project.list")

    let recorded = frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try recorded.write(to: directory.appending(path: "frames.jsonl"))
      return
    }

    // The checked-in oracle is what this composition answers, frame by frame.
    let expected = try Data(contentsOf: Self.oracle.appending(path: "frames.jsonl"))
      .split(separator: UInt8(ascii: "\n"))
    let actual = recorded.split(separator: UInt8(ascii: "\n"))
    XCTAssertEqual(expected.count, actual.count, "frame count")
    for (index, (lhs, rhs)) in zip(expected, actual).enumerated() {
      XCTAssertEqual(
        String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self),
        "frame \(index)")
    }
  }
}
