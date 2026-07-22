import ArkDeckCore
import ArkDeckWorkflows
import Darwin
import Foundation

// TASK-RF-002. `arkdeck flash` — the product face of the RockUSB Provider.
//
// This executable never dispatches a device command and never spawns an external process.
// Its execute branch ends at a human handoff: exact plan → prerequisite attestation →
// destructive confirmation → manual-confirmation record → authorization gate → handoff
// document. A human operator runs the handoff commands personally (REQ-FLASH-015).

@main
struct ArkDeckCommandLine {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "flash" else {
      printUsage()
      exit(EX_USAGE)
    }
    let flashArguments = Array(arguments.dropFirst())
    guard let subcommand = flashArguments.first else {
      printUsage()
      exit(EX_USAGE)
    }
    do {
      switch subcommand {
      case "plan":
        try runPlan(Array(flashArguments.dropFirst()))
      case "execute":
        try await runExecute(Array(flashArguments.dropFirst()))
      case "postflight":
        try runPostflight(Array(flashArguments.dropFirst()))
      default:
        printUsage()
        exit(EX_USAGE)
      }
    } catch let error as CLIError {
      FileHandle.standardError.write(Data("arkdeck flash: \(error.message)\n".utf8))
      exit(error.exitCode)
    } catch {
      FileHandle.standardError.write(Data("arkdeck flash: \(error)\n".utf8))
      exit(1)
    }
  }

  // MARK: plan

  static func runPlan(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
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
    let operatorIdentity = options.value("--operator")
    let authority = RockchipExecutionAuthorityResolver.resolve(
      operatorProvided: operatorIdentity?.isEmpty == false,
      standardInputIsInteractive: isatty(FileHandle.standardInput.fileDescriptor) == 1,
      environmentOverride: ProcessInfo.processInfo.environment["ARKDECK_EXECUTION_AUTHORITY"])

    let plan = try validateAndPlan(options: options, mode: .execute)
    try writePlanDocument(plan, options: options)
    printExactPlan(plan)

    let provider = RockchipRockUSBFlashProvider()
    let gate = RockchipFlashAuthorizationGate()
    let monitor = RockchipFlashDispatchMonitor()

    guard authority == .humanOperator, let operatorIdentity else {
      if options.value("--authorization") != nil {
        // TASK-AIN-003 unattended path: a maintainer-merged standing authorization
        // replaces the in-person operator; the gate compares it pin-by-pin.
        try await runUnattendedExecute(
          options: options, plan: plan, authority: authority, gate: gate,
          provider: provider, monitor: monitor)
        return
      }
      // No standing authorization: fail closed before any prompt, produce the controlled
      // handoff naming the missing carrier.
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
          + "TTY) or a maintainer-merged standing authorization (--authorization plus "
          + "--unattended-context); this run is \(authority.rawValue) and real destructive "
          + "dispatch stays 0.")
      try writeHandoff(handoff, options: options)
      exit(3)
    }

    guard case .realDevice(let binding) = bindingState(options) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "execute requires --target-location-id <usb-location> to confirm the "
          + "physical target")
    }

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

  // MARK: unattended execute (TASK-AIN-003)

  static func runUnattendedExecute(
    options: CLIOptions,
    plan: RockchipFlashPlan,
    authority: RockchipExecutionAuthority,
    gate: RockchipFlashAuthorizationGate,
    provider: RockchipRockUSBFlashProvider,
    monitor: RockchipFlashDispatchMonitor
  ) async throws {
    guard let authorizationPath = options.value("--authorization") else {
      throw CLIError(exitCode: EX_USAGE, message: "missing --authorization <AUTH-*.json>")
    }
    guard let contextPath = options.value("--unattended-context") else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "unattended execute requires --unattended-context <context.json> "
          + "(prior run count, durable binding revision, prerequisites, identity readback)")
    }
    let authorization = try RockchipStandingAuthorization.parse(
      Data(contentsOf: URL(fileURLWithPath: authorizationPath)))
    let contextDocument = try JSONDecoder().decode(
      CLIUnattendedContext.self, from: Data(contentsOf: URL(fileURLWithPath: contextPath)))

    let prerequisites = provider.evaluatePrerequisites(contextDocument.observations())
    let decision = await gate.authorize(
      authority: authority,
      binding: bindingState(options),
      plan: plan,
      prerequisites: prerequisites,
      destructiveConfirmationAccepted: false,
      manualConfirmation: nil,
      standingAuthorization: authorization,
      standingContext: contextDocument.standingContext(
        currentTimestamp: ISO8601DateFormatter().string(from: Date())),
      monitor: monitor)
    print("Job marker: \(decision.jobMarker)")

    switch decision.outcome {
    case .authorizedForUnattendedAgentExecution(let commandSurface, let intent):
      // Durable intent first (POL-WORKFLOW-001), then the command surface.
      let intentURL = outputURL(options, fileName: "arkdeck-flash-unattended-intent.json")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(intent).write(to: intentURL, options: .atomic)
      print("durable intent: \(intentURL.path)")
      print("authorizationRef: \(decision.authorizationRef ?? "")")
      try writeHandoff(commandSurface, options: options)
      print(
        "\nAuthorized for unattended execution. The executing run must persist the intent, "
          + "dispatch exactly the listed commands, and record executor.kind=agent with the "
          + "authorizationRef in the v3 evidence.")
    case .policyBlocked(let handoff):
      print("standing authorization not applicable for \(authority.rawValue); dispatch 0.")
      try writeHandoff(handoff, options: options)
      exit(3)
    case .blockedStandingAuthorizationExpiredOrExhausted(let reason):
      print("standing authorization expired/exhausted (\(reason)); dispatch 0.")
      exit(4)
    case .blockedStandingAuthorizationMismatch(let fields):
      print(
        "standing authorization mismatch (\(fields.joined(separator: ", "))); dispatch 0.")
      exit(4)
    case .blockedDeviceIdentityReadbackMismatch(let fields):
      print(
        "device identity readback mismatch (\(fields.joined(separator: ", "))); dispatch 0.")
      exit(4)
    case .blockedByPrerequisites(let violations):
      for violation in violations {
        print("blocked: \(violation)")
      }
      exit(4)
    case .blockedTargetBindingUnconfirmed:
      throw CLIError(
        exitCode: EX_USAGE,
        message: "unattended execute requires --target-location-id <usb-location>")
    default:
      exit(4)
    }
  }

  // MARK: postflight

  static func runPostflight(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    guard let observationPath = options.value("--observation") else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "postflight requires --observation <observation.json>")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: observationPath))
    let observation = try JSONDecoder().decode(CLIRunObservation.self, from: data)
    let provider = RockchipRockUSBFlashProvider()
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

  // MARK: shared helpers

  static func validateAndPlan(
    options: CLIOptions, mode: RockchipFlashExecutionMode
  ) throws -> RockchipFlashPlan {
    guard let imagesPath = options.value("--images") else {
      throw CLIError(exitCode: EX_USAGE, message: "missing --images <images.tar.gz>")
    }
    print("validating \(imagesPath) (streaming SHA-256; this can take a while)…")
    let summary = try GzipTarArchiveReader.summarize(fileAt: URL(fileURLWithPath: imagesPath))
    let provider = RockchipRockUSBFlashProvider()
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
    let document = RockchipRockUSBFlashProvider().planDocument(for: plan)
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

  static func outputURL(_ options: CLIOptions, fileName: String) -> URL {
    let directory = options.value("--out") ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: directory).appendingPathComponent(fileName)
  }

  static func printUsage() {
    let usage = """
      usage:
        arkdeck flash plan --images <images.tar.gz> [--mode planOnly|simulated] [--out <dir>]
        arkdeck flash execute --images <images.tar.gz> --target-location-id <usb-location> \
      --operator <name> [--out <dir>]
        arkdeck flash execute --images <images.tar.gz> --target-location-id <usb-location> \
      --authorization <AUTH-*.json> --unattended-context <context.json> [--out <dir>]
        arkdeck flash postflight --observation <observation.json>

      execute never flashes by itself: it validates the archive, shows the exact plan and
      ends at an authorization decision. A human operator at a TTY gets a handoff whose
      commands they run personally; an agent credential passes only when a maintainer-
      merged standing authorization matches the plan pin-by-pin (CHG-2026-025), producing
      a durable intent plus the authorized command surface. Everything else fails closed.
      """
    print(usage)
  }
}

struct CLIError: Error {
  let exitCode: Int32
  let message: String
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
      values[argument] = arguments[index + 1]
      index += 2
    }
  }

  func value(_ name: String) -> String? {
    values[name]
  }
}

/// Codable carrier for the unattended-execute context (TASK-AIN-003): durable facts the
/// gate must not guess — prior run count, current binding revision, machine-checked
/// prerequisites and the pre-dispatch identity readback.
struct CLIUnattendedContext: Codable {
  struct Readback: Codable {
    let serialDigestSHA256: String
    let usbVendorID: UInt16
    let usbProductID: UInt16
    let readAtTimestamp: String
  }

  struct Prerequisites: Codable {
    let loader: String
    let recoveryPath: String
    let unlocked: String
  }

  let priorRunCount: Int
  let durableBindingRevision: Int
  let prerequisites: Prerequisites
  let identityReadback: Readback?

  func observations() -> [RockchipPrerequisiteObservation] {
    func status(_ raw: String) -> RockchipPrerequisiteStatus {
      switch raw {
      case "satisfied": return .satisfied
      case "unsatisfied": return .unsatisfied
      default: return .unknown  // anything unrecognized stays unknown (fail closed)
      }
    }
    return [
      RockchipPrerequisiteObservation(identifier: .loader, status: status(prerequisites.loader)),
      RockchipPrerequisiteObservation(
        identifier: .recoveryPath, status: status(prerequisites.recoveryPath)),
      RockchipPrerequisiteObservation(
        identifier: .unlocked, status: status(prerequisites.unlocked)),
    ]
  }

  func standingContext(currentTimestamp: String) -> RockchipStandingAuthorizationContext {
    RockchipStandingAuthorizationContext(
      currentTimestamp: currentTimestamp,
      priorRunCount: priorRunCount,
      durableBindingRevision: durableBindingRevision,
      identityReadback: identityReadback.map {
        RockchipDeviceIdentityReadback(
          serialDigestSHA256: $0.serialDigestSHA256,
          usbVendorID: $0.usbVendorID,
          usbProductID: $0.usbProductID,
          readAtTimestamp: $0.readAtTimestamp)
      })
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
