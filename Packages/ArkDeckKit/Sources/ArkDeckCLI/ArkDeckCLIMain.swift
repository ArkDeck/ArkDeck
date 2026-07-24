import ArkDeckCore
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

// TASK-RF-002. `arkdeck flash` — the product face of the RockUSB Provider.
//
// The human execute branch still ends at a handoff. The autonomous branch passes only the strict
// authorization ID, archive URL and location selector into the product-owned typed executor; it
// has no executable, argv, shell, fact receipt, storage-root or dependency-injection surface.
// Migration guard: the obsolete executorUnavailable branch must not be restored below this host.

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
    case "plan":
      try runPlan(Array(arguments.dropFirst()))
    case "execute":
      try await runExecute(Array(arguments.dropFirst()))
    case "postflight":
      try runPostflight(Array(arguments.dropFirst()))
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported flash subcommand")
    }
  }

  // MARK: plan

  static func runPlan(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--images", "--mode", "--out"])
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
      "--images", "--target-location-id", "--operator", "--authorization-id", "--out",
    ])
    let operatorIdentity = options.value("--operator")
    let authority = RockchipExecutionAuthorityResolver.resolve(
      operatorProvided: operatorIdentity?.isEmpty == false,
      standardInputIsInteractive: isatty(FileHandle.standardInput.fileDescriptor) == 1,
      environmentOverride: ProcessInfo.processInfo.environment["ARKDECK_EXECUTION_AUTHORITY"])

    if let authorizationID = options.value("--authorization-id") {
      guard RockchipStandingAuthorizationIdentifier.isValid(authorizationID) else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "invalid --authorization-id; expected strict AUTH-[A-Z0-9-] identifier")
      }
      guard authority != .humanOperator, operatorIdentity == nil else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "--operator and --authorization-id are mutually exclusive")
      }
      guard options.value("--out") == nil else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "--out is unavailable with --authorization-id; the trusted host owns "
            + "Session storage")
      }
      guard let imagesPath = options.value("--images"),
        let location = options.value("--target-location-id")
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "authorized execution requires --images and --target-location-id")
      }
      let request = try RockchipFlashExecutionRequest(
        authorizationID: authorizationID,
        archiveURL: URL(fileURLWithPath: imagesPath),
        targetLocationSelector: location)
      let result = try await RockchipFlashExecutionHost().execute(request)
      print("session: \(result.sessionID)")
      print("job: \(result.jobID)")
      print("terminal status: \(result.status.rawValue)")
      print("evidence class: \(result.evidenceClass.rawValue)")
      if let manifestURL = result.manifestURL { print("manifest: \(manifestURL.path)") }
      return
    }

    let plan = try validateAndPlan(options: options, mode: .execute)
    try writePlanDocument(plan, options: options)
    printExactPlan(plan)

    let provider = RockchipRockUSBFlashProvider()
    let gate = RockchipFlashAuthorizationGate()
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
          + "TTY); an AI caller must present --authorization-id to the trusted executor. "
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

  // MARK: postflight

  static func runPostflight(_ arguments: [String]) throws {
    let options = try CLIOptions(arguments)
    try options.validateAllowed(["--observation"])
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
      --authorization-id <AUTH-ID>
        arkdeck flash postflight --observation <observation.json>
        arkdeck update-feed prepare --sequence <n> --version <x.y.z> \
      --minimum-system <x.y.z> --issued-at <RFC3339> --expires-at <RFC3339> \
      --artifact <ArkDeck.dmg> --artifact-url <https-url> --notes <summary> --out <dir>
        arkdeck update-feed assemble --payload <payload.json> --signature <signature.bin> \
      --out <feed.json>

      A human operator at a TTY gets a handoff whose commands they run personally. The AI
      surface accepts only an authorization ID, archive path and target-location selector; the
      product-owned host performs fresh protected-main admission, durable usage reservation,
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

  func load() throws -> UpdateReplayRecord? {
    lock.withLock { record }
  }

  func save(_ record: UpdateReplayRecord) throws {
    lock.withLock { self.record = record }
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
