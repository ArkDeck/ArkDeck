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
      var envelope = CLIResultEnvelope.failure(
        command: error.command ?? CLIResultEnvelope.parsePhaseCommand,
        error: error,
        controlRequestID: error.controlRequestID ?? newControlRequestID())
      envelope = CLIResultEnvelope.withLifecycle(
        envelope, error.lifecycle, replacement: error.replacementArgvPattern)
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
        // §12's compatibility spelling of `maintainer update-feed`.
        try runUpdateFeed(arguments, spelledAs: "update-feed")
      case "maintainer":
        guard arguments.first == "update-feed" else {
          throw CLIError(
            exitCode: EX_USAGE, message: "missing maintainer subcommand (update-feed)")
        }
        try runUpdateFeed(Array(arguments.dropFirst()), spelledAs: "maintainer.update-feed")
      case "legacy":
        // §6.3's explicit compatibility namespace. It holds the historical
        // flash archive and nothing else: these decode and settle records that
        // already exist and dispatch nothing, which is why §12 keeps them out
        // of the surface a caller reaches a device through.
        guard arguments.first == "flash" else {
          throw CLIError(exitCode: EX_USAGE, message: "missing legacy subcommand (flash)")
        }
        let archiveArguments = Array(arguments.dropFirst())
        switch archiveArguments.first {
        case "status":
          try runCampaignStatus(
            Array(archiveArguments.dropFirst()), spelledAs: "legacy.flash.status")
        case "reconcile":
          try runFlashReconcile(
            Array(archiveArguments.dropFirst()), spelledAs: "legacy.flash.reconcile")
        default:
          throw CLIError(
            exitCode: EX_USAGE, message: "missing legacy flash subcommand (status|reconcile)")
        }
      case "doctor":
        try RuntimeCLI.runDoctor(arguments)
      case "debug":
        try await RuntimeCLI.runDebug(arguments)
      case "operation":
        try RuntimeCLI.runOperation(arguments)
      case "device":
        try RuntimeCLI.runDevice(arguments)
      case "runtime":
        try await RuntimeCLI.runRuntime(arguments)
      case "target":
        try await RuntimeCLI.runTarget(arguments)
      case "trace":
        try RuntimeCLI.runTrace(arguments)
      case "job":
        try RuntimeCLI.runJob(arguments)
      case "cleanup-debt":
        try RuntimeCLI.runCleanupDebt(arguments)
      case "recovery":
        try RuntimeCLI.runRecovery(arguments)
      case "screen", "input", "diagnostics", "analyze", "port-forward", "workspace":
        // §6.2's domain layer. The registry holds each leaf's exact Catalog
        // mapping, so dispatch is uniform and the family name carries no logic
        // of its own — which is what keeps these from becoming a second way to
        // reach a device.
        // `arguments` is already past the family token, so the subcommand is
        // its first element — taking [1] silently built the path from the
        // caller's first *option* instead.
        guard let verb = arguments.first, !verb.hasPrefix("-") else {
          throw CLIError(
            exitCode: EX_USAGE,
            message: "`\(command)` needs a subcommand; run `arkdeck help \(command)`")
        }
        try await RuntimeCLI.runDomainOperation(
          path: [command, verb], Array(arguments.dropFirst()))
      case "agent":
        try await RuntimeCLI.runAgent(arguments)
      case "agentd":
        // §12's compatibility spellings. Both reach the same handler; only the
        // name they report differs, which is what the registry needs to answer
        // "is this the target surface?" without a second table.
        try RuntimeCLI.runAgentDaemon(
          arguments, spelledAs: "agentd",
          beforeBootstrap: RuntimeCLI.refreshSigningAccessIfInstalled)
      case "signing":
        try await RuntimeCLI.runSigningAsync(arguments, spelledAs: "signing")
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
      try runCampaignStatus(Array(arguments.dropFirst()), spelledAs: "flash.status")
    case "reconcile":
      try runFlashReconcile(Array(arguments.dropFirst()), spelledAs: "flash.reconcile")
    case "run":
      try await RuntimeCLI.runDomainOperation(
        path: ["flash", "run"], Array(arguments.dropFirst()))
    case "device-access", "bootloader-status", "prerequisites", "lane-preview", "bind-loader":
      try RuntimeCLI.runFlashObservation(subcommand, Array(arguments.dropFirst()))
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
  static func runFlashReconcile(
    _ arguments: [String], spelledAs canonicalCommand: String = "legacy.flash.reconcile"
  ) throws {
    var rest = arguments
    let session = RuntimeCLI.runtimeSession(&rest, command: canonicalCommand)
    session.warnIfLegacy()
    let options = try CLIOptions(rest)
    try options.validateAllowed(["--session"])
    let reconciler = try RockchipLegacyFlashJournalReconciler.production()

    if let sessionID = options.value("--session") {
      let finding = try reconciler.inspect(sessionID: sessionID)
      if session.rendering == .human {
        printFlashFinding(finding)
      } else {
        session.emit(
          .object([
            "findings": .array([flashFindingJSON(finding)]),
            "orphanedReservations": .array([]),
            "requiresAttention": .bool(finding.requiresAttention),
          ]))
      }
      guard !finding.requiresAttention else {
        throw CLIError(exitCode: 4, message: "unresolved flash session \(sessionID)")
      }
      return
    }

    let findings = try reconciler.scan()
    let orphans = try reconciler.orphanedReservations()
    let unresolved = findings.count + orphans.count
    if session.rendering != .human {
      // Always the same shape, including when there is nothing to report: a
      // caller that has to branch on "did it print the empty sentence" is
      // parsing prose again.
      session.emit(
        .object([
          "findings": .array(findings.map(flashFindingJSON)),
          "orphanedReservations": .array(orphans.map(flashOrphanJSON)),
          "requiresAttention": .bool(unresolved > 0),
        ]))
      guard unresolved == 0 else {
        throw CLIError(exitCode: 4, message: "\(unresolved) unresolved flash item(s)")
      }
      return
    }
    guard unresolved > 0 else {
      print("no unresolved flash sessions")
      return
    }
    for finding in findings { printFlashFinding(finding) }
    for orphan in orphans { printFlashOrphan(orphan) }
    throw CLIError(exitCode: 4, message: "\(unresolved) unresolved flash item(s)")
  }

  /// The machine form of what `printFlashFinding` lays out for a person.
  ///
  /// One projection, not a second description: every field here is the same
  /// fact the human line carries, which is what stops the two from drifting
  /// into disagreeing about the same session.
  static func flashFindingJSON(_ finding: RockchipFlashSessionFinding) -> JSONValue {
    var fields: [String: JSONValue] = [
      "sessionId": .string(finding.sessionID),
      "jobId": finding.jobID.map(JSONValue.string) ?? .null,
      "state": finding.currentState.map { .string($0.rawValue) } ?? .null,
      "finalized": .bool(finding.finalized),
      "hasTornTail": .bool(finding.hasTornTail),
      "live": .bool(finding.isLive),
      "requiresAttention": .bool(finding.requiresAttention),
      "journalError": finding.journalError.map { .string("\($0)") } ?? .null,
      "lastConfirmedStepId": finding.lastConfirmedStepID.map(JSONValue.string) ?? .null,
      "campaignId": finding.campaignID.map(JSONValue.string) ?? .null,
    ]
    fields["outstandingIntents"] = .array(
      finding.outstandingIntents.map {
        .object([
          "eventId": .string($0.eventID),
          "stepId": .string($0.stepID),
          "attempt": .integer(Int64($0.attempt)),
          "effect": .string($0.effect.rawValue),
        ])
      })
    fields["unknownOutcomes"] = .array(
      finding.unknownOutcomes.map {
        .object([
          "correlatedIntentEventId": .string($0.correlatedIntentEventID),
          "stepId": .string($0.stepID),
          "effect": .string($0.effect.rawValue),
        ])
      })
    switch finding.ledgerState {
    case .openAgentReservation(let reservationID):
      fields["authority"] = .object([
        "reservationId": .string(reservationID), "state": .string("open"),
      ])
    case .closed(let reservationID):
      fields["authority"] = .object([
        "reservationId": .string(reservationID), "state": .string("closed"),
      ])
    case .missing(let reservationID):
      fields["authority"] = .object([
        "reservationId": .string(reservationID), "state": .string("missingFromLedger"),
      ])
    case .none:
      fields["authority"] = .null
    }
    return .object(fields)
  }

  static func flashOrphanJSON(_ orphan: RockchipFlashOrphanedReservation) -> JSONValue {
    .object([
      "reservationId": .string(orphan.reservationID),
      "jobId": .string(orphan.jobID),
      "reservedAt": .string(orphan.reservedAt),
      "campaignId": orphan.campaignID.map(JSONValue.string) ?? .null,
    ])
  }

  /// The machine form of a historical campaign document. Decode-only, like the
  /// human rendering: nothing here can admit or dispatch anything.
  static func campaignStatusJSON(_ document: HistoricalEvolutionCampaignDocument) -> JSONValue {
    .object([
      "campaignId": .string(document.campaignID),
      "terminal": .bool(document.isTerminal),
      "reservedAttemptCount": .integer(Int64(document.reservedAttemptCount)),
      "maximumAttempts": .integer(Int64(document.assertion.maxAttempts)),
      "events": .array(
        document.events.map { event in
          .object([
            "sequence": .integer(Int64(event.sequence)),
            "kind": .string(event.kind.rawValue),
            "at": .string(event.at),
            "ordinal": event.ordinal.map { .integer(Int64($0)) } ?? .null,
            "candidateId": event.candidate.map { .string($0.candidateID) } ?? .null,
            "reviewId": event.review.map { .string($0.reviewID) } ?? .null,
            "disposition": event.disposition.map { .string($0.rawValue) } ?? .null,
            "reasonCode": event.reasonCode.map(JSONValue.string) ?? .null,
            "detail": event.detail.map(JSONValue.string) ?? .null,
          ])
        }),
    ])
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
        // The target spelling: a hint that sends a caller into a deprecation
        // warning teaches them to ignore the next one.
        print("  inspect: arkdeck legacy flash status --campaign-id \(campaignID)")
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
    let session = RuntimeCLI.runtimeSession(&rest, command: "flash.install-binding")
    let rebind = rest.contains("--rebind")
    rest.removeAll { $0 == "--rebind" }
    let options = try CLIOptions(rest)
    try options.validateAllowed([])
    let receipt = try RockchipDeviceBindingInstallation.installCurrentTarget(rebind: rebind)
    guard session.rendering == .human else {
      session.emit(
        .object([
          "created": .bool(receipt.created),
          "bindingRevision": .integer(Int64(receipt.revision)),
          "usbTopology": .string(receipt.usbTopology),
        ]))
      return
    }
    print(
      receipt.created
        ? "durable DAYU200 cross-mode binding installed"
        : "durable DAYU200 cross-mode binding unchanged")
    print("binding revision: \(receipt.revision)")
    print("USB topology: \(receipt.usbTopology)")
    print("serial sha256: \(receipt.serialDigestSHA256)")
    print("device mutation dispatch: 0")
  }

  static func runCampaignStatus(
    _ arguments: [String], spelledAs canonicalCommand: String = "legacy.flash.status"
  ) throws {
    var rest = arguments
    let session = RuntimeCLI.runtimeSession(&rest, command: canonicalCommand)
    session.warnIfLegacy()
    let options = try CLIOptions(rest)
    try options.validateAllowed(["--campaign-id"])
    guard let campaignID = options.value("--campaign-id") else {
      throw CLIError(exitCode: EX_USAGE, message: "status requires --campaign-id")
    }
    // Mapped exhaustively, not partially: the archive publishes exactly three
    // failures, so each gets its §8.4 code and a caller that asked for JSON
    // gets the failure in JSON too. A half-mapped enum would answer some
    // failures in the caller's shape and others in prose on stderr, which is
    // worse than answering none of them.
    let document: HistoricalEvolutionCampaignDocument
    do {
      document = try HistoricalEvolutionCampaignArchive.production().load(campaignID)
    } catch HistoricalEvolutionCampaignArchiveError.campaignNotFound(let missing) {
      throw session.fail(
        .resourceNotFound, "no historical campaign \(missing)",
        details: ["campaignId": .string(missing)])
    } catch HistoricalEvolutionCampaignArchiveError.invalidRoot {
      throw session.fail(.recordUnreadable, "the historical campaign archive root is invalid")
    } catch HistoricalEvolutionCampaignArchiveError.unreadable(let reason) {
      throw session.fail(.recordUnreadable, "the historical campaign record is unreadable: \(reason)")
    }
    guard session.rendering == .human else {
      session.emit(campaignStatusJSON(document))
      return
    }
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

  /// §8.4 for the maintainer feed tooling.
  ///
  /// This family computes entirely on the host, so its failures are file and
  /// format failures rather than control-plane ones. That does not make them
  /// exempt: a leaf that publishes `--output json` owes every failure a code
  /// and one document, and before this existed a missing payload file left
  /// stdout empty and a sentence on stderr — the exact shape §8.2 forbids.
  ///
  /// The switch over `UpdateFeedError` is exhaustive on purpose. It is a
  /// closed set, and a default branch would silently classify whatever case is
  /// added to it next, which is how a signature failure ends up reported as a
  /// bad argument.
  private static func updateFeedFailure(
    _ error: Error, _ session: CLIRuntimeSession, _ doing: String
  ) -> Error {
    // An argv refusal and an already-classified failure both keep their own.
    if error is CLIRegistryError || error is CLIError { return error }

    if let feed = error as? UpdateFeedError {
      let code: CLIErrorCode
      switch feed {
      case .feedTooLarge, .payloadTooLarge:
        code = .inputTooLarge
      // The two that mean "do not publish this": the bytes are well-formed and
      // the signature over them is not the one this key would produce.
      case .invalidSignature, .unknownKey:
        code = .artifactIntegrityFailed
      case .malformedEnvelope, .nonCanonicalEnvelope, .wrongSchemaVersion, .malformedBase64,
        .nonCanonicalPayload, .invalidPayload, .invalidVersion, .invalidSystemVersion,
        .invalidArchitecture, .invalidTimestamp, .invalidValidityWindow, .feedNotYetValid,
        .feedExpired, .invalidArtifactURL, .invalidArtifactLength, .invalidArtifactDigest:
        code = .invalidInput
      // A sequence the local replay ledger has already seen is a conflict with
      // durable state, not a malformed input: the fix is a new sequence.
      case .downgrade, .replay, .sequenceConflict, .nonIncreasingRelease:
        code = .resourceConflict
      case .replayStateCorrupt:
        code = .recordUnreadable
      case .replayStateWriteFailed:
        code = .ioFailure
      }
      return session.fail(
        code, "\(doing) failed: \(feed)", details: ["reason": .string("\(feed)")])
    }

    let cocoa = error as NSError
    if cocoa.domain == NSCocoaErrorDomain,
      [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(cocoa.code)
    {
      return session.fail(.resourceNotFound, "\(doing) failed: \(cocoa.localizedDescription)")
    }
    return session.fail(.ioFailure, "\(doing) failed: \(cocoa.localizedDescription)")
  }

  static func runUpdateFeed(
    _ arguments: [String], spelledAs canonicalPrefix: String = "maintainer.update-feed"
  ) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing update-feed subcommand")
    }
    switch subcommand {
    case "prepare":
      try prepareUpdateFeed(
        Array(arguments.dropFirst()), spelledAs: "\(canonicalPrefix).prepare")
    case "assemble":
      try assembleUpdateFeed(
        Array(arguments.dropFirst()), spelledAs: "\(canonicalPrefix).assemble")
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported update-feed subcommand")
    }
  }

  static func prepareUpdateFeed(
    _ arguments: [String], spelledAs canonicalCommand: String = "maintainer.update-feed.prepare"
  ) throws {
    var rest = arguments
    let session = RuntimeCLI.runtimeSession(
      &rest, command: canonicalCommand, connectsToRuntime: false)
    session.warnIfLegacy()
    let options = try CLIOptions(rest)
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
    let measurement: (byteLength: UInt64, sha256: String)
    do {
      measurement = try measureArtifact(artifact)
    } catch {
      throw updateFeedFailure(error, session, "measuring \(artifact.path)")
    }
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
    let output = URL(filePath: outputPath).standardizedFileURL
    let payloadURL = output.appending(path: "arkdeck-update-payload-v1.json")
    let inputURL = output.appending(path: "arkdeck-update-signature-input-v1.bin")
    do {
      try UpdateFeedVerifier.validateUnsignedPayloadForSigning(payload)
      let canonicalPayload = try UpdateFeedCodec.canonicalPayload(payload)
      let signatureInput = try UpdateFeedCodec.signatureInput(
        payload: canonicalPayload, keyID: UpdateFeedTrust.productionKeyID)
      try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try canonicalPayload.write(to: payloadURL, options: [.atomic, .completeFileProtection])
      try signatureInput.write(to: inputURL, options: [.atomic, .completeFileProtection])
    } catch {
      throw updateFeedFailure(error, session, "preparing the payload")
    }
    // The human lines are kept verbatim rather than regenerated from the
    // result: this is a release runbook people follow line by line, and
    // §12 forbids changing what an existing spelling prints. The machine
    // shape is additive.
    guard session.isMachineOutput else {
      print("payload: \(payloadURL.path)")
      print("signature input: \(inputURL.path)")
      print("artifact bytes: \(measurement.byteLength)")
      print("artifact sha256: \(measurement.sha256)")
      print("key ID: \(UpdateFeedTrust.productionKeyID)")
      return
    }
    session.emit(
      .object([
        "payloadPath": .string(payloadURL.path),
        "signatureInputPath": .string(inputURL.path),
        "artifact": .object([
          "url": .string(artifactURL),
          "byteLength": .integer(Int64(measurement.byteLength)),
          "sha256": .string(measurement.sha256),
        ]),
        "keyId": .string(UpdateFeedTrust.productionKeyID),
        "sequence": .integer(Int64(sequence)),
        "version": .string(version),
      ]))
  }

  static func assembleUpdateFeed(
    _ arguments: [String], spelledAs canonicalCommand: String = "maintainer.update-feed.assemble"
  ) throws {
    var rest = arguments
    let session = RuntimeCLI.runtimeSession(
      &rest, command: canonicalCommand, connectsToRuntime: false)
    session.warnIfLegacy()
    let options = try CLIOptions(rest)
    try options.validateAllowed(["--payload", "--signature", "--out"])
    guard let payloadPath = options.value("--payload"),
      let signaturePath = options.value("--signature"),
      let outputPath = options.value("--out")
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "assemble requires --payload, --signature and --out")
    }
    let payload: Data
    let signature: Data
    do {
      payload = try Data(
        contentsOf: URL(filePath: payloadPath), options: [.mappedIfSafe, .uncached])
    } catch {
      throw updateFeedFailure(error, session, "reading \(payloadPath)")
    }
    do {
      signature = try Data(
        contentsOf: URL(filePath: signaturePath), options: [.mappedIfSafe, .uncached])
    } catch {
      throw updateFeedFailure(error, session, "reading \(signaturePath)")
    }
    let envelope: Data
    do {
      envelope = try UpdateFeedCodec.assemble(
        canonicalPayload: payload,
        signature: signature,
        keyID: UpdateFeedTrust.productionKeyID)
      let decoded = try UpdateFeedCodec.decodeAndVerify(
        envelope, trust: try UpdateFeedTrust.production)
      guard decoded.canonicalPayload == payload else {
        // The envelope decodes and verifies but does not carry the bytes it
        // was built from, which is an integrity failure rather than a bad
        // argument: publishing it would ship a feed nobody signed.
        throw session.fail(
          .artifactIntegrityFailed,
          "self-verification found the assembled feed does not carry the signed payload")
      }
    } catch {
      throw updateFeedFailure(error, session, "assembling the feed")
    }
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let output = URL(filePath: outputPath).standardizedFileURL
    do {
      _ = try UpdateFeedVerifier(
        trust: try UpdateFeedTrust.production,
        replayStore: CLIUpdateReplayStore()
      ).verify(
        envelope,
        context: UpdateVerificationContext(
          installedVersion: "0.0.0",
          systemVersion:
            "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
          architecture: "arm64"),
        now: Date())
      try envelope.write(to: output, options: [.atomic, .completeFileProtection])
    } catch {
      throw updateFeedFailure(error, session, "verifying and writing the feed")
    }
    // `self-verification: valid` is the only signal that the envelope,
    // canonical payload and signature all agree, so it is a published fact
    // rather than decoration: the machine shape has to carry it too, and the
    // human line stays exactly as the runbook has it.
    guard session.isMachineOutput else {
      print("feed: \(output.path)")
      print("feed sha256: \(UpdateFeedCodec.sha256(envelope))")
      print("self-verification: valid")
      return
    }
    session.emit(
      .object([
        "feedPath": .string(output.path),
        "feedSha256": .string(UpdateFeedCodec.sha256(envelope)),
        "keyId": .string(UpdateFeedTrust.productionKeyID),
        "selfVerified": .bool(true),
      ]))
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
