import ArkDeckCore
import ArkDeckProcess
import Foundation

enum RockchipFlashExecutionLoweringError: Error, Equatable, Sendable {
  case unsupportedStep(String)
  case malformedStep(String)
  case stagedImageMissing(String)
  case outputTooLarge
  case invalidUTF8
  case unexpectedStandardError
  case processDidNotExitSuccessfully
  case semanticMarkerMissing(String)
  case partitionTableMismatch
  case loaderObservationMismatch
}

enum RockchipClosedCommand: Sendable {
  case loaderGate(step: WorkflowStep)
  case partitionTablePrecheck(step: WorkflowStep)
  case writePartition(step: WorkflowStep, partition: String, image: StagedRockchipImage)
  case reset(step: WorkflowStep)

  var step: WorkflowStep {
    switch self {
    case .loaderGate(let step), .partitionTablePrecheck(let step),
      .writePartition(let step, _, _), .reset(let step):
      step
    }
  }

  var arguments: [String] {
    switch self {
    case .loaderGate: ["ld"]
    case .partitionTablePrecheck: ["ppt"]
    case .writePartition(_, let partition, let image):
      ["wlx", partition, image.stableDescriptorPath]
    case .reset: ["rd"]
    }
  }

  var isCriticalWrite: Bool {
    if case .writePartition = self { return true }
    return false
  }
}

enum RockchipFlashExecutionLowering {
  static func commands(
    plan: RockchipFlashPlan,
    stagedImages: [String: StagedRockchipImage]
  ) throws -> [RockchipClosedCommand] {
    guard plan.executionMode == .execute else {
      throw RockchipFlashExecutionLoweringError.malformedStep("executionMode")
    }
    var commands: [RockchipClosedCommand] = []
    var sawLoader = false
    var sawPartitionTable = false
    var sawReset = false
    var partitions: [String] = []
    for step in plan.steps {
      switch step.kind {
      case .requestConfirmation:
        continue
      case .enterUpdater:
        guard !sawLoader,
          step.arguments["providerOperationId"] == .string("rockusb.enter-loader")
        else { throw RockchipFlashExecutionLoweringError.malformedStep(step.id) }
        sawLoader = true
        commands.append(.loaderGate(step: step))
      case .verifyRemoteState:
        if step.arguments["probeId"] == .string("rockusb-ppt-precheck") {
          guard sawLoader, !sawPartitionTable else {
            throw RockchipFlashExecutionLoweringError.malformedStep(step.id)
          }
          sawPartitionTable = true
          commands.append(.partitionTablePrecheck(step: step))
        } else if step.arguments["probeId"] == .string("rockusb-postflight-list-targets") {
          // Postflight is a typed product probe, not an rkdeveloptool command.
          continue
        } else {
          throw RockchipFlashExecutionLoweringError.unsupportedStep(step.id)
        }
      case .flashPartition:
        guard sawPartitionTable, !sawReset,
          step.arguments["providerOperationId"] == .string("rockusb.wlx-write"),
          case .string(let partition)? = step.arguments["partition"],
          case .string(let memberName)? = step.arguments["imageArtifactId"],
          case .string(let expectedHash)? = step.arguments["imageSha256"],
          case .integer(let expectedSize)? = step.arguments["imageSize"],
          let image = stagedImages[memberName], image.memberName == memberName,
          image.sha256 == expectedHash, image.sizeBytes == expectedSize,
          image.partitionName == partition
        else { throw RockchipFlashExecutionLoweringError.stagedImageMissing(step.id) }
        partitions.append(partition)
        commands.append(.writePartition(step: step, partition: partition, image: image))
      case .rebootDevice:
        guard sawPartitionTable, !sawReset,
          step.arguments["targetMode"] == .string("normal"),
          step.arguments["reason"] == .string("rockusb-rd-reset-after-flash")
        else { throw RockchipFlashExecutionLoweringError.malformedStep(step.id) }
        sawReset = true
        commands.append(.reset(step: step))
      default:
        throw RockchipFlashExecutionLoweringError.unsupportedStep(step.id)
      }
    }
    let expectedPartitions = RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName)
    if plan.archiveSHA256 == RockchipFlashProfile.dayu200.archiveSHA256 {
      guard partitions == expectedPartitions else {
        throw RockchipFlashExecutionLoweringError.malformedStep("partitionOrder")
      }
    } else {
      guard partitions.count == stagedImages.count,
        Set(partitions) == Set(stagedImages.values.map(\.partitionName))
      else { throw RockchipFlashExecutionLoweringError.malformedStep("partitionSet") }
    }
    guard sawLoader, sawPartitionTable, sawReset,
      commands.map(\.arguments.first) == ["ld", "ppt"]
        + Array(repeating: "wlx", count: partitions.count) + ["rd"]
    else { throw RockchipFlashExecutionLoweringError.malformedStep("commandSequence") }
    return commands
  }
}

enum RockchipCommandSemanticResult: Equatable, Sendable {
  case succeeded
  case failed(RockchipFlashExecutionLoweringError)
}

struct RockchipCommandSemanticEvaluator: ProcessSemanticEvaluating {
  typealias SemanticResult = RockchipCommandSemanticResult

  static let maximumOutputBytes = 64 * 1_024
  let command: RockchipClosedCommand
  private var stdout = Data()
  private var stderr = Data()
  private var exceededLimit = false

  init(command: RockchipClosedCommand) { self.command = command }

  mutating func consume(_ chunk: ProcessOutputChunk) {
    let current = stdout.count + stderr.count
    guard current <= Self.maximumOutputBytes else {
      exceededLimit = true
      return
    }
    let remaining = Self.maximumOutputBytes + 1 - current
    let bytes = chunk.bytes.prefix(max(0, remaining))
    if bytes.count < chunk.bytes.count { exceededLimit = true }
    switch chunk.stream {
    case .stdout: stdout.append(bytes)
    case .stderr: stderr.append(bytes)
    }
  }

  mutating func finish(execution: ProcessExecutionResult) -> RockchipCommandSemanticResult {
    guard !exceededLimit, stdout.count + stderr.count <= Self.maximumOutputBytes else {
      return .failed(.outputTooLarge)
    }
    guard stderr.isEmpty else { return .failed(.unexpectedStandardError) }
    guard execution.termination == .exited(0) else {
      return .failed(.processDidNotExitSuccessfully)
    }
    guard let text = String(data: stdout, encoding: .utf8) else {
      return .failed(.invalidUTF8)
    }
    switch command {
    case .loaderGate:
      guard
        case .observations(let observations) = RockchipLDOutputParser.parse(
          stdout: stdout, stderr: stderr, termination: execution.termination),
        observations.count == 1, let observation = observations.first,
        observation.usbVendorID == RockchipProbeEvidence.rockUSBVendorID,
        observation.usbProductID == RockchipProbeEvidence.dayu200LoaderProductID,
        observation.mode == .loader
      else { return .failed(.loaderObservationMismatch) }
      return .succeeded
    case .partitionTablePrecheck:
      return Self.matchesPinnedPartitionTable(text)
        ? .succeeded : .failed(.partitionTableMismatch)
    case .writePartition:
      return text.contains(RockchipRockUSBFlashProvider.writeSuccessMarker)
        ? .succeeded
        : .failed(.semanticMarkerMissing(RockchipRockUSBFlashProvider.writeSuccessMarker))
    case .reset:
      return text.contains(RockchipRockUSBFlashProvider.resetSuccessMarker)
        ? .succeeded
        : .failed(.semanticMarkerMissing(RockchipRockUSBFlashProvider.resetSuccessMarker))
    }
  }

  private static func matchesPinnedPartitionTable(_ text: String) -> Bool {
    let expectedRows = [
      "00  00002000  uboot", "01  00004000  misc", "02  00006000  bootctrl",
      "03  00007000  resource", "04  0000A000  boot_linux", "05  0003A000  ramdisk",
      "06  0003C000  system", "07  0043C000  vendor", "08  0063C000  sys-prod",
      "09  00655000  chip-prod", "10  0066E000  updater", "11  0067E000  eng_system",
      "12  00686000  eng_chipset", "13  0069E000  chip_ckm", "14  01308000  userdata",
    ]
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    guard lines.contains("**********Partition Info(GPT)**********") else { return false }
    let normalizedRows = expectedRows.map {
      $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return lines.filter { line in
      line.range(of: #"^[0-9]{2} [0-9A-F]{8} [A-Za-z0-9_-]+$"#, options: .regularExpression)
        != nil
    } == normalizedRows
  }
}
