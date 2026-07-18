import Foundation

/// The platform-neutral tool kind fixed by a Job intent. The closed vocabulary
/// is deliberately separate from a process executable or argv surface.
public enum JobToolchainKind: String, Codable, Sendable, Equatable {
  case hdc
}

/// Where the user-visible tool selection came from when the Job was created.
public enum JobToolchainSource: String, Codable, Sendable, Equatable {
  case userConfigured
  case devecoSDK
  case openHarmonySDK
}

/// A diagnostic field never disappears merely because a probe cannot prove a
/// value. Unknown and unverified values retain their reason in durable bytes.
public enum JobToolchainEvidence<Value>: Sendable, Equatable
where Value: Codable & Sendable & Equatable {
  case known(Value)
  case unknown(reason: String)
  case unverified(value: Value?, reason: String)
}

extension JobToolchainEvidence: Codable {
  private enum State: String, Codable {
    case known
    case unknown
    case unverified
  }

  private enum CodingKeys: String, CodingKey {
    case state
    case value
    case reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(State.self, forKey: .state) {
    case .known:
      guard container.contains(.value), !container.contains(.reason) else {
        throw DecodingError.dataCorruptedError(
          forKey: .state, in: container,
          debugDescription: "known evidence requires only a value")
      }
      self = .known(try container.decode(Value.self, forKey: .value))
    case .unknown:
      guard !container.contains(.value),
        let reason = try container.decodeIfPresent(String.self, forKey: .reason),
        JobToolchainIntent.isValidDiagnosticText(reason)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .state, in: container,
          debugDescription: "unknown evidence requires a non-empty reason and no value")
      }
      self = .unknown(reason: reason)
    case .unverified:
      guard
        let reason = try container.decodeIfPresent(String.self, forKey: .reason),
        JobToolchainIntent.isValidDiagnosticText(reason)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .state, in: container,
          debugDescription: "unverified evidence requires a non-empty reason")
      }
      self = .unverified(
        value: try container.decodeIfPresent(Value.self, forKey: .value), reason: reason)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .known(let value):
      try container.encode(State.known, forKey: .state)
      try container.encode(value, forKey: .value)
    case .unknown(let reason):
      try container.encode(State.unknown, forKey: .state)
      try container.encode(reason, forKey: .reason)
    case .unverified(let value, let reason):
      try container.encode(State.unverified, forKey: .state)
      try container.encodeIfPresent(value, forKey: .value)
      try container.encode(reason, forKey: .reason)
    }
  }
}

public enum JobToolchainIntentValidationError: Error, Sendable, Equatable {
  case invalidIdentifier(field: String)
  case executablePathMustBeAbsolute
  case invalidSHA256
  case invalidDiagnosticEvidence(field: String)
  case jobMismatch(expected: String, actual: String)
  case unsupportedStepKind(WorkflowStepKind)
}

/// Immutable Core value persisted for a Job before a tool-backed typed Step is
/// dispatched. It contains no bookmark, file descriptor, process handle, or
/// argv and therefore cannot itself grant platform launch authority.
public struct JobToolchainIntent: Codable, Sendable, Equatable {
  public static let schemaVersion = "1.0.0"

  public let schemaVersion: String
  public let id: UUID
  public let jobID: String
  public let kind: JobToolchainKind
  public let executablePath: String
  public let source: JobToolchainSource
  public let executableSHA256: String
  public let platformTrust: JobToolchainEvidence<String>
  public let clientVersion: JobToolchainEvidence<String>
  public let serverVersion: JobToolchainEvidence<String>
  public let daemonVersion: JobToolchainEvidence<String>
  public let endpoint: String
  public let serverGeneration: JobToolchainEvidence<Int>

  public init(
    id: UUID,
    jobID: String,
    kind: JobToolchainKind = .hdc,
    executablePath: String,
    source: JobToolchainSource,
    executableSHA256: String,
    platformTrust: JobToolchainEvidence<String>,
    clientVersion: JobToolchainEvidence<String>,
    serverVersion: JobToolchainEvidence<String>,
    daemonVersion: JobToolchainEvidence<String>,
    endpoint: String,
    serverGeneration: JobToolchainEvidence<Int>
  ) throws {
    guard Self.isValidIdentifier(jobID) else {
      throw JobToolchainIntentValidationError.invalidIdentifier(field: "jobID")
    }
    guard executablePath.hasPrefix("/"), Self.isValidDiagnosticText(executablePath) else {
      throw JobToolchainIntentValidationError.executablePathMustBeAbsolute
    }
    guard Self.isValidSHA256(executableSHA256) else {
      throw JobToolchainIntentValidationError.invalidSHA256
    }
    guard Self.isValidDiagnosticText(endpoint) else {
      throw JobToolchainIntentValidationError.invalidIdentifier(field: "endpoint")
    }
    try Self.validate(platformTrust, field: "platformTrust", value: Self.isValidDiagnosticText)
    try Self.validate(clientVersion, field: "clientVersion", value: Self.isValidDiagnosticText)
    try Self.validate(serverVersion, field: "serverVersion", value: Self.isValidDiagnosticText)
    try Self.validate(daemonVersion, field: "daemonVersion", value: Self.isValidDiagnosticText)
    try Self.validate(serverGeneration, field: "serverGeneration") { $0 >= 0 }

    self.schemaVersion = Self.schemaVersion
    self.id = id
    self.jobID = jobID
    self.kind = kind
    self.executablePath = executablePath
    self.source = source
    self.executableSHA256 = executableSHA256
    self.platformTrust = platformTrust
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.daemonVersion = daemonVersion
    self.endpoint = endpoint
    self.serverGeneration = serverGeneration
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case id
    case jobID
    case kind
    case executablePath
    case source
    case executableSHA256
    case platformTrust
    case clientVersion
    case serverVersion
    case daemonVersion
    case endpoint
    case serverGeneration
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(String.self, forKey: .schemaVersion)
    guard version == Self.schemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "unsupported Job toolchain intent schema version")
    }
    try self.init(
      id: container.decode(UUID.self, forKey: .id),
      jobID: container.decode(String.self, forKey: .jobID),
      kind: container.decode(JobToolchainKind.self, forKey: .kind),
      executablePath: container.decode(String.self, forKey: .executablePath),
      source: container.decode(JobToolchainSource.self, forKey: .source),
      executableSHA256: container.decode(String.self, forKey: .executableSHA256),
      platformTrust: container.decode(JobToolchainEvidence<String>.self, forKey: .platformTrust),
      clientVersion: container.decode(JobToolchainEvidence<String>.self, forKey: .clientVersion),
      serverVersion: container.decode(JobToolchainEvidence<String>.self, forKey: .serverVersion),
      daemonVersion: container.decode(JobToolchainEvidence<String>.self, forKey: .daemonVersion),
      endpoint: container.decode(String.self, forKey: .endpoint),
      serverGeneration: container.decode(
        JobToolchainEvidence<Int>.self, forKey: .serverGeneration)
    )
  }

  static func isValidDiagnosticText(_ value: String) -> Bool {
    !value.isEmpty && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    isValidDiagnosticText(value)
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)
      }
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private static func validate<Value>(
    _ evidence: JobToolchainEvidence<Value>,
    field: String,
    value isValidValue: (Value) -> Bool
  ) throws where Value: Codable & Sendable & Equatable {
    let isValid: Bool
    switch evidence {
    case .known(let value):
      isValid = isValidValue(value)
    case .unknown(let reason):
      isValid = isValidDiagnosticText(reason)
    case .unverified(let value, let reason):
      isValid = isValidDiagnosticText(reason) && value.map(isValidValue) != false
    }
    guard isValid else {
      throw JobToolchainIntentValidationError.invalidDiagnosticEvidence(field: field)
    }
  }
}

/// Durable association between one immutable Job toolchain intent and an HDC
/// tool-backed typed Step. Workflows persist this value before requesting any
/// platform probe or launch authorization.
public struct JobToolchainIntentBinding: Codable, Sendable, Equatable {
  public let jobID: String
  public let intent: JobToolchainIntent
  public let step: WorkflowStep

  public init(jobID: String, intent: JobToolchainIntent, step: WorkflowStep) throws {
    guard jobID == intent.jobID else {
      throw JobToolchainIntentValidationError.jobMismatch(
        expected: intent.jobID, actual: jobID)
    }
    guard Self.supportedStepKinds.contains(step.kind) else {
      throw JobToolchainIntentValidationError.unsupportedStepKind(step.kind)
    }
    self.jobID = jobID
    self.intent = intent
    self.step = step
  }

  private static let supportedStepKinds: Set<WorkflowStepKind> = [
    .probeHostTool, .probeHDCServer, .mutateHDCServerLifecycle,
  ]

  private enum CodingKeys: String, CodingKey {
    case jobID
    case intent
    case step
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      jobID: container.decode(String.self, forKey: .jobID),
      intent: container.decode(JobToolchainIntent.self, forKey: .intent),
      step: container.decode(WorkflowStep.self, forKey: .step)
    )
  }
}
