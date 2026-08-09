import ArkDeckAgentComposition
import ArkDeckCore
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
      case "job":
        try RuntimeCLI.runJob(Array(arguments.dropFirst()))
      case "cleanup-debt":
        try RuntimeCLI.runCleanupDebt(Array(arguments.dropFirst()))
      case "agent":
        try RuntimeCLI.runAgent(Array(arguments.dropFirst()))
      case "capability":
        try RuntimeCLI.runCapability(Array(arguments.dropFirst()))
      case "artifact":
        try RuntimeCLI.runArtifact(Array(arguments.dropFirst()))
      case "task":
        try RuntimeCLI.runTask(Array(arguments.dropFirst()))
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
    case "install-tool":
      try runInstallTool(Array(arguments.dropFirst()))
    case "trust-tool":
      try runTrustTool(Array(arguments.dropFirst()))
    case "install-binding":
      try runInstallBinding(Array(arguments.dropFirst()))
    case "plan":
      try runPlan(Array(arguments.dropFirst()))
    case "preview":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "historical campaign preview is retired; Runtime owns Flash admission")
    case "execute":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "use the ArkDeck Flash UI or submit flash.dayu200 through the typed Job API")
    case "continue":
      throw CLIError(
        exitCode: EX_USAGE,
        message: "historical campaign continuation is retired and cannot dispatch")
    case "status":
      try runCampaignStatus(Array(arguments.dropFirst()))
    case "postflight":
      try runPostflight(Array(arguments.dropFirst()))
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
    let reconciler = try RockchipFlashSessionReconciler.production()

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


  // MARK: install-tool

  static func runInstallTool(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--path"])
    guard let path = options.value("--path"), path.hasPrefix("/") else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "install-tool requires --path with a canonical absolute file path")
    }
    let receipt = try RockchipToolInstallation.install(
      executableURL: URL(fileURLWithPath: path))
    print("pinned rkdeveloptool ordinary bookmark and live trust facts installed")
    print("tool sha256: \(receipt.executableSHA256)")
    print("code trust: \(receipt.codeTrust.rawValue)")
    print("quarantine present: \(receipt.quarantinePresent)")
  }

  static func runTrustTool(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--path", "--expected-sha256"])
    guard let path = options.value("--path"), path.hasPrefix("/"),
      let expectedSHA256 = options.value("--expected-sha256")
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "trust-tool requires --path and the full --expected-sha256 product pin")
    }
    let receipt = try RockchipToolInstallation.trustAndInstall(
      executableURL: URL(fileURLWithPath: path),
      expectedSHA256: expectedSHA256)
    print("exact pinned rkdeveloptool trusted and installed")
    print("tool sha256: \(receipt.executableSHA256)")
    print("code trust: \(receipt.codeTrust.rawValue)")
    print("quarantine present: \(receipt.quarantinePresent)")
  }

  static func runInstallBinding(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed([])
    let receipt = try RockchipDeviceBindingInstallation.installCurrentTarget()
    print(
      receipt.created
        ? "durable DAYU200 cross-mode binding installed"
        : "durable DAYU200 cross-mode binding unchanged")
    print("binding revision: \(receipt.revision)")
    print("USB topology: \(receipt.usbTopology)")
    print("serial sha256: \(receipt.serialDigestSHA256)")
    print("device mutation dispatch: 0")
  }

  // MARK: plan

  static func runPlan(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--images", "--device-profile", "--mode", "--out"])
    let modeName = options.value("--mode") ?? "planOnly"
    guard let mode = RockchipFlashExecutionMode(rawValue: modeName), mode != .execute else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "plan supports --mode planOnly|simulated; the execute branch is `arkdeck "
          + "flash execute` and always ends at a human handoff")
    }
    let plan = try validateAndPlan(options: options, mode: mode)
    try writePlanDocument(plan, options: options)
    printExactPlan(plan)
    print("terminal status: notExecuted(\(mode.rawValue))")
  }

  // MARK: execute

  static func runExecute(_ arguments: [String]) async throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed([
      "--images", "--device-profile", "--target-location-id", "--operator",
      "--authorization-id", "--campaign-confirmation-digest-sha256", "--out",
      // Campaign authority only: its attempt runs on the runtime job lane.
      "--runtime-target", "--socket",
    ])
    let operatorIdentity = options.value("--operator")
    let authority = RockchipExecutionAuthorityResolver.resolve(
      operatorProvided: operatorIdentity?.isEmpty == false,
      standardInputIsInteractive: isatty(FileHandle.standardInput.fileDescriptor) == 1,
      environmentOverride: ProcessInfo.processInfo.environment["ARKDECK_EXECUTION_AUTHORITY"])

    let authorizationID = options.value("--authorization-id")
    let campaignDigest = options.value("--campaign-confirmation-digest-sha256")
    guard authorizationID == nil || campaignDigest == nil else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "--authorization-id and campaign confirmation are mutually exclusive")
    }

    if authorizationID != nil || campaignDigest != nil {
      if let authorizationID,
        !RockchipStandingAuthorizationIdentifier.isValid(authorizationID)
      {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "invalid --authorization-id; expected strict AUTH-[A-Z0-9-] identifier")
      }
      guard authority != .humanOperator, operatorIdentity == nil else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "--operator and Agent E2 authority are mutually exclusive")
      }
      guard options.value("--out") == nil else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "--out is unavailable with Agent E2 authority; the trusted host owns "
            + "Session storage")
      }
      guard options.value("--device-profile") == nil else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "authorized execution derives the published device profile from the "
            + "pinned archive; --device-profile is unavailable")
      }
      guard let imagesPath = options.value("--images"),
        let location = options.value("--target-location-id")
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "authorized execution requires --images and --target-location-id")
      }
      if authorizationID != nil {
        // The standing lane no longer executes here. Its runtime equivalent is
        // the maintainer-signed exact-plan capability, and the two are
        // different carriers of the same authority — translating one into the
        // other automatically would be the agent minting its own capability
        // (HTP-INV-6), so this hands the maintainer the exact steps instead.
        throw CLIError(
          exitCode: EX_USAGE,
          message: """
            standing-authorization flash no longer executes in this process; it runs on the \
            runtime job lane under a maintainer-issued exact-plan capability. Steps:
              1. arkdeck capability draft --target <id> --operation flash.dayu200 \
            --inputs-file <inputs.json> --output-directory <dir>
              2. open a PR that backfills the drafted envelope, and have the maintainer merge it
              3. arkdeck capability install --file <cap.json>
              4. arkdeck artifact import-flash-bundle --target <id> --file <images.tar.gz>
              5. arkdeck job submit --request-file <request.json> --wait
            An AUTH- identifier is not translated into a capability automatically: they are two \
            different authority carriers, and only a merged PR can issue the second.
            """)
      } else if let campaignDigest {
        try requireCampaignAgentContext(firstAdmission: true)
        try await requireGreenPreflight(imagesPath: imagesPath)
        let result = try await engineLaneCampaignHost(options: options)
          .executeConfirmedCampaign(
            confirmationDigestSHA256: campaignDigest,
            archiveURL: URL(fileURLWithPath: imagesPath), targetLocationSelector: location)
        printCampaignResult(result)
      } else {
        throw CLIError(exitCode: EX_USAGE, message: "Agent E2 authority is missing")
      }
      return
    }

    let plan = try validateAndPlan(options: options, mode: .execute)
    try writePlanDocument(plan, options: options)
    printExactPlan(plan)

    let profile = try publishedProfile(for: plan)
    let provider = RockchipRockUSBFlashProvider(profile: profile)
    let gate = RockchipFlashAuthorizationGate(profile: profile)
    let monitor = RockchipFlashDispatchMonitor()

    guard authority == .humanOperator, let operatorIdentity else {
      // No authorization ID: fail closed before any prompt and retain the controlled human
      // handoff required by AC-FLASH-015-01. This branch never mints an AI capability.
      let decision = await gate.authorize(
        authority: authority,
        binding: bindingState(options),
        plan: plan,
        prerequisites: .blockedBeforeDestructiveConfirmation([]),
        destructiveConfirmationAccepted: false,
        manualConfirmation: nil,
        monitor: monitor)
      guard case .policyBlocked(let handoff) = decision.outcome else {
        throw CLIError(exitCode: 1, message: "unexpected authorization outcome")
      }
      print("Job marker: \(decision.jobMarker)")
      print(
        "execute requires a human operator at an interactive terminal (--operator plus a "
          + "TTY); an AI caller must present either --authorization-id or a current bounded "
          + "campaign confirmation digest to the trusted executor. "
          + "This run is \(authority.rawValue) and real destructive dispatch stays 0.")
      try writeHandoff(handoff, options: options)
      exit(3)
    }

    guard case .realDevice(let binding) = bindingState(options) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "execute requires --target-location-id <usb-location> to confirm the "
          + "physical target")
    }

    // Ahead of the interactive prerequisite questions, not just ahead of the
    // phrase: a red host is a refusal either way, and there is no reason to
    // make an operator answer three questions first. `validateAndPlan` above
    // already refused a missing --images.
    try await requireGreenPreflight(imagesPath: options.value("--images") ?? "")

    let prerequisites = provider.evaluatePrerequisites(promptPrerequisites())
    if case .blockedBeforeDestructiveConfirmation(let violations) = prerequisites {
      for violation in violations {
        print("blocked: \(violation)")
      }
      exit(4)
    }

    let confirmationPhrase = "FLASH \(plan.planDigestSHA256.prefix(12))"
    print("\nDestructive confirmation. This overwrites all 9 mapped partitions including")
    print("userdata (existing user data is destroyed). Type exactly: \(confirmationPhrase)")
    let acceptedDestructive = readLine() == confirmationPhrase
    print("Strong confirmation for userdata. Type exactly: ERASE-USERDATA")
    let acceptedUserdata = readLine() == "ERASE-USERDATA"

    let confirmation = RockchipManualFlashConfirmation(
      operatorIdentity: operatorIdentity,
      targetBindingDigestSHA256: binding.identityDigestSHA256,
      firmwareArchiveSHA256: plan.archiveSHA256,
      transport: "usb",
      toolchainFingerprint: RockchipFlashProfile.pinnedToolchainFingerprint,
      providerIdentity: RockchipRockUSBFlashProvider.providerIdentity,
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      confirmedAtTimestamp: ISO8601DateFormatter().string(from: Date()))

    let decision = await gate.authorize(
      authority: .humanOperator,
      binding: .realDevice(binding),
      plan: plan,
      prerequisites: prerequisites,
      destructiveConfirmationAccepted: acceptedDestructive && acceptedUserdata,
      manualConfirmation: acceptedDestructive && acceptedUserdata ? confirmation : nil,
      monitor: monitor)
    print("Job marker: \(decision.jobMarker)")

    switch decision.outcome {
    case .authorizedForHumanExecution(let handoff):
      try writeHandoff(handoff, options: options)
      print("\nThe handoff document lists the exact commands. Run them yourself; ArkDeck")
      print("does not dispatch them. Record operator, physical target, time and recovery")
      print("path in the run evidence.")
    case .blockedDestructiveConfirmationDeclined, .blockedMissingManualConfirmation:
      print("destructive confirmation declined; wlx/rd/erase dispatch count is 0.")
      exit(4)
    case .blockedManualConfirmationMismatch(let fields):
      print("manual confirmation mismatch (\(fields.joined(separator: ", "))); dispatch 0.")
      exit(4)
    default:
      exit(4)
    }
  }

  // MARK: preflight

  /// The non-destructive gate every confirmation phrase now sits behind.
  ///
  /// It exists because of what the 2026-08-04 campaigns cost: four confirmed
  /// campaigns, one attempt each, all four killed by the same host-side tool
  /// fault, and every retry needing a merged PR. None of those failures was a
  /// product defect the campaign lane could repair, so none of them should
  /// have consumed a campaign. Device mutation dispatch here is 0 — this is
  /// four read-only observations and a refusal, never an execution stack.
  static func requireGreenPreflight(imagesPath: String) async throws {
    let receipt = await RockchipFlashPreflight().run(
      archiveURL: URL(fileURLWithPath: imagesPath))
    for line in receipt.renderedLines() { print(line) }
    guard receipt.isGreen else {
      throw CLIError(
        exitCode: 4,
        message: "preflight refused before any confirmation: "
          + receipt.failedChecks.map(\.rawValue).joined(separator: ", ")
          + ". No campaign attempt, reservation or device mutation was spent.")
    }
  }

  // MARK: default bounded Evolution E2 campaign

  static func runCampaignPreview(_ arguments: [String]) async throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed([
      "--images", "--max-attempts", "--max-changed-files", "--max-diff-lines",
      "--validity-seconds",
    ])
    guard let images = options.value("--images"), images.hasPrefix("/"),
      let maxAttempts = strictPositiveInt(options.value("--max-attempts") ?? "16"),
      let maxChangedFiles = strictPositiveInt(options.value("--max-changed-files") ?? "8"),
      let maxDiffLines = strictPositiveInt(options.value("--max-diff-lines") ?? "2000"),
      let validitySeconds = strictPositiveInt(options.value("--validity-seconds") ?? "14400")
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "preview requires absolute --images and canonical positive budgets")
    }
    // Before the draft exists, not after: a preview that mints a confirmation
    // digest against a dead host tool is how a campaign gets spent on a
    // problem that was free to fix a second earlier.
    try await requireGreenPreflight(imagesPath: images)
    let preview = try await RockchipEvolutionCampaignPlanning.preview(
      archiveURL: URL(fileURLWithPath: images), maxAttempts: maxAttempts,
      maxChangedFiles: maxChangedFiles, maxDiffLines: maxDiffLines,
      validitySeconds: validitySeconds)
    let assertion = preview.assertion
    print("bounded Evolution Flash campaign preview")
    print("campaign: \(assertion.campaignID)")
    print("confirmation digest: \(assertion.confirmationDigestSHA256)")
    print("protected-main base: \(assertion.baseCommitOID)")
    print(
      "candidate build target: "
        + RockchipEvolutionCampaignConfirmationAssertion.candidateBuildTarget)
    print("candidate toolchain: \(assertion.candidateToolchainDigestSHA256)")
    print("merged broker executable: \(assertion.brokerExecutableDigestSHA256)")
    print("allowed candidate paths: \(assertion.allowedPaths.joined(separator: ","))")
    print(
      "candidate budget: files<=\(assertion.maxChangedFiles), "
        + "diff-lines<=\(assertion.maxDiffLines)")
    print("plan: \(assertion.planDigestSHA256)")
    print("archive: \(assertion.archiveDigestSHA256)")
    print("step-set: \(assertion.stepSetDigestSHA256)")
    print("target stable identity: \(assertion.targetStableIdentitySHA256)")
    print("binding lineage root revision: \(assertion.bindingLineageRootRevision)")
    print("data impact: \(assertion.userdataImpact)")
    print("hard budget: attempts<=\(assertion.maxAttempts), concurrency=1")
    print("valid until: \(assertion.validUntil)")
    print("device mutation dispatch: \(preview.deviceMutationDispatchCount)")
    print("")
    print(
      "确认本次 Evolution Flash campaign：campaign=\(assertion.confirmationDigestSHA256)，"
        + "base=\(assertion.baseCommitOID)，plan=\(assertion.planDigestSHA256)，"
        + "archive=\(assertion.archiveDigestSHA256)，step-set=\(assertion.stepSetDigestSHA256)，"
        + "target=\(assertion.targetStableIdentitySHA256)，"
        + "bindingRevision=\(assertion.bindingLineageRootRevision)，"
        + "最多 \(assertion.maxAttempts) 次、并发 1、有效至 \(assertion.validUntil)，"
        + "ERASE-USERDATA；unknown/unsafe partial 不重试。")
  }

  static func runCampaignContinue(_ arguments: [String]) async throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed([
      "--images", "--target-location-id", "--campaign-id", "--runtime-target", "--socket",
    ])
    guard let images = options.value("--images"), images.hasPrefix("/"),
      let location = options.value("--target-location-id"),
      let campaignID = options.value("--campaign-id")
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "continue requires --images, --target-location-id and --campaign-id "
          + "(plus --runtime-target for the runtime job lane)")
    }
    try requireCampaignAgentContext(firstAdmission: false)
    try await requireGreenPreflight(imagesPath: images)
    let result = try await engineLaneCampaignHost(options: options).continueCampaign(
      campaignID: campaignID, archiveURL: URL(fileURLWithPath: images),
      targetLocationSelector: location)
    printCampaignResult(result)
  }

  /// A campaign attempt executes on the engine lane. There is no in-process
  /// fallback on purpose: falling back would put two flash execution stacks
  /// back in production behind one command, which is the condition this swap
  /// exists to end. A daemon that is not running is a loud, closed failure.
  /// Everything the campaign host needs from the runtime job lane, from one
  /// socket path: the dispatcher that submits attempts and the read-only
  /// evidence reader reconciliation consults before it may settle an unknown
  /// Loader transition.
  private static func engineLaneCampaignHost(
    options: CLIOptions
  ) throws -> RockchipEvolutionCampaignHost {
    try RockchipEvolutionCampaignHost(
      flash: try engineLaneDispatcher(options: options),
      attemptIntents: DaemonRockchipEvolutionAttemptIntents(
        socketPath: options.value("--socket") ?? RuntimeCLI.defaultSocketPath()))
  }

  private static func engineLaneDispatcher(
    options: CLIOptions
  ) throws -> EngineLaneEvolutionFlashDispatcher {
    guard let runtimeTarget = options.value("--runtime-target"),
      !runtimeTarget.isEmpty
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "a campaign attempt runs on the runtime job lane and needs --runtime-target "
          + "<adopted target id>; the runtime refuses any target whose identity is not "
          + "the one the campaign confirmation pins")
    }
    let socketPath = options.value("--socket") ?? RuntimeCLI.defaultSocketPath()
    guard FileManager.default.fileExists(atPath: socketPath) else {
      throw CLIError(
        exitCode: EX_UNAVAILABLE,
        message:
          "the runtime daemon is not listening at \(socketPath); start arkdeck-agentd "
          + "before running a campaign attempt")
    }
    return try EngineLaneEvolutionFlashDispatcher(
      socketPath: socketPath, runtimeTargetID: runtimeTarget)
  }

  static func runCampaignStatus(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--campaign-id"])
    guard let campaignID = options.value("--campaign-id") else {
      throw CLIError(exitCode: EX_USAGE, message: "status requires --campaign-id")
    }
    let document = try RockchipEvolutionCampaignHost.status(campaignID: campaignID)
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

  static func requireCampaignAgentContext(firstAdmission: Bool) throws {
    let environment = ProcessInfo.processInfo.environment
    let authority = RockchipExecutionAuthorityResolver.resolve(
      operatorProvided: false,
      standardInputIsInteractive: isatty(FileHandle.standardInput.fileDescriptor) == 1,
      environmentOverride: environment["ARKDECK_EXECUTION_AUTHORITY"])
    let expected = firstAdmission ? "supervisedInteractiveAgent" : "boundedEvolutionAgent"
    guard authority == .standardAgent,
      environment["ARKDECK_EVOLUTION_CAMPAIGN_CONTEXT"] == expected,
      environment["CI"] != "true", environment["GITHUB_ACTIONS"] != "true"
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: firstAdmission
          ? "first campaign admission requires the current supervised interactive Agent "
            + "confirmation context; CI/daemon/scheduler are rejected"
          : "campaign continuation requires boundedEvolutionAgent context; CI is rejected")
    }
  }

  static func printCampaignResult(_ result: RockchipEvolutionCampaignExecutionResult) {
    print("campaign: \(result.campaignID)")
    print("attempt ordinal: \(result.attemptOrdinal)")
    print("session: \(result.flash.sessionID)")
    print("job: \(result.flash.jobID)")
    print("terminal status: \(result.flash.status.rawValue)")
    print("evidence class: \(result.flash.evidenceClass.rawValue)")
    if let manifest = result.flash.manifestURL { print("manifest: \(manifest.path)") }
  }

  static func strictPositiveInt(_ raw: String) -> Int? {
    guard let value = Int(raw), value > 0, raw == String(value) else { return nil }
    return value
  }

  // MARK: postflight

  static func runPostflight(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--observation", "--device-profile"])
    guard let observationPath = options.value("--observation") else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "postflight requires --observation <observation.json>")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: observationPath))
    let observation = try JSONDecoder().decode(CLIRunObservation.self, from: data)
    let provider = RockchipRockUSBFlashProvider(profile: try selectedProfile(options: options))
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let assessment = provider.assessOutcome(plan: plan, observation: observation.observation())

    print("job state: \(assessment.jobState.rawValue)")
    print("outcome certainty: \(assessment.certainty.rawValue)")
    for failure in assessment.failures {
      print("finding: \(failure)")
    }
    if let guide = assessment.recoveryGuide {
      print("\nRecovery guide (\(guide.currentPhase); device mode \(guide.deviceMode)):")
      for (index, step) in guide.manualRecoverySteps.enumerated() {
        print("  \(index + 1). \(step)")
      }
      for disclosure in guide.disclosures {
        print("  note: \(disclosure)")
      }
    }
    if !assessment.isSucceeded {
      exit(5)
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
    let artifact = URL(fileURLWithPath: artifactPath).standardizedFileURL
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
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
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
      contentsOf: URL(fileURLWithPath: payloadPath),
      options: [.mappedIfSafe, .uncached])
    let signature = try Data(
      contentsOf: URL(fileURLWithPath: signaturePath),
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
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
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
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (measured, digest)
  }

  // MARK: shared helpers

  static func validateAndPlan(
    options: CLIOptions, mode: RockchipFlashExecutionMode
  ) throws -> RockchipFlashPlan {
    guard let imagesPath = options.value("--images") else {
      throw CLIError(exitCode: EX_USAGE, message: "missing --images <images.tar.gz>")
    }
    print("validating \(imagesPath) (streaming SHA-256; this can take a while)…")
    let board = try selectedProfile(options: options)
    let summary = try GzipTarArchiveReader.summarize(
      fileAt: URL(fileURLWithPath: imagesPath),
      derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
    // The plan is built for the archive in hand. Anything the board cannot
    // make a complete plan for is refused here, by name; a build nobody had
    // enumerated yet is not one of those things.
    let profile: RockchipFlashProfile
    do {
      profile = try board.forBuild(
        RockchipImageArchiveIntrospection.describe(summary: summary, board: board))
    } catch {
      throw CLIError(exitCode: 2, message: "archive does not fit \(board.catalogReference): \(error)")
    }
    print("build: \(profile.runtimeBuildVersion)")
    let provider = RockchipRockUSBFlashProvider(profile: profile)
    let verdict = provider.profile.validate(summary.archiveObservation())
    if case .blocked(let violations) = verdict {
      for violation in violations {
        FileHandle.standardError.write(Data("validation: \(violation)\n".utf8))
      }
      throw CLIError(
        exitCode: 2,
        message: "archive validation failed; execute and planned-success are both blocked")
    }
    return try provider.makePlan(mode: mode, archiveValidation: verdict)
  }

  static func selectedProfile(options: CLIOptions) throws -> RockchipFlashProfile {
    let profileReference = options.value("--device-profile") ?? "dayu200"
    guard let profile = RockchipFlashProfile.board(reference: profileReference) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "unsupported DAYU200 device profile \(profileReference)")
    }
    return profile
  }

  /// The board profile carrying the facts the plan was built with. The plan
  /// records the archive it was materialized against, so the pins travel with
  /// the plan instead of having to be found in a list of known builds.
  static func publishedProfile(for plan: RockchipFlashPlan) throws -> RockchipFlashProfile {
    // Board facts only, which is all its consumers read — the provider's step
    // set and the authorization gate. Per-build facts travel on the plan.
    _ = plan
    return .dayu200
  }

  static func bindingState(_ options: CLIOptions) -> RockchipDeviceBindingState {
    guard let locationID = options.value("--target-location-id") else { return .none }
    return .realDevice(
      RockchipRealDeviceBinding(
        usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
        usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
        usbLocationID: locationID))
  }

  static func promptPrerequisites() -> [RockchipPrerequisiteObservation] {
    func ask(_ question: String) -> RockchipPrerequisiteStatus {
      print("\(question) [yes/no/unknown]: ", terminator: "")
      switch readLine()?.lowercased() {
      case "yes": return .satisfied
      case "no": return .unsatisfied
      default: return .unknown
      }
    }
    return [
      RockchipPrerequisiteObservation(
        identifier: .loader,
        status: ask("Does `sudo rkdeveloptool ld` report 0x2207:0x350a in Loader mode?")),
      RockchipPrerequisiteObservation(
        identifier: .recoveryPath,
        status: ask(
          "Is the CHG-2026-016 Loader-mode wlx recovery route available (validated archive "
            + "on hand)?")),
      RockchipPrerequisiteObservation(
        identifier: .unlocked,
        status: ask("Do you accept that userdata will be overwritten (device unlocked)?")),
    ]
  }

  static func printExactPlan(_ plan: RockchipFlashPlan) {
    print("\nExact plan (\(plan.executionMode.rawValue))")
    print("  provider: \(RockchipRockUSBFlashProvider.providerIdentity)")
    if let profile = RockchipFlashProfile.profile(
      archiveSHA256: plan.archiveSHA256, byteCount: Int(plan.archiveSizeBytes)
    ) {
      print("  profile: \(profile.catalogReference) (\(profile.firmwareVersion))")
    }
    print("  target: \(RockchipFlashProfile.targetDeviceModel)")
    print("  archive: sha256 \(plan.archiveSHA256) (\(plan.archiveSizeBytes) bytes)")
    print("  plan digest: \(plan.planDigestSHA256)")
    print("  step-set digest: \(plan.stepSetDigestSHA256)")
    for impact in plan.dataImpact {
      print("  data impact: \(impact)")
    }
    for step in plan.steps {
      print("  step \(step.id) kind=\(step.kind.rawValue) effect=\(step.effect.rawValue)")
    }
  }

  static func writePlanDocument(_ plan: RockchipFlashPlan, options: CLIOptions) throws {
    // The document describes the plan, and the plan already carries the
    // archive it was built for. Finding a profile whose compiled-in digest
    // equals the plan's is how a build published after the last release ended
    // up with a complete plan it could not write down.
    let document = RockchipRockUSBFlashProvider(profile: .dayu200)
      .planDocument(for: plan)
    let url = outputURL(options, fileName: "arkdeck-flash-plan.json")
    try document.canonicalData().write(to: url, options: .atomic)
    print("plan document: \(url.path)")
  }

  static func writeHandoff(_ handoff: RockchipHumanHandoff, options: CLIOptions) throws {
    var lines: [String] = [
      "# arkdeck flash — human execution handoff",
      "plan digest: \(handoff.planDigestSHA256)",
      "step-set digest: \(handoff.stepSetDigestSHA256)",
      "recovery path: \(handoff.recoveryPathSummary)",
      "",
      "## requirements",
    ]
    lines.append(contentsOf: handoff.confirmationRequirements.map { "- \($0)" })
    lines.append("")
    lines.append("## commands (run personally, in order, stop on any deviation)")
    lines.append(contentsOf: handoff.commandLines.map { "    \($0)" })
    let url = outputURL(options, fileName: "arkdeck-flash-handoff.md")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    print("handoff document: \(url.path)")
  }

  /// Where a produced document goes when the caller did not choose.
  ///
  /// Not the current directory. The campaign lane requires the repository top
  /// level as its working directory, and the candidate scope check reads every
  /// untracked file `git ls-files --others --exclude-standard` reports — so a
  /// document dropped in the current directory by `flash plan` makes the
  /// `flash execute` that follows it refuse with `scopeDrift`. Two of this
  /// product's own requirements, colliding through a default.
  ///
  /// The state directory is where ArkDeck's other durable host files already
  /// live, and both writers print the full path, so the document stays as easy
  /// to find as it was.
  static func outputURL(_ options: CLIOptions, fileName: String) -> URL {
    if let chosen = options.value("--out") {
      return URL(fileURLWithPath: chosen).appendingPathComponent(fileName)
    }
    return defaultDocumentDirectory().appendingPathComponent(fileName)
  }

  static func defaultDocumentDirectory() -> URL {
    let manager = FileManager.default
    guard
      let applicationSupport = try? manager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    else {
      // Nowhere durable to write. The temporary directory is still not the
      // working tree, which is the property that matters here.
      return manager.temporaryDirectory
    }
    let directory =
      applicationSupport
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
      .appending(path: "FlashDocuments", directoryHint: .isDirectory)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func printUsage() {
    let usage = """
      usage:
        arkdeck flash install-tool --path <absolute-rkdeveloptool-path>
        arkdeck flash trust-tool --path <absolute-rkdeveloptool-path> \
      --expected-sha256 <full-product-pin>
        arkdeck flash install-binding
        arkdeck flash plan --images <images.tar.gz> \
      [--device-profile <dayu200>] [--mode planOnly|simulated] [--out <dir>]
        arkdeck flash status --campaign-id <ECAMP-id>
        arkdeck flash postflight --observation <observation.json> \
      [--device-profile <dayu200>]
        arkdeck update-feed prepare --sequence <n> --version <x.y.z> \
      --minimum-system <x.y.z> --issued-at <RFC3339> --expires-at <RFC3339> \
      --artifact <ArkDeck.dmg> --artifact-url <https-url> --notes <summary> --out <dir>
        arkdeck update-feed assemble --payload <payload.json> --signature <signature.bin> \
      --out <feed.json>
        arkdeck doctor [--socket <path>] [--json]
        arkdeck operation list [--socket <path>] [--json]
        arkdeck device list|show|adopt [--candidate <connect-key>] [--socket <path>] [--json]
        arkdeck job plan --request-file <request.json> [--socket <path>] [--json]
        arkdeck job submit --target <id> --operation <reference> \
      [--expected-binding-revision <n>] [--wait] [--json]
        arkdeck job status --job <id> [--json] | arkdeck job list [--json]
        arkdeck job run --job <id> [--json] | arkdeck job reconcile --job <id> [--json]
        arkdeck debug start --request-file <typed-request.json> [--json]
        arkdeck debug evaluate --invocation <id> --action-file <effect-action.json> \
      --source-sha256 <sha256> --build-sha256 <sha256> [--json]
        arkdeck debug status --invocation <id> [--json]
        arkdeck cleanup-debt list [--json]
        arkdeck cleanup-debt continue --job <id> (--remote-path <path> | --bundle <name>) [--json]
        arkdeck job submit --request-file <request.json> [--wait] [--json]
        arkdeck capability list [--json]
        arkdeck capability inspect --capability <id> [--json]
        arkdeck artifact import-hap --target <id> --file <signed.hap> [--json]
        arkdeck artifact import-flash-bundle --target <id> --file <images.tar.gz> \
      [--device-profile <dayu200>] [--json]
        arkdeck artifact import-native-library --target <id> --file <libname.so> [--json]
        arkdeck task submit --target <id> --goal <text> [--crash-signature <SIGx+Symbol>] \
      [--intake <text>] [--project <ref>] [--max-rounds <n>] \
      [--bundle-name <reverse-dns>] [--ability-name <name>] [--process-name <name>] \
      [--baseline-hap-artifact-lease <lease-v1:job:artifact>] \
      [--build-preset <ref>] [--test-preset <ref>] [--device-profile <ref>] \
      [--base-workspace-revision <sha256>] [--component <name>] \
      [--expected-binding-revision <n>] \
      [--workspace-allowed-paths <glob,...>] \
      [--workspace-allowed-operations <id@v,...>] [--max-attempts <n>] \
      [--max-changed-files <n>] [--max-diff-lines <n>] \
      [--max-wall-clock-seconds <n>] [--max-no-progress-rounds <n>] \
      [--max-action-retries-per-run <n>] [--max-e1-mutations <n>] \
      [--max-model-calls <n>] [--json]
        arkdeck task list|status|result|events|evaluations|attempts|humanActions|memory|reconcile|\
      pause|cancel --task <HTASK-id> [--json]
        arkdeck task workspace-gc [--retain-days <n>] [--retain-last <n>] [--dry-run] [--json]
        arkdeck task resume --task <HTASK-id> --resolution <typed reason> [--json]
        arkdeck task promotion --task <HTASK-id> [--destination <directory>] [--json]
        arkdeck artifact list|inspect|read|export --job <id> [--artifact <id>] \
      [--destination <directory>] [--allow-sensitive]
        arkdeck agent run --operation <reference> [--target <id>] [--inputs-file <path>] \
      [--capability <CAP-RT-...>] [--json]
        arkdeck agent resume --resume-token <token> [--selection <target-or-candidate>] [--json]

      doctor/operation/device/job/debug talk only to arkdeck-agentd over its user-private socket:
      this CLI holds no HDC or Rockchip executor and cannot build a device command itself.

      A human operator at a TTY gets a handoff whose commands they run personally. The Agent
      surface defaults to a bounded campaign confirmation and separately accepts a protected-main
      standing authorization ID, plus archive path and target-location selector; the product-owned
      host performs fresh admission, durable usage reservation,
      descriptor-bound typed execution and terminal persistence. Caller-provided authorization
      files, fact/context documents, executables, argv and storage roots are rejected.

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

/// Codable mirror of `RockchipFlashRunObservation` for the postflight subcommand.
struct CLIRunObservation: Codable {
  struct PartitionWrite: Codable {
    let partitionName: String
    let toolExitCode: Int32
    let semanticOutput: String
  }

  let partitionWrites: [PartitionWrite]
  let resetExitCode: Int32?
  let resetSemanticOutput: String?
  let reconnectedWithinDeadline: Bool
  let postflightProbeSemanticOutput: String?

  func observation() -> RockchipFlashRunObservation {
    RockchipFlashRunObservation(
      partitionWrites: partitionWrites.map {
        RockchipPartitionWriteObservation(
          partitionName: $0.partitionName,
          toolExitCode: $0.toolExitCode,
          semanticOutput: $0.semanticOutput)
      },
      resetExitCode: resetExitCode,
      resetSemanticOutput: resetSemanticOutput,
      reconnectedWithinDeadline: reconnectedWithinDeadline,
      postflightProbeSemanticOutput: postflightProbeSemanticOutput)
  }
}
