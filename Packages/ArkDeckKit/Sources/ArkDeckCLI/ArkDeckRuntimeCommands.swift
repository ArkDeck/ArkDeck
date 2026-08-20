// Runtime client commands (CHG-2026-048, T09/T11).
//
// `arkdeck doctor`, `arkdeck operation list`, `arkdeck device list|adopt|show` and
// `arkdeck job submit|status` are thin daemon clients: they construct a
// typed request or a control-plane call and print the response. No HDC,
// no argv, no executor lives here - the CLI cannot execute a device
// operation even in principle, only ask the daemon to.

import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckRuntime
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

enum RuntimeCLI {

  /// Every option `agentd install` and `agentd update` accept.
  ///
  /// One list, exposed, because the failure it prevents already happened: the
  /// ArkForge lane flags were read by the command and absent from this
  /// set, so `validateAllowed` rejected them before the reader ever ran and
  /// the lane could not be installed at all. `--arkforge-profile` was answered
  /// with "unsupported option" by a build whose next twenty lines were about
  /// to parse it.
  ///
  /// `AgentdOptionCoverageContractTests` holds this to the flags the command
  /// actually reads, so the two cannot drift apart again.
  static let agentdInstallOptions: Set<String> = [
    "--daemon", "--hdc", "--workspace-project", "--deveco-sdk",
    "--sensitive-evidence", "--harness-model-provider", "--harness-model-name",
    "--harness-cli", "--harness-cli-timeout-seconds",  // refused by name below
    "--arktrace-descriptor",
    "--arkforged", "--arkforged-sha256", "--arkforge-profile", "--arkforge-campaign",
  ]

  static func defaultSocketPath() -> String {
    ArkDeckAgentFilesystemLayout.defaultSocketURL().path
  }

  static func client(_ arguments: inout [String]) -> AgentClient {
    var socketPath = defaultSocketPath()
    if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
      socketPath = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
    }
    return AgentClient(socketPath: socketPath)
  }

  static func emit(_ value: JSONValue, json: Bool) {
    if json {
      let encoder = CanonicalJSONEncoders.canonicalPretty()
      if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
        return
      }
    }
    print(render(value, indent: 0))
  }

  /// A terminal Job that did not succeed must not leave the process at exit 0.
  ///
  /// `arkdeck job ...` is the surface an unattended caller drives — PRODUCT-LOOP
  /// §14 puts the human budget at 0 after adoption — and exit 0 is the universal
  /// "it worked" signal. Reporting a failed, cancelled or outcome-unknown Job
  /// that way makes a script or an agent read a device that was never touched as
  /// one that was. The payload is still printed either way; only the exit status
  /// changes. Non-terminal states stay 0: the Job is simply still running, which
  /// is not an error.
  static func terminalJobExit(_ value: JSONValue) -> (code: Int32, reason: String)? {
    guard case .object(let fields) = value else { return nil }
    // Checked before the state, because an unknown outcome is not a failure to
    // retry: the effect is undetermined and the Job needs `job reconcile`.
    // POL-RECOVERY-001 forbids replaying it, so it gets its own exit status.
    if case .bool(true)? = fields["outcomeUnknown"] {
      return (
        75, "job outcome is unknown: reconcile it; the original effect is never replayed"
      )
    }
    guard case .string(let state)? = fields["state"] else { return nil }
    switch state {
    case "failed", "cancelled", "interrupted":
      return (1, "job terminal state is \(state)")
    default:
      // succeeded / recovered / planned, or any non-terminal state.
      return nil
    }
  }

  /// Which call finishes a `--wait`, given what the submit answered.
  ///
  /// A deduplicated submit returns an existing job, and that job is usually
  /// already terminal — the caller is retrying precisely because it could not
  /// tell whether the first attempt landed. `job.run` resolves against the
  /// jobs the engine still holds in memory, which no longer include terminal
  /// ones, so running a finished job answers `jobNotFound`. That reports a
  /// correct idempotent replay as a rejection, for exactly the case an
  /// idempotency key exists to make safe, and pushes a retrying caller toward
  /// submitting under a fresh key — a second real effect for a
  /// `deviceMutation` operation. Read the durable status for a duplicate and
  /// keep running a fresh one.
  ///
  /// Absent or non-`true` `deduplicated` means fresh: only an explicit
  /// duplicate may skip the run, so a daemon that stops sending the field
  /// degrades to today's behaviour instead of silently never running a job.
  static func waitedSubmitCall(_ submitted: JSONValue) -> (method: String, jobID: String)? {
    guard case .object(let fields) = submitted,
      case .string(let jobID)? = fields["jobId"]
    else { return nil }
    if case .bool(true)? = fields["deduplicated"] {
      return ("job.status", jobID)
    }
    return ("job.run", jobID)
  }

  static func completeWaitedSubmit(
    _ submitted: JSONValue, client: AgentClient, json: Bool
  ) throws {
    guard let call = waitedSubmitCall(submitted) else { return }
    let response = try client.request(
      method: call.method, params: ["jobId": .string(call.jobID)])
    emit(response, json: json)
    if let terminal = terminalJobExit(response) {
      throw CLIError(exitCode: terminal.code, message: terminal.reason)
    }
  }

  private static func render(_ value: JSONValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch value {
    case .object(let fields):
      return fields.keys.sorted().map { key in
        "\(pad)\(key): \(render(fields[key] ?? .null, indent: indent + 1).trimmingCharacters(in: .whitespaces))"
      }.joined(separator: "\n")
    case .array(let items):
      if items.isEmpty { return "\(pad)(none)" }
      return items.map {
        "\(pad)- \(render($0, indent: indent + 1).trimmingCharacters(in: .whitespaces))"
      }
      .joined(separator: "\n")
    case .string(let text): return "\(pad)\(text)"
    case .integer(let number): return "\(pad)\(number)"
    case .unsignedInteger(let number): return "\(pad)\(number)"
    case .number(let number): return "\(pad)\(number)"
    case .bool(let flag): return "\(pad)\(flag)"
    case .null: return "\(pad)-"
    }
  }

  static func runDoctor(_ arguments: [String]) throws {
    var rest = arguments
    let json = rest.contains("--json")
    let client = client(&rest)
    emit(try client.request(method: "doctor"), json: json)
  }

  /// Installs and diagnoses the one production daemon as a user-domain
  /// LaunchAgent. This surface invokes only `/bin/launchctl`; all device work
  /// still crosses the daemon's typed UDS/XPC control plane.
  static func runAgentDaemon(
    _ arguments: [String], service: LaunchAgentService = LaunchAgentService(),
    beforeBootstrap: (@Sendable () throws -> Void)? = nil
  ) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing agentd subcommand (install|update|status|verify|uninstall)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    switch subcommand {
    case "install", "update":
      let options = try CLIOptions(rest)
      try options.validateAllowed(Self.agentdInstallOptions)
      let previousStatus = subcommand == "update" ? try? service.status() : nil
      let daemonBundlePath = options.value("--daemon") ?? defaultAgentDaemonBundlePath()
      let configuredHDC: String?
      if let supplied = options.value("--hdc") {
        configuredHDC = supplied
      } else if subcommand == "update" {
        configuredHDC = previousStatus?.hdcPath
      } else {
        configuredHDC = nil
      }
      guard let hdcPath = configuredHDC, hdcPath.hasPrefix("/") else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "agentd \(subcommand) requires --hdc with an absolute executable path")
      }
      guard daemonBundlePath.hasPrefix("/") else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "agentd \(subcommand) requires an absolute ArkDeckAgent.app path")
      }
      let workspaceProject =
        options.value("--workspace-project") ?? previousStatus?.workspaceProjectPath
      let devecoSDK = options.value("--deveco-sdk") ?? previousStatus?.devecoSDKPath
      guard (workspaceProject == nil) == (devecoSDK == nil) else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "agentd \(subcommand) requires --workspace-project and --deveco-sdk together")
      }
      if let workspaceProject, !workspaceProject.hasPrefix("/") {
        throw CLIError(
          exitCode: EX_USAGE, message: "--workspace-project must be an absolute path")
      }
      if let devecoSDK, !devecoSDK.hasPrefix("/") {
        throw CLIError(exitCode: EX_USAGE, message: "--deveco-sdk must be an absolute path")
      }
      let workspace: LaunchAgentWorkspaceConfiguration?
      if let workspaceProject, let devecoSDK {
        workspace = LaunchAgentWorkspaceConfiguration(
          projectRoot: URL(filePath: workspaceProject),
          devecoSDKRoot: URL(filePath: devecoSDK))
      } else {
        workspace = nil
      }
      // The in-process decision plane and its evaluator were removed by
      // CHG-2026-064; their configuration flags are refused by name so an
      // operator's muscle memory gets a real answer instead of silence.
      for removed in [
        "--sensitive-evidence", "--harness-model-provider", "--harness-model-name",
        "--harness-cli", "--harness-cli-timeout-seconds",
      ] where options.value(removed) != nil {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "\(removed) was removed by CHG-2026-064: decisions come from external "
            + "agents through the published caller surface; re-run without it")
      }
      let arkTraceDescriptor: URL?
      if let supplied = options.value("--arktrace-descriptor") {
        if supplied == "none" {
          arkTraceDescriptor = nil
        } else {
          guard supplied.hasPrefix("/") else {
            throw CLIError(
              exitCode: EX_USAGE,
              message: "--arktrace-descriptor must be an absolute path or none")
          }
          arkTraceDescriptor = URL(filePath: supplied)
        }
      } else if subcommand == "update" {
        arkTraceDescriptor = try service.arkTraceDescriptorForPreservingUpdate()
      } else {
        arkTraceDescriptor = nil
      }
      // The ArkForge lane: three inputs that go in together or not at all. A
      // partial set is refused here rather than written, because the lane
      // ignores an incomplete configuration and the daemon would start looking
      // configured while having no lane at all.
      let arkForgeLane: LaunchAgentArkForgeLaneStatus?
      let laneFlags = [
        "--arkforged": options.value("--arkforged"),
        "--arkforged-sha256": options.value("--arkforged-sha256"),
        "--arkforge-profile": options.value("--arkforge-profile"),
      ]
      if laneFlags.values.contains(where: { $0 == "none" }) {
        guard laneFlags.values.allSatisfy({ $0 == nil || $0 == "none" }) else {
          throw CLIError(
            exitCode: EX_USAGE,
            message: "--arkforged none revokes the whole lane; it cannot be combined with "
              + "the other ArkForge options")
        }
        arkForgeLane = nil
      } else if laneFlags.values.contains(where: { $0 != nil }) {
        let missing = laneFlags.filter { $0.value == nil }.keys.sorted()
        guard missing.isEmpty else {
          throw CLIError(
            exitCode: EX_USAGE,
            message: "the ArkForge lane needs all of --arkforged, --arkforged-sha256, "
              + "and --arkforge-profile; missing "
              + missing.joined(separator: ", "))
        }
        do {
          arkForgeLane = try LaunchAgentArkForgeLaneStatus.measuring(
            daemonPath: laneFlags["--arkforged"]!!,
            declaredDaemonSHA256: laneFlags["--arkforged-sha256"]!!,
            deviceProfilePath: laneFlags["--arkforge-profile"]!!,
            // Optional and separate: the three above install a lane, this
            // authorizes it to execute a combination nobody has verified yet.
            // Omitted means hardwareGated, which is what every ordinary
            // install wants.
            campaign: options.value("--arkforge-campaign") ?? "")
        } catch let refusal as LaunchAgentArkForgeLaneStatus.Refusal {
          // Measured at install time on purpose: this executable performs
          // destructive writes, and a mistyped path should be found
          // now rather than with a board half-written.
          throw CLIError(exitCode: EX_USAGE, message: "\(refusal)")
        }
      } else if subcommand == "update" {
        arkForgeLane = try service.arkForgeLaneForPreservingUpdate()
      } else {
        arkForgeLane = nil
      }
      let receipt = try service.install(
        daemonBundleSource: URL(filePath: daemonBundlePath, directoryHint: .isDirectory),
        hdcExecutable: URL(filePath: hdcPath), workspace: workspace,
        arkTraceDescriptor: arkTraceDescriptor,
        arkForgeLane: arkForgeLane,
        beforeBootstrap: beforeBootstrap)
      emit(try encodedJSON(receipt), json: json)

    case "status":
      guard rest.isEmpty else {
        throw CLIError(exitCode: EX_USAGE, message: "agentd status accepts only --json")
      }
      let status = try service.status()
      let health: JSONValue
      if status.socketPresent {
        do {
          health = try AgentClient(socketPath: status.socketPath).request(method: "health")
        } catch {
          health = .object([
            "status": .string("unreachable"),
            "detail": .string("\(error)"),
          ])
        }
      } else {
        health = .object(["status": .string("socket_absent")])
      }
      emit(
        .object([
          "launchAgent": try encodedJSON(status),
          "daemonHealth": health,
        ]),
        json: json)

    case "verify":
      let options = try CLIOptions(rest)
      try options.validateAllowed(["--target", "--maximum-wait-seconds", "--execution-id"])
      let maximumWaitSeconds: Int
      if let raw = options.value("--maximum-wait-seconds") {
        guard let parsed = Int(raw), (1...300).contains(parsed) else {
          throw CLIError(
            exitCode: EX_USAGE,
            message: "agentd verify --maximum-wait-seconds must be between 1 and 300")
        }
        maximumWaitSeconds = parsed
      } else {
        maximumWaitSeconds = 90
      }

      // A socket-shaped path is not enough. The verifier is deliberately
      // anchored to the installed, loaded and identity-checked LaunchAgent,
      // then opens exactly the UDS that service owns.
      let status = try service.status()
      guard status.ready else {
        emit(
          .object([
            "launchAgent": try encodedJSON(status),
            "runtime": .null,
            "runtimeVerified": .bool(false),
          ]),
          json: json)
        throw CLIError(
          exitCode: 69,
          message: "LaunchAgent is not ready: \(status.diagnostics.joined(separator: "; "))")
      }

      let verifier = RuntimeHeadlessVerifier(
        client: AgentClient(socketPath: status.socketPath), nowUTC: utcNow)
      let outcome = try verifier.verifyObserveDevice(
        targetID: options.value("--target"),
        maximumWaitSeconds: maximumWaitSeconds,
        executionID: options.value("--execution-id") ?? UUID().uuidString.lowercased())
      switch outcome {
      case .verified(let report):
        emit(
          .object([
            "launchAgent": try encodedJSON(status),
            "runtime": try encodedJSON(report),
            "runtimeVerified": .bool(true),
          ]),
          json: json)
      case .awaitingHumanAction(let action, let receipt):
        emit(
          .object([
            "humanAction": try encodedJSON(action),
            "launchAgent": try encodedJSON(status),
            "runtimeReceipt": try encodedJSON(receipt),
            "runtimeVerified": .bool(false),
          ]),
          json: json)
        FileHandle.standardError.write(
          Data(
            "resume with: arkdeck agent resume --resume-token \(action.resumeToken)\n".utf8))
        throw CLIError(exitCode: 75, message: "paused for physical assistance")
      case .failed(let reason, let report):
        emit(
          .object([
            "launchAgent": try encodedJSON(status),
            "runtime": try encodedJSON(report),
            "runtimeVerified": .bool(false),
          ]),
          json: json)
        throw CLIError(exitCode: 1, message: reason)
      }

    case "uninstall":
      guard rest.isEmpty else {
        throw CLIError(exitCode: EX_USAGE, message: "agentd uninstall accepts only --json")
      }
      emit(try encodedJSON(service.uninstall()), json: json)

    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported agentd subcommand")
    }
  }

  static func refreshSigningAccessIfInstalled() throws {
    let store = OpenHarmonySigningPresetStore(
      secrets: LoginKeychainSigningSecretStore(allowsUserInteraction: true))
    // `status()` proves value readability. Calling it from an ad-hoc rebuilt
    // maintenance CLI can therefore ask legacy Keychain ACLs to authorize the
    // CLI before we have compared the installed daemon's exact trusted-app
    // identity. Receipt existence is the only fact needed to decide whether
    // maintenance applies; the store then validates public identities without
    // secrets. SDK-managed presets can create a fresh envelope from the
    // official public password, while private presets read the old envelope
    // only when an actual daemon-identity/access-schema migration is required.
    guard FileManager.default.fileExists(atPath: store.receiptPath) else { return }
    try store.refreshDaemonKeychainIdentity()
  }

  /// Installs the single published OpenHarmony signing preset. Passwords are
  /// accepted only from an interactive terminal with echo disabled; neither
  /// argv nor the LaunchAgent environment can become a secret transport.
  static func runSigningAsync(
    _ arguments: [String],
    store suppliedStore: OpenHarmonySigningPresetStore? = nil,
    materialParentURL: URL? = nil
  ) async throws {
    guard arguments.first == "install-sdk-release" else {
      return try runSigning(arguments, store: suppliedStore)
    }
    let store =
      suppliedStore
      ?? OpenHarmonySigningPresetStore(
        secrets: LoginKeychainSigningSecretStore(allowsUserInteraction: true))
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let options = try CLIOptions(rest)
    try options.validateAllowed(["--sdk", "--java", "--bundle-name", "--project-ref"])
    func required(_ name: String) throws -> String {
      guard let value = options.value(name), !value.isEmpty else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "signing install-sdk-release requires \(name)")
      }
      return value
    }
    let sdk = try required("--sdk")
    let java = try required("--java")
    for (name, value) in [("--sdk", sdk), ("--java", java)] where !value.hasPrefix("/") {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "signing install-sdk-release \(name) must be an absolute path")
    }
    let installer = OpenHarmonySDKReleasePresetInstaller(
      store: store,
      materialParentURL: materialParentURL ?? OpenHarmonyLocalSigning.defaultRootURL())
    let receipt = try await installer.install(
      configuration: OpenHarmonySDKReleasePresetConfiguration(
        projectRef: options.value("--project-ref")
          ?? OpenHarmonyLocalSigning.defaultProjectRef,
        bundleName: try required("--bundle-name"),
        javaExecutable: URL(filePath: java),
        sdkRoot: URL(filePath: sdk)))
    emit(try encodedJSON(receipt), json: json)
  }

  static func runSigning(
    _ arguments: [String],
    store suppliedStore: OpenHarmonySigningPresetStore? = nil
  ) throws {
    let store =
      suppliedStore
      ?? OpenHarmonySigningPresetStore(
        secrets: LoginKeychainSigningSecretStore(allowsUserInteraction: true))
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "missing signing subcommand (install-sdk-release|install|normalize|migrate-deveco|status|remove)"
      )
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    switch subcommand {
    case "install":
      let options = try CLIOptions(rest)
      try options.validateAllowed([
        "--java", "--jar", "--keystore", "--certificate", "--profile",
        "--key-alias", "--project-ref",
      ])
      func required(_ name: String) throws -> String {
        guard let value = options.value(name), !value.isEmpty else {
          throw CLIError(exitCode: EX_USAGE, message: "signing install requires \(name)")
        }
        return value
      }
      let java = try required("--java")
      let jar = try required("--jar")
      let keystore = try required("--keystore")
      let certificate = try required("--certificate")
      let profile = try required("--profile")
      for (name, value) in [
        ("--java", java), ("--jar", jar), ("--keystore", keystore),
        ("--certificate", certificate), ("--profile", profile),
      ] where !value.hasPrefix("/") {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "signing install \(name) must be an absolute path")
      }
      var keystorePassword = try readTTYSecret(prompt: "Keystore password: ")
      defer { keystorePassword.resetBytes(in: 0..<keystorePassword.count) }
      var keyPassword = try readTTYSecret(prompt: "Key password: ")
      defer { keyPassword.resetBytes(in: 0..<keyPassword.count) }
      let keystoreURL = URL(filePath: keystore)
      var normalizedKeystorePassword = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        keystorePassword, keystore: keystoreURL)
      defer {
        normalizedKeystorePassword.resetBytes(in: 0..<normalizedKeystorePassword.count)
      }
      var normalizedKeyPassword = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        keyPassword, keystore: keystoreURL)
      defer { normalizedKeyPassword.resetBytes(in: 0..<normalizedKeyPassword.count) }
      let receipt = try store.install(
        configuration: OpenHarmonySigningPresetConfiguration(
          projectRef: options.value("--project-ref")
            ?? OpenHarmonyLocalSigning.defaultProjectRef,
          javaExecutable: URL(filePath: java),
          signerJAR: URL(filePath: jar),
          keystore: keystoreURL,
          appCertificate: URL(filePath: certificate),
          signedProfile: URL(filePath: profile),
          keyAlias: try required("--key-alias")),
        keystorePassword: normalizedKeystorePassword,
        keyPassword: normalizedKeyPassword)
      emit(try encodedJSON(receipt), json: json)

    case "normalize":
      guard rest.isEmpty else {
        throw CLIError(exitCode: EX_USAGE, message: "signing normalize accepts only --json")
      }
      emit(try encodedJSON(store.normalizeDevEcoSecrets()), json: json)

    case "migrate-deveco":
      let options = try CLIOptions(rest)
      try options.validateAllowed(["--build-profile", "--daemon", "--key-alias"])
      guard let buildProfilePath = options.value("--build-profile"),
        let daemonPath = options.value("--daemon"),
        buildProfilePath.hasPrefix("/"), daemonPath.hasPrefix("/")
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "signing migrate-deveco requires --build-profile and --daemon absolute paths")
      }
      let daemonURL = URL(filePath: daemonPath)
      if suppliedStore == nil {
        let installedDaemon = OpenHarmonyLocalSigning.defaultAgentDaemonURL()
        guard daemonURL.standardizedFileURL.path == installedDaemon.path,
          daemonURL.resolvingSymlinksInPath().standardizedFileURL.path
            == installedDaemon.path
        else {
          throw CLIError(
            exitCode: EX_USAGE,
            message:
              "signing migrate-deveco --daemon must name the canonical installed LaunchAgent daemon"
          )
        }
      }
      let migrationStore =
        suppliedStore
        ?? OpenHarmonySigningPresetStore(
          secrets: LoginKeychainSigningSecretStore(
            agentDaemonURL: daemonURL,
            allowsUserInteraction: true))
      let receipt = try migrationStore.loadValidated(requireSecrets: false)
      var encrypted = try readDevEcoBuildProfileSigningMaterial(
        at: URL(filePath: buildProfilePath))
      defer {
        encrypted.keystore.resetBytes(in: 0..<encrypted.keystore.count)
        encrypted.key.resetBytes(in: 0..<encrypted.key.count)
      }
      // The ciphertext is bound to the `material/` directory beside the
      // build-profile's storeFile. Authenticate that storeFile as the exact
      // keystore already installed in the preset before using its adjacent
      // material. Otherwise a stale or repaired build-profile can supply a
      // valid password for a different keystore and silently replace the
      // Runtime credential envelope.
      let materialAnchor = encrypted.storeFile
      let sourceKeystore = try OpenHarmonySigningPresetStore.measure(
        materialAnchor, role: "DevEco build-profile keystore", ownerPrivate: true)
      guard sourceKeystore.sha256 == receipt.keystore.sha256,
        sourceKeystore.byteCount == receipt.keystore.byteCount
      else {
        throw OpenHarmonySigningError.identityDrift(
          "DevEco build-profile keystore does not match the installed preset")
      }
      var keystorePassword = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        encrypted.keystore, keystore: materialAnchor)
      defer { keystorePassword.resetBytes(in: 0..<keystorePassword.count) }
      var keyPassword = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        encrypted.key, keystore: materialAnchor)
      defer { keyPassword.resetBytes(in: 0..<keyPassword.count) }
      emit(
        try encodedJSON(
          migrationStore.migrateToSecretEnvelope(
            keystorePassword: keystorePassword, keyPassword: keyPassword,
            keyAlias: options.value("--key-alias"))),
        json: json)

    case "status":
      guard rest.isEmpty else {
        throw CLIError(exitCode: EX_USAGE, message: "signing status accepts only --json")
      }
      // Status is a diagnostic probe, not an authorization ceremony. Match
      // the LaunchAgent's fail-closed read contract so it can never summon a
      // SecurityAgent dialog merely by checking readiness.
      let statusStore =
        suppliedStore
        ?? OpenHarmonySigningPresetStore(
          secrets: LoginKeychainSigningSecretStore())
      emit(try encodedJSON(statusStore.status()), json: json)

    case "remove":
      guard rest.isEmpty else {
        throw CLIError(exitCode: EX_USAGE, message: "signing remove accepts only --json")
      }
      emit(try encodedJSON(store.remove()), json: json)

    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported signing subcommand")
    }
  }

  private static func readTTYSecret(prompt: String) throws -> Data {
    guard isatty(STDIN_FILENO) == 1 else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "signing passwords require an interactive TTY")
    }
    FileHandle.standardError.write(Data(prompt.utf8))
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw CLIError(exitCode: 1, message: "could not read terminal attributes")
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
      throw CLIError(exitCode: 1, message: "could not disable terminal echo")
    }
    defer {
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      FileHandle.standardError.write(Data("\n".utf8))
    }
    var secret = Data()
    while secret.count <= 1_024 {
      var byte: UInt8 = 0
      let count = Darwin.read(STDIN_FILENO, &byte, 1)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw CLIError(exitCode: 1, message: "could not read signing password")
      }
      if byte == 10 || byte == 13 { break }
      guard byte >= 32, byte != 127 else {
        throw CLIError(exitCode: EX_USAGE, message: "signing password contains control bytes")
      }
      secret.append(byte)
    }
    guard !secret.isEmpty, secret.count <= 1_024 else {
      secret.resetBytes(in: 0..<secret.count)
      throw CLIError(exitCode: EX_USAGE, message: "signing password is empty or too long")
    }
    return secret
  }

  private static func readDevEcoBuildProfileSigningMaterial(
    at buildProfile: URL
  ) throws -> (keystore: Data, key: Data, storeFile: URL) {
    let path = buildProfile.standardizedFileURL.path
    var before = stat()
    guard buildProfile.isFileURL, buildProfile.path == path,
      buildProfile.resolvingSymlinksInPath().standardizedFileURL.path == path,
      path.withCString({ lstat($0, &before) }) == 0,
      before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o022 == 0,
      before.st_size > 0, before.st_size <= 1_048_576
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "DevEco build-profile is absent, mutable by another user, or unbounded")
    }
    let bytes = try Data(contentsOf: buildProfile, options: [.uncached])
    var after = stat()
    guard bytes.count == Int(before.st_size),
      path.withCString({ lstat($0, &after) }) == 0,
      before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      let document = String(data: bytes, encoding: .utf8)
    else {
      throw CLIError(exitCode: EX_USAGE, message: "DevEco build-profile identity drifted")
    }
    func exactHexField(_ name: String) throws -> Data {
      let escaped = NSRegularExpression.escapedPattern(for: name)
      let expression = try NSRegularExpression(
        pattern: "[\\\"']?\(escaped)[\\\"']?\\s*:\\s*[\\\"']([0-9A-Fa-f]{32,2048})[\\\"']")
      let range = NSRange(document.startIndex..<document.endIndex, in: document)
      let matches = expression.matches(in: document, range: range)
      guard matches.count == 1,
        let valueRange = Range(matches[0].range(at: 1), in: document)
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "DevEco build-profile must contain exactly one \(name) ciphertext")
      }
      let value = String(document[valueRange])
      guard value.utf8.count.isMultiple(of: 2) else {
        throw CLIError(exitCode: EX_USAGE, message: "DevEco \(name) ciphertext is malformed")
      }
      return Data(value.utf8)
    }
    let storeFileExpression = try NSRegularExpression(
      pattern: "[\\\"']?storeFile[\\\"']?\\s*:\\s*[\\\"']([^\\\"'\\r\\n]{1,4096})[\\\"']")
    let documentRange = NSRange(document.startIndex..<document.endIndex, in: document)
    let storeFileMatches = storeFileExpression.matches(in: document, range: documentRange)
    guard storeFileMatches.count == 1,
      let storeFileRange = Range(storeFileMatches[0].range(at: 1), in: document)
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "DevEco build-profile must contain exactly one storeFile path")
    }
    let storeFile = URL(filePath: String(document[storeFileRange]))
    guard storeFile.path.hasPrefix("/"),
      storeFile.standardizedFileURL.path == storeFile.path
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "DevEco build-profile storeFile must be a canonical absolute path")
    }
    return (
      try exactHexField("storePassword"), try exactHexField("keyPassword"), storeFile
    )
  }

  private static func defaultAgentDaemonBundlePath() -> String {
    if Bundle.main.bundleURL.pathExtension == "app" {
      return Bundle.main.bundleURL.appending(
        path:
          "Contents/Helpers/\(ArkDeckHelperIdentity.daemonBundleName)", directoryHint: .isDirectory
      ).path
    }
    guard let executable = Bundle.main.executableURL else {
      return ArkDeckHelperIdentity.daemonBundleName
    }
    return executable.deletingLastPathComponent().appending(
      path:
        ArkDeckHelperIdentity.daemonBundleName, directoryHint: .isDirectory
    ).path
  }

  private static func encodedJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  static func runOperation(_ arguments: [String]) throws {
    guard arguments.first == "list" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "usage: arkdeck operation list [--socket <path>] [--json]")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let client = client(&rest)
    guard rest.isEmpty else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "operation list received unsupported arguments")
    }
    emit(try client.request(method: "operation.list"), json: json)
  }

  static func runDevice(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing device subcommand (list|adopt|show)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list", "show":
      emit(try client.request(method: "target.list"), json: json)
    case "adopt":
      var params: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--candidate"), index + 1 < rest.count {
        params["candidate"] = .string(rest[index + 1])
      }
      emit(try client.request(method: "target.adopt", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported device subcommand")
    }
  }

  /// Read-only Trace capability portrait from the daemon's protected
  /// provider. The CLI supplies only a durable target ID; executable
  /// selection, connect-key binding and every HDC argv remain Runtime-owned.
  static func runTrace(_ arguments: [String]) throws {
    guard arguments.first == "probe" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "usage: arkdeck trace probe --target <id> [--socket <path>] [--json]")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let client = client(&rest)
    guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count else {
      throw CLIError(exitCode: EX_USAGE, message: "trace probe requires --target <id>")
    }
    let targetID = rest[targetIndex + 1]
    rest.removeSubrange(targetIndex...(targetIndex + 1))
    guard rest.isEmpty else {
      throw CLIError(exitCode: EX_USAGE, message: "trace probe received unsupported arguments")
    }
    emit(
      try client.request(method: "trace.probe", params: ["targetId": .string(targetID)]),
      json: json)
  }

  /// `arkdeck agent chat|run|resume` - the Device Runtime Agent entry point.
  /// Chat keeps conversation and tool-loop state inside ArkDeck, while every
  /// device action still enters through the typed Runtime executor.
  /// A persisted resume token keeps physical assistance inside the same
  /// execution instead of asking a maintainer to restart host commands.
  static func runAgent(_ arguments: [String]) async throws {
    if arguments.first == "chat" {
      try await AgentChatCLI.run(Array(arguments.dropFirst()))
      return
    }
    guard let subcommand = arguments.first, subcommand == "run" || subcommand == "resume" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "usage: arkdeck agent chat | agent run --operation <id@v> "
          + "| agent resume --resume-token <token>"
      )
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    let executor = AgentRuntimeExecutor(client: client, nowUTC: RuntimeCLI.utcNow)
    let outcome: RuntimeAgentExecutionOutcome

    if subcommand == "resume" {
      guard let tokenIndex = rest.firstIndex(of: "--resume-token"),
        tokenIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent resume requires --resume-token")
      }
      var selection: String?
      if let index = rest.firstIndex(of: "--selection"), index + 1 < rest.count {
        selection = rest[index + 1]
      }
      outcome = try executor.resume(
        resumeToken: rest[tokenIndex + 1], selection: selection)
    } else {
      guard let operationIndex = rest.firstIndex(of: "--operation"),
        operationIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent run requires --operation <reference>")
      }
      let parts = rest[operationIndex + 1].split(
        separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 1 || parts.count == 2 else {
        throw CLIError(exitCode: EX_USAGE, message: "invalid operation reference")
      }
      let version: Int?
      if parts.count == 2 {
        guard let parsed = Int(parts[1]), parsed > 0 else {
          throw CLIError(exitCode: EX_USAGE, message: "invalid operation version")
        }
        version = parsed
      } else {
        version = nil
      }
      var inputs: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--inputs-file"), index + 1 < rest.count {
        let url = URL(filePath: rest[index + 1])
        guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read typed inputs from \(url.path)")
        }
        inputs = decoded
      }
      var capability: String?
      if let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count {
        capability = rest[index + 1]
      }
      var target: String?
      if let index = rest.firstIndex(of: "--target"), index + 1 < rest.count {
        target = rest[index + 1]
      }
      var executionID: String?
      if let index = rest.firstIndex(of: "--execution-id"), index + 1 < rest.count {
        executionID = rest[index + 1]
      }

      outcome = try executor.run(
        RuntimeAgentExecutionRequest(
          operationID: String(parts[0]), operationVersion: version, inputs: inputs,
          capabilityReference: capability, targetID: target,
          executionID: executionID ?? UUID().uuidString.lowercased()))
    }
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    switch outcome {
    case .completed(let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      } else {
        print("completed \(receipt.operationReference) job=\(receipt.jobID ?? "-")")
      }
    case .awaitingHumanAction(let action, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      FileHandle.standardError.write(
        Data(
          """
          human action required (\(action.kind.rawValue)): \(action.prompt)
          \(action.selectionOptions.map { "selection options: \($0.joined(separator: ", "))\n" } ?? "")\
          resume with: arkdeck agent resume --resume-token \(action.resumeToken)

          """.utf8))
      throw CLIError(exitCode: 75, message: "paused for physical assistance")
    case .failed(let reason, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      throw CLIError(exitCode: 1, message: reason)
    }
  }

  static func utcNow() -> String {
    ISO8601Timestamps.string(from: Date())
  }

  static func runCapability(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing capability subcommand (list|inspect)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "capability.list"), json: json)
    case "inspect":
      guard let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "capability inspect requires --capability <id>")
      }
      emit(
        try client.request(
          method: "capability.inspect",
          params: ["capabilityId": .string(rest[index + 1])]),
        json: json)
    case "draft", "install", "revoke":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "capability administration is Runtime-owned and is not Agent-facing")
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported capability subcommand")
    }
  }

  private static func bindingRevision(targetID: String, client: AgentClient) throws -> Int {
    guard case .array(let targets) = try client.request(method: "target.list"),
      let match = targets.first(where: { value in
        guard case .object(let fields) = value,
          case .string(let listed)? = fields["targetId"]
        else {
          return false
        }
        return listed == targetID
      }),
      case .object(let fields) = match,
      case .integer(let revision)? = fields["bindingRevision"],
      let exact = Int(exactly: revision),
      exact > 0
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "target \(targetID) has no durable binding revision")
    }
    return exact
  }

  static func runArtifact(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "missing artifact subcommand "
          + "(import-hap|import-workspace-patch|import-flash-bundle|"
          + "import-native-library|list|inspect|read|export)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    if subcommand == "import-flash-bundle" {
      try importFlashBundle(rest, client: client, json: json)
      return
    }
    if subcommand == "import-hap" {
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"), fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "artifact import-hap requires --target <id> --file <unsigned-or-signed.hap>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readHAPImportPayload(path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importHap.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importHap.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importHap.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importHap.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importHap.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importHap.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    if subcommand == "import-workspace-patch" {
      guard let targetIndex = rest.firstIndex(of: "--target"),
        targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"),
        fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "artifact import-workspace-patch requires --target <id> --file <change.patch>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readWorkspacePatchImportPayload(path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importWorkspacePatch.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importWorkspacePatch.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importWorkspacePatch.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importWorkspacePatch.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importWorkspacePatch.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importWorkspacePatch.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    if subcommand == "import-native-library" {
      guard let targetIndex = rest.firstIndex(of: "--target"),
        targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"),
        fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "artifact import-native-library requires "
            + "--target <id> --file <libname.so>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readNativeLibraryImportPayload(
        path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importNativeLibrary.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? =
          beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importNativeLibrary.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importNativeLibrary.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importNativeLibrary.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importNativeLibrary.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importNativeLibrary.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    guard let jobIndex = rest.firstIndex(of: "--job"), jobIndex + 1 < rest.count else {
      throw CLIError(exitCode: EX_USAGE, message: "artifact commands require --job <id>")
    }
    var params: [String: JSONValue] = ["jobId": .string(rest[jobIndex + 1])]
    if let index = rest.firstIndex(of: "--artifact"), index + 1 < rest.count {
      params["artifactId"] = .string(rest[index + 1])
    }
    if rest.contains("--allow-sensitive") { params["allowSensitive"] = .bool(true) }
    switch subcommand {
    case "list":
      emit(try client.request(method: "artifact.list", params: params), json: json)
    case "inspect":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact inspect requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.inspect", params: params), json: json)
    case "read":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact read requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.read", params: params), json: json)
    case "export":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact export requires --artifact <id>")
      }
      guard let index = rest.firstIndex(of: "--destination"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "artifact export requires --destination <directory>")
      }
      params["destinationDirectory"] = .string(rest[index + 1])
      emit(try client.request(method: "artifact.export", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported artifact subcommand")
    }
  }

  private static func importFlashBundle(
    _ arguments: [String],
    client: AgentClient,
    json: Bool
  ) throws {
    guard let targetIndex = arguments.firstIndex(of: "--target"),
      targetIndex + 1 < arguments.count,
      let fileIndex = arguments.firstIndex(of: "--file"),
      fileIndex + 1 < arguments.count
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "artifact import-flash-bundle requires "
          + "--target <id> --file <images.tar.gz> "
          + "[--device-profile <dayu200>]")
    }
    let targetID = arguments[targetIndex + 1]
    let url = URL(filePath: arguments[fileIndex + 1]).standardizedFileURL
    // The vendor publishes `version-Daily_Version-OpenHarmony_7.0.0.37-…-\
    // dayu200_img.tar.gz`. Requiring a rename before the product would look at
    // the file was never a safety check — the archive is judged by reading it.
    let profileReference: String
    if let profileIndex = arguments.firstIndex(of: "--device-profile"),
      profileIndex + 1 < arguments.count
    {
      profileReference = arguments[profileIndex + 1]
    } else {
      profileReference = "dayu200"
    }
    guard RockchipFlashProfile.profile(reference: profileReference) != nil else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "unsupported DAYU200 device profile \(profileReference)")
    }
    emit(
      try importFlashBundleResult(
        client: client, targetID: targetID, url: url, expectedProfile: nil),
      json: json)
  }

  /// Streams the archive to the daemon and returns the commit response. The
  /// wire name is the published member name the daemon pins; the on-disk
  /// basename is not what identifies these bytes. A campaign supplies its
  /// admission-derived profile and must match its exact size/SHA before the
  /// first RPC. The generic import lane accepts a structurally valid new daily
  /// and lets daemon validation derive its identity. Both lanes re-hash the
  /// same descriptor while uploading and reject source-file drift.
  private static func importFlashBundleResult(
    client: AgentClient,
    targetID: String,
    url: URL,
    expectedProfile: RockchipFlashProfile?
  ) throws -> JSONValue {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "cannot open flash bundle file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "flash bundle must be a non-empty regular file")
    }
    // What the daemon is told the upload will be. It reads the archive itself
    // and refuses one that does not arrive as declared, or does not fit the
    // board; the CLI states facts about the file it holds, and pins nothing.
    let declaredByteCount = Int64(before.st_size)
    let declaredSHA256 = try Self.streamedDigest(ofDescriptor: descriptor)
    if let expectedProfile {
      guard declaredByteCount == expectedProfile.archiveSizeBytes,
        declaredSHA256 == expectedProfile.archiveSHA256
      else {
        throw CLIError(
          exitCode: EX_DATAERR,
          message:
            "flash bundle size or SHA-256 does not match the profile materialized by admission")
      }
    }

    let begin = try client.request(
      method: "artifact.importFlashBundle.begin",
      params: [
        "targetId": .string(targetID),
        "name": .string("images.tar.gz"),
        "byteCount": .integer(declaredByteCount),
        "sha256": .string(declaredSHA256),
      ])
    guard case .object(let beginFields) = begin,
      case .string(let uploadID)? = beginFields["uploadId"],
      case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
      maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
    else {
      throw AgentClientError.malformedResponse(
        "artifact.importFlashBundle.begin returned no bounded upload identity")
    }
    var committed = false
    defer {
      if !committed {
        _ = try? client.request(
          method: "artifact.importFlashBundle.abort",
          params: ["uploadId": .string(uploadID)])
      }
    }

    let maximumChunk = Int(maximumChunkValue)
    var buffer = [UInt8](repeating: 0, count: maximumChunk)
    var hasher = SHA256()
    var offset = 0
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_IOERR,
          message: "flash bundle read failed (errno \(errno))")
      }
      if count == 0 { break }
      let chunk = Data(buffer[0..<count])
      hasher.update(data: chunk)
      let appended = try client.request(
        method: "artifact.importFlashBundle.append",
        params: [
          "uploadId": .string(uploadID),
          "offset": .integer(Int64(offset)),
          "base64": .string(chunk.base64EncodedString()),
        ])
      let expectedNextOffset = offset + count
      guard case .object(let fields) = appended,
        case .integer(let nextOffset)? = fields["nextOffset"],
        nextOffset == Int64(expectedNextOffset)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importFlashBundle.append returned a mismatched offset")
      }
      offset = expectedNextOffset
    }
    var after = stat()
    let digest =
      SHA256Hex.hexString(hasher.finalize())
    guard offset == Int(declaredByteCount),
      digest == declaredSHA256,
      fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message:
          "flash bundle changed during import or does not match the pinned DAYU200 SHA-256")
    }
    let result = try client.request(
      method: "artifact.importFlashBundle.commit",
      params: ["uploadId": .string(uploadID)])
    committed = true
    return result
  }

  private struct HAPImportPayload {
    let name: String
    let contents: Data
    let sha256: String
  }

  private static func readHAPImportPayload(path: String) throws -> HAPImportPayload {
    let url = URL(filePath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.hap$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP file must have a safe .hap basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE, message: "cannot open HAP file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = 64 * 1_024 * 1_024
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "HAP must be a non-empty regular file no larger than \(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_USAGE, message: "HAP read failed (errno \(errno))")
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP changed while it was being imported")
    }
    guard contents.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP is not a ZIP-based .hap container")
    }
    let digest = SHA256Hex.string(of: contents)
    return HAPImportPayload(name: name, contents: contents, sha256: digest)
  }

  private static func readWorkspacePatchImportPayload(path: String) throws -> HAPImportPayload {
    let url = URL(filePath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.(patch|diff)$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "workspace patch file must have a safe .patch or .diff basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE, message: "cannot open workspace patch file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = 512 * 1_024
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "workspace patch must be a non-empty regular file no larger than "
          + "\(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
    while contents.count < Int(before.st_size) {
      let remaining = Int(before.st_size) - contents.count
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw CLIError(
          exitCode: EX_USAGE, message: "workspace patch changed while it was being imported")
      }
      contents.append(contentsOf: buffer[0..<count])
    }
    var extra: UInt8 = 0
    let extraCount = Darwin.read(descriptor, &extra, 1)
    var after = stat()
    guard extraCount == 0,
      fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "workspace patch changed while it was being imported")
    }
    do {
      _ = try WorkspaceProviderSupport.patchPaths(from: contents)
    } catch {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "workspace patch is not a safe bounded UTF-8 unified diff")
    }
    return HAPImportPayload(
      name: name,
      contents: contents,
      sha256: SHA256Hex.string(of: contents))
  }

  private static func readNativeLibraryImportPayload(
    path: String
  ) throws -> HAPImportPayload {
    let url = URL(filePath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "native library file must have a safe lib*.so basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "cannot open native library file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = NativeLibraryArtifactValidator.maximumBytes
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 64,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "native library must be a regular file of 64...\(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "native library read failed (errno \(errno))")
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "native library changed while it was being imported")
    }
    do {
      _ = try NativeLibraryArtifactValidator.validate(
        contents, requireOpenHarmonyCodeSignature: true)
    } catch {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "native library failed ELF validation: \(error)")
    }
    let digest = SHA256Hex.string(of: contents)
    return HAPImportPayload(name: name, contents: contents, sha256: digest)
  }

  private static func json2Bool(_ arguments: [String]) -> Bool {
    arguments.contains("--json")
  }

  /// `arkdeck cleanup-debt list|continue` — the operator surface for cleanup
  /// that ran and did not take effect, whether it left a remote file or an
  /// installed bundle (CHG-2026-049 r3). The engine records the debt with the *exact typed
  /// action* it could not complete; `continue` only re-runs that recorded
  /// action, so `--remote-path` is a lookup key into the ledger, never a
  /// device path a caller gets to choose. The daemon has owned these two
  /// methods since MU-4 and nothing could call them.
  static func runCleanupDebt(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE, message: "missing cleanup-debt subcommand (list|continue)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "cleanupDebt.list"), json: json)
    case "continue":
      var residue: (key: String, value: String)?
      if let index = rest.firstIndex(of: "--remote-path"), index + 1 < rest.count {
        residue = ("remotePath", rest[index + 1])
      } else if let index = rest.firstIndex(of: "--bundle"), index + 1 < rest.count {
        residue = ("bundleName", rest[index + 1])
      }
      guard let jobIndex = rest.firstIndex(of: "--job"), jobIndex + 1 < rest.count,
        let residue
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "cleanup-debt continue requires --job <id> and one of "
            + "--remote-path <recorded path> / --bundle <recorded bundle>")
      }
      emit(
        try client.request(
          method: "cleanupDebt.continue",
          params: [
            "jobId": .string(rest[jobIndex + 1]),
            .init(residue.key): .string(residue.value),
          ]),
        json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported cleanup-debt subcommand")
    }
  }

  /// Builds the typed v2 request document `job plan` and `job submit` send.
  ///
  /// Both used to demand a hand-written document the moment an operation had
  /// typed inputs, which is nearly all of them: the flag form could express
  /// only target and operation. So a caller wanting to pass `durationSeconds`
  /// also had to get `schemaVersion`, `requestId` and `idempotencyKey` right,
  /// and the only way to learn those was to be refused once for each. The
  /// envelope is not the caller's problem, so the CLI writes it — exactly as
  /// `arkdeck agent run` already did.
  ///
  /// `--request-file` stays for a caller that wants to control the document
  /// byte for byte; it is still passed through verbatim so the daemon, not
  /// this CLI, remains the validator.
  private static func operationRequestJSON(
    _ rest: [String], subcommand: String
  ) throws -> String {
    func value(_ flag: String) -> String? {
      guard let index = rest.firstIndex(of: flag), index + 1 < rest.count else { return nil }
      return rest[index + 1]
    }

    let requestFile = value("--request-file")
    let inputsFile = value("--inputs-file")
    guard requestFile == nil || inputsFile == nil else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "\(subcommand) takes --request-file (a complete document) or --inputs-file "
          + "(typed inputs the CLI wraps), not both")
    }

    if let requestFile {
      let url = URL(filePath: requestFile)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
      }
      return text
    }

    guard let targetID = value("--target"), let reference = value("--operation") else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "\(subcommand) requires --target <id> --operation <reference> "
          + "[--inputs-file <typed-inputs.json>], or --request-file <path>")
    }
    let parts = reference.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else {
      throw CLIError(exitCode: EX_USAGE, message: "invalid operation reference")
    }
    var version: Int?
    if parts.count == 2 {
      guard let parsed = Int(parts[1]), parsed > 0 else {
        throw CLIError(exitCode: EX_USAGE, message: "invalid operation version")
      }
      version = parsed
    }
    var pinnedRevision: Int?
    if let raw = value("--expected-binding-revision") {
      guard let parsed = Int(raw), parsed >= 1 else {
        throw CLIError(
          exitCode: EX_USAGE, message: "--expected-binding-revision takes a positive integer")
      }
      pinnedRevision = parsed
    }
    // Typed inputs only: the file is the `inputs` object, not a request. A
    // whole document here would silently lose its envelope, so it is refused
    // with the flag that does take one.
    var inputs: [String: JSONValue] = [:]
    if let inputsFile {
      let url = URL(filePath: inputsFile)
      guard let data = try? Data(contentsOf: url) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
      }
      guard let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "--inputs-file must be a JSON object of typed inputs: \(url.path)")
      }
      if decoded["schemaVersion"] != nil || decoded["operation"] != nil {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "--inputs-file looks like a complete request document; pass it with "
            + "--request-file, or reduce it to the inputs object")
      }
      inputs = decoded
    }

    let request: RuntimeOperationRequest
    do {
      // The request model owns the rules a caller keeps getting wrong —
      // a device-bound operation must pin its binding revision, a host-only
      // one must not — so the refusal is its wording, not a second one here.
      request = try RuntimeOperationRequest.operatorFlagForm(
        targetID: targetID,
        expectedBindingRevision: pinnedRevision,
        operationID: String(parts[0]),
        version: version,
        inputs: inputs,
        requestID: "cli-\(UUID().uuidString.prefix(8).lowercased())",
        idempotencyKey: "cli-\(UUID().uuidString.lowercased())")
    } catch let rejection as RuntimeOperationRequestRejection {
      throw CLIError(exitCode: EX_USAGE, message: rejection.message)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let text = String(data: try encoder.encode(request), encoding: .utf8) else {
      throw CLIError(exitCode: 1, message: "could not encode the operation request")
    }
    return text
  }

  static func runJob(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing job subcommand (plan|submit|status|list|run|cancel|reconcile)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "plan":
      let planJSON = try operationRequestJSON(rest, subcommand: "job plan")
      emit(
        try client.request(
          method: "job.plan", params: ["requestJson": .string(planJSON)]),
        json: json)
    case "list":
      let pageSize: Int?
      if let index = rest.firstIndex(of: "--page-size"), index + 1 < rest.count {
        guard let value = Int(rest[index + 1]), (1...1_000).contains(value) else {
          throw CLIError(exitCode: EX_USAGE, message: "--page-size must be 1...1000")
        }
        pageSize = value
      } else {
        pageSize = nil
      }
      let cursor = rest.firstIndex(of: "--cursor").flatMap { index in
        index + 1 < rest.count ? rest[index + 1] : nil
      }
      if rest.contains("--cursor"), cursor == nil {
        throw CLIError(exitCode: EX_USAGE, message: "--cursor requires a value")
      }
      if pageSize != nil || cursor != nil {
        var params: [String: JSONValue] = [:]
        if let pageSize { params["pageSize"] = .integer(Int64(pageSize)) }
        if let cursor { params["cursor"] = .string(cursor) }
        emit(try client.request(method: "job.list-page", params: params), json: json)
      } else {
        emit(try client.request(method: "job.list"), json: json)
      }
    case "status":
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job status requires --job <id>")
      }
      let statusResponse = try client.request(
        method: "job.status", params: ["jobId": .string(rest[index + 1])])
      emit(statusResponse, json: json)
      if let terminal = terminalJobExit(statusResponse) {
        throw CLIError(exitCode: terminal.code, message: terminal.reason)
      }
    case "run":
      // Resuming a reconciled job is what settles its authorization lineage.
      // `reconcile` deliberately leaves a `confirmedCompleted` decision
      // holding its reservation — the job still owns it until the remaining
      // plan (cleanup, finalize) runs — but nothing could run it: `job.run`
      // accepts `resumeAtConfirmedSafeBoundary` and the CLI only ever
      // reached it through `submit --wait`. Without this, every reconciled
      // job left the target blocked for automatic E1 forever.
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job run requires --job <id>")
      }
      let runResponse = try client.request(
        method: "job.run", params: ["jobId": .string(rest[index + 1])])
      emit(runResponse, json: json)
      if let terminal = terminalJobExit(runResponse) {
        throw CLIError(exitCode: terminal.code, message: terminal.reason)
      }
    case "cancel":
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job cancel requires --job <id>")
      }
      emit(
        try client.request(
          method: "job.cancel", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "reconcile":
      // The daemon has owned `job.reconcile` since MU-4; the CLI did not
      // expose it, so a job left in `waitingForRecovery` had no operator
      // path to resolution — and an unresolved mutation use blocks every
      // later automatic E1 on that target (2026-07-31 device window). This
      // asks the daemon to run the read-only readback that settles the
      // outstanding intent; it never redispatches the mutation.
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job reconcile requires --job <id>")
      }
      emit(
        try client.request(method: "job.reconcile", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "submit":
      let requestJSON = try operationRequestJSON(rest, subcommand: "job submit")
      let submitted = try client.request(
        method: "job.submit", params: ["requestJson": .string(requestJSON)])
      emit(submitted, json: json)
      if rest.contains("--wait") {
        try completeWaitedSubmit(submitted, client: client, json: json)
      }
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported job subcommand")
    }
  }

  /// Protected destructive Flash recovery only. Ordinary Agent debugging is
  /// driven by an external agent through the published job/artifact surface.
  /// The candidate file here is the closed recovery decision document; the
  /// CLI has no target, inputs, plan, argv or capability flag on the
  /// evaluation path.
  static func runDebug(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing debug subcommand (start|evaluate|status)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let client = client(&rest)

    func value(_ flag: String) -> String? {
      guard let index = rest.firstIndex(of: flag), index + 1 < rest.count else { return nil }
      return rest[index + 1]
    }

    switch subcommand {
    case "start":
      guard let requestPath = value("--request-file") else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "debug start requires --request-file <destructive-flash-request.json>")
      }
      let requestURL = URL(filePath: requestPath)
      guard let requestJSON = try? String(contentsOf: requestURL, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(requestURL.path)")
      }
      emit(
        try client.request(
          method: "debug.start", params: ["requestJson": .string(requestJSON)]),
        json: json)

    case "evaluate":
      guard let invocationID = value("--invocation"),
        let actionPath = value("--action-file"),
        let sourceSHA256 = value("--source-sha256"),
        let buildSHA256 = value("--build-sha256")
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "debug evaluate requires --invocation <id> --action-file <effect-action.json> "
            + "--source-sha256 <sha256> --build-sha256 <sha256>")
      }
      let actionURL = URL(filePath: actionPath)
      guard let actionJSON = try? String(contentsOf: actionURL, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(actionURL.path)")
      }
      emit(
        try client.request(
          method: "debug.evaluate",
          params: [
            "invocationId": .string(invocationID),
            "actionJson": .string(actionJSON),
            "sourceSha256": .string(sourceSHA256),
            "buildSha256": .string(buildSHA256),
          ]),
        json: json)

    case "status":
      guard let invocationID = value("--invocation") else {
        throw CLIError(
          exitCode: EX_USAGE, message: "debug status requires --invocation <id>")
      }
      emit(
        try client.request(
          method: "debug.status", params: ["invocationId": .string(invocationID)]),
        json: json)

    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported debug subcommand")
    }
  }

  /// SHA-256 of an already-open file, read from the start and leaving the
  /// descriptor where it began. The upload re-reads the same descriptor and
  /// re-hashes as it goes, so a file that changes underneath is still caught
  /// by the identity and mtime checks after the last chunk.
  static func streamedDigest(ofDescriptor descriptor: Int32) throws -> String {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw CLIError(exitCode: EX_IOERR, message: "cannot rewind flash bundle file")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if read == 0 { break }
      guard read > 0 else {
        throw CLIError(exitCode: EX_IOERR, message: "cannot read flash bundle file")
      }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<read]))
      }
    }
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw CLIError(exitCode: EX_IOERR, message: "cannot rewind flash bundle file")
    }
    return SHA256Hex.hexString(hasher.finalize())
  }

}
