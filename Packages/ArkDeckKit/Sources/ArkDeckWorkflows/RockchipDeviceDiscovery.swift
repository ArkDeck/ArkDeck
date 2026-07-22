import ArkDeckProcess
import Foundation

/// The closed RockUSB discovery family registered by CHG-2026-026/TASK-RKFUI-001.
/// Production accepts one hash-pinned upstream build and one read-only argv shape.
public struct RockchipDiscoveryIntegrationProfile: Sendable, Equatable {
  public static let pinnedProduction = RockchipDiscoveryIntegrationProfile(
    identifier: "ROCKCHIP-ROCKUSB-DISCOVERY@1.0.0",
    reportedToolVersion: "rkdeveloptool ver 1.32",
    executableSHA256: "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611",
    upstreamCommit: "304f073752fd25c854e1bcf05d8e7f925b1f4e14",
    exactArguments: ["ld"],
    timeout: 5,
    requiresSecurityScopedBookmark: true)

  public let identifier: String
  public let reportedToolVersion: String
  public let executableSHA256: String
  public let upstreamCommit: String
  public let exactArguments: [String]
  public let timeout: TimeInterval
  let requiresSecurityScopedBookmark: Bool
}

public enum RockchipToolPathSource: String, Sendable, Equatable {
  case userSelectedSecurityScopedBookmark
  case explicitSupportPath
}

public enum RockchipPlatformCodeTrust: String, Sendable, Equatable {
  case developerID
  case adHoc
  case unsigned
  case rejected
  case unknown
}

/// Platform assessment is recorded independently from the registry's source/hash pin.
/// A quarantined, rejected, unsigned, or unknown executable never reaches ProcessExecutor.
public struct RockchipPlatformTrustReceipt: Sendable, Equatable {
  public let codeTrust: RockchipPlatformCodeTrust
  public let quarantinePresent: Bool?

  public init(codeTrust: RockchipPlatformCodeTrust, quarantinePresent: Bool?) {
    self.codeTrust = codeTrust
    self.quarantinePresent = quarantinePresent
  }

  var permitsPinnedDiscovery: Bool {
    quarantinePresent == false && (codeTrust == .developerID || codeTrust == .adHoc)
  }
}

public struct RockchipSelectedDiscoveryTool: Sendable, Equatable {
  public let executableURL: URL
  public let pathSource: RockchipToolPathSource
  public let securityScopedBookmark: Data?
  public let reportedVersion: String
  public let sha256: String
  public let platformTrust: RockchipPlatformTrustReceipt

  public init(
    executableURL: URL,
    pathSource: RockchipToolPathSource,
    securityScopedBookmark: Data?,
    reportedVersion: String,
    sha256: String,
    platformTrust: RockchipPlatformTrustReceipt
  ) {
    self.executableURL = executableURL
    self.pathSource = pathSource
    self.securityScopedBookmark = securityScopedBookmark
    self.reportedVersion = reportedVersion
    self.sha256 = sha256
    self.platformTrust = platformTrust
  }
}

public enum RockchipToolValidationError: Error, Sendable, Equatable {
  case executableMustBeAbsolute
  case pathSourceNotUserSelected
  case securityScopedBookmarkMissing
  case reportedVersionMismatch
  case executableHashMismatch
  case platformTrustRejected
  case securityScopedBookmarkStale
  case securityScopedBookmarkPathMismatch
}

public enum RockchipDeviceMode: String, Sendable, Equatable {
  case loader = "Loader"
  case maskrom = "Maskrom"
}

public enum RockchipProviderBlockReason: Sendable, Equatable {
  case maskromNotSupported
  case deviceNotExpectedRockUSB
}

public enum RockchipProviderPreflightDisposition: Sendable, Equatable {
  case applicableLoader
  case blocked(RockchipProviderBlockReason)
}

public struct RockchipDeviceObservation: Sendable, Equatable {
  public let deviceNumber: UInt32
  public let usbVendorID: UInt16
  public let usbProductID: UInt16
  public let locationID: UInt64
  public let mode: RockchipDeviceMode

  public init(
    deviceNumber: UInt32,
    usbVendorID: UInt16,
    usbProductID: UInt16,
    locationID: UInt64,
    mode: RockchipDeviceMode
  ) {
    self.deviceNumber = deviceNumber
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.locationID = locationID
    self.mode = mode
  }

  public var providerPreflightDisposition: RockchipProviderPreflightDisposition {
    guard usbVendorID == 0x2207, usbProductID == 0x350a else {
      return .blocked(.deviceNotExpectedRockUSB)
    }
    guard mode == .loader else { return .blocked(.maskromNotSupported) }
    return .applicableLoader
  }
}

public enum RockchipDiscoveryDiagnostic: Error, Sendable, Equatable {
  case outputTooLarge
  case invalidUTF8
  case unexpectedStandardError
  case permissionDenied
  case driverUnavailable
  case offline
  case unauthorized
  case processTerminated(ProcessTermination)
  case tooManyDevices
  case malformedLine(line: Int)
  case numberOutOfRange(line: Int)
  case duplicateDeviceNumber(UInt32)
  case duplicateLocationID(UInt64)
  case unknownMode(line: Int, value: String)
}

public enum RockchipLDParseResult: Sendable, Equatable {
  case observations([RockchipDeviceObservation])
  case blocked(RockchipDiscoveryDiagnostic)
}

/// Consumes the complete registered `rkdeveloptool ld` stdout family. It never
/// drops an unrecognized line or turns malformed output into an empty list.
public enum RockchipLDOutputParser {
  public static let maximumOutputBytes = 64 * 1024
  public static let maximumDeviceCount = 64

  private static let lineExpression = try! NSRegularExpression(
    pattern:
      #"\ADevNo=([0-9]+)\tVid=0x([0-9A-Fa-f]{4}),Pid=0x([0-9A-Fa-f]{4}),LocationID=([0-9]+)\t([A-Za-z][A-Za-z0-9_-]{0,31})\z"#
  )

  public static func parse(
    stdout: Data,
    stderr: Data = Data(),
    termination: ProcessTermination = .exited(0)
  ) -> RockchipLDParseResult {
    guard stdout.count <= maximumOutputBytes, stderr.count <= maximumOutputBytes else {
      return .blocked(.outputTooLarge)
    }

    let diagnosticBytes = stdout + stderr
    guard let diagnosticText = String(data: diagnosticBytes, encoding: .utf8) else {
      return .blocked(.invalidUTF8)
    }
    let lowercasedDiagnostic = diagnosticText.lowercased()
    if containsAny(
      lowercasedDiagnostic,
      markers: ["permission denied", "operation not permitted", "libusb_error_access"])
    {
      return .blocked(.permissionDenied)
    }
    if containsAny(
      lowercasedDiagnostic,
      markers: ["driver unavailable", "libusb_init failed", "no libusb backend"])
    {
      return .blocked(.driverUnavailable)
    }
    if lowercasedDiagnostic.contains("unauthorized") {
      return .blocked(.unauthorized)
    }
    guard termination == .exited(0) else {
      return .blocked(.processTerminated(termination))
    }
    guard stderr.isEmpty else { return .blocked(.unexpectedStandardError) }
    guard !stdout.isEmpty else { return .blocked(.offline) }
    guard let text = String(data: stdout, encoding: .utf8), !text.contains("\r") else {
      return .blocked(.invalidUTF8)
    }

    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    guard !lines.isEmpty, lines.count <= maximumDeviceCount else {
      return .blocked(lines.isEmpty ? .offline : .tooManyDevices)
    }

    var observations: [RockchipDeviceObservation] = []
    var deviceNumbers = Set<UInt32>()
    var locationIDs = Set<UInt64>()
    for (offset, line) in lines.enumerated() {
      let lineNumber = offset + 1
      let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
      guard
        let match = lineExpression.firstMatch(in: line, range: fullRange),
        match.range == fullRange,
        let deviceNumberText = substring(match.range(at: 1), in: line),
        let vendorText = substring(match.range(at: 2), in: line),
        let productText = substring(match.range(at: 3), in: line),
        let locationText = substring(match.range(at: 4), in: line),
        let modeText = substring(match.range(at: 5), in: line)
      else {
        return .blocked(.malformedLine(line: lineNumber))
      }
      guard
        isCanonicalDecimal(deviceNumberText),
        isCanonicalDecimal(locationText),
        let deviceNumber = UInt32(deviceNumberText),
        let vendorID = UInt16(vendorText, radix: 16),
        let productID = UInt16(productText, radix: 16),
        let locationID = UInt64(locationText)
      else {
        return .blocked(.numberOutOfRange(line: lineNumber))
      }
      guard let mode = RockchipDeviceMode(rawValue: modeText) else {
        return .blocked(.unknownMode(line: lineNumber, value: modeText))
      }
      guard deviceNumbers.insert(deviceNumber).inserted else {
        return .blocked(.duplicateDeviceNumber(deviceNumber))
      }
      guard locationIDs.insert(locationID).inserted else {
        return .blocked(.duplicateLocationID(locationID))
      }
      observations.append(
        RockchipDeviceObservation(
          deviceNumber: deviceNumber,
          usbVendorID: vendorID,
          usbProductID: productID,
          locationID: locationID,
          mode: mode))
    }
    return .observations(observations)
  }

  private static func containsAny(_ text: String, markers: [String]) -> Bool {
    markers.contains(where: text.contains)
  }

  private static func isCanonicalDecimal(_ value: String) -> Bool {
    value == "0" || (value.first != "0" && value.allSatisfy(\.isNumber))
  }

  private static func substring(_ range: NSRange, in value: String) -> String? {
    guard let range = Range(range, in: value) else { return nil }
    return String(value[range])
  }
}

public enum RockchipDeviceAccessVerdict: Sendable, Equatable {
  case accessible
  case offlineOrUnauthorized
  case permissionDenied
  case driverUnavailable
  case protocolBlocked
  case malformedOutput
  case toolBlocked(RockchipToolValidationError)
  case probeFailed
}

public enum RockchipDeviceAccessResponsibility: String, Sendable, Equatable {
  case user
  case systemAdministrator
  case deviceOrToolVendor
}

public enum RockchipDeviceAccessRemediation: String, Sendable, Equatable {
  case reconnectOrEnterLoader
  case reviewDevicePermissionOutsideArkDeck
  case repairDriverOutsideArkDeck
  case selectPinnedUserApprovedTool
  case chooseSupportedLoaderObservation
  case inspectControlledDiagnostics
}

public struct RockchipDeviceAccessAdvice: Sendable, Equatable {
  public let verdict: RockchipDeviceAccessVerdict
  public let responsibility: RockchipDeviceAccessResponsibility
  public let remediation: RockchipDeviceAccessRemediation
  public let reprobeAvailable: Bool

  public init(
    verdict: RockchipDeviceAccessVerdict,
    responsibility: RockchipDeviceAccessResponsibility,
    remediation: RockchipDeviceAccessRemediation,
    reprobeAvailable: Bool
  ) {
    self.verdict = verdict
    self.responsibility = responsibility
    self.remediation = remediation
    self.reprobeAvailable = reprobeAvailable
  }
}

public enum RockchipDeviceAccessAdvisor {
  public static func verdict(for result: RockchipLDParseResult) -> RockchipDeviceAccessVerdict {
    switch result {
    case .observations(let observations):
      return observations.contains {
        $0.providerPreflightDisposition == .applicableLoader
      } ? .accessible : .protocolBlocked
    case .blocked(let diagnostic):
      switch diagnostic {
      case .permissionDenied: return .permissionDenied
      case .driverUnavailable: return .driverUnavailable
      case .offline, .unauthorized: return .offlineOrUnauthorized
      case .malformedLine, .numberOutOfRange, .duplicateDeviceNumber, .duplicateLocationID,
        .unknownMode, .invalidUTF8, .unexpectedStandardError, .outputTooLarge,
        .tooManyDevices:
        return .malformedOutput
      case .processTerminated: return .probeFailed
      }
    }
  }

  public static func advice(
    for verdict: RockchipDeviceAccessVerdict
  ) -> RockchipDeviceAccessAdvice {
    switch verdict {
    case .accessible:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .chooseSupportedLoaderObservation, reprobeAvailable: true)
    case .offlineOrUnauthorized:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .reconnectOrEnterLoader, reprobeAvailable: true)
    case .permissionDenied:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .systemAdministrator,
        remediation: .reviewDevicePermissionOutsideArkDeck, reprobeAvailable: true)
    case .driverUnavailable:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .deviceOrToolVendor,
        remediation: .repairDriverOutsideArkDeck, reprobeAvailable: true)
    case .protocolBlocked:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .chooseSupportedLoaderObservation, reprobeAvailable: true)
    case .toolBlocked:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .selectPinnedUserApprovedTool, reprobeAvailable: true)
    case .malformedOutput, .probeFailed:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .deviceOrToolVendor,
        remediation: .inspectControlledDiagnostics, reprobeAvailable: true)
    }
  }
}

public struct RockchipDeviceDiscoveryAttempt: Sendable, Equatable {
  public let observations: [RockchipDeviceObservation]
  public let diagnostic: RockchipDiscoveryDiagnostic?
  public let advice: RockchipDeviceAccessAdvice
  public let execution: ProcessExecutionResult?
  public let executableIdentity: ProcessExecutableIdentityReceipt?

  public init(
    observations: [RockchipDeviceObservation],
    diagnostic: RockchipDiscoveryDiagnostic?,
    advice: RockchipDeviceAccessAdvice,
    execution: ProcessExecutionResult?,
    executableIdentity: ProcessExecutableIdentityReceipt?
  ) {
    self.observations = observations
    self.diagnostic = diagnostic
    self.advice = advice
    self.execution = execution
    self.executableIdentity = executableIdentity
  }
}

struct RockchipLDSemanticEvaluator: ProcessSemanticEvaluating {
  typealias SemanticResult = RockchipLDParseResult

  private var stdout = Data()
  private var stderr = Data()
  private var exceededLimit = false

  mutating func consume(_ chunk: ProcessOutputChunk) {
    let currentCount = stdout.count + stderr.count
    guard currentCount <= RockchipLDOutputParser.maximumOutputBytes else {
      exceededLimit = true
      return
    }
    let remaining = RockchipLDOutputParser.maximumOutputBytes + 1 - currentCount
    let bytes = chunk.bytes.prefix(max(0, remaining))
    if bytes.count < chunk.bytes.count { exceededLimit = true }
    switch chunk.stream {
    case .stdout: stdout.append(bytes)
    case .stderr: stderr.append(bytes)
    }
  }

  mutating func finish(execution: ProcessExecutionResult) -> RockchipLDParseResult {
    guard !exceededLimit, stdout.count + stderr.count <= RockchipLDOutputParser.maximumOutputBytes
    else {
      return .blocked(.outputTooLarge)
    }
    return RockchipLDOutputParser.parse(
      stdout: stdout, stderr: stderr, termination: execution.termination)
  }
}

private enum RockchipSecurityScopedAccessError: Error {
  case staleBookmark
  case pathMismatch
}

private final class RockchipSecurityScopedExecutableAccess {
  private let url: URL?
  private var didStart = false

  init(path: URL, bookmark: Data?) throws {
    guard let bookmark else {
      url = nil
      return
    }
    var isStale = false
    let resolved = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale)
    guard !isStale else { throw RockchipSecurityScopedAccessError.staleBookmark }
    guard
      resolved.resolvingSymlinksInPath().standardizedFileURL
        == path.resolvingSymlinksInPath().standardizedFileURL
    else {
      throw RockchipSecurityScopedAccessError.pathMismatch
    }
    url = resolved
    didStart = resolved.startAccessingSecurityScopedResource()
  }

  func stop() {
    guard didStart, let url else { return }
    didStart = false
    url.stopAccessingSecurityScopedResource()
  }

  deinit { stop() }
}

/// Shell-free, identity-bound adapter. Callers cannot supply arguments; the
/// profile fixes the only process request to the read-only `ld` operation.
public actor RockchipDeviceDiscoveryAdapter {
  private let profile: RockchipDiscoveryIntegrationProfile
  private let executor: FoundationProcessExecutor

  public init() {
    profile = .pinnedProduction
    executor = FoundationProcessExecutor()
  }

  init(
    profile: RockchipDiscoveryIntegrationProfile,
    executor: FoundationProcessExecutor = FoundationProcessExecutor()
  ) {
    self.profile = profile
    self.executor = executor
  }

  func processRequest(
    for tool: RockchipSelectedDiscoveryTool
  ) throws -> ProcessIdentityBoundRequest {
    guard tool.executableURL.isFileURL, tool.executableURL.path.hasPrefix("/") else {
      throw RockchipToolValidationError.executableMustBeAbsolute
    }
    guard tool.pathSource == .userSelectedSecurityScopedBookmark else {
      throw RockchipToolValidationError.pathSourceNotUserSelected
    }
    guard !profile.requiresSecurityScopedBookmark || tool.securityScopedBookmark != nil else {
      throw RockchipToolValidationError.securityScopedBookmarkMissing
    }
    guard tool.reportedVersion == profile.reportedToolVersion else {
      throw RockchipToolValidationError.reportedVersionMismatch
    }
    guard tool.sha256 == profile.executableSHA256 else {
      throw RockchipToolValidationError.executableHashMismatch
    }
    guard tool.platformTrust.permitsPinnedDiscovery else {
      throw RockchipToolValidationError.platformTrustRejected
    }
    return ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: tool.executableURL,
        arguments: profile.exactArguments,
        environment: [:],
        timeout: profile.timeout),
      expectedSHA256: profile.executableSHA256)
  }

  public func discover(using tool: RockchipSelectedDiscoveryTool) async
    -> RockchipDeviceDiscoveryAttempt
  {
    let request: ProcessIdentityBoundRequest
    do {
      request = try processRequest(for: tool)
    } catch let error as RockchipToolValidationError {
      return blockedToolAttempt(error)
    } catch {
      return blockedToolAttempt(.platformTrustRejected)
    }

    let access: RockchipSecurityScopedExecutableAccess
    do {
      access = try RockchipSecurityScopedExecutableAccess(
        path: tool.executableURL, bookmark: tool.securityScopedBookmark)
    } catch RockchipSecurityScopedAccessError.staleBookmark {
      return blockedToolAttempt(.securityScopedBookmarkStale)
    } catch RockchipSecurityScopedAccessError.pathMismatch {
      return blockedToolAttempt(.securityScopedBookmarkPathMismatch)
    } catch {
      return blockedToolAttempt(.securityScopedBookmarkStale)
    }
    defer { access.stop() }

    do {
      let evaluated = try await executor.executeIdentityBound(
        request, evaluating: RockchipLDSemanticEvaluator())
      return attempt(
        from: evaluated.semantic,
        execution: evaluated.execution,
        executableIdentity: evaluated.executableIdentity)
    } catch {
      return RockchipDeviceDiscoveryAttempt(
        observations: [],
        diagnostic: nil,
        advice: RockchipDeviceAccessAdvisor.advice(for: .probeFailed),
        execution: nil,
        executableIdentity: nil)
    }
  }

  private func blockedToolAttempt(
    _ error: RockchipToolValidationError
  ) -> RockchipDeviceDiscoveryAttempt {
    let verdict = RockchipDeviceAccessVerdict.toolBlocked(error)
    return RockchipDeviceDiscoveryAttempt(
      observations: [],
      diagnostic: nil,
      advice: RockchipDeviceAccessAdvisor.advice(for: verdict),
      execution: nil,
      executableIdentity: nil)
  }

  private func attempt(
    from result: RockchipLDParseResult,
    execution: ProcessExecutionResult,
    executableIdentity: ProcessExecutableIdentityReceipt
  ) -> RockchipDeviceDiscoveryAttempt {
    switch result {
    case .observations(let observations):
      let verdict = RockchipDeviceAccessAdvisor.verdict(for: result)
      return RockchipDeviceDiscoveryAttempt(
        observations: observations,
        diagnostic: nil,
        advice: RockchipDeviceAccessAdvisor.advice(for: verdict),
        execution: execution,
        executableIdentity: executableIdentity)
    case .blocked(let diagnostic):
      let verdict = RockchipDeviceAccessAdvisor.verdict(for: result)
      return RockchipDeviceDiscoveryAttempt(
        observations: [],
        diagnostic: diagnostic,
        advice: RockchipDeviceAccessAdvisor.advice(for: verdict),
        execution: execution,
        executableIdentity: executableIdentity)
    }
  }
}
