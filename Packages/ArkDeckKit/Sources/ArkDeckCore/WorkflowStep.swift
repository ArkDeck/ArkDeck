import Foundation

public enum JSONValue: Equatable, Sendable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .unsignedInteger(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

public enum WorkflowEffect: String, CaseIterable, Codable, Sendable, Comparable {
  case hostOnly
  case readOnly
  case deviceMutation
  case destructive

  private var riskRank: Int {
    switch self {
    case .hostOnly: 0
    case .readOnly: 1
    case .deviceMutation: 2
    case .destructive: 3
    }
  }

  public static func < (lhs: WorkflowEffect, rhs: WorkflowEffect) -> Bool {
    lhs.riskRank < rhs.riskRank
  }
}

public enum WorkflowCancellationPolicy: String, CaseIterable, Codable, Sendable, Comparable {
  case immediate
  case atSafeBoundary
  case criticalNonInterruptible

  private var interruptionRiskRank: Int {
    switch self {
    case .immediate: 0
    case .atSafeBoundary: 1
    case .criticalNonInterruptible: 2
    }
  }

  public static func < (lhs: WorkflowCancellationPolicy, rhs: WorkflowCancellationPolicy) -> Bool {
    lhs.interruptionRiskRank < rhs.interruptionRiskRank
  }
}

public enum WorkflowBindingRequirement: String, CaseIterable, Codable, Sendable, Comparable {
  case none
  case confirmedDevice

  public static func < (lhs: WorkflowBindingRequirement, rhs: WorkflowBindingRequirement) -> Bool {
    lhs == .none && rhs == .confirmedDevice
  }
}

public enum WorkflowStepKind: String, CaseIterable, Codable, Sendable {
  case probeHostTool
  case probeHDCServer
  case mutateHDCServerLifecycle
  case probeDevice
  case captureRemoteStdout
  case captureRemoteFile
  case stopRemoteCapture
  case sendFile
  case receiveFile
  case snapshotParameter
  case setParameter
  case restoreParameter
  case waitForDisconnect
  case waitForReconnect
  case verifyRemoteState
  case verifyArtifact
  case preflightHostStorage
  case preflightDeviceStorage
  case hashFile
  case postprocessArtifact
  case cleanupOwnedRemotePath
  case requestConfirmation
  case installPackage
  case uninstallPackage
  case startApplication
  case stopApplication
  case createPortForward
  case removePortForward
  case clearLogBuffer
  case resizeLogBuffer
  case startDeviceLogPersist
  case runApprovedRemoteRead
  case runApprovedRemoteMutation
  case rebootDevice
  case enterUpdater
  case flashPartition
  case updatePackage
  case erasePartition
  case formatPartition
  case unlockDevice
  case finalizeSession
}

public struct WorkflowStepMetadata: Equatable, Sendable {
  public let minimumEffect: WorkflowEffect
  public let minimumCancellation: WorkflowCancellationPolicy
  public let minimumBindingRequirement: WorkflowBindingRequirement
  public let bindingIsExact: Bool
  public let profileExposable: Bool
  public let requiredArgumentKeys: Set<String>
  public let allowedArgumentKeys: Set<String>

  fileprivate init(
    minimumEffect: WorkflowEffect,
    minimumCancellation: WorkflowCancellationPolicy,
    minimumBindingRequirement: WorkflowBindingRequirement,
    bindingIsExact: Bool,
    profileExposable: Bool,
    requiredArgumentKeys: Set<String>,
    optionalArgumentKeys: Set<String> = []
  ) {
    self.minimumEffect = minimumEffect
    self.minimumCancellation = minimumCancellation
    self.minimumBindingRequirement = minimumBindingRequirement
    self.bindingIsExact = bindingIsExact
    self.profileExposable = profileExposable
    self.requiredArgumentKeys = requiredArgumentKeys
    self.allowedArgumentKeys = requiredArgumentKeys.union(optionalArgumentKeys)
  }
}

public enum WorkflowStepResolution: Equatable, Sendable {
  case supported(kind: WorkflowStepKind, metadata: WorkflowStepMetadata)
  case unsupported(rawKind: String, assumedEffect: WorkflowEffect)
}

public enum WorkflowStepRegistry {
  public static let schemaIdentifier = "https://arkdeck.dev/schemas/workflow-step-1.0.0.json"

  public static func resolve(rawKind: String) -> WorkflowStepResolution {
    guard let kind = WorkflowStepKind(rawValue: rawKind) else {
      return .unsupported(rawKind: rawKind, assumedEffect: .destructive)
    }
    return .supported(kind: kind, metadata: metadata(for: kind))
  }

  public static func metadata(for kind: WorkflowStepKind) -> WorkflowStepMetadata {
    switch kind {
    case .probeHostTool:
      host(required: ["toolIdentity", "candidatePath"], optional: ["expectedSha256"])
    case .probeHDCServer:
      host(required: ["endpoint", "clientIdentity"], optional: ["expectedServerGeneration"])
    case .mutateHDCServerLifecycle:
      metadata(
        .destructive,
        .atSafeBoundary,
        .none,
        bindingIsExact: true,
        required: [
          "action", "endpoint", "expectedGeneration", "expectedOwnership", "impactSnapshotHash",
          "confirmationId",
        ]
      )
    case .probeDevice:
      deviceRead(required: ["evidencePolicy"])
    case .captureRemoteStdout:
      deviceRead(
        required: ["catalogId", "actionId", "parameters", "artifactId"],
        profileExposable: true)
    case .captureRemoteFile:
      deviceMutation(
        required: [
          "catalogId", "actionId", "parameters", "artifactId", "ownedRemotePath",
        ],
        profileExposable: true)
    case .stopRemoteCapture:
      deviceMutation(required: ["captureStepId", "stopPolicy"])
    case .sendFile:
      deviceMutation(
        required: ["sourceArtifactId", "remotePath", "sourceSha256"],
        optional: ["overwritePolicy"],
        profileExposable: true
      )
    case .receiveFile:
      deviceRead(
        required: ["remotePath", "artifactId", "localRelativePath"],
        optional: ["expectedSha256"],
        profileExposable: true
      )
    case .snapshotParameter:
      deviceRead(required: ["name"], profileExposable: true)
    case .setParameter:
      deviceMutation(required: ["name", "value", "readbackPolicy"], profileExposable: true)
    case .restoreParameter:
      deviceMutation(required: ["name", "snapshotStepId", "restorePolicy"])
    case .waitForDisconnect, .waitForReconnect:
      deviceRead(required: ["deadlineMilliseconds", "reason"])
    case .verifyRemoteState:
      deviceRead(required: ["probeId", "expectedState"])
    case .verifyArtifact, .hashFile:
      host(required: ["artifactId"], optional: ["validationPolicy"])
    case .preflightHostStorage:
      host(required: ["volumeIdentity", "requiredBytes", "metadataHeadroomBytes", "writerClass"])
    case .preflightDeviceStorage:
      deviceRead(required: ["remotePath", "requiredBytes"])
    case .postprocessArtifact:
      host(required: ["inputArtifactIds", "outputArtifactId", "processorId", "parameters"])
    case .cleanupOwnedRemotePath:
      deviceMutation(required: ["remotePath", "ownershipEvidenceId"])
    case .requestConfirmation:
      host(required: ["confirmationId", "promptKey", "riskClass", "scopeHash"])
    case .installPackage:
      deviceMutation(
        required: ["packageArtifactId", "packageName", "replacePolicy"],
        profileExposable: true)
    case .uninstallPackage:
      deviceMutation(required: ["packageName"], profileExposable: true)
    case .startApplication, .stopApplication:
      deviceMutation(
        required: ["bundleName", "abilityName"], optional: ["parameters"],
        profileExposable: true)
    case .createPortForward:
      deviceMutation(
        required: ["forwardId", "hostEndpoint", "deviceEndpoint"], profileExposable: true)
    case .removePortForward:
      deviceMutation(required: ["forwardId"], profileExposable: true)
    case .clearLogBuffer:
      deviceMutation(required: ["bufferId", "confirmationId"])
    case .resizeLogBuffer:
      deviceMutation(required: ["bufferId", "sizeBytes", "restorePolicy"])
    case .startDeviceLogPersist:
      deviceMutation(required: [
        "profileId", "artifactSeriesId", "rotationBytes", "retainedSegments",
      ])
    case .runApprovedRemoteRead:
      deviceRead(
        required: ["catalogId", "actionId", "parameters", "artifactId"],
        optional: ["semanticResultPolicy"],
        profileExposable: true
      )
    case .runApprovedRemoteMutation:
      deviceMutation(
        required: ["catalogId", "actionId", "parameters", "artifactId", "confirmationId"],
        optional: ["semanticResultPolicy"],
        profileExposable: true
      )
    case .rebootDevice:
      deviceMutation(required: ["targetMode", "reason"], profileExposable: true)
    case .enterUpdater:
      deviceMutation(
        required: [
          "providerOperationId", "expectedMode", "reconnectDeadlineMilliseconds",
        ],
        profileExposable: true)
    case .flashPartition:
      destructive(
        required: [
          "providerOperationId", "partition", "imageArtifactId", "imageSha256", "imageSize",
          "confirmationId", "safeBoundaryId",
        ]
      )
    case .updatePackage:
      destructive(
        required: [
          "providerOperationId", "packageArtifactId", "packageSha256", "packageSize",
          "confirmationId", "safeBoundaryId",
        ]
      )
    case .erasePartition:
      destructive(required: [
        "providerOperationId", "partition", "confirmationId", "safeBoundaryId",
      ])
    case .formatPartition:
      destructive(required: [
        "providerOperationId", "partition", "confirmationId", "safeBoundaryId", "formatType",
      ])
    case .unlockDevice:
      destructive(required: [
        "providerOperationId", "confirmationId", "scopeHash", "safeBoundaryId",
      ])
    case .finalizeSession:
      metadata(.hostOnly, .atSafeBoundary, .none, required: ["sessionId", "publicationPolicy"])
    }
  }

  private static func host(required: Set<String>, optional: Set<String> = [])
    -> WorkflowStepMetadata
  {
    metadata(.hostOnly, .immediate, .none, required: required, optional: optional)
  }

  private static func deviceRead(
    required: Set<String>, optional: Set<String> = [], profileExposable: Bool = false
  )
    -> WorkflowStepMetadata
  {
    metadata(
      .readOnly, .immediate, .confirmedDevice, profileExposable: profileExposable,
      required: required, optional: optional)
  }

  private static func deviceMutation(
    required: Set<String>, optional: Set<String> = [], profileExposable: Bool = false
  )
    -> WorkflowStepMetadata
  {
    metadata(
      .deviceMutation, .atSafeBoundary, .confirmedDevice, profileExposable: profileExposable,
      required: required, optional: optional)
  }

  private static func destructive(required: Set<String>, optional: Set<String> = [])
    -> WorkflowStepMetadata
  {
    metadata(
      .destructive, .criticalNonInterruptible, .confirmedDevice, profileExposable: true,
      required: required, optional: optional)
  }

  private static func metadata(
    _ effect: WorkflowEffect,
    _ cancellation: WorkflowCancellationPolicy,
    _ binding: WorkflowBindingRequirement,
    bindingIsExact: Bool = false,
    profileExposable: Bool = false,
    required: Set<String>,
    optional: Set<String> = []
  ) -> WorkflowStepMetadata {
    WorkflowStepMetadata(
      minimumEffect: effect,
      minimumCancellation: cancellation,
      minimumBindingRequirement: binding,
      bindingIsExact: bindingIsExact,
      profileExposable: profileExposable,
      requiredArgumentKeys: required,
      optionalArgumentKeys: optional
    )
  }
}

public enum CompensationTrigger: String, CaseIterable, Codable, Sendable {
  case onSuccess
  case onFailure
  case onCancel
  case onAnyTerminal
}

public enum WorkflowStepValidationError: Error, Equatable, Sendable {
  case unsupportedKind(rawKind: String, assumedEffect: WorkflowEffect)
  case unsupportedCompensationKind(WorkflowStepKind)
  case invalidIdentifier(String)
  case invalidSHA256(String)
  case unexpectedFields([String])
  case missingArgumentFields(kind: WorkflowStepKind, fields: [String])
  case unexpectedArgumentFields(kind: WorkflowStepKind, fields: [String])
  case unsafeArgumentKey(path: String)
  case invalidArgument(kind: WorkflowStepKind, path: String, expectation: String)
  case exactBindingMismatch(
    kind: WorkflowStepKind,
    declared: WorkflowBindingRequirement,
    required: WorkflowBindingRequirement
  )
  case kindNotProfileExposable(WorkflowStepKind)
  case duplicateJSONMemberName(path: String)
}

public struct CompensationDescriptor: Equatable, Sendable, Codable {
  public static let allowedKinds: Set<WorkflowStepKind> = [
    .stopRemoteCapture,
    .restoreParameter,
    .cleanupOwnedRemotePath,
    .removePortForward,
    .stopApplication,
  ]

  public let id: String
  public let kind: WorkflowStepKind
  public let effect: WorkflowEffect
  public let cancellation: WorkflowCancellationPolicy
  public let bindingRequirement: WorkflowBindingRequirement
  public let trigger: CompensationTrigger
  public let arguments: [String: JSONValue]
  public let argumentsHash: String

  public init(
    id: String,
    kind: WorkflowStepKind,
    declaredEffect: WorkflowEffect,
    declaredCancellation: WorkflowCancellationPolicy,
    declaredBindingRequirement: WorkflowBindingRequirement,
    trigger: CompensationTrigger,
    arguments: [String: JSONValue],
    argumentsHash: String
  ) throws {
    guard Self.allowedKinds.contains(kind) else {
      throw WorkflowStepValidationError.unsupportedCompensationKind(kind)
    }
    try WorkflowStepValidator.validateIdentifier(id)
    try WorkflowStepValidator.validateSHA256(argumentsHash)
    try WorkflowStepValidator.validate(arguments: arguments, for: kind)
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    self.id = id
    self.kind = kind
    self.effect = max(declaredEffect, metadata.minimumEffect)
    self.cancellation = max(declaredCancellation, metadata.minimumCancellation)
    self.bindingRequirement = max(declaredBindingRequirement, metadata.minimumBindingRequirement)
    self.trigger = trigger
    self.arguments = arguments
    self.argumentsHash = argumentsHash.lowercased()
  }

  public init(from decoder: any Decoder) throws {
    try WorkflowStepValidator.rejectUnknownFields(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    let kind = try WorkflowStepValidator.resolveKind(rawKind)
    try self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: kind,
      declaredEffect: try container.decode(WorkflowEffect.self, forKey: .effect),
      declaredCancellation: try container.decode(
        WorkflowCancellationPolicy.self, forKey: .cancellation),
      declaredBindingRequirement: try container.decode(
        WorkflowBindingRequirement.self, forKey: .bindingRequirement),
      trigger: try container.decode(CompensationTrigger.self, forKey: .trigger),
      arguments: try container.decode([String: JSONValue].self, forKey: .arguments),
      argumentsHash: try container.decode(String.self, forKey: .argumentsHash)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, kind, effect, cancellation, bindingRequirement, trigger, arguments, argumentsHash
  }
}

public struct WorkflowStep: Equatable, Sendable, Codable {
  public let id: String
  public let kind: WorkflowStepKind
  public let effect: WorkflowEffect
  public let cancellation: WorkflowCancellationPolicy
  public let bindingRequirement: WorkflowBindingRequirement
  public let arguments: [String: JSONValue]
  public let compensationDescriptors: [CompensationDescriptor]

  public init(
    id: String,
    kind: WorkflowStepKind,
    declaredEffect: WorkflowEffect,
    declaredCancellation: WorkflowCancellationPolicy,
    declaredBindingRequirement: WorkflowBindingRequirement,
    arguments: [String: JSONValue],
    compensationDescriptors: [CompensationDescriptor] = []
  ) throws {
    try WorkflowStepValidator.validateIdentifier(id)
    try WorkflowStepValidator.validate(arguments: arguments, for: kind)
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    guard
      !metadata.bindingIsExact || declaredBindingRequirement == metadata.minimumBindingRequirement
    else {
      throw WorkflowStepValidationError.exactBindingMismatch(
        kind: kind,
        declared: declaredBindingRequirement,
        required: metadata.minimumBindingRequirement
      )
    }
    self.id = id
    self.kind = kind
    self.effect = max(declaredEffect, metadata.minimumEffect)
    self.cancellation = max(declaredCancellation, metadata.minimumCancellation)
    self.bindingRequirement = max(declaredBindingRequirement, metadata.minimumBindingRequirement)
    self.arguments = arguments
    self.compensationDescriptors = compensationDescriptors
  }

  public init(from decoder: any Decoder) throws {
    try WorkflowStepValidator.rejectUnknownFields(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    let kind = try WorkflowStepValidator.resolveKind(rawKind)
    try self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: kind,
      declaredEffect: try container.decode(WorkflowEffect.self, forKey: .effect),
      declaredCancellation: try container.decode(
        WorkflowCancellationPolicy.self, forKey: .cancellation),
      declaredBindingRequirement: try container.decode(
        WorkflowBindingRequirement.self, forKey: .bindingRequirement),
      arguments: try container.decode([String: JSONValue].self, forKey: .arguments),
      compensationDescriptors: try container.decode(
        [CompensationDescriptor].self, forKey: .compensationDescriptors)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, kind, effect, cancellation, bindingRequirement, arguments, compensationDescriptors
  }
}

public enum WorkflowStepDecoder {
  public static func decodeCoreOrProviderStep(_ data: Data) throws -> WorkflowStep {
    try decode(data, enforceProfileExposure: false)
  }

  public static func decodeProfileStep(_ data: Data) throws -> WorkflowStep {
    try decode(data, enforceProfileExposure: true)
  }

  private static func decode(_ data: Data, enforceProfileExposure: Bool) throws -> WorkflowStep {
    var duplicateMemberValidator = DuplicateJSONMemberNameValidator(data: data)
    try duplicateMemberValidator.validate()
    let step = try JSONDecoder().decode(WorkflowStep.self, from: data)
    if enforceProfileExposure {
      let declaredKinds = [step.kind] + step.compensationDescriptors.map(\.kind)
      for kind in declaredKinds
      where !WorkflowStepRegistry.metadata(for: kind).profileExposable {
        throw WorkflowStepValidationError.kindNotProfileExposable(kind)
      }
    }
    return step
  }
}

private struct DuplicateJSONMemberNameValidator {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) {
    self.bytes = Array(data)
  }

  mutating func validate() throws {
    skipWhitespace()
    try parseValue(path: "$", depth: 0)
    skipWhitespace()
    guard index == bytes.count else {
      throw invalidJSON("unexpected trailing data")
    }
  }

  private mutating func parseValue(path: String, depth: Int) throws {
    guard depth <= 256, let byte = currentByte else {
      throw invalidJSON(depth > 256 ? "JSON nesting exceeds 256 levels" : "missing JSON value")
    }
    switch byte {
    case Self.objectStart:
      try parseObject(path: path, depth: depth)
    case Self.arrayStart:
      try parseArray(path: path, depth: depth)
    case Self.quote:
      _ = try parseString()
    case Self.minus, Self.zero...Self.nine:
      try parseNumber()
    case Self.lowercaseT:
      try parseLiteral(Array("true".utf8))
    case Self.lowercaseF:
      try parseLiteral(Array("false".utf8))
    case Self.lowercaseN:
      try parseLiteral(Array("null".utf8))
    default:
      throw invalidJSON("unexpected byte while parsing JSON value")
    }
  }

  private mutating func parseObject(path: String, depth: Int) throws {
    try consume(Self.objectStart, expectation: "object start")
    skipWhitespace()
    if consumeIfPresent(Self.objectEnd) { return }

    var memberNames: Set<String> = []
    while true {
      guard currentByte == Self.quote else {
        throw invalidJSON("object member name must be a JSON string")
      }
      let memberName = try parseString()
      let memberPath = "\(path).\(memberName)"
      guard memberNames.insert(memberName).inserted else {
        throw WorkflowStepValidationError.duplicateJSONMemberName(path: memberPath)
      }

      skipWhitespace()
      try consume(Self.nameSeparator, expectation: "colon after object member name")
      skipWhitespace()
      try parseValue(path: memberPath, depth: depth + 1)
      skipWhitespace()

      if consumeIfPresent(Self.objectEnd) { return }
      try consume(Self.valueSeparator, expectation: "comma between object members")
      skipWhitespace()
    }
  }

  private mutating func parseArray(path: String, depth: Int) throws {
    try consume(Self.arrayStart, expectation: "array start")
    skipWhitespace()
    if consumeIfPresent(Self.arrayEnd) { return }

    var elementIndex = 0
    while true {
      try parseValue(path: "\(path)[\(elementIndex)]", depth: depth + 1)
      elementIndex += 1
      skipWhitespace()
      if consumeIfPresent(Self.arrayEnd) { return }
      try consume(Self.valueSeparator, expectation: "comma between array elements")
      skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    try consume(Self.quote, expectation: "string opening quote")

    while let byte = currentByte {
      switch byte {
      case Self.quote:
        index += 1
        let token = Data(bytes[start..<index])
        do {
          return try JSONDecoder().decode(String.self, from: token)
        } catch {
          throw invalidJSON("invalid JSON string")
        }
      case Self.escape:
        index += 1
        guard let escaped = currentByte else {
          throw invalidJSON("unterminated JSON escape")
        }
        if escaped == Self.lowercaseU {
          index += 1
          for _ in 0..<4 {
            guard let hex = currentByte, Self.isHexDigit(hex) else {
              throw invalidJSON("invalid Unicode escape")
            }
            index += 1
          }
        } else {
          guard Self.simpleEscapes.contains(escaped) else {
            throw invalidJSON("invalid JSON escape")
          }
          index += 1
        }
      case 0x00...0x1F:
        throw invalidJSON("unescaped control character in JSON string")
      default:
        index += 1
      }
    }
    throw invalidJSON("unterminated JSON string")
  }

  private mutating func parseLiteral(_ literal: [UInt8]) throws {
    let end = index + literal.count
    guard end <= bytes.count, bytes[index..<end].elementsEqual(literal) else {
      throw invalidJSON("invalid JSON literal")
    }
    index = end
  }

  private mutating func parseNumber() throws {
    if consumeIfPresent(Self.minus), currentByte == nil {
      throw invalidJSON("minus must be followed by a JSON number")
    }

    if consumeIfPresent(Self.zero) {
      if let byte = currentByte, Self.isDigit(byte) {
        throw invalidJSON("leading zero in JSON number")
      }
    } else {
      guard let byte = currentByte, Self.one...Self.nine ~= byte else {
        throw invalidJSON("invalid JSON integer")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }

    if consumeIfPresent(Self.decimalPoint) {
      guard currentByte.map(Self.isDigit) == true else {
        throw invalidJSON("fraction requires a digit")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }

    if currentByte == Self.lowercaseE || currentByte == Self.uppercaseE {
      index += 1
      if currentByte == Self.plus || currentByte == Self.minus { index += 1 }
      guard currentByte.map(Self.isDigit) == true else {
        throw invalidJSON("exponent requires a digit")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
  }

  private mutating func consume(_ expected: UInt8, expectation: String) throws {
    guard consumeIfPresent(expected) else {
      throw invalidJSON("expected \(expectation)")
    }
  }

  private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
    guard currentByte == expected else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while let byte = currentByte, Self.whitespace.contains(byte) {
      index += 1
    }
  }

  private var currentByte: UInt8? {
    index < bytes.count ? bytes[index] : nil
  }

  private func invalidJSON(_ description: String) -> DecodingError {
    .dataCorrupted(
      .init(codingPath: [], debugDescription: "\(description) at byte offset \(index)")
    )
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    zero...nine ~= byte
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || uppercaseA...uppercaseF ~= byte || lowercaseA...lowercaseF ~= byte
  }

  private static let objectStart: UInt8 = 0x7B
  private static let objectEnd: UInt8 = 0x7D
  private static let arrayStart: UInt8 = 0x5B
  private static let arrayEnd: UInt8 = 0x5D
  private static let quote: UInt8 = 0x22
  private static let escape: UInt8 = 0x5C
  private static let nameSeparator: UInt8 = 0x3A
  private static let valueSeparator: UInt8 = 0x2C
  private static let minus: UInt8 = 0x2D
  private static let plus: UInt8 = 0x2B
  private static let decimalPoint: UInt8 = 0x2E
  private static let zero: UInt8 = 0x30
  private static let one: UInt8 = 0x31
  private static let nine: UInt8 = 0x39
  private static let uppercaseA: UInt8 = 0x41
  private static let uppercaseE: UInt8 = 0x45
  private static let uppercaseF: UInt8 = 0x46
  private static let lowercaseA: UInt8 = 0x61
  private static let lowercaseE: UInt8 = 0x65
  private static let lowercaseF: UInt8 = 0x66
  private static let lowercaseN: UInt8 = 0x6E
  private static let lowercaseT: UInt8 = 0x74
  private static let lowercaseU: UInt8 = 0x75
  private static let simpleEscapes: Set<UInt8> = [
    0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74,
  ]
  private static let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
}

private enum WorkflowStepValidator {
  private static let unsafeArgumentKeys: Set<String> = [
    "argv", "command", "commandline", "executable", "hdcarguments", "rawarguments", "shell",
  ]

  static func resolveKind(_ rawKind: String) throws -> WorkflowStepKind {
    switch WorkflowStepRegistry.resolve(rawKind: rawKind) {
    case .supported(let kind, _):
      kind
    case .unsupported(let rawKind, let assumedEffect):
      throw WorkflowStepValidationError.unsupportedKind(
        rawKind: rawKind,
        assumedEffect: assumedEffect
      )
    }
  }

  static func validateIdentifier(_ identifier: String) throws {
    guard isValidIdentifier(identifier) else {
      throw WorkflowStepValidationError.invalidIdentifier(identifier)
    }
  }

  static func validateSHA256(_ hash: String) throws {
    guard isValidSHA256(hash) else {
      throw WorkflowStepValidationError.invalidSHA256(hash)
    }
  }

  static func validate(arguments: [String: JSONValue], for kind: WorkflowStepKind) throws {
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    let actual = Set(arguments.keys)
    let missing = metadata.requiredArgumentKeys.subtracting(actual).sorted()
    guard missing.isEmpty else {
      throw WorkflowStepValidationError.missingArgumentFields(kind: kind, fields: missing)
    }
    let unexpected = actual.subtracting(metadata.allowedArgumentKeys).sorted()
    guard unexpected.isEmpty else {
      throw WorkflowStepValidationError.unexpectedArgumentFields(kind: kind, fields: unexpected)
    }
    try validateTypedArgumentValues(arguments, for: kind)
    if let unsafePath = firstUnsafeArgumentPath(in: .object(arguments), path: "arguments") {
      throw WorkflowStepValidationError.unsafeArgumentKey(path: unsafePath)
    }
  }

  private static func validateTypedArgumentValues(
    _ arguments: [String: JSONValue],
    for kind: WorkflowStepKind
  ) throws {
    let reader = ArgumentReader(kind: kind, arguments: arguments)
    switch kind {
    case .probeHostTool:
      try reader.identifier("toolIdentity")
      _ = try reader.string("candidatePath", minimumLength: 1)
      try reader.optionalSHA256("expectedSha256")
    case .probeHDCServer:
      _ = try reader.string("endpoint", minimumLength: 1)
      try reader.identifier("clientIdentity")
      try reader.optionalIntegerOrNull("expectedServerGeneration", minimum: 0)
    case .mutateHDCServerLifecycle:
      let action = try reader.enumeration(
        "action",
        allowed: ["startManaged", "stopConfirmedGeneration", "restartConfirmedGeneration"]
      )
      _ = try reader.string("endpoint", minimumLength: 1)
      try reader.sha256("impactSnapshotHash")
      if action == "startManaged" {
        try reader.null("expectedGeneration")
        try reader.constant("expectedOwnership", value: "absent")
        try reader.null("confirmationId")
      } else {
        try reader.integer("expectedGeneration", minimum: 0)
        _ = try reader.enumeration(
          "expectedOwnership", allowed: ["arkDeckManaged", "external", "unknown"]
        )
        try reader.identifier("confirmationId")
      }
    case .probeDevice:
      try reader.identifier("evidencePolicy")
    case .captureRemoteStdout:
      try reader.constant("catalogId", value: "arkui-ui-dump")
      _ = try reader.enumeration(
        "actionId",
        allowed: [
          "nodeSummary", "elementTree", "fullDefaultTree", "componentDetail",
          "renderTreeLegacy",
        ]
      )
      try reader.validatedOptions("parameters")
      try reader.identifier("artifactId")
    case .captureRemoteFile:
      let catalog = try reader.enumeration(
        "catalogId", allowed: ["arkui-ui-dump", "trace-presets"]
      )
      if catalog == "arkui-ui-dump" {
        _ = try reader.enumeration(
          "actionId",
          allowed: [
            "nodeSummary", "elementTree", "fullDefaultTree", "componentDetail",
            "renderTreeLegacy",
          ]
        )
      } else {
        _ = try reader.enumeration(
          "actionId",
          allowed: [
            "attachmentPanorama", "arkuiDeep", "renderAnimation", "schedulingIpc", "io",
            "custom",
          ]
        )
      }
      try reader.validatedOptions("parameters")
      try reader.identifier("artifactId")
      try reader.remoteAbsolutePath("ownedRemotePath")
    case .stopRemoteCapture:
      try reader.identifier("captureStepId")
      try reader.identifier("stopPolicy")
    case .sendFile:
      try reader.identifier("sourceArtifactId")
      try reader.remoteAbsolutePath("remotePath")
      try reader.sha256("sourceSha256")
      try reader.optionalEnumeration("overwritePolicy", allowed: ["forbid", "replaceOwnedPath"])
    case .receiveFile:
      try reader.remoteAbsolutePath("remotePath")
      try reader.identifier("artifactId")
      try reader.relativePath("localRelativePath")
      try reader.optionalSHA256("expectedSha256")
    case .snapshotParameter:
      try reader.parameterName("name")
    case .setParameter:
      try reader.parameterName("name")
      _ = try reader.string("value", maximumLength: 4096)
      try reader.constant("readbackPolicy", value: "required")
    case .restoreParameter:
      try reader.parameterName("name")
      try reader.identifier("snapshotStepId")
      _ = try reader.enumeration(
        "restorePolicy", allowed: ["restoreKnownValue", "persistentChangeNoRestore"]
      )
    case .waitForDisconnect, .waitForReconnect:
      try reader.integer("deadlineMilliseconds", minimum: 1, maximum: 86_400_000)
      try reader.identifier("reason")
    case .verifyRemoteState:
      try reader.identifier("probeId")
      _ = try reader.string("expectedState", minimumLength: 1, maximumLength: 256)
    case .verifyArtifact, .hashFile:
      try reader.identifier("artifactId")
      try reader.optionalIdentifier("validationPolicy")
    case .preflightHostStorage:
      try reader.identifier("volumeIdentity")
      try reader.integer("requiredBytes", minimum: 0)
      try reader.integer("metadataHeadroomBytes", minimum: 1)
      _ = try reader.enumeration("writerClass", allowed: ["light", "heavy", "unknown"])
    case .preflightDeviceStorage:
      try reader.remoteAbsolutePath("remotePath")
      try reader.integer("requiredBytes", minimum: 0)
    case .postprocessArtifact:
      try reader.identifierArray("inputArtifactIds", minimumCount: 1, unique: true)
      try reader.identifier("outputArtifactId")
      try reader.identifier("processorId")
      try reader.validatedOptions("parameters")
    case .cleanupOwnedRemotePath:
      try reader.remoteAbsolutePath("remotePath")
      try reader.identifier("ownershipEvidenceId")
    case .requestConfirmation:
      try reader.identifier("confirmationId")
      try reader.identifier("promptKey")
      _ = try reader.enumeration(
        "riskClass",
        allowed: [
          "deviceMutation", "destructive", "serverLifecycle", "recoveryAbandon",
          "securityBoundary",
        ]
      )
      try reader.sha256("scopeHash")
    case .installPackage:
      try reader.identifier("packageArtifactId")
      _ = try reader.string("packageName", minimumLength: 1, maximumLength: 255)
      _ = try reader.enumeration("replacePolicy", allowed: ["forbid", "allow"])
    case .uninstallPackage:
      _ = try reader.string("packageName", minimumLength: 1, maximumLength: 255)
    case .startApplication, .stopApplication:
      _ = try reader.string("bundleName", minimumLength: 1, maximumLength: 255)
      _ = try reader.string("abilityName", minimumLength: 1, maximumLength: 255)
      try reader.optionalValidatedOptions("parameters")
    case .createPortForward:
      try reader.identifier("forwardId")
      _ = try reader.string("hostEndpoint", minimumLength: 1, maximumLength: 255)
      _ = try reader.string("deviceEndpoint", minimumLength: 1, maximumLength: 255)
    case .removePortForward:
      try reader.identifier("forwardId")
    case .clearLogBuffer:
      try reader.identifier("bufferId")
      try reader.identifier("confirmationId")
    case .resizeLogBuffer:
      try reader.identifier("bufferId")
      try reader.integer("sizeBytes", minimum: 1)
      _ = try reader.enumeration(
        "restorePolicy", allowed: ["restoreSnapshot", "persistentChangeNoRestore"]
      )
    case .startDeviceLogPersist:
      try reader.identifier("profileId")
      try reader.identifier("artifactSeriesId")
      try reader.integer("rotationBytes", minimum: 1)
      try reader.integer("retainedSegments", minimum: 1, maximum: 10_000)
    case .runApprovedRemoteRead:
      try reader.constant("catalogId", value: "arkdeck-remote-operations")
      _ = try reader.enumeration(
        "actionId",
        allowed: [
          "deviceSummary", "systemProperties", "processList", "packageInfo", "storageUsage",
        ]
      )
      try reader.validatedOptions("parameters")
      try reader.identifier("artifactId")
      try reader.optionalIdentifier("semanticResultPolicy")
    case .runApprovedRemoteMutation:
      try reader.constant("catalogId", value: "arkdeck-remote-operations")
      try reader.constant("actionId", value: "requestRootMode")
      try reader.validatedOptions("parameters")
      try reader.identifier("artifactId")
      try reader.identifier("confirmationId")
      try reader.optionalIdentifier("semanticResultPolicy")
    case .rebootDevice:
      _ = try reader.enumeration(
        "targetMode", allowed: ["normal", "recovery", "updater", "providerDefined"]
      )
      try reader.identifier("reason")
    case .enterUpdater:
      try reader.actionIdentifier("providerOperationId")
      _ = try reader.string("expectedMode", minimumLength: 1, maximumLength: 128)
      try reader.integer("reconnectDeadlineMilliseconds", minimum: 1, maximum: 86_400_000)
    case .flashPartition:
      try reader.actionIdentifier("providerOperationId")
      try reader.partitionName("partition")
      try reader.identifier("imageArtifactId")
      try reader.sha256("imageSha256")
      try reader.integer("imageSize", minimum: 1)
      try reader.identifier("confirmationId")
      try reader.identifier("safeBoundaryId")
    case .updatePackage:
      try reader.actionIdentifier("providerOperationId")
      try reader.identifier("packageArtifactId")
      try reader.sha256("packageSha256")
      try reader.integer("packageSize", minimum: 1)
      try reader.identifier("confirmationId")
      try reader.identifier("safeBoundaryId")
    case .erasePartition, .formatPartition:
      try reader.actionIdentifier("providerOperationId")
      try reader.partitionName("partition")
      try reader.identifier("confirmationId")
      try reader.identifier("safeBoundaryId")
      if kind == .formatPartition {
        _ = try reader.string("formatType", minimumLength: 1, maximumLength: 64)
      }
    case .unlockDevice:
      try reader.actionIdentifier("providerOperationId")
      try reader.identifier("confirmationId")
      try reader.sha256("scopeHash")
      try reader.identifier("safeBoundaryId")
    case .finalizeSession:
      try reader.identifier("sessionId")
      try reader.constant("publicationPolicy", value: "atomicAfterValidation")
    }
  }

  private struct ArgumentReader {
    let kind: WorkflowStepKind
    let arguments: [String: JSONValue]

    func string(
      _ key: String,
      minimumLength: Int = 0,
      maximumLength: Int? = nil
    ) throws -> String {
      guard case .string(let value) = arguments[key] else {
        throw invalid(key, "string")
      }
      let length = value.unicodeScalars.count
      guard length >= minimumLength, maximumLength.map({ length <= $0 }) ?? true else {
        throw invalid(
          key, "string length \(minimumLength)...\(maximumLength.map(String.init) ?? "unbounded")")
      }
      return value
    }

    func identifier(_ key: String) throws {
      let value = try string(key)
      guard WorkflowStepValidator.isValidIdentifier(value) else {
        throw invalid(key, "ArkDeck identifier")
      }
    }

    func optionalIdentifier(_ key: String) throws {
      guard arguments[key] != nil else { return }
      try identifier(key)
    }

    func actionIdentifier(_ key: String) throws {
      let value = try string(key)
      let scalars = value.unicodeScalars
      let forbidden = ["runhdc", "runremotetool", "shell", "exec", "command"]
      guard (1...128).contains(scalars.count),
        let first = scalars.first,
        WorkflowStepValidator.isASCIIAlpha(first),
        scalars.dropFirst().allSatisfy({
          WorkflowStepValidator.isASCIIAlphaNumeric($0) || ".-".unicodeScalars.contains($0)
        }),
        !forbidden.contains(value.lowercased())
      else {
        throw invalid(key, "registered action identifier")
      }
    }

    func sha256(_ key: String) throws {
      let value = try string(key)
      guard WorkflowStepValidator.isValidSHA256(value) else {
        throw invalid(key, "64 hexadecimal SHA-256 characters")
      }
    }

    func optionalSHA256(_ key: String) throws {
      guard arguments[key] != nil else { return }
      try sha256(key)
    }

    func integer(_ key: String, minimum: Int64, maximum: Int64? = nil) throws {
      guard let value = arguments[key], integerIsInRange(value, minimum: minimum, maximum: maximum)
      else {
        throw invalid(
          key,
          "integer in \(minimum)...\(maximum.map(String.init) ?? "unbounded")"
        )
      }
    }

    func optionalIntegerOrNull(_ key: String, minimum: Int64, maximum: Int64? = nil) throws {
      guard let value = arguments[key] else { return }
      if case .null = value { return }
      guard integerIsInRange(value, minimum: minimum, maximum: maximum) else {
        throw invalid(key, "null or integer in the required range")
      }
    }

    func null(_ key: String) throws {
      guard case .null = arguments[key] else {
        throw invalid(key, "null")
      }
    }

    func constant(_ key: String, value expected: String) throws {
      guard try string(key) == expected else {
        throw invalid(key, "constant \(expected)")
      }
    }

    func enumeration(_ key: String, allowed: Set<String>) throws -> String {
      let value = try string(key)
      guard allowed.contains(value) else {
        throw invalid(key, "one of \(allowed.sorted().joined(separator: ", "))")
      }
      return value
    }

    func optionalEnumeration(_ key: String, allowed: Set<String>) throws {
      guard arguments[key] != nil else { return }
      _ = try enumeration(key, allowed: allowed)
    }

    func parameterName(_ key: String) throws {
      let value = try string(key, minimumLength: 1, maximumLength: 255)
      guard
        value.unicodeScalars.allSatisfy({
          WorkflowStepValidator.isASCIIAlphaNumeric($0) || "_.-".unicodeScalars.contains($0)
        })
      else {
        throw invalid(key, "parameter name containing only ASCII letters, digits, _, ., or -")
      }
    }

    func partitionName(_ key: String) throws {
      let value = try string(key, minimumLength: 1, maximumLength: 128)
      guard
        value.unicodeScalars.allSatisfy({
          WorkflowStepValidator.isASCIIAlphaNumeric($0) || "_.-".unicodeScalars.contains($0)
        })
      else {
        throw invalid(key, "partition name containing only ASCII letters, digits, _, ., or -")
      }
    }

    func remoteAbsolutePath(_ key: String) throws {
      let value = try string(key, minimumLength: 2, maximumLength: 1024)
      let segments = value.split(separator: "/", omittingEmptySubsequences: false)
      guard value.first == "/",
        !value.unicodeScalars.contains(where: WorkflowStepValidator.isControlCharacter),
        !segments.dropFirst().contains(where: { $0 == "." || $0 == ".." })
      else {
        throw invalid(key, "normalized remote absolute path")
      }
    }

    func relativePath(_ key: String) throws {
      let value = try string(key, minimumLength: 1, maximumLength: 1024)
      let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
      let segments = value.split(separator: "/", omittingEmptySubsequences: false)
      guard value.first != "/",
        !(value.unicodeScalars.count >= 2
          && WorkflowStepValidator.isASCIIAlpha(value.unicodeScalars.first!)
          && value.unicodeScalars.dropFirst().first?.value == 58),
        segments.allSatisfy({ segment in
          !segment.isEmpty && segment != "." && segment != ".."
            && segment.last != "." && segment.last != " "
            && !segment.unicodeScalars.contains(where: {
              forbidden.contains($0) || WorkflowStepValidator.isControlCharacter($0)
            })
        })
      else {
        throw invalid(key, "normalized portable relative path")
      }
    }

    func identifierArray(_ key: String, minimumCount: Int, unique: Bool) throws {
      guard case .array(let values) = arguments[key], values.count >= minimumCount else {
        throw invalid(key, "array containing at least \(minimumCount) identifiers")
      }
      var identifiers: [String] = []
      for (index, value) in values.enumerated() {
        guard case .string(let identifier) = value,
          WorkflowStepValidator.isValidIdentifier(identifier)
        else {
          throw invalid("\(key)[\(index)]", "ArkDeck identifier")
        }
        identifiers.append(identifier)
      }
      if unique && Set(identifiers).count != identifiers.count {
        throw invalid(key, "unique identifier array")
      }
    }

    func validatedOptions(_ key: String) throws {
      guard case .object(let options) = arguments[key], options.count <= 128 else {
        throw invalid(key, "validated options object with at most 128 properties")
      }
      for optionKey in options.keys.sorted() {
        let scalars = optionKey.unicodeScalars
        guard (1...64).contains(scalars.count),
          let first = scalars.first,
          WorkflowStepValidator.isASCIIAlpha(first),
          scalars.dropFirst().allSatisfy({
            WorkflowStepValidator.isASCIIAlphaNumeric($0)
              || "_.-".unicodeScalars.contains($0)
          })
        else {
          throw invalid("\(key).\(optionKey)", "validated option key")
        }
        try validateOptionValue(options[optionKey]!, path: "\(key).\(optionKey)")
      }
    }

    func optionalValidatedOptions(_ key: String) throws {
      guard arguments[key] != nil else { return }
      try validatedOptions(key)
    }

    private func validateOptionValue(_ value: JSONValue, path: String) throws {
      switch value {
      case .null, .bool, .integer, .unsignedInteger:
        return
      case .number(let number):
        guard number.isFinite else { throw invalid(path, "finite JSON number") }
      case .string(let string):
        guard string.unicodeScalars.count <= 4096 else {
          throw invalid(path, "string no longer than 4096 characters")
        }
      case .object:
        throw invalid(path, "scalar or scalar array option value")
      case .array(let values):
        guard values.count <= 256 else {
          throw invalid(path, "array with at most 256 scalar values")
        }
        for (index, element) in values.enumerated() {
          switch element {
          case .bool, .integer, .unsignedInteger:
            continue
          case .number(let number) where number.isFinite:
            continue
          case .string(let string) where string.unicodeScalars.count <= 4096:
            continue
          default:
            throw invalid("\(path)[\(index)]", "string, number, or boolean")
          }
        }
      }
    }

    private func integerIsInRange(
      _ value: JSONValue,
      minimum: Int64,
      maximum: Int64?
    ) -> Bool {
      switch value {
      case .integer(let integer):
        integer >= minimum && (maximum.map { integer <= $0 } ?? true)
      case .unsignedInteger(let integer):
        minimum <= 0 && (maximum.map { integer <= UInt64($0) } ?? true)
          || minimum > 0 && integer >= UInt64(minimum)
            && (maximum.map { integer <= UInt64($0) } ?? true)
      default:
        false
      }
    }

    private func invalid(_ key: String, _ expectation: String) -> WorkflowStepValidationError {
      .invalidArgument(kind: kind, path: "arguments.\(key)", expectation: expectation)
    }
  }

  static func rejectUnknownFields(_ decoder: any Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let unexpected = Set(container.allKeys.map(\.stringValue)).subtracting(allowed).sorted()
    guard unexpected.isEmpty else {
      throw WorkflowStepValidationError.unexpectedFields(unexpected)
    }
  }

  private static func firstUnsafeArgumentPath(in value: JSONValue, path: String) -> String? {
    switch value {
    case .object(let object):
      for key in object.keys.sorted() {
        let childPath = "\(path).\(key)"
        if unsafeArgumentKeys.contains(key.lowercased()) {
          return childPath
        }
        if let nested = firstUnsafeArgumentPath(in: object[key]!, path: childPath) {
          return nested
        }
      }
      return nil
    case .array(let array):
      for (index, element) in array.enumerated() {
        if let nested = firstUnsafeArgumentPath(in: element, path: "\(path)[\(index)]") {
          return nested
        }
      }
      return nil
    case .null, .bool, .integer, .unsignedInteger, .number, .string:
      return nil
    }
  }

  private static func isValidIdentifier(_ identifier: String) -> Bool {
    let scalars = identifier.unicodeScalars
    return (1...128).contains(scalars.count)
      && scalars.first.map(isASCIIAlphaNumeric) == true
      && scalars.dropFirst().allSatisfy({
        isASCIIAlphaNumeric($0) || "._:-".unicodeScalars.contains($0)
      })
  }

  private static func isValidSHA256(_ hash: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    return hash.unicodeScalars.count == 64
      && hash.unicodeScalars.allSatisfy(allowed.contains)
  }

  private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }

  private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
    (48...57).contains(scalar.value)
      || isASCIIAlpha(scalar)
  }

  private static func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
    (0...31).contains(scalar.value) || scalar.value == 127
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
