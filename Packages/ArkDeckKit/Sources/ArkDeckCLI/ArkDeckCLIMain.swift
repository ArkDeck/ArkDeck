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
  /// argv is judged by `CLICommandRegistry` before anything is dispatched.
  ///
  /// Nothing below re-reads a flag the registry has not already accepted, so
  /// an unknown, repeated, valueless or inapplicable argument can no longer be
  /// silently dropped on its way to a handler that scans for the one flag it
  /// wants (CLI-REQ-005). Help, the machine registry projection and the
  /// completion scripts come from the same description, so the surface cannot
  /// be documented and parsed differently.
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    // §8.1: the renderer for an argv-level failure is chosen before the parse,
    // because a caller that asked for JSON needs the refusal in JSON even when
    // the command path never resolved.
    let bootstrapMode = CLIArgumentParser.bootstrapOutputMode(arguments)

    switch CLIArgumentParser.parse(arguments) {
    case .failure(let error):
      emitRegistryFailure(error, mode: bootstrapMode)
      exit(error.exitCode)
    case .success(let invocation):
      await run(invocation)
    }
  }

  private static func run(_ invocation: CLIInvocation) async {
    switch invocation {
    case .rootHelp:
      print(CLIHelpRenderer.root())
      exit(0)
    case .nodeHelp(let node):
      print(CLIHelpRenderer.node(node))
      exit(0)
    case .leafHelp(let path, let leaf):
      print(CLIHelpRenderer.leaf(path: path, leaf: leaf))
      exit(0)
    case .version(let mode):
      emit(
        command: "version", result: CLIHelpRenderer.versionResult(),
        human: CLIHelpRenderer.versionHuman(), mode: mode)
      exit(0)
    case .commands(let mode):
      emit(
        command: "commands", result: CLIRegistryProjection.result(),
        human: CLIRegistryProjection.human(), mode: mode)
      exit(0)
    case .completion(let shell):
      guard let script = CLICompletionScripts.script(for: shell) else {
        // The registry enumerates the shells, so reaching this means the
        // registry and the generator disagree — a defect, not a user error.
        emitRegistryFailure(
          CLIRegistryError(
            code: .internalError,
            message: "no completion generator for \(shell)",
            command: "completion"),
          mode: .human)
        exit(CLIErrorCode.internalError.exitCode)
      }
      FileHandle.standardOutput.write(Data(script.utf8))
      exit(0)
    case .dispatch(let path, _, let handlerArguments):
      await dispatch(path: path, arguments: Array(handlerArguments.dropFirst()))
    }
  }

  private static func emit(
    command: String, result: JSONValue, human: String, mode: CLIOutputMode
  ) {
    switch mode {
    case .human:
      print(human)
    case .json, .jsonl:
      let envelope = CLIResultEnvelope.success(
        command: command, result: result, controlRequestID: newControlRequestID())
      FileHandle.standardOutput.write(Data(CLIResultEnvelope.render(envelope).utf8))
    }
  }

  private static func emitRegistryFailure(_ error: CLIRegistryError, mode: CLIOutputMode) {
    emitRegistryFailure(error, rendering: mode == .human ? .human : .envelope)
  }

  /// One failure, rendered in the shape the caller asked for.
  ///
  /// A failure raised after the parse carries its own rendering, because the
  /// alternative — deciding here from a mode this function cannot see — is how
  /// a caller who asked for JSON gets prose on stderr and an exit status it has
  /// to guess from.
  private static func emitRegistryFailure(
    _ error: CLIRegistryError, rendering: CLIRendering
  ) {
    // The result is already on stdout and §8.1 allows exactly one document
    // there, so this failure reports itself through the exit status and a
    // stderr diagnostic — which every mode permits.
    guard !error.suppressesMachineRendering else {
      FileHandle.standardError.write(Data("arkdeck: \(error.message)\n".utf8))
      return
    }
    switch rendering {
    case .human:
      FileHandle.standardError.write(Data("arkdeck: \(error.message)\n".utf8))
    case .legacyJSON:
      FileHandle.standardOutput.write(
        Data(CLIRuntimeSession.legacyDocument(CLIResultEnvelope.legacyFailure(error)).utf8))
    case .envelope:
      let envelope = CLIResultEnvelope.failure(
        command: error.command ?? CLIResultEnvelope.parsePhaseCommand,
        error: error,
        controlRequestID: error.controlRequestID ?? newControlRequestID())
      FileHandle.standardOutput.write(Data(CLIResultEnvelope.render(envelope).utf8))
    }
  }

  /// A bounded correlation identity for one CLI invocation (§8.2). It is not a
  /// Runtime idempotency key and nothing is derived from it.
  private static func newControlRequestID() -> String {
    "ctl-" + UUID().uuidString.lowercased()
  }

  private static func dispatch(path: [String], arguments: [String]) async {
    let command = path[0]
    do {
      switch command {
      case "flash":
        try await runFlash(arguments)
      case "update-feed":
        try runUpdateFeed(arguments)
      case "doctor":
        try RuntimeCLI.runDoctor(arguments)
      case "debug":
        try RuntimeCLI.runDebug(arguments)
      case "operation":
        try RuntimeCLI.runOperation(arguments)
      case "device":
        try RuntimeCLI.runDevice(arguments)
      case "runtime":
        try RuntimeCLI.runRuntime(arguments)
      case "target":
        try RuntimeCLI.runTarget(arguments)
      case "trace":
        try RuntimeCLI.runTrace(arguments)
      case "job":
        try RuntimeCLI.runJob(arguments)
      case "cleanup-debt":
        try RuntimeCLI.runCleanupDebt(arguments)
      case "agent":
        try await RuntimeCLI.runAgent(arguments)
      case "agentd":
        try RuntimeCLI.runAgentDaemon(
          arguments,
          beforeBootstrap: RuntimeCLI.refreshSigningAccessIfInstalled)
      case "signing":
        try await RuntimeCLI.runSigningAsync(arguments)
      case "capability":
        try RuntimeCLI.runCapability(arguments)
      case "artifact":
        try RuntimeCLI.runArtifact(arguments)
      default:
        // The registry resolved this path, so a missing handler is a defect in
        // the wiring between the two rather than anything the caller typed.
        emitRegistryFailure(
          CLIRegistryError(
            code: .internalError,
            message: "no handler is wired for the registered command `\(command)`",
            command: command),
          mode: .human)
        exit(CLIErrorCode.internalError.exitCode)
      }
    } catch let error as CLIRegistryError {
      // A registry error already knows its code, its exit status and the shape
      // the caller asked for. Letting it fall through to the generic catch
      // below is what used to turn an unknown outcome into a bare exit 1.
      emitRegistryFailure(error, rendering: error.rendering)
      exit(error.exitCode)
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
    case "status":
      try runCampaignStatus(Array(arguments.dropFirst()))
    case "reconcile":
      try runFlashReconcile(Array(arguments.dropFirst()))
    default:
      // The retired verbs (plan, preview, execute, continue, postflight) are
      // registry tombstones now, answered before dispatch with an exact
      // machine replacement contract. Reaching here means the registry and
      // this switch disagree.
      throw CLIError(
        exitCode: EX_USAGE,
        message: "no handler is wired for the registered flash subcommand \(subcommand)")
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
