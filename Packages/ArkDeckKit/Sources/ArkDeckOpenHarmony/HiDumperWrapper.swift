import ArkDeckProcess

/// The four canonical ArkUI UI Dump recipes. The recipe vocabulary is closed so callers cannot
/// substitute a free-form HiDumper argument string.
public enum HiDumperRecipe: String, CaseIterable, Sendable {
  case nodeSummary
  case elementTree
  case fullDefaultTree
  case componentDetail
}

public enum HiDumperInvocationValidationError: Error, Sendable, Equatable {
  case invalidIdentifier(field: String)
  case missingComponentID
  case unexpectedComponentID
}

/// Only output families backed by the current integration profile can report semantic success.
/// Recipe captures remain unregistered until a future approved integration change supplies a
/// byte-pinned successful output family.
public enum HiDumperRegisteredOutputFamily: Sendable, Equatable {
  case systemAbilityList
  case unregistered
}

/// A typed remote-tool invocation. `arguments` is an argv array for HiDumper itself; it is never a
/// host shell command line. The value passed after `-a` is the WindowManagerService sub-argument
/// required by HiDumper and is assembled only from fixed tokens plus validated identifiers.
public struct HiDumperInvocation: Sendable, Equatable {
  public let remoteExecutable: String
  public let arguments: [String]
  public let outputFamily: HiDumperRegisteredOutputFamily

  fileprivate init(
    arguments: [String],
    outputFamily: HiDumperRegisteredOutputFamily
  ) {
    self.remoteExecutable = "hidumper"
    self.arguments = arguments
    self.outputFamily = outputFamily
  }
}

/// OPENHARMONY-TOOLS@0.3.0 HiDumper argv mapping.
public enum HiDumperWrapper {
  public static let windowManagerService = "WindowManagerService"

  /// M0B-registered read-only service-list probe. This is not a Recipe or compatibility claim.
  public static let systemAbilityListProbe = HiDumperInvocation(
    arguments: ["-ls"],
    outputFamily: .systemAbilityList
  )

  /// Window inventory uses the same fixed service wrapper as the four Recipes. Its successful
  /// output family is not yet registered, so output remains fail-closed as `unknownOutput`.
  public static let windowInventory = HiDumperInvocation(
    arguments: ["-s", windowManagerService, "-a", "-a"],
    outputFamily: .unregistered
  )

  public static func invocation(
    for recipe: HiDumperRecipe,
    windowID: String,
    componentID: String? = nil
  ) throws -> HiDumperInvocation {
    try validateIdentifier(windowID, field: "windowID")

    let serviceArgument: String
    switch recipe {
    case .nodeSummary:
      guard componentID == nil else {
        throw HiDumperInvocationValidationError.unexpectedComponentID
      }
      serviceArgument = "-w \(windowID) -default"
    case .elementTree:
      guard componentID == nil else {
        throw HiDumperInvocationValidationError.unexpectedComponentID
      }
      serviceArgument = "-w \(windowID) -element -c"
    case .fullDefaultTree:
      guard componentID == nil else {
        throw HiDumperInvocationValidationError.unexpectedComponentID
      }
      serviceArgument = "-w \(windowID) -default -all"
    case .componentDetail:
      guard let componentID else { throw HiDumperInvocationValidationError.missingComponentID }
      try validateIdentifier(componentID, field: "componentID")
      serviceArgument = "-w \(windowID) -element -lastpage \(componentID)"
    }

    return HiDumperInvocation(
      arguments: ["-s", windowManagerService, "-a", serviceArgument],
      outputFamily: .unregistered
    )
  }

  private static func validateIdentifier(_ value: String, field: String) throws {
    let bytes = Array(value.utf8)
    guard (1...128).contains(bytes.count), bytes.first.map(isASCIIAlphaNumeric) == true,
      bytes.dropFirst().allSatisfy({
        isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x3A || $0 == 0x5F || $0 == 0x2D
      })
    else {
      throw HiDumperInvocationValidationError.invalidIdentifier(field: field)
    }
  }

  private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
      || (0x61...0x7A).contains(byte)
  }
}

public enum HiDumperSemanticResult: Sendable, Equatable {
  case success
  case failure(HiDumperFailure)
  case unknownOutput
}

public enum HiDumperFailure: Sendable, Equatable {
  case nonZeroExit(Int32)
  case explicitFailureMarker
}

/// Bounded streaming classifier for the output families registered by OPENHARMONY-TOOLS@0.3.0.
/// Exit zero is deliberately insufficient for success. The observed exit-zero
/// `hidumper: option ... missed` form is an explicit failure, and an unregistered family cannot
/// borrow the success marker of a registered command.
public struct HiDumperSemanticOutputParser: Sendable {
  private static let systemAbilityListMarker = Array("system ability list:".utf8)
  private static let optionFailurePrefix = Array("hidumper: option ".utf8)
  private static let optionFailureSuffix = Array(" missed".utf8)
  private static let carryLength = 255

  private let outputFamily: HiDumperRegisteredOutputFamily
  private var stdoutCarry: [UInt8] = []
  private var stderrCarry: [UInt8] = []
  private var hasRegisteredSuccessMarker = false
  private var hasExplicitFailureMarker = false

  public init(outputFamily: HiDumperRegisteredOutputFamily) {
    self.outputFamily = outputFamily
  }

  public mutating func consume(_ chunk: ProcessOutputChunk) {
    let normalized = chunk.bytes.map(asciiLowercased)
    let searchable: [UInt8]
    switch chunk.stream {
    case .stdout:
      searchable = stdoutCarry + normalized
      stdoutCarry = Array(searchable.suffix(Self.carryLength))
      if outputFamily == .systemAbilityList,
        contains(searchable, marker: Self.systemAbilityListMarker)
      {
        hasRegisteredSuccessMarker = true
      }
    case .stderr:
      searchable = stderrCarry + normalized
      stderrCarry = Array(searchable.suffix(Self.carryLength))
    }

    hasExplicitFailureMarker =
      hasExplicitFailureMarker || containsOptionMissedFailure(in: searchable)
  }

  public func finish(exitCode: Int32) -> HiDumperSemanticResult {
    if hasExplicitFailureMarker {
      return .failure(.explicitFailureMarker)
    }
    if exitCode != 0 {
      return .failure(.nonZeroExit(exitCode))
    }
    return hasRegisteredSuccessMarker ? .success : .unknownOutput
  }

  private func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
  }

  private func contains(_ bytes: [UInt8], marker: [UInt8]) -> Bool {
    guard !marker.isEmpty, bytes.count >= marker.count else { return false }
    return bytes.indices.contains { start in
      guard start + marker.count <= bytes.endIndex else { return false }
      return bytes[start..<(start + marker.count)].elementsEqual(marker)
    }
  }

  private func containsOptionMissedFailure(in bytes: [UInt8]) -> Bool {
    guard bytes.count >= Self.optionFailurePrefix.count + Self.optionFailureSuffix.count else {
      return false
    }

    for start in bytes.indices {
      let prefixEnd = start + Self.optionFailurePrefix.count
      guard prefixEnd <= bytes.endIndex,
        bytes[start..<prefixEnd].elementsEqual(Self.optionFailurePrefix)
      else { continue }

      let lineEnd =
        bytes[prefixEnd...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
        ?? bytes.endIndex
      guard prefixEnd < lineEnd else { continue }
      let remainder = Array(bytes[prefixEnd..<lineEnd])
      if contains(remainder, marker: Self.optionFailureSuffix) {
        return true
      }
    }
    return false
  }
}
