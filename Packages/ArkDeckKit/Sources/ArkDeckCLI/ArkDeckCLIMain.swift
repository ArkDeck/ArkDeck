import ArkDeckAgentComposition
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

// TASK-RF-002. `arkdeck flash` — the product face of the RockUSB Provider.
//
// Real Flash execution is submitted by the App or the generic typed Runtime Job API.
// Historical campaign and standing-authority records remain status/export inputs only;
// this CLI exposes no authority writer, capability administration, or second execution stack.

@main
struct ArkDeckCommandLine {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
      printUsage()
      exit(EX_USAGE)
    }
    do {
      switch command {
      case "flash":
        try await runFlash(Array(arguments.dropFirst()))
      case "update-feed":
        try runUpdateFeed(Array(arguments.dropFirst()))
      case "doctor":
        try RuntimeCLI.runDoctor(Array(arguments.dropFirst()))
      case "debug":
        try RuntimeCLI.runDebug(Array(arguments.dropFirst()))
      case "operation":
        try RuntimeCLI.runOperation(Array(arguments.dropFirst()))
      case "device":
        try RuntimeCLI.runDevice(Array(arguments.dropFirst()))
      case "trace":
        try RuntimeCLI.runTrace(Array(arguments.dropFirst()))
      case "job":
        try RuntimeCLI.runJob(Array(arguments.dropFirst()))
      case "cleanup-debt":
        try RuntimeCLI.runCleanupDebt(Array(arguments.dropFirst()))
      case "agent":
        try await RuntimeCLI.runAgent(Array(arguments.dropFirst()))
      case "agentd":
        try RuntimeCLI.runAgentDaemon(
          Array(arguments.dropFirst()),
          beforeBootstrap: RuntimeCLI.refreshSigningAccessIfInstalled)
      case "signing":
        try await RuntimeCLI.runSigningAsync(Array(arguments.dropFirst()))
      case "capability":
        try RuntimeCLI.runCapability(Array(arguments.dropFirst()))
      case "artifact":
        try RuntimeCLI.runArtifact(Array(arguments.dropFirst()))
      default:
        printUsage()
        exit(EX_USAGE)
      }
    } catch let error as CLIError {
      FileHandle.standardError.write(Data("arkdeck \(command): \(error.message)\n".utf8))
      exit(error.exitCode)
    } catch {
      FileHandle.standardError.write(Data("arkdeck \(command): \(error)\n".utf8))
      exit(1)
    }
  }

  static func runFlash(_ arguments: [String]) async throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing flash subcommand")
    }
    switch subcommand {
    case "install-binding":
      try runInstallBinding(Array(arguments.dropFirst()))
    case "plan":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "legacy command handoff is retired; use Runtime plan-only for flash.full-restore@1")
    case "preview":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "historical campaign preview is retired; Runtime owns Flash admission")
    case "execute":
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "the legacy flash executor is retired; for headless real-device validation use "
          + "`arkdeck agent run --operation flash.full-restore@1` with its typed inputs, "
          + "or use the ArkDeck Flash UI only when validating the App surface")
    case "continue":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "historical campaign continuation is retired and cannot dispatch")
    case "status":
      try runCampaignStatus(Array(arguments.dropFirst()))
    case "postflight":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "legacy observation-file postflight is retired; use Runtime job evidence")
    case "reconcile":
      try runFlashReconcile(Array(arguments.dropFirst()))
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported flash subcommand")
    }
  }

  // MARK: reconcile

  /// Host-side recovery report for interrupted flash sessions. Read-only and
  /// zero device dispatch: it decodes session journals and the campaign usage
  /// ledger and prints what is still unresolved. Legacy records never admit
  /// or dispatch a new operation.
  ///
  /// It no longer writes terminals. `--mode close` existed to close orphaned
  /// standing-authorization reservations; that lane and its ledger are
  /// decode/export-only. A close verb that can no longer close anything would
  /// report work it never did, so it is gone rather than kept as a no-op.
  /// Exit 4 while anything stays unresolved, so scripts still observe the debt.
  static func runFlashReconcile(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--session"])
    let reconciler = try RockchipLegacyFlashJournalReconciler.production()

    if let sessionID = options.value("--session") {
      let finding = try reconciler.inspect(sessionID: sessionID)
      printFlashFinding(finding)
      guard !finding.requiresAttention else {
        throw CLIError(exitCode: 4, message: "unresolved flash session \(sessionID)")
      }
      return
    }

    let findings = try reconciler.scan()
    let orphans = try reconciler.orphanedReservations()
    guard !findings.isEmpty || !orphans.isEmpty else {
      print("no unresolved flash sessions")
      return
    }
    for finding in findings { printFlashFinding(finding) }
    for orphan in orphans { printFlashOrphan(orphan) }
    throw CLIError(
      exitCode: 4,
      message: "\(findings.count + orphans.count) unresolved flash item(s)")
  }

  private static func printFlashOrphan(_ orphan: RockchipFlashOrphanedReservation) {
    print(
      "orphaned reservation: \(orphan.reservationID) job=\(orphan.jobID) "
        + "reservedAt=\(orphan.reservedAt)")
    print("  no session directory accounts for this open reservation")
    if let campaignID = orphan.campaignID {
      print("  historical campaign: \(campaignID) (decode/export only)")
    }
  }

  private static func printFlashFinding(_ finding: RockchipFlashSessionFinding) {
    var header = ["session: \(finding.sessionID)"]
    if let jobID = finding.jobID { header.append("job: \(jobID)") }
    header.append("state: \(finding.currentState?.rawValue ?? "unknown")")
    header.append("finalized: \(finding.finalized)")
    if finding.hasTornTail { header.append("tornTail: true") }
    if finding.isLive { header.append("live: true") }
    print(header.joined(separator: " "))
    if finding.isLive {
      print("  a live run owns this session; its own terminal is authoritative")
    }
    if let journalError = finding.journalError {
      print("  journal unreadable: \(journalError)")
    }
    for intent in finding.outstandingIntents {
      print(
        "  outstanding intent: \(intent.eventID) step=\(intent.stepID) "
          + "attempt=\(intent.attempt) effect=\(intent.effect.rawValue)")
    }
    for outcome in finding.unknownOutcomes {
      print(
        "  unknown outcome: \(outcome.correlatedIntentEventID) step=\(outcome.stepID) "
          + "effect=\(outcome.effect.rawValue)")
    }
    if let lastConfirmed = finding.lastConfirmedStepID {
      print("  last confirmed step: \(lastConfirmed)")
    }
    switch finding.ledgerState {
    case .openAgentReservation(let reservationID):
      print("  authority: campaign reservation=\(reservationID) (open)")
      if let campaignID = finding.campaignID {
        print("  inspect: arkdeck flash status --campaign-id \(campaignID)")
      }
    case .closed(let reservationID):
      print("  authority: reservation=\(reservationID) (closed)")
    case .missing(let reservationID):
      print("  authority: reservation=\(reservationID) missing from ledger")
    case .none:
      print("  authority: no usage reservation recorded")
    }
  }

  static func runInstallBinding(_ arguments: [String]) throws {
    // A bench board that moved to another USB port, or a different board on
    // the bench, changes the binding this product matches every destructive
    // admission against. Refusing by default is right; refusing with no way to
    // say "yes, rebind" left a replugged board permanently unflashable.
    //
    // Stripped before parsing because it carries no value, the same shape as
    // `--json`.
    var rest = arguments
    let rebind = rest.contains("--rebind")
    rest.removeAll { $0 == "--rebind" }
    let options = try CLIOptions(rest)
    try options.validateAllowed([])
    let receipt = try RockchipDeviceBindingInstallation.installCurrentTarget(rebind: rebind)
    print(
      receipt.created
        ? "durable DAYU200 cross-mode binding installed"
        : "durable DAYU200 cross-mode binding unchanged")
    print("binding revision: \(receipt.revision)")
    print("USB topology: \(receipt.usbTopology)")
    print("serial sha256: \(receipt.serialDigestSHA256)")
    print("device mutation dispatch: 0")
  }

  static func runCampaignStatus(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--campaign-id"])
    guard let campaignID = options.value("--campaign-id") else {
      throw CLIError(exitCode: EX_USAGE, message: "status requires --campaign-id")
    }
    let document = try HistoricalEvolutionCampaignArchive.production().load(campaignID)
    print("campaign: \(document.campaignID)")
    print("terminal: \(document.isTerminal)")
    print("reserved attempts: \(document.reservedAttemptCount)/\(document.assertion.maxAttempts)")
    for event in document.events {
      var fields = ["#\(event.sequence)", event.kind.rawValue, event.at]
      if let ordinal = event.ordinal { fields.append("ordinal=\(ordinal)") }
      if let candidate = event.candidate { fields.append("candidate=\(candidate.candidateID)") }
      if let review = event.review { fields.append("review=\(review.reviewID)") }
      if let disposition = event.disposition {
        fields.append("disposition=\(disposition.rawValue)")
      }
      if let reason = event.reasonCode { fields.append("reason=\(reason)") }
      print(fields.joined(separator: " "))
      // The root cause, printed on its own line: it is the one field here that
      // is prose rather than an identifier, and folding it into the columns
      // above would make the stop event unreadable.
      if let detail = event.detail { print("  detail: \(detail)") }
    }
  }

  // MARK: update-feed

  static func runUpdateFeed(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing update-feed subcommand")
    }
    switch subcommand {
    case "prepare":
      try prepareUpdateFeed(Array(arguments.dropFirst()))
    case "assemble":
      try assembleUpdateFeed(Array(arguments.dropFirst()))
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported update-feed subcommand")
    }
  }

  static func prepareUpdateFeed(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed([
      "--sequence", "--version", "--minimum-system", "--issued-at", "--expires-at",
      "--artifact", "--artifact-url", "--notes", "--out",
    ])
    guard let sequenceText = options.value("--sequence"), let sequence = UInt64(sequenceText),
      sequence > 0,
      let version = options.value("--version"),
      let minimumSystemVersion = options.value("--minimum-system"),
      let issuedAt = options.value("--issued-at"), let expiresAt = options.value("--expires-at"),
      let artifactPath = options.value("--artifact"),
      let artifactURL = options.value("--artifact-url"),
      let notes = options.value("--notes"), let outputPath = options.value("--out")
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "prepare requires sequence/version/minimum-system/issued-at/expires-at/"
          + "artifact/artifact-url/notes/out")
    }
    let artifact = URL(filePath: artifactPath).standardizedFileURL
    let measurement = try measureArtifact(artifact)
    let payload = UpdateFeedPayload(
      sequence: sequence,
      version: version,
      minimumSystemVersion: minimumSystemVersion,
      architectures: ["arm64"],
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      artifact: UpdateArtifactDescriptor(
        url: artifactURL, byteLength: measurement.byteLength, sha256: measurement.sha256),
      releaseNotesSummary: notes)
    try UpdateFeedVerifier.validateUnsignedPayloadForSigning(payload)
    let canonicalPayload = try UpdateFeedCodec.canonicalPayload(payload)
    let signatureInput = try UpdateFeedCodec.signatureInput(
      payload: canonicalPayload, keyID: UpdateFeedTrust.productionKeyID)
    let output = URL(filePath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let payloadURL = output.appending(path: "arkdeck-update-payload-v1.json")
    let inputURL = output.appending(path: "arkdeck-update-signature-input-v1.bin")
    try canonicalPayload.write(to: payloadURL, options: [.atomic, .completeFileProtection])
    try signatureInput.write(to: inputURL, options: [.atomic, .completeFileProtection])
    print("payload: \(payloadURL.path)")
    print("signature input: \(inputURL.path)")
    print("artifact bytes: \(measurement.byteLength)")
    print("artifact sha256: \(measurement.sha256)")
    print("key ID: \(UpdateFeedTrust.productionKeyID)")
  }

  static func assembleUpdateFeed(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--payload", "--signature", "--out"])
    guard let payloadPath = options.value("--payload"),
      let signaturePath = options.value("--signature"),
      let outputPath = options.value("--out")
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "assemble requires --payload, --signature and --out")
    }
    let payload = try Data(
      contentsOf: URL(filePath: payloadPath),
      options: [.mappedIfSafe, .uncached])
    let signature = try Data(
      contentsOf: URL(filePath: signaturePath),
      options: [.mappedIfSafe, .uncached])
    let envelope = try UpdateFeedCodec.assemble(
      canonicalPayload: payload,
      signature: signature,
      keyID: UpdateFeedTrust.productionKeyID)
    let decoded = try UpdateFeedCodec.decodeAndVerify(
      envelope, trust: try UpdateFeedTrust.production)
    guard decoded.canonicalPayload == payload else {
      throw CLIError(exitCode: 2, message: "self-verification payload mismatch")
    }
    let system = ProcessInfo.processInfo.operatingSystemVersion
    _ = try UpdateFeedVerifier(
      trust: try UpdateFeedTrust.production,
      replayStore: CLIUpdateReplayStore()
    ).verify(
      envelope,
      context: UpdateVerificationContext(
        installedVersion: "0.0.0",
        systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
        architecture: "arm64"),
      now: Date())
    let output = URL(filePath: outputPath).standardizedFileURL
    try envelope.write(to: output, options: [.atomic, .completeFileProtection])
    print("feed: \(output.path)")
    print("feed sha256: \(UpdateFeedCodec.sha256(envelope))")
    print("self-verification: valid")
  }

  static func measureArtifact(_ url: URL) throws -> (byteLength: UInt64, sha256: String) {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(exitCode: 2, message: "cannot open artifact (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0
    else { throw CLIError(exitCode: 2, message: "artifact must be a non-empty regular file") }
    var hasher = SHA256()
    var measured: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(exitCode: 2, message: "artifact read failed (errno \(errno))")
      }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
      measured += UInt64(count)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      measured == UInt64(metadata.st_size),
      after.st_dev == metadata.st_dev,
      after.st_ino == metadata.st_ino,
      after.st_size == metadata.st_size,
      after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec
    else {
      throw CLIError(exitCode: 2, message: "artifact changed while being measured")
    }
    let digest = SHA256Hex.hexString(hasher.finalize())
    return (measured, digest)
  }

  static func printUsage() {
    let usage = """
      usage:
        arkdeck flash install-binding [--rebind]
        arkdeck flash status --campaign-id <ECAMP-id>
        arkdeck flash reconcile [--session <id>]
        arkdeck update-feed prepare --sequence <n> --version <x.y.z> \
      --minimum-system <x.y.z> --issued-at <RFC3339> --expires-at <RFC3339> \
      --artifact <ArkDeck.dmg> --artifact-url <https-url> --notes <summary> --out <dir>
        arkdeck update-feed assemble --payload <payload.json> --signature <signature.bin> \
      --out <feed.json>
        arkdeck doctor [--socket <path>] [--json]
        arkdeck agentd install --hdc <absolute-hdc-path> [--daemon <absolute-agentd-path>] \
      [--workspace-project <absolute-waterflow-path> --deveco-sdk <absolute-sdk-path>] \
      [--arktrace-descriptor <absolute-descriptor-path|none>] [--json]
      [--arkforge-bundle <absolute-ArkForge.bundle|none> [--arkforge-campaign <id>]]
        arkdeck agentd update [--hdc <absolute-hdc-path>] [--daemon <absolute-agentd-path>] \
      [--workspace-project <absolute-waterflow-path> --deveco-sdk <absolute-sdk-path>] \
      [--arktrace-descriptor <absolute-descriptor-path|none>] [--json]
      [--arkforge-bundle <absolute-ArkForge.bundle|none> [--arkforge-campaign <id>]]
        legacy ArkForge options are rejected with migration guidance: \
      --arkforged --arkforged-sha256 --arkforge-profile
        arkdeck agentd restart [--maximum-wait-seconds <1...300>] [--json]
        arkdeck agentd status [--json]
        arkdeck agentd verify [--target <id>] [--maximum-wait-seconds <1...300>] \
      [--execution-id <id>] [--json]
        arkdeck agentd verify --job <existing-profiled-job-id> [--json]
        arkdeck agentd uninstall [--json]
        arkdeck signing install-sdk-release --sdk <absolute-openharmony-sdk-path> \
      --java <absolute-java-path> --bundle-name <application-bundle-name> \
      [--project-ref <demo-app>] [--json]
        arkdeck signing install --java <absolute-java-path> --jar <absolute-hapsigntool-jar> \
      --keystore <absolute-p12-or-jks> --certificate <absolute-pem-or-cer> \
      --profile <absolute-p7b> --key-alias <alias> [--project-ref <demo-app>] [--json]
        arkdeck signing normalize [--json]
        arkdeck signing migrate-deveco --build-profile <absolute-build-profile.json5> \
      --daemon <absolute-agentd-path> [--key-alias <alias>] [--json]
        arkdeck signing status [--json]
        arkdeck signing remove [--json]
        arkdeck operation list [--socket <path>] [--json]
        arkdeck operation describe --operation <reference> [--socket <path>] [--json]
        arkdeck device list|show|adopt [--candidate <connect-key>] [--socket <path>] [--json]
        arkdeck trace probe --target <id> [--socket <path>] [--json]
        arkdeck job plan --target <id> --operation <reference> \
      [--inputs-file <typed-inputs.json>] [--expected-binding-revision <n>] \
      [--socket <path>] [--json]
        arkdeck job plan --request-file <request.json> [--socket <path>] [--json]
        arkdeck job submit --target <id> --operation <reference> \
      [--inputs-file <typed-inputs.json>] [--expected-binding-revision <n>] \
      [--wait] [--json]
        arkdeck job status --job <id> [--json]
        arkdeck job list [--page-size <1...1000>] [--cursor <token>] [--json]
        arkdeck job run|cancel|reconcile --job <id> [--json]
        arkdeck debug start --request-file <destructive-flash-request.json> [--json]
        arkdeck debug evaluate --invocation <id> --action-file <effect-action.json> \
      --source-sha256 <sha256> --build-sha256 <sha256> [--json]
        arkdeck debug status --invocation <id> [--json]
        arkdeck cleanup-debt list [--json]
        arkdeck cleanup-debt continue --job <id> (--remote-path <path> | --bundle <name>) [--json]
        arkdeck job submit --request-file <request.json> [--wait] [--json]
        arkdeck capability list [--json]
        arkdeck capability inspect --capability <id> [--json]
        arkdeck artifact import-hap --target <id> --file <package.hap|package.hsp> [--json]
        arkdeck artifact import-workspace-patch --target <id> --file <change.patch> [--json]
        arkdeck artifact import-flash-bundle --target <id> --file <images.tar.gz> \
      [--device-profile <dayu200>] [--json]
        arkdeck artifact import-native-library --target <id> \
      --file <libname.so|ART-id-libname.so> [--json]
        arkdeck artifact list|inspect|read|export --job <id> [--artifact <id>] \
      [--destination <directory>] [--allow-sensitive]
        arkdeck agent run --operation <reference> [--target <id>] [--inputs-file <path>] \
      [--capability <CAP-RT-...>] [--execution-id <id>] [--json]
        arkdeck agent resume --resume-token <token> [--selection <target-or-candidate>] [--json]

      doctor/operation/device/trace/job/debug talk only to arkdeck-agentd over its user-private socket:
      this CLI holds no HDC or Rockchip executor and cannot build a device command itself.

      ArkDeck runs no model of its own. Decisions come from whichever agent you already use;
      it reaches ArkDeck through this same published surface, and every side effect it causes
      passes the admission every other caller passes. `operation describe` publishes an
      operation's typed inputs and an example request.

      Real-device validation defaults to `arkdeck agent run`; use the App only when the acceptance
      criterion is specifically about its UI. Flash execution uses flash.full-restore@1 through
      that headless Agent/typed Job surface or through the App; UI acknowledgement is never a
      prerequisite or authority for headless execution. The historical campaign records exposed
      by `flash status` and
      `flash reconcile` are decode/export-only and cannot admit or dispatch a new operation.
      Caller-provided authorization files, fact/context documents, executables, argv and storage
      roots are rejected.

      update-feed never accepts or reads a private key. `prepare` emits deterministic public
      payload and signature-input files; an isolated maintainer signs the latter with local
      OpenSSL, then `assemble` verifies the raw 64-byte signature against the pinned public key.
      """
    print(usage)
  }
}

struct CLIError: Error {
  let exitCode: Int32
  let message: String
}

private final class CLIUpdateReplayStore: UpdateReplayStoring, @unchecked Sendable {
  private var record: UpdateReplayRecord?
  private let lock = NSLock()

  func validateAndCommit(
    _ candidate: UpdateReplayRecord
  ) throws -> UpdateReplayDecision {
    lock.withLock {
      let decision = UpdateReplayPolicy.decision(previous: record, candidate: candidate)
      if decision == .accepted { record = candidate }
      return decision
    }
  }
}

struct CLIOptions {
  private var values: [String: String] = [:]

  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else {
        throw CLIError(exitCode: EX_USAGE, message: "unexpected argument \(argument)")
      }
      guard index + 1 < arguments.count else {
        throw CLIError(exitCode: EX_USAGE, message: "missing value for \(argument)")
      }
      guard values[argument] == nil else {
        throw CLIError(exitCode: EX_USAGE, message: "duplicate option \(argument)")
      }
      values[argument] = arguments[index + 1]
      index += 2
    }
  }

  func value(_ name: String) -> String? {
    values[name]
  }

  func validateAllowed(_ allowed: Set<String>) throws {
    for key in values.keys.sorted() where !allowed.contains(key) {
      throw CLIError(exitCode: EX_USAGE, message: "unsupported option \(key)")
    }
  }
}
