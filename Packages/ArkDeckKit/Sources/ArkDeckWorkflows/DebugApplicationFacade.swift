// App-facing Debug workspace over Runtime's closed typed XPC door.
//
// Executable work is limited to published Debug operations: bounded
// diagnostics, one target-bound HAP lifecycle, one app-owned native-library
// deployment, typed port rules and four read-only templates. There is no
// executable, argv, device path or authority input: the daemon owns lowering
// and the App receives a disclosure.

import ArkDeckCore
import ArkDeckRuntime
import CryptoKit
import Foundation
import os

public enum DebugRuntimeAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct DebugOperationPresentation: Sendable, Equatable, Identifiable {
  public let reference: String
  public let title: String
  public let minimumEffect: String
  public let permittedEffects: [String]
  public let timeoutSeconds: Int
  public let outputByteBudget: Int
  public let availability: DebugRuntimeAvailability
  public let fields: [DebugFieldPresentation]
  public let steps: [DebugStepPresentation]
  public let artifacts: [DebugArtifactPresentation]

  public var id: String { reference }

  public init(
    reference: String,
    title: String,
    minimumEffect: String,
    permittedEffects: [String],
    timeoutSeconds: Int,
    outputByteBudget: Int,
    availability: DebugRuntimeAvailability,
    fields: [DebugFieldPresentation],
    steps: [DebugStepPresentation],
    artifacts: [DebugArtifactPresentation]
  ) {
    self.reference = reference
    self.title = title
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.timeoutSeconds = timeoutSeconds
    self.outputByteBudget = outputByteBudget
    self.availability = availability
    self.fields = fields
    self.steps = steps
    self.artifacts = artifacts
  }
}

public struct DebugFieldPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let type: String
  public let isRequired: Bool
  public let constraintSummary: String

  public var id: String { name }

  public init(name: String, type: String, isRequired: Bool, constraintSummary: String) {
    self.name = name
    self.type = type
    self.isRequired = isRequired
    self.constraintSummary = constraintSummary
  }
}

public struct DebugStepPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let effect: String
  public let isOptional: Bool
  public let actionReference: String?

  public init(
    id: String, kind: String, effect: String, isOptional: Bool, actionReference: String?
  ) {
    self.id = id
    self.kind = kind
    self.effect = effect
    self.isOptional = isOptional
    self.actionReference = actionReference
  }
}

public struct DebugArtifactPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let role: String
  public let mediaType: String
  public let privacy: String
  public let isRequired: Bool

  public var id: String { name }

  public init(
    name: String, role: String, mediaType: String, privacy: String, isRequired: Bool
  ) {
    self.name = name
    self.role = role
    self.mediaType = mediaType
    self.privacy = privacy
    self.isRequired = isRequired
  }
}

public struct DebugTargetPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let bindingRevision: Int
  public let toolVersion: String
  public let adoptedAtUTC: String

  public init(id: String, bindingRevision: Int, toolVersion: String, adoptedAtUTC: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
  }
}

public struct DebugJobPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let operationReference: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let operationFailure: RuntimeOperationFailure?
  public let outstandingResidueCount: Int
  public let timeline: [String]

  public var needsAttention: Bool {
    waitingForHuman || outcomeUnknown
      || (operationFailure.map { $0.code != .cancelled } ?? false)
      || outstandingResidueCount > 0
  }

  public var isActive: Bool {
    guard let state = JobState(rawValue: state) else { return false }
    return !state.isTerminal
  }

  public init(
    id: String,
    operationReference: String,
    targetID: String,
    state: String,
    waitingForHuman: Bool,
    outcomeUnknown: Bool,
    operationFailure: RuntimeOperationFailure? = nil,
    outstandingResidueCount: Int,
    timeline: [String] = []
  ) {
    self.id = id
    self.operationReference = operationReference
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.operationFailure = operationFailure
    self.outstandingResidueCount = outstandingResidueCount
    self.timeline = timeline
  }
}

public struct DebugWorkspacePresentation: Sendable, Equatable {
  public let operations: [DebugOperationPresentation]
  public let targets: [DebugTargetPresentation]
  public let jobs: [DebugJobPresentation]
  public let targetLoadFailure: String?
  public let jobLoadFailure: String?
  public let runtimeProbe: DebugRuntimeProbeSnapshot?
  public let probeFailure: String?

  public init(
    operations: [DebugOperationPresentation],
    targets: [DebugTargetPresentation],
    jobs: [DebugJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil,
    runtimeProbe: DebugRuntimeProbeSnapshot? = nil,
    probeFailure: String? = nil
  ) {
    self.operations = operations
    self.targets = targets
    self.jobs = jobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
    self.runtimeProbe = runtimeProbe
    self.probeFailure = probeFailure
  }

  public static let loading = DebugWorkspacePresentation(
    operations: DebugApplicationFacade.descriptors.map {
      DebugApplicationFacade.operationPresentation(descriptor: $0, availability: .checking)
    },
    targets: [], jobs: [])

  public func operation(_ reference: String) -> DebugOperationPresentation? {
    operations.first { $0.reference == reference }
  }
}

public struct DebugCommandTemplatePresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let effect: String
  public let parameterNames: [String]
  public let isRunnable: Bool

  public init(
    id: String, effect: String, parameterNames: [String], isRunnable: Bool
  ) {
    self.id = id
    self.effect = effect
    self.parameterNames = parameterNames
    self.isRunnable = isRunnable
  }
}

public struct DebugLogJobAcceptancePresentation: Sendable, Equatable {
  public let jobID: String
  public init(jobID: String) { self.jobID = jobID }
}

public enum DebugLogJobSubmissionResult: Sendable, Equatable {
  case submitted(DebugLogJobAcceptancePresentation)
  case failed(String)
}

public struct DebugNativeLibraryPlanStepPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let effect: String

  public init(id: String, kind: String, effect: String) {
    self.id = id
    self.kind = kind
    self.effect = effect
  }
}

/// A Runtime-materialized, target-bound plan for one app-owned .so. The
/// request bytes stay package-private so the App can only submit the exact
/// reviewed plan; it cannot rewrite the lease, target or operation.
public struct DebugNativeLibraryPreparation: Sendable, Equatable, Identifiable {
  public let operationReference: String
  public let targetID: String
  public let bindingRevision: Int
  public let libraryName: String
  public let byteCount: Int
  public let sha256: String
  public let abi: String
  public let elfClassBits: Int
  public let machine: Int
  public let buildID: String
  public let targetBundle: String
  public let verificationProfile: String
  public let rollbackPolicy: String
  public let planDigest: String
  public let steps: [DebugNativeLibraryPlanStepPresentation]
  let requestJSON: String

  public var id: String { planDigest }
}

public enum DebugNativeLibraryPreparationResult: Sendable, Equatable {
  case prepared(DebugNativeLibraryPreparation)
  case failed(String)
}

private struct DebugNativeLibraryLocalArtifact: Sendable {
  let name: String
  let contents: Data
  let sha256: String
  let abi: String
  let elfClassBits: Int
  let machine: Int
  let buildID: String
}

private enum DebugNativeLibraryLocalArtifactError: Error, CustomStringConvertible {
  case invalidName
  case invalidSize
  case notRegularFile
  case changedWhileReading
  case invalidELF(String)

  var description: String {
    switch self {
    case .invalidName:
      "Choose a file named lib<name>.so using only letters, numbers, dot, underscore or hyphen"
    case .invalidSize:
      "Choose a native library between 64 bytes and 64 MiB"
    case .notRegularFile:
      "Choose a readable regular .so file"
    case .changedWhileReading:
      "The selected library changed while ArkDeck read it. Choose the file again"
    case .invalidELF(let detail):
      "The selected library did not pass signed OpenHarmony ELF validation: \(detail)"
    }
  }
}

private enum DebugNativeLibraryLocalArtifactInspector {
  static func inspect(_ url: URL) throws -> DebugNativeLibraryLocalArtifact {
    let name = url.lastPathComponent
    guard DebugTypedValueValidator.isValidNativeLibraryLogicalName(name) else {
      throw DebugNativeLibraryLocalArtifactError.invalidName
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw DebugNativeLibraryLocalArtifactError.notRegularFile
    }
    guard (64...NativeLibraryArtifactValidator.maximumBytes).contains(fileSize) else {
      throw DebugNativeLibraryLocalArtifactError.invalidSize
    }
    let contents = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard contents.count == fileSize else {
      throw DebugNativeLibraryLocalArtifactError.changedWhileReading
    }
    let facts: HDCNativeLibraryArtifactFacts
    do {
      facts = try NativeLibraryArtifactValidator.validate(
        contents, requireOpenHarmonyCodeSignature: true)
    } catch {
      throw DebugNativeLibraryLocalArtifactError.invalidELF(String(describing: error))
    }
    return DebugNativeLibraryLocalArtifact(
      name: name,
      contents: contents,
      sha256: SHA256Hex.string(of: contents),
      abi: facts.abi.rawValue,
      elfClassBits: facts.elfClassBits,
      machine: Int(facts.machine),
      buildID: facts.buildID)
  }
}

/// Selection checks do not import bytes or grant device authority. Runtime
/// independently checks every lease and binding when admitting the one Job.
public enum DebugHAPPackageSelection {
  public static let maximumAdditionalPackages = 16

  public enum Failure: String, Error, Sendable {
    case invalidEntry, invalidAdditional, tooManyPackages, duplicatePackage
  }

  public static func validate(entry: URL, additional: [URL]) throws {
    guard entry.isFileURL, isSafeName(entry.lastPathComponent, allowsHSP: false) else {
      throw Failure.invalidEntry
    }
    guard additional.count <= maximumAdditionalPackages else {
      throw Failure.tooManyPackages
    }
    guard
      additional.allSatisfy({
        $0.isFileURL && isSafeName($0.lastPathComponent, allowsHSP: true)
      })
    else { throw Failure.invalidAdditional }
    let paths = ([entry] + additional).map { $0.standardizedFileURL.path }
    guard Set(paths).count == paths.count else { throw Failure.duplicatePackage }
  }

  package static func isSafeName(_ name: String, allowsHSP: Bool) -> Bool {
    name.count <= 128
      && name.range(
        of: allowsHSP
          ? #"^[A-Za-z0-9][A-Za-z0-9._-]*\.(hap|hsp)$"#
          : #"^[A-Za-z0-9][A-Za-z0-9._-]*\.hap$"#,
        options: .regularExpression) != nil
  }
}

struct DebugHAPLocalArtifact: Sendable, Equatable {
  let name: String
  let byteCount: Int64
  let sha256: String
}

enum DebugHAPLocalArtifactError: Error, CustomStringConvertible {
  case invalidName
  case invalidSize
  case notRegularFile

  var description: String {
    switch self {
    case .invalidName:
      "Choose a package with a safe .hap basename, or .hsp for an additional package"
    case .invalidSize:
      "Each selected package must be between 1 byte and 64 MiB"
    case .notRegularFile:
      "The selected package is not a readable regular file"
    }
  }
}

enum DebugHAPLocalArtifactInspector {
  static let maximumBytes: Int64 = 64 * 1_024 * 1_024
  static let readChunkBytes = 512 * 1_024

  static func inspect(_ url: URL, allowsHSP: Bool = false) throws -> DebugHAPLocalArtifact {
    let name = url.lastPathComponent
    guard DebugHAPPackageSelection.isSafeName(name, allowsHSP: allowsHSP)
    else { throw DebugHAPLocalArtifactError.invalidName }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw DebugHAPLocalArtifactError.notRegularFile
    }
    guard let fileSize = values.fileSize,
      (1...maximumBytes).contains(Int64(fileSize))
    else { throw DebugHAPLocalArtifactError.invalidSize }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      let chunk = try handle.read(upToCount: readChunkBytes) ?? Data()
      if chunk.isEmpty { break }
      byteCount += Int64(chunk.count)
      guard byteCount <= maximumBytes else {
        throw DebugHAPLocalArtifactError.invalidSize
      }
      hasher.update(data: chunk)
    }
    guard byteCount == Int64(fileSize) else {
      throw DebugHAPLocalArtifactError.notRegularFile
    }
    return DebugHAPLocalArtifact(
      name: name,
      byteCount: byteCount,
      sha256: SHA256Hex.lowercaseHex(hasher.finalize()))
  }
}

public struct DebugLogJobTerminalPresentation: Sendable, Equatable {
  public let jobID: String
  public let state: String
  public let outcomeUnknown: Bool
  public let operationFailure: RuntimeOperationFailure?
  public let timeline: [String]

  public init(
    jobID: String,
    state: String,
    outcomeUnknown: Bool,
    operationFailure: RuntimeOperationFailure? = nil,
    timeline: [String]
  ) {
    self.jobID = jobID
    self.state = state
    self.outcomeUnknown = outcomeUnknown
    self.operationFailure = operationFailure
    self.timeline = timeline
  }
}

public enum DebugLogJobRunResult: Sendable, Equatable {
  case completed(DebugLogJobTerminalPresentation)
  case failed(String)
}

public enum DebugPortRuleDirection: String, CaseIterable, Sendable {
  case forward
  case reverse
}

public struct DebugValidatedPortRule: Sendable, Equatable {
  public let direction: DebugPortRuleDirection
  public let localPort: Int
  public let remotePort: Int

  public init(direction: DebugPortRuleDirection, localPort: Int, remotePort: Int) {
    self.direction = direction
    self.localPort = localPort
    self.remotePort = remotePort
  }
}

public enum DebugPortRuleFailure: String, Sendable, Equatable {
  case localPortNotNumeric
  case localPortOutOfRange
  case remotePortNotNumeric
  case remotePortOutOfRange
}

public enum DebugPortRuleValidationResult: Sendable, Equatable {
  case valid(DebugValidatedPortRule)
  case invalid(DebugPortRuleFailure)
}

/// Validates two decimal port fields without ever accepting an endpoint or a
/// shell fragment. Provider-owned lowering is intentionally outside the App.
public enum DebugPortRuleValidator {
  public static func validate(
    direction: DebugPortRuleDirection, localPortText: String, remotePortText: String
  ) -> DebugPortRuleValidationResult {
    guard !localPortText.isEmpty, localPortText.allSatisfy(\.isNumber),
      let localPort = Int(localPortText)
    else { return .invalid(.localPortNotNumeric) }
    guard (1_024...65_535).contains(localPort) else { return .invalid(.localPortOutOfRange) }
    guard !remotePortText.isEmpty, remotePortText.allSatisfy(\.isNumber),
      let remotePort = Int(remotePortText)
    else { return .invalid(.remotePortNotNumeric) }
    guard (1_024...65_535).contains(remotePort) else { return .invalid(.remotePortOutOfRange) }
    return .valid(
      DebugValidatedPortRule(
        direction: direction, localPort: localPort, remotePort: remotePort))
  }
}

/// Conservative App-side validation for the structured HiLog fields. Runtime
/// remains authoritative, but an obviously free-form shell fragment never
/// appears in the UI's typed request preview.
public enum DebugTypedValueValidator {
  public static func isSafeHilogComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 200 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || "._:-".unicodeScalars.contains(scalar)
    }
  }

  /// Bundle and ability names share the conservative character policy: they
  /// are Catalog-schema identifiers, and nothing that could read as a shell
  /// fragment may appear in a typed request preview.
  public static func isSafeTypedIdentifier(_ value: String) -> Bool {
    isSafeHilogComponent(value)
  }

  public static func isValidBundleName(_ value: String) -> Bool {
    value.count <= 200
      && value.range(
        of: #"^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$"#,
        options: .regularExpression) != nil
  }

  public static func isValidAbilityName(_ value: String) -> Bool {
    value.count <= 200
      && value.range(
        of: #"^[a-zA-Z][a-zA-Z0-9_.]*$"#,
        options: .regularExpression) != nil
  }

  public static func isValidNativeLibraryLogicalName(_ value: String) -> Bool {
    value.count <= 128
      && value.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil
  }
}

public protocol DebugApplicationProviding: Sendable {
  func refreshWorkspace(targetID: String?) async -> DebugWorkspacePresentation
  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) async -> DebugLogJobSubmissionResult
  func submitHAP(
    target: DebugTargetPresentation,
    fileURL: URL,
    additionalFileURLs: [URL],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int
  ) async -> DebugLogJobSubmissionResult
  func prepareNativeLibrary(
    target: DebugTargetPresentation,
    fileURL: URL,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult
  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation,
    sourceID: UUID,
    relativePath: String,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult
  func submitNativeLibrary(
    preparation: DebugNativeLibraryPreparation
  ) async -> DebugLogJobSubmissionResult
  func run(jobID: String) async -> DebugLogJobRunResult
  func cancel(jobID: String) async -> Bool
  func submitPortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) async -> DebugLogJobSubmissionResult
  func runTemplate(
    target: DebugTargetPresentation,
    templateID: String
  ) async -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure>
}

enum DebugHAPSubmission {
  typealias Request =
    @Sendable (String, [String: JSONValue]?) async
    -> Result<Data, DebugXPCReadFailure>

  static func submit(
    target: DebugTargetPresentation,
    fileURL: URL,
    additionalFileURLs: [URL],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int,
    send: Request = { await DebugXPCReadTransport.request(method: $0, params: $1) }
  ) async -> DebugLogJobSubmissionResult {
    do {
      try DebugHAPPackageSelection.validate(entry: fileURL, additional: additionalFileURLs)
      // Validate the closed request dimensions before importing any bytes.
      _ = try DebugHAPRequestBuilder.request(
        target: target, lease: "validation-only", bundleName: bundleName,
        abilityName: abilityName, installPolicy: installPolicy, cleanupPolicy: cleanupPolicy,
        postRunAbilityState: postRunAbilityState, captureDiagnostics: captureDiagnostics,
        diagnosticsDurationSeconds: diagnosticsDurationSeconds)
      let files = [fileURL] + additionalFileURLs
      let scopedFiles = files.filter { $0.startAccessingSecurityScopedResource() }
      defer { scopedFiles.forEach { $0.stopAccessingSecurityScopedResource() } }
      // Finish bounded local inspection for the entire set before the first
      // upload. Equal basenames from different folders are valid; equal bytes
      // are not two modules. No local path is sent to Runtime.
      var locals: [DebugHAPLocalArtifact] = []
      for (index, file) in files.enumerated() {
        try Task.checkCancellation()
        let local = try await Task.detached(priority: .userInitiated) {
          try DebugHAPLocalArtifactInspector.inspect(file, allowsHSP: index > 0)
        }.value
        guard !locals.contains(where: { $0.sha256 == local.sha256 }) else {
          throw DebugHAPPackageSelection.Failure.duplicatePackage
        }
        locals.append(local)
      }
      var leases: [String] = []
      for (file, local) in zip(files, locals) {
        try Task.checkCancellation()
        leases.append(
          try await importPackage(target: target, fileURL: file, local: local, send: send))
      }
      try Task.checkCancellation()
      let request = try DebugHAPRequestBuilder.request(
        target: target, lease: leases[0], additionalLeases: Array(leases.dropFirst()),
        bundleName: bundleName, abilityName: abilityName,
        installPolicy: installPolicy, cleanupPolicy: cleanupPolicy,
        postRunAbilityState: postRunAbilityState, captureDiagnostics: captureDiagnostics,
        diagnosticsDurationSeconds: diagnosticsDurationSeconds)
      let requestData = try CanonicalJSONEncoders.canonical().encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        throw DebugXPCReadFailure.transport("Could not encode the typed HAP request")
      }
      let submitted = try DebugRuntimeResponseDecoding.resultObject(
        await send("job.submit", ["requestJson": .string(requestJSON)]))
      guard let jobID = submitted["jobId"] as? String, !jobID.isEmpty else {
        throw DebugXPCReadFailure.transport("Runtime accepted HAP Debug without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugHAPPackageSelection.Failure {
      return .failed(failureMessage(failure))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  private static func failureMessage(_ failure: DebugHAPPackageSelection.Failure) -> String {
    switch failure {
    case .invalidEntry: "Choose one entry .hap with a safe basename"
    case .invalidAdditional: "Choose additional .hap or .hsp packages with safe basenames"
    case .tooManyPackages: "Choose at most 16 additional packages"
    case .duplicatePackage: "Select each package only once; duplicate files or bytes were found"
    }
  }

  private static func importPackage(
    target: DebugTargetPresentation, fileURL: URL, local: DebugHAPLocalArtifact, send: Request
  ) async throws -> String {
    var uploadID: String?
    do {
      let begin = try DebugRuntimeResponseDecoding.resultObject(
        await send(
          "artifact.importHap.begin",
          [
            "targetId": .string(target.id),
            "name": .string(local.name),
            "byteCount": .integer(local.byteCount),
            "sha256": .string(local.sha256),
          ]))
      guard let startedUploadID = begin["uploadId"] as? String else {
        throw DebugXPCReadFailure.transport("Runtime returned no HAP upload identity")
      }
      uploadID = startedUploadID
      guard let maximumChunkBytes = begin["maximumChunkBytes"] as? Int,
        maximumChunkBytes > 0,
        maximumChunkBytes <= DebugHAPLocalArtifactInspector.readChunkBytes,
        begin["targetId"] as? String == target.id,
        begin["bindingRevision"] as? Int == target.bindingRevision
      else { throw DebugXPCReadFailure.transport("Runtime returned incomplete HAP import facts") }

      let handle = try FileHandle(forReadingFrom: fileURL)
      defer { try? handle.close() }
      var offset = 0
      while Int64(offset) < local.byteCount {
        guard !Task.isCancelled else { throw CancellationError() }
        let chunk = try handle.read(upToCount: maximumChunkBytes) ?? Data()
        guard !chunk.isEmpty else {
          throw DebugXPCReadFailure.transport("Selected HAP changed while it was imported")
        }
        let appended = try DebugRuntimeResponseDecoding.resultObject(
          await send(
            "artifact.importHap.append",
            [
              "uploadId": .string(startedUploadID),
              "offset": .integer(Int64(offset)),
              "base64": .string(chunk.base64EncodedString()),
            ]))
        guard let nextOffset = appended["nextOffset"] as? Int,
          nextOffset == offset + chunk.count
        else { throw DebugXPCReadFailure.transport("Runtime HAP import offset drifted") }
        offset = nextOffset
      }
      guard Int64(offset) == local.byteCount else {
        throw DebugXPCReadFailure.transport("Selected HAP changed while it was imported")
      }
      guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
        throw DebugXPCReadFailure.transport("Selected HAP changed while it was imported")
      }

      let imported = try DebugRuntimeResponseDecoding.resultObject(
        await send(
          "artifact.importHap.commit",
          ["uploadId": .string(startedUploadID)]))
      uploadID = nil
      guard let lease = imported["lease"] as? String,
        imported["targetId"] as? String == target.id,
        imported["bindingRevision"] as? Int == target.bindingRevision,
        imported["name"] as? String == local.name,
        imported["byteCount"] as? Int == Int(local.byteCount),
        imported["sha256"] as? String == local.sha256
      else {
        throw DebugXPCReadFailure.transport(
          "Runtime import facts no longer match the selected target and package")
      }

      return lease
    } catch {
      // Abort only the current uncommitted upload. Completed immutable leases
      // remain in Runtime storage; failure never submits a partial package set.
      if let uploadID {
        _ = await send("artifact.importHap.abort", ["uploadId": .string(uploadID)])
      }
      throw error
    }
  }
}

enum DebugHAPRequestBuilder {
  static func request(
    target: DebugTargetPresentation,
    lease: String,
    additionalLeases: [String] = [],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int,
    nonce: String = UUID().uuidString.lowercased()
  ) throws -> RuntimeOperationRequest {
    let allLeases = [lease] + additionalLeases
    guard allLeases.allSatisfy({ !$0.isEmpty }),
      additionalLeases.count <= DebugHAPPackageSelection.maximumAdditionalPackages,
      Set(allLeases).count == allLeases.count,
      DebugTypedValueValidator.isValidBundleName(bundleName),
      DebugTypedValueValidator.isValidAbilityName(abilityName),
      installPolicy == "installOrReplace",
      ["uninstall", "retain"].contains(cleanupPolicy),
      ["stopped", "running"].contains(postRunAbilityState),
      (1...300).contains(diagnosticsDurationSeconds)
    else { throw DebugXPCReadFailure.transport("HAP request is outside the published bounds") }
    var inputs: [String: JSONValue] = [
      "hapArtifactLease": .string(lease),
      "bundleName": .string(bundleName),
      "abilityName": .string(abilityName),
      "installPolicy": .string(installPolicy),
      "cleanupPolicy": .string(cleanupPolicy),
      "postRunAbilityState": .string(postRunAbilityState),
      "captureDiagnostics": .bool(captureDiagnostics),
      "diagnosticsDurationSeconds": .integer(Int64(diagnosticsDurationSeconds)),
      "portForwardProfile": .string("none"),
    ]
    // Preserveerving absence keeps the published single-package plan unchanged.
    if !additionalLeases.isEmpty {
      inputs["additionalHapArtifactLeases"] = .array(additionalLeases.map(JSONValue.string))
    }
    return try RuntimeOperationRequest(
      requestID: "debug-hap-ui-\(nonce)",
      idempotencyKey: "debug-hap-ui-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "debug.hap", version: 1),
      inputs: inputs,
      requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.debugAppsWorkspace, targetID: target.id))
  }
}

enum DebugNativeLibraryRequestBuilder {
  static func request(
    target: DebugTargetPresentation,
    lease: String,
    targetBundle: String,
    libraryLogicalName: String,
    expectedABI: String,
    verificationProfile: String,
    rollbackPolicy: String,
    nonce: String = UUID().uuidString.lowercased()
  ) throws -> RuntimeOperationRequest {
    guard !lease.isEmpty,
      DebugTypedValueValidator.isValidBundleName(targetBundle),
      DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName),
      HDCNativeLibraryABI(rawValue: expectedABI) != nil,
      ["hashOnly", "hashAndProcess", "hashProcessAndMaps"].contains(verificationProfile),
      ["autoRollback", "retainBackup"].contains(rollbackPolicy)
    else {
      throw DebugXPCReadFailure.transport(
        "Native-library request is outside the published bounds")
    }
    return try RuntimeOperationRequest(
      requestID: "debug-native-ui-\(nonce)",
      idempotencyKey: "debug-native-ui-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(
        id: "deploy.native-library.app-owned", version: 1),
      inputs: [
        "libraryArtifactLease": .string(lease),
        "targetBundle": .string(targetBundle),
        "libraryLogicalName": .string(libraryLogicalName),
        "expectedABI": .string(expectedABI),
        "restartProfile": .string("restartAbility"),
        "verificationProfile": .string(verificationProfile),
        "rollbackPolicy": .string(rollbackPolicy),
      ],
      requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
      clientContext: RuntimeClientContext(
        clientName: ArkDeckAgentClientName.debugArtifactsWorkspace))
  }
}

public enum DebugApplicationFacade {
  public static let debugHAPReference = "debug.hap@1"
  public static let nativeLibraryReference = "deploy.native-library.app-owned@1"
  public static let captureDiagnosticsReference = "capture.diagnostics@1"
  public static let createPortForwardReference = "port-forward.create@1"
  public static let removePortForwardReference = "port-forward.remove@1"

  static let descriptors: [CatalogOperationDescriptor] = [
    RuntimeOperationCatalog.descriptor(reference: captureDiagnosticsReference),
    RuntimeOperationCatalog.descriptor(reference: debugHAPReference),
    RuntimeOperationCatalog.descriptor(reference: nativeLibraryReference),
    RuntimeOperationCatalog.descriptor(reference: createPortForwardReference),
    RuntimeOperationCatalog.descriptor(reference: removePortForwardReference),
  ].compactMap { $0 }

  /// The exact read-only template set implemented by the daemon. No member
  /// accepts user text; the Debug parameter key is fixed in provider code.
  public static let approvedCommandTemplates: [DebugCommandTemplatePresentation] = [
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.packageInventory.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.debugParameterRead.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.windowInventory.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
    DebugCommandTemplatePresentation(
      id: DebugRuntimeCommandTemplate.uptime.rawValue,
      effect: "readOnly", parameterNames: [], isRunnable: true),
  ]

  public static func make() -> any DebugApplicationProviding {
    DebugProductionApplicationProvider()
  }

  static func operationPresentation(
    descriptor: CatalogOperationDescriptor, availability: DebugRuntimeAvailability
  ) -> DebugOperationPresentation {
    DebugOperationPresentation(
      reference: descriptor.reference,
      title: descriptor.title,
      minimumEffect: descriptor.minimumEffect.rawValue,
      permittedEffects: descriptor.permittedEffects.map(\.rawValue),
      timeoutSeconds: descriptor.timeoutSeconds,
      outputByteBudget: descriptor.outputByteBudget,
      availability: availability,
      fields: descriptor.inputs.map {
        DebugFieldPresentation(
          name: $0.name,
          type: $0.type.rawValue,
          isRequired: $0.isRequired,
          constraintSummary: fieldConstraintSummary($0))
      },
      steps: descriptor.steps.map {
        DebugStepPresentation(
          id: $0.stepID,
          kind: $0.kind.rawValue,
          effect: $0.effect.rawValue,
          isOptional: $0.isOptional,
          actionReference: $0.actionReference.map { "\($0.catalogID)/\($0.actionID)" })
      },
      artifacts: descriptor.artifacts.map {
        DebugArtifactPresentation(
          name: $0.name,
          role: $0.role.rawValue,
          mediaType: $0.mediaType,
          privacy: $0.privacy.rawValue,
          isRequired: $0.isRequired)
      })
  }

  private static func fieldConstraintSummary(_ field: CatalogFieldDescriptor) -> String {
    var constraints: [String] = []
    if let values = field.enumValues { constraints.append(values.joined(separator: " | ")) }
    if let minimum = field.minimum { constraints.append("min \(minimum)") }
    if let maximum = field.maximum { constraints.append("max \(maximum)") }
    if let maxLength = field.maxLength { constraints.append("≤ \(maxLength) chars") }
    if let maxItems = field.maxItems { constraints.append("≤ \(maxItems) items") }
    if field.pattern != nil { constraints.append("pattern checked") }
    return constraints.isEmpty ? "—" : constraints.joined(separator: " · ")
  }
}

private actor DebugProductionApplicationProvider: DebugApplicationProviding {
  private let remoteBuildSources: any RemoteBuildSourceProviding

  init(
    remoteBuildSources: any RemoteBuildSourceProviding = RemoteBuildSourceApplicationFacade.make()
  ) {
    self.remoteBuildSources = remoteBuildSources
  }

  func refreshWorkspace(targetID: String?) async -> DebugWorkspacePresentation {
    async let operations = DebugXPCReadTransport.request(method: "operation.list")
    async let targets = DebugXPCReadTransport.request(method: "target.list")
    async let jobs = DebugXPCReadTransport.request(
      method: "job.list", params: RuntimeAppJobListPolicy.recentSummaryParams)
    let base = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
    guard let target = base.targets.first(where: { $0.id == targetID }) ?? base.targets.first
    else { return base }
    switch DebugRuntimeResponseDecoding.snapshot(
      await DebugXPCReadTransport.request(
        method: "debug.probe", params: ["targetId": .string(target.id)]),
      target: target)
    {
    case .success(let snapshot):
      return DebugWorkspacePresentation(
        operations: base.operations, targets: base.targets, jobs: base.jobs,
        targetLoadFailure: base.targetLoadFailure, jobLoadFailure: base.jobLoadFailure,
        runtimeProbe: snapshot)
    case .failure(let failure):
      return DebugWorkspacePresentation(
        operations: base.operations, targets: base.targets, jobs: base.jobs,
        targetLoadFailure: base.targetLoadFailure, jobLoadFailure: base.jobLoadFailure,
        probeFailure: failure.message)
    }
  }

  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) async -> DebugLogJobSubmissionResult {
    // The projection is owned by the shared preset so the App and
    // `arkdeck debug logs` cannot drift; the bounds it refuses are the ones
    // this guard used to restate.
    guard let inputs = try? DiagnosticCapturePreset.logs(
      durationSeconds: durationSeconds, filters: filters)
    else { return .failed("HiLog request is outside the published bounds") }
    do {
      let nonce = UUID().uuidString.lowercased()
      let request = try RuntimeOperationRequest(
        requestID: "debug-logs-ui-\(nonce)",
        idempotencyKey: "debug-logs-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id, expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
        inputs: inputs,
        requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeWorkspaceThread.clientContext(
          clientName: ArkDeckAgentClientName.debugLogsWorkspace, targetID: target.id))
      let encoder = CanonicalJSONEncoders.canonical()
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed HiLog request")
      }
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted HiLog capture without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func submitHAP(
    target: DebugTargetPresentation,
    fileURL: URL,
    additionalFileURLs: [URL],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int
  ) async -> DebugLogJobSubmissionResult {
    await DebugHAPSubmission.submit(
      target: target, fileURL: fileURL, additionalFileURLs: additionalFileURLs,
      bundleName: bundleName, abilityName: abilityName,
      installPolicy: installPolicy, cleanupPolicy: cleanupPolicy,
      postRunAbilityState: postRunAbilityState, captureDiagnostics: captureDiagnostics,
      diagnosticsDurationSeconds: diagnosticsDurationSeconds)
  }

  func prepareNativeLibrary(
    target: DebugTargetPresentation,
    fileURL: URL,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult {
    guard DebugTypedValueValidator.isValidBundleName(targetBundle),
      DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName),
      ["hashOnly", "hashAndProcess", "hashProcessAndMaps"].contains(verificationProfile),
      ["autoRollback", "retainBackup"].contains(rollbackPolicy)
    else {
      return .failed("Complete the bundle, library name and published verification settings")
    }

    let gainedScope = fileURL.startAccessingSecurityScopedResource()
    defer {
      if gainedScope { fileURL.stopAccessingSecurityScopedResource() }
    }
    var uploadID: String?
    do {
      let local = try await Task.detached(priority: .userInitiated) {
        try DebugNativeLibraryLocalArtifactInspector.inspect(fileURL)
      }.value

      let begin = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "artifact.importNativeLibrary.begin",
          params: [
            "targetId": .string(target.id),
            "name": .string(local.name),
            "byteCount": .integer(Int64(local.contents.count)),
            "sha256": .string(local.sha256),
          ]))
      guard let startedUploadID = begin["uploadId"] as? String else {
        throw DebugXPCReadFailure.transport(
          "Runtime returned no native-library upload identity")
      }
      uploadID = startedUploadID
      guard let maximumChunkBytes = begin["maximumChunkBytes"] as? Int,
        maximumChunkBytes > 0,
        maximumChunkBytes <= 512 * 1_024,
        begin["targetId"] as? String == target.id,
        begin["bindingRevision"] as? Int == target.bindingRevision
      else {
        throw DebugXPCReadFailure.transport(
          "Runtime returned incomplete native-library import facts")
      }

      var offset = 0
      while offset < local.contents.count {
        guard !Task.isCancelled else { throw CancellationError() }
        let end = min(local.contents.count, offset + maximumChunkBytes)
        let chunk = local.contents.subdata(in: offset..<end)
        let appended = try DebugRuntimeResponseDecoding.resultObject(
          await DebugXPCReadTransport.request(
            method: "artifact.importNativeLibrary.append",
            params: [
              "uploadId": .string(startedUploadID),
              "offset": .integer(Int64(offset)),
              "base64": .string(chunk.base64EncodedString()),
            ]))
        guard appended["nextOffset"] as? Int == end else {
          throw DebugXPCReadFailure.transport(
            "Runtime native-library import offset drifted")
        }
        offset = end
      }

      let imported = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "artifact.importNativeLibrary.commit",
          params: ["uploadId": .string(startedUploadID)]))
      uploadID = nil
      guard let lease = imported["lease"] as? String,
        imported["targetId"] as? String == target.id,
        imported["bindingRevision"] as? Int == target.bindingRevision,
        imported["name"] as? String == local.name,
        imported["byteCount"] as? Int == local.contents.count,
        imported["sha256"] as? String == local.sha256,
        imported["abi"] as? String == local.abi,
        imported["elfClassBits"] as? Int == local.elfClassBits,
        imported["machine"] as? Int == local.machine,
        imported["buildId"] as? String == local.buildID
      else {
        throw DebugXPCReadFailure.transport(
          "Runtime import facts no longer match the selected target and library")
      }

      let request = try DebugNativeLibraryRequestBuilder.request(
        target: target,
        lease: lease,
        targetBundle: targetBundle,
        libraryLogicalName: libraryLogicalName,
        // ABI is an observed property of the signed ELF, not a user-authored
        // compatibility claim. Runtime validates the same value again against
        // the immutable lease bytes during plan materialization.
        expectedABI: local.abi,
        verificationProfile: verificationProfile,
        rollbackPolicy: rollbackPolicy)
      let encoder = CanonicalJSONEncoders.canonical()
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        throw DebugXPCReadFailure.transport(
          "Could not encode the typed native-library request")
      }

      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.plan", params: ["requestJson": .string(requestJSON)]))
      if let blocker = result["providerAdmissionBlocker"] as? String, !blocker.isEmpty {
        throw DebugXPCReadFailure.transport(blocker)
      }
      guard
        let descriptor = RuntimeOperationCatalog.descriptor(
          reference: DebugApplicationFacade.nativeLibraryReference),
        result["executionMode"] as? String == "planOnly",
        result["operationReference"] as? String
          == DebugApplicationFacade.nativeLibraryReference,
        result["targetID"] as? String == target.id,
        result["bindingRevision"] as? Int == target.bindingRevision,
        result["providerID"] as? String == CatalogProvider.hdc.rawValue,
        result["effectiveEffect"] as? String == WorkflowEffect.deviceMutation.rawValue,
        result["jobAdmitted"] as? Bool == false,
        result["dispatchDisposition"] as? String == "notDispatched",
        result["providerAdmissionBlocker"] == nil
          || result["providerAdmissionBlocker"] is NSNull,
        let planDigest = result["materializedPlanDigest"] as? String,
        SHA256Hex.isLowercaseSHA256(planDigest),
        let inputs = result["inputs"] as? [String: Any],
        inputs["libraryArtifactLease"] as? String == lease,
        inputs["targetBundle"] as? String == targetBundle,
        inputs["libraryLogicalName"] as? String == libraryLogicalName,
        inputs["expectedABI"] as? String == local.abi,
        inputs["restartProfile"] as? String == "restartAbility",
        inputs["verificationProfile"] as? String == verificationProfile,
        inputs["rollbackPolicy"] as? String == rollbackPolicy,
        let rows = result["steps"] as? [[String: Any]]
      else {
        throw DebugXPCReadFailure.transport(
          "Runtime plan facts no longer match the selected target and library")
      }
      let steps = try rows.map { row in
        guard let id = row["stepID"] as? String,
          let kind = row["kind"] as? String,
          let effect = row["effect"] as? String
        else {
          throw DebugXPCReadFailure.transport(
            "Runtime returned an incomplete native-library plan step")
        }
        return DebugNativeLibraryPlanStepPresentation(id: id, kind: kind, effect: effect)
      }
      let expectedSteps = descriptor.steps.map {
        DebugNativeLibraryPlanStepPresentation(
          id: $0.stepID, kind: $0.kind.rawValue, effect: $0.effect.rawValue)
      }
      guard steps == expectedSteps else {
        throw DebugXPCReadFailure.transport(
          "Runtime plan steps no longer match the published native-library operation")
      }

      var reviewedEnvelope = try JSONDecoder().decode(
        [String: JSONValue].self, from: requestData)
      reviewedEnvelope["reviewedPlanDigest"] = .string(planDigest)
      let reviewedData = try encoder.encode(reviewedEnvelope)
      guard let reviewedJSON = String(data: reviewedData, encoding: .utf8) else {
        throw DebugXPCReadFailure.transport(
          "Could not pin the reviewed native-library plan")
      }
      return .prepared(
        DebugNativeLibraryPreparation(
          operationReference: descriptor.reference,
          targetID: target.id,
          bindingRevision: target.bindingRevision,
          libraryName: libraryLogicalName,
          byteCount: local.contents.count,
          sha256: local.sha256,
          abi: local.abi,
          elfClassBits: local.elfClassBits,
          machine: local.machine,
          buildID: local.buildID,
          targetBundle: targetBundle,
          verificationProfile: verificationProfile,
          rollbackPolicy: rollbackPolicy,
          planDigest: planDigest,
          steps: steps,
          requestJSON: reviewedJSON))
    } catch let failure as DebugXPCReadFailure {
      if let uploadID {
        _ = await DebugXPCReadTransport.request(
          method: "artifact.importNativeLibrary.abort",
          params: ["uploadId": .string(uploadID)])
      }
      return .failed(failure.message)
    } catch {
      if let uploadID {
        _ = await DebugXPCReadTransport.request(
          method: "artifact.importNativeLibrary.abort",
          params: ["uploadId": .string(uploadID)])
      }
      return .failed(String(describing: error))
    }
  }

  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation,
    sourceID: UUID,
    relativePath: String,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-remote-native-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      let artifact = try await remoteBuildSources.fetchNativeLibrary(
        sourceID: sourceID, relativePath: relativePath)
      guard artifact.byteCount == artifact.contents.count,
        artifact.sha256 == SHA256Hex.string(of: artifact.contents)
      else {
        return .failed("Remote Artifact bytes no longer match the inspected SSH source")
      }
      try FileManager.default.createDirectory(
        at: temporaryRoot, withIntermediateDirectories: false)
      let fileURL = temporaryRoot.appending(path: artifact.fileName)
      try artifact.contents.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      defer { try? FileManager.default.removeItem(at: temporaryRoot) }
      return await prepareNativeLibrary(
        target: target,
        fileURL: fileURL,
        targetBundle: targetBundle,
        libraryLogicalName: libraryLogicalName,
        verificationProfile: verificationProfile,
        rollbackPolicy: rollbackPolicy)
    } catch {
      try? FileManager.default.removeItem(at: temporaryRoot)
      return .failed(error.localizedDescription)
    }
  }

  func submitNativeLibrary(
    preparation: DebugNativeLibraryPreparation
  ) async -> DebugLogJobSubmissionResult {
    guard preparation.operationReference == DebugApplicationFacade.nativeLibraryReference,
      SHA256Hex.isLowercaseSHA256(preparation.planDigest),
      !preparation.requestJSON.isEmpty
    else { return .failed("The reviewed native-library plan is incomplete") }
    do {
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.submit",
          params: ["requestJson": .string(preparation.requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed(
          "Runtime accepted native-library deployment without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func run(jobID: String) async -> DebugLogJobRunResult {
    do {
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.run", params: ["jobId": .string(jobID)]))
      return .completed(try DebugRuntimeResponseDecoding.terminal(result, jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func cancel(jobID: String) async -> Bool {
    guard
      let result = try? DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.cancel", params: ["jobId": .string(jobID)]))
    else { return false }
    return result["cancelRequested"] as? Bool == true
  }

  func submitPortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) async -> DebugLogJobSubmissionResult {
    guard (1_024...65_535).contains(rule.localPort),
      (1_024...65_535).contains(rule.remotePort)
    else { return .failed("Port rule is outside the published bounds") }
    do {
      let nonce = UUID().uuidString.lowercased()
      let operationID = removing ? "port-forward.remove" : "port-forward.create"
      let request = try RuntimeOperationRequest(
        requestID: "debug-network-ui-\(nonce)",
        idempotencyKey: "debug-network-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id, expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: operationID, version: 1),
        inputs: [
          "direction": .string(rule.direction.rawValue),
          "localPort": .integer(Int64(rule.localPort)),
          "remotePort": .integer(Int64(rule.remotePort)),
        ],
        requestedOutputs: [.derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeWorkspaceThread.clientContext(
          clientName: ArkDeckAgentClientName.debugNetworkWorkspace, targetID: target.id))
      let encoder = CanonicalJSONEncoders.canonical()
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed port rule")
      }
      let result = try DebugRuntimeResponseDecoding.resultObject(
        await DebugXPCReadTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = result["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted the port rule without returning a Job ID")
      }
      return .submitted(DebugLogJobAcceptancePresentation(jobID: jobID))
    } catch let failure as DebugXPCReadFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func runTemplate(
    target: DebugTargetPresentation,
    templateID: String
  ) async -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure> {
    guard DebugRuntimeCommandTemplate(rawValue: templateID) != nil else {
      return .failure(.transport("Unknown Debug template"))
    }
    return DebugRuntimeResponseDecoding.command(
      await DebugXPCReadTransport.request(
        method: "debug.template.run",
        params: [
          "targetId": .string(target.id),
          "templateId": .string(templateID),
        ]),
      target: target, templateID: templateID)
  }
}

enum DebugWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, DebugXPCReadFailure>,
    targetResponse: Result<Data, DebugXPCReadFailure>,
    jobResponse: Result<Data, DebugXPCReadFailure>
  ) -> DebugWorkspacePresentation {
    let operations = decodeOperations(operationResponse)
    let decodedTargets = decodeTargets(targetResponse)
    let decodedJobs = decodeJobs(jobResponse)
    return DebugWorkspacePresentation(
      operations: operations,
      targets: decodedTargets.value ?? [],
      jobs: decodedJobs.value ?? [],
      targetLoadFailure: decodedTargets.failure,
      jobLoadFailure: decodedJobs.failure)
  }

  private static func decodeOperations(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> [DebugOperationPresentation] {
    let entries: [[String: Any]]
    switch response {
    case .failure(let failure):
      return DebugApplicationFacade.descriptors.map {
        DebugApplicationFacade.operationPresentation(
          descriptor: $0, availability: .unavailable(reasons: [failure.message]))
      }
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return DebugApplicationFacade.descriptors.map {
          DebugApplicationFacade.operationPresentation(
            descriptor: $0, availability: .unavailable(reasons: [failure.message]))
        }
      case .success(let result): entries = result
      }
    }
    return DebugApplicationFacade.descriptors.map { descriptor in
      guard
        let entry = entries.first(where: { $0["reference"] as? String == descriptor.reference }),
        let state = entry["availability"] as? String,
        let reasons = entry["reasons"] as? [String]
      else {
        return DebugApplicationFacade.operationPresentation(
          descriptor: descriptor,
          availability: .unavailable(
            reasons: ["\(descriptor.reference) is missing complete availability facts"]))
      }
      return DebugApplicationFacade.operationPresentation(
        descriptor: descriptor,
        availability: state == "available"
          ? .available
          : .unavailable(
            reasons: reasons.isEmpty
              ? ["Runtime did not report an availability reason"] : reasons))
    }
  }

  private static func decodeTargets(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> DecodedList<DebugTargetPresentation> {
    switch response {
    case .failure(let failure): return DecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return DecodedList(failure: failure.message)
      case .success(let entries):
        var values: [DebugTargetPresentation] = []
        for entry in entries {
          guard
            let id = entry["targetId"] as? String,
            let revision = entry["bindingRevision"] as? Int,
            let toolVersion = entry["toolVersion"] as? String,
            let adoptedAtUTC = entry["adoptedAtUtc"] as? String
          else {
            return DecodedList(
              failure: "Runtime returned a target without complete binding facts")
          }
          values.append(
            DebugTargetPresentation(
              id: id, bindingRevision: revision, toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return DecodedList(value: values)
      }
    }
  }

  private static func decodeJobs(
    _ response: Result<Data, DebugXPCReadFailure>
  ) -> DecodedList<DebugJobPresentation> {
    switch response {
    case .failure(let failure): return DecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return DecodedList(failure: failure.message)
      case .success(let entries):
        var values: [DebugJobPresentation] = []
        for entry in entries {
          guard let operation = entry["operation"] as? String else { continue }
          guard
            operation == DebugApplicationFacade.debugHAPReference
              || operation == DebugApplicationFacade.captureDiagnosticsReference
              || operation == DebugApplicationFacade.nativeLibraryReference
              || operation == DebugApplicationFacade.createPortForwardReference
              || operation == DebugApplicationFacade.removePortForwardReference
          else { continue }
          guard
            let id = entry["jobId"] as? String,
            let targetID = entry["targetId"] as? String,
            let state = entry["state"] as? String,
            let waitingForHuman = entry["waitingForHuman"] as? Bool,
            let outcomeUnknown = entry["outcomeUnknown"] as? Bool,
            let residueCount = entry["outstandingResidueCount"] as? Int
          else {
            return DecodedList(failure: "Runtime returned an incomplete Debug job")
          }
          let operationFailure: RuntimeOperationFailure?
          do {
            operationFailure = try DebugRuntimeResponseDecoding.operationFailure(
              in: entry, state: state, outcomeUnknown: outcomeUnknown)
          } catch let failure as DebugXPCReadFailure {
            return DecodedList(failure: failure.message)
          } catch {
            return DecodedList(failure: "Runtime returned a malformed Debug failure")
          }
          values.append(
            DebugJobPresentation(
              id: id, operationReference: operation, targetID: targetID, state: state,
              waitingForHuman: waitingForHuman, outcomeUnknown: outcomeUnknown,
              operationFailure: operationFailure,
              outstandingResidueCount: residueCount,
              timeline: entry["timeline"] as? [String] ?? []))
        }
        return DecodedList(value: values)
      }
    }
  }

  private static func decodeResultArray(
    _ data: Data
  ) -> Result<[[String: Any]], DebugResponseFailure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(DebugResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        DebugResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
      return .failure(DebugResponseFailure(message: "Runtime returned no result list"))
    }
    return .success(result)
  }
}

enum DebugRuntimeResponseDecoding {
  static func terminal(
    _ result: [String: Any], jobID: String
  ) throws -> DebugLogJobTerminalPresentation {
    guard result["jobId"] as? String == jobID,
      let state = result["state"] as? String,
      let outcomeUnknown = result["outcomeUnknown"] as? Bool,
      let timeline = result["timeline"] as? [String]
    else { throw DebugXPCReadFailure.transport("Runtime returned incomplete terminal Debug facts") }
    return DebugLogJobTerminalPresentation(
      jobID: jobID,
      state: state,
      outcomeUnknown: outcomeUnknown,
      operationFailure: try operationFailure(
        in: result, state: state, outcomeUnknown: outcomeUnknown),
      timeline: timeline)
  }

  static func operationFailure(
    in fields: [String: Any], state: String, outcomeUnknown: Bool
  ) throws -> RuntimeOperationFailure? {
    guard let raw = fields["failure"] else {
      return compatibilityFailure(state: state, outcomeUnknown: outcomeUnknown)
    }
    if raw is NSNull {
      guard compatibilityFailure(state: state, outcomeUnknown: outcomeUnknown) == nil else {
        throw DebugXPCReadFailure.transport(
          "Runtime omitted the machine-readable failure for a failed Debug job")
      }
      return nil
    }
    guard let object = raw as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: object),
      let failure = try? JSONDecoder().decode(RuntimeOperationFailure.self, from: data),
      failure.schemaVersion == RuntimeOperationFailure.schemaVersion
    else {
      throw DebugXPCReadFailure.transport("Runtime returned a malformed Debug failure")
    }
    return failure
  }

  private static func compatibilityFailure(
    state: String, outcomeUnknown: Bool
  ) -> RuntimeOperationFailure? {
    if outcomeUnknown || state == JobState.waitingForRecovery.rawValue {
      return RuntimeOperationFailure(
        code: .outcomeUnknown, category: .unknownOutcome,
        retryability: .runtimeDecisionRequired,
        recovery: .awaitRuntimeReconciliation)
    }
    switch JobState(rawValue: state) {
    case .failed:
      return RuntimeOperationFailure(
        code: .legacyFailure, category: .runtime,
        retryability: .runtimeDecisionRequired, recovery: .inspectJob)
    case .cancelled:
      return RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none)
    case .interrupted:
      return RuntimeOperationFailure(
        code: .interrupted, category: .runtime,
        retryability: .runtimeDecisionRequired, recovery: .inspectJob)
    default:
      return nil
    }
  }

  static func resultObject(
    _ response: Result<Data, DebugXPCReadFailure>
  ) throws -> [String: Any] {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure): throw failure
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw DebugXPCReadFailure.transport("Runtime returned an unreadable response") }
    if let error = envelope["error"] as? [String: Any] {
      throw DebugXPCReadFailure.transport(
        "Runtime refused the request: " + (error["message"] as? String ?? "no message"))
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any]
    else { throw DebugXPCReadFailure.transport("Runtime returned no result object") }
    return result
  }

  static func snapshot(
    _ response: Result<Data, DebugXPCReadFailure>,
    target: DebugTargetPresentation
  ) -> Result<DebugRuntimeProbeSnapshot, DebugXPCReadFailure> {
    do {
      let result = try resultObject(response)
      guard result["targetId"] as? String == target.id,
        result["bindingRevision"] as? Int == target.bindingRevision,
        let packages = result["packages"] as? [String],
        Set(packages).count == packages.count,
        packages.allSatisfy({ DebugTypedValueValidator.isSafeTypedIdentifier($0) }),
        let ruleRows = result["portRules"] as? [[String: Any]],
        let warnings = result["warnings"] as? [String]
      else { return .failure(.transport("Runtime returned mismatched Debug probe facts")) }
      var rules: [DebugRuntimePortRule] = []
      for row in ruleRows {
        guard let directionText = row["direction"] as? String,
          let direction = DebugRuntimePortDirection(rawValue: directionText),
          let localPort = row["localPort"] as? Int,
          let remotePort = row["remotePort"] as? Int,
          (1_024...65_535).contains(localPort),
          (1_024...65_535).contains(remotePort)
        else { return .failure(.transport("Runtime returned malformed port rules")) }
        rules.append(
          DebugRuntimePortRule(
            direction: direction, localPort: localPort, remotePort: remotePort))
      }
      return .success(
        DebugRuntimeProbeSnapshot(
          targetID: target.id, bindingRevision: target.bindingRevision,
          packages: packages, portRules: rules, warnings: warnings))
    } catch let failure as DebugXPCReadFailure {
      return .failure(failure)
    } catch {
      return .failure(.transport(String(describing: error)))
    }
  }

  static func command(
    _ response: Result<Data, DebugXPCReadFailure>,
    target: DebugTargetPresentation,
    templateID: String
  ) -> Result<DebugRuntimeCommandResult, DebugXPCReadFailure> {
    do {
      let result = try resultObject(response)
      guard result["targetId"] as? String == target.id,
        result["bindingRevision"] as? Int == target.bindingRevision,
        result["templateId"] as? String == templateID,
        result["effect"] as? String == "readOnly",
        result["executable"] as? String == "hdc",
        let executableSHA256 = result["executableSha256"] as? String,
        executableSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
        let arguments = result["arguments"] as? [String],
        arguments.first == "-t", arguments.dropFirst().first == "<redacted-connect-key>",
        let loweringSHA256 = result["loweringSha256"] as? String,
        loweringSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
        let durationMilliseconds = result["durationMilliseconds"] as? Int,
        durationMilliseconds >= 0,
        let stdout = result["stdout"] as? String,
        let stderr = result["stderr"] as? String,
        let outputTruncated = result["outputTruncated"] as? Bool
      else { return .failure(.transport("Runtime returned mismatched Debug command facts")) }
      let exitCode = result["exitCode"] as? Int
      return .success(
        DebugRuntimeCommandResult(
          targetID: target.id, bindingRevision: target.bindingRevision,
          templateID: templateID, effect: "readOnly", executable: "hdc",
          executableSHA256: executableSHA256, argumentDisclosure: arguments,
          loweringSHA256: loweringSHA256, exitCode: exitCode,
          durationMilliseconds: durationMilliseconds,
          stdout: stdout, stderr: stderr, outputTruncated: outputTruncated))
    } catch let failure as DebugXPCReadFailure {
      return .failure(failure)
    } catch {
      return .failure(.transport(String(describing: error)))
    }
  }
}

private struct DebugResponseFailure: Error {
  let message: String
}

private struct DecodedList<Value> {
  let value: [Value]?
  let failure: String?

  init(value: [Value]) {
    self.value = value
    failure = nil
  }

  init(failure: String) {
    value = nil
    self.failure = failure
  }
}

public enum DebugXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  public var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

enum DebugXPCReadTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> Result<Data, DebugXPCReadFailure> {
    await RuntimeXPCRequestTransport.request(method: method, params: params)
      .mapError { DebugXPCReadFailure.transport($0.message) }
  }
}
