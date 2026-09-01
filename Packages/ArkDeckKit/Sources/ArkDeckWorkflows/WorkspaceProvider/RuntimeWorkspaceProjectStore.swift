import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public struct RuntimeWorkspaceProjectResource: Equatable, Sendable {
  public let projectRef: String
  public let generation: UInt64
  public let kind: String
  public let registeredAtUTC: String
  public let updatedAtUTC: String
  public let configurationStatus: String

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.workspace-project/1"),
      "projectRef": .string(projectRef),
      "generation": .string(String(generation)),
      "kind": .string(kind),
      "registeredAtUtc": .string(registeredAtUTC),
      "updatedAtUtc": .string(updatedAtUTC),
      "configurationStatus": .string(configurationStatus),
    ])
  }
}

public struct RuntimeWorkspaceProjectFailure: Error, Equatable, Sendable {
  public let code: String
  public let message: String

  package init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

public struct RuntimeWorkspacePresetConstraints: Codable, Equatable, Sendable {
  public let module: String?
  public let product: String?
  public let buildMode: String?
  public let relativeSourceMap: String?

  public init(
    module: String? = nil, product: String? = nil, buildMode: String? = nil,
    relativeSourceMap: String? = nil
  ) {
    self.module = module
    self.product = product
    self.buildMode = buildMode
    self.relativeSourceMap = relativeSourceMap
  }

  package var projection: JSONValue {
    var fields: [String: JSONValue] = [:]
    if let module { fields["module"] = .string(module) }
    if let product { fields["product"] = .string(product) }
    if let buildMode { fields["buildMode"] = .string(buildMode) }
    if let relativeSourceMap { fields["relativeSourceMap"] = .string(relativeSourceMap) }
    return .object(fields)
  }
}

public struct RuntimeWorkspacePresetResource: Equatable, Sendable {
  public let presetRef: String
  public let generation: UInt64
  public let projectRef: String
  public let kind: String
  public let templateRef: String
  public let toolchainRef: String?
  public let toolchainGeneration: UInt64?
  public let credentialRef: String?
  public let timeoutSeconds: Int
  public let constraints: RuntimeWorkspacePresetConstraints
  public let registeredAtUTC: String
  public let updatedAtUTC: String
  public let configurationStatus: String

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.workspace-preset/1"),
      "presetRef": .string(presetRef),
      "generation": .string(String(generation)),
      "projectRef": .string(projectRef),
      "kind": .string(kind),
      "templateRef": .string(templateRef),
      "toolchainRef": toolchainRef.map(JSONValue.string) ?? .null,
      "toolchainGeneration": toolchainGeneration.map { .string(String($0)) } ?? .null,
      "credentialRef": credentialRef.map(JSONValue.string) ?? .null,
      "timeoutSeconds": .integer(Int64(timeoutSeconds)),
      "constraints": constraints.projection,
      "registeredAtUtc": .string(registeredAtUTC),
      "updatedAtUtc": .string(updatedAtUTC),
      "configurationStatus": .string(configurationStatus),
    ])
  }
}

package struct RuntimeWorkspacePresetComposition: Sendable, Equatable {
  package let resource: RuntimeWorkspacePresetResource
}

package struct RuntimeWorkspaceToolchainPinning: Sendable {
  package let acquire: @Sendable (_ toolchainRef: String, _ generation: UInt64, _ presetRef: String) throws -> Void
  package let release: @Sendable (_ toolchainRef: String, _ presetRef: String) throws -> Void

  package init(
    acquire: @escaping @Sendable (String, UInt64, String) throws -> Void,
    release: @escaping @Sendable (String, String) throws -> Void
  ) {
    self.acquire = acquire
    self.release = release
  }
}

package struct RuntimeWorkspaceProjectUseToken: Sendable {
  fileprivate let id: UUID
  fileprivate let projectRef: String
  fileprivate let presetRefs: [String]
}

/// The private half of one registered workspace project.
///
/// A control response can receive `resource`; `rootPath` and its file identity
/// stay inside the production composition root and provider. Keeping the two
/// projections as different types prevents an encoder call from accidentally
/// publishing the grant.
package struct RuntimeWorkspaceProjectComposition: Sendable, Equatable {
  package let resource: RuntimeWorkspaceProjectResource
  package let rootPath: String
  package let rootDevice: UInt64
  package let rootInode: UInt64
}

package struct RuntimeWorkspaceProjectStartupRecord: Sendable, Equatable {
  package let resource: RuntimeWorkspaceProjectResource
  package let composition: RuntimeWorkspaceProjectComposition?
  package let failure: RuntimeWorkspaceProjectFailure?
}

/// Runtime-owned workspace root registrations.
///
/// Registration is the sole place a caller path enters this owner. The path is
/// opened without following the leaf, every ancestor is checked with `lstat`,
/// and the durable grant pins the opened directory's device/inode identity.
/// Public projections contain only the generated reference and generation.
///
/// The process lock also closes the acquire/update race. A workspace Job holds
/// a token until its SQLite admission row is durable; update/remove hold the
/// same lock while checking both tokens and durable active Jobs.
public final class RuntimeWorkspaceProjectStore: @unchecked Sendable {
  private struct RootIdentity: Codable, Equatable, Hashable {
    let path: String
    let device: UInt64
    let inode: UInt64
  }

  private struct Record: Codable, Equatable {
    let projectRef: String
    var generation: UInt64
    var kind: String
    var root: RootIdentity
    let registrationRequestID: String
    let registrationKind: String
    let registrationRoot: RootIdentity
    let registrationDigest: String
    let registeredAtUTC: String
    var updatedAtUTC: String
  }

  private struct PresetRecord: Codable, Equatable {
    let presetRef: String
    var generation: UInt64
    let projectRef: String
    var kind: String
    var templateRef: String
    var toolchainRef: String?
    var toolchainGeneration: UInt64?
    var credentialRef: String?
    var timeoutSeconds: Int
    var constraints: RuntimeWorkspacePresetConstraints
    let registrationRequestID: String
    let registrationProjectRef: String
    let registrationKind: String
    let registrationTemplateRef: String
    let registrationToolchainRef: String?
    let registrationToolchainGeneration: UInt64?
    let registrationCredentialRef: String?
    let registrationTimeoutSeconds: Int
    let registrationConstraints: RuntimeWorkspacePresetConstraints
    let registrationDigest: String
    var currentDefinitionDigest: String
    let registeredAtUTC: String
    var updatedAtUTC: String
    var state: String
    var lastMutationRequestID: String
    var lastMutationDigest: String
  }

  private struct PendingToolchainMutation: Codable, Equatable {
    let action: String
    let toolchainRef: String
    let toolchainGeneration: UInt64
    let presetRef: String
    let proposedRecord: PresetRecord?
    let releaseAfterAcquireRef: String?
  }

  private struct Document: Codable, Equatable {
    var schemaVersion = "arkdeck.workspace-project-store/2"
    var records: [Record] = []
    var presets: [PresetRecord] = []
    var pendingToolchainMutation: PendingToolchainMutation?

    private enum CodingKeys: String, CodingKey {
      case schemaVersion, records, presets, pendingToolchainMutation
    }

    init() {}

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
      records = try values.decode([Record].self, forKey: .records)
      presets = try values.decodeIfPresent([PresetRecord].self, forKey: .presets) ?? []
      pendingToolchainMutation = try values.decodeIfPresent(
        PendingToolchainMutation.self, forKey: .pendingToolchainMutation)
    }
  }

  private static let documentName = "projects.json"
  private static let lockName = ".projects.lock"
  private static let maximumDocumentBytes = 1 * 1_024 * 1_024
  private static let maximumProjects = 64
  private static let maximumPresets = 256
  private static let kinds: Set<String> = ["arkdeck", "openharmony"]
  private static let presetTemplates: [String: String] = [
    "build": "openharmony.hvigor-build@1",
    "test": "openharmony.hvigor-test@1",
    "signing": "openharmony.local-sign@1",
    "symbol": "openharmony.arkts-symbol@1",
  ]

  private let directoryURL: URL
  private let nowUTC: @Sendable () -> String
  private let processLock = NSLock()
  private var uses: [String: Set<UUID>] = [:]
  private var presetUses: [String: Set<UUID>] = [:]
  private var appliedGenerations: [String: UInt64]
  private var appliedPresetGenerations: [String: UInt64]
  private let toolchainPinning: RuntimeWorkspaceToolchainPinning?

  package init(
    rootURL: URL,
    appliedGenerations: [String: UInt64] = [:],
    appliedPresetGenerations: [String: UInt64] = [:],
    toolchainPinning: RuntimeWorkspaceToolchainPinning? = nil,
    nowUTC: @escaping @Sendable () -> String = {
      ISO8601Timestamps.string(from: Date(), includingFractionalSeconds: true)
    }
  ) throws {
    directoryURL = rootURL.appending(path: "workspace-projects", directoryHint: .isDirectory)
    self.appliedGenerations = appliedGenerations
    self.appliedPresetGenerations = appliedPresetGenerations
    self.toolchainPinning = toolchainPinning
    self.nowUTC = nowUTC
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Self.validateOwnerDirectory(directoryURL)
    try processLock.withLock {
      try withDocument { _, _ in () }
    }
  }

  package func markApplied(_ generations: [String: UInt64]) {
    processLock.withLock { appliedGenerations = generations }
  }

  package func markApplied(
    projects: [String: UInt64], presets: [String: UInt64]
  ) {
    processLock.withLock {
      appliedGenerations = projects
      appliedPresetGenerations = presets
    }
  }

  package func list() throws -> [RuntimeWorkspaceProjectResource] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { try resource($0) }
          .sorted { $0.projectRef < $1.projectRef }
      }
    }
  }

  package func inspect(_ projectRef: String) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    return try processLock.withLock {
      try withDocument { _, document in
        guard let record = document.records.first(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        return try resource(record)
      }
    }
  }

  package func listPresets(
    projectRef: String? = nil, kind: String? = nil
  ) throws -> [RuntimeWorkspacePresetResource] {
    if let projectRef { try validateProjectRef(projectRef) }
    if let kind { try validatePresetKind(kind) }
    return try processLock.withLock {
      try withDocument { _, document in
        if let projectRef,
          !document.records.contains(where: { $0.projectRef == projectRef })
        {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        return try document.presets
          .filter { $0.state == "available" }
          .filter { projectRef == nil || $0.projectRef == projectRef }
          .filter { kind == nil || $0.kind == kind }
          .map { try presetResource($0) }
          .sorted { $0.presetRef < $1.presetRef }
      }
    }
  }

  package func inspectPreset(
    projectRef: String, presetRef: String
  ) throws -> RuntimeWorkspacePresetResource {
    try validateProjectRef(projectRef)
    try validatePresetRef(presetRef)
    return try processLock.withLock {
      try withDocument { _, document in
        guard let record = document.presets.first(where: {
          $0.projectRef == projectRef && $0.presetRef == presetRef && $0.state == "available"
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace preset is not registered")
        }
        return try presetResource(record)
      }
    }
  }

  package func presetCompositionRecords() throws -> [RuntimeWorkspacePresetComposition] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.presets.filter { $0.state == "available" }.map {
          RuntimeWorkspacePresetComposition(resource: try presetResource($0))
        }.sorted { $0.resource.presetRef < $1.resource.presetRef }
      }
    }
  }

  package func registerPreset(
    requestID: String, projectRef: String, kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws -> RuntimeWorkspacePresetResource {
    try validateRequestID(requestID)
    try validateProjectRef(projectRef)
    try validatePresetDefinition(
      kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
    let digest = try Self.presetDigest(
      projectRef: projectRef, kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
    let presetRef = Self.presetRef(requestID: requestID)
    return try processLock.withLock {
      try withDocument { rootFD, document in
        var next = document
        if let existing = next.presets.first(where: { $0.registrationRequestID == requestID }) {
          guard existing.registrationDigest == digest, existing.presetRef == presetRef else {
            throw RuntimeWorkspaceProjectFailure(
              "idempotencyConflict", "registration request identity belongs to another preset")
          }
          return try presetResource(existing)
        }
        guard next.records.contains(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        guard next.presets.count < Self.maximumPresets else {
          throw RuntimeWorkspaceProjectFailure(
            "quotaExceeded", "workspace preset registration limit is reached")
        }
        let timestamp = try validTimestamp()
        let record = PresetRecord(
          presetRef: presetRef, generation: 1, projectRef: projectRef,
          kind: kind, templateRef: templateRef,
          toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
          credentialRef: credentialRef, timeoutSeconds: timeoutSeconds,
          constraints: constraints, registrationRequestID: requestID,
          registrationProjectRef: projectRef, registrationKind: kind,
          registrationTemplateRef: templateRef,
          registrationToolchainRef: toolchainRef,
          registrationToolchainGeneration: toolchainGeneration,
          registrationCredentialRef: credentialRef,
          registrationTimeoutSeconds: timeoutSeconds,
          registrationConstraints: constraints,
          registrationDigest: digest, currentDefinitionDigest: digest,
          registeredAtUTC: timestamp, updatedAtUTC: timestamp,
          state: "available", lastMutationRequestID: requestID,
          lastMutationDigest: digest)
        if let toolchainRef, let toolchainGeneration {
          try requireToolchainOwner()
          next.pendingToolchainMutation = PendingToolchainMutation(
            action: "acquire", toolchainRef: toolchainRef,
            toolchainGeneration: toolchainGeneration, presetRef: presetRef,
            proposedRecord: record, releaseAfterAcquireRef: nil)
          try save(next, rootFD: rootFD)
          next = try reconcileToolchainMutation(next, rootFD: rootFD)
        } else {
          next.presets.append(record)
          next.presets.sort { $0.presetRef < $1.presetRef }
          try save(next, rootFD: rootFD)
        }
        guard let published = next.presets.first(where: { $0.presetRef == presetRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "outcomeUnknown", "workspace preset publication could not be verified")
        }
        return try presetResource(published)
      }
    }
  }

  package func updatePreset(
    requestID: String, projectRef: String, presetRef: String,
    expectedGeneration: UInt64, kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints,
    requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspacePresetResource {
    try validateRequestID(requestID)
    try validateProjectRef(projectRef)
    try validatePresetRef(presetRef)
    try validateGeneration(expectedGeneration)
    try validatePresetDefinition(
      kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
    let mutationDigest = try Self.presetMutationDigest(
      verb: "update", projectRef: projectRef, presetRef: presetRef,
      expectedGeneration: expectedGeneration, kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
    return try processLock.withLock {
      try requireNoPresetUse(presetRef)
      try requireNoActiveReference(presetRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.presets.firstIndex(where: {
          $0.projectRef == projectRef && $0.presetRef == presetRef
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace preset is not registered")
        }
        let current = next.presets[index]
        if current.lastMutationRequestID == requestID {
          guard current.lastMutationDigest == mutationDigest else {
            throw RuntimeWorkspaceProjectFailure(
              "idempotencyConflict", "mutation request identity belongs to another preset update")
          }
          return try presetResource(current)
        }
        guard current.state == "available", current.generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset generation changed")
        }
        let advanced = expectedGeneration.addingReportingOverflow(1)
        guard !advanced.overflow, advanced.partialValue <= UInt64(Int64.max) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset generation is exhausted")
        }
        let proposed = PresetRecord(
          presetRef: current.presetRef, generation: advanced.partialValue,
          projectRef: current.projectRef, kind: kind, templateRef: templateRef,
          toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
          credentialRef: credentialRef, timeoutSeconds: timeoutSeconds,
          constraints: constraints, registrationRequestID: current.registrationRequestID,
          registrationProjectRef: current.registrationProjectRef,
          registrationKind: current.registrationKind,
          registrationTemplateRef: current.registrationTemplateRef,
          registrationToolchainRef: current.registrationToolchainRef,
          registrationToolchainGeneration: current.registrationToolchainGeneration,
          registrationCredentialRef: current.registrationCredentialRef,
          registrationTimeoutSeconds: current.registrationTimeoutSeconds,
          registrationConstraints: current.registrationConstraints,
          registrationDigest: current.registrationDigest,
          currentDefinitionDigest: try Self.presetDigest(
            projectRef: current.projectRef, kind: kind, templateRef: templateRef,
            toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
            credentialRef: credentialRef, timeoutSeconds: timeoutSeconds,
            constraints: constraints),
          registeredAtUTC: current.registeredAtUTC, updatedAtUTC: try validTimestamp(),
          state: "available", lastMutationRequestID: requestID,
          lastMutationDigest: mutationDigest)
        if toolchainRef != current.toolchainRef {
          if let toolchainRef, let toolchainGeneration {
            try requireToolchainOwner()
            next.pendingToolchainMutation = PendingToolchainMutation(
              action: "acquire", toolchainRef: toolchainRef,
              toolchainGeneration: toolchainGeneration, presetRef: presetRef,
              proposedRecord: proposed, releaseAfterAcquireRef: current.toolchainRef)
            try save(next, rootFD: rootFD)
            next = try reconcileToolchainMutation(next, rootFD: rootFD)
          } else {
            next.presets[index] = proposed
            if let old = current.toolchainRef {
              try requireToolchainOwner()
              next.pendingToolchainMutation = PendingToolchainMutation(
                action: "release", toolchainRef: old,
                toolchainGeneration: current.toolchainGeneration ?? 1,
                presetRef: presetRef, proposedRecord: nil, releaseAfterAcquireRef: nil)
            }
            try save(next, rootFD: rootFD)
            next = try reconcileToolchainMutation(next, rootFD: rootFD)
          }
        } else {
          next.presets[index] = proposed
          try save(next, rootFD: rootFD)
        }
        guard let published = next.presets.first(where: { $0.presetRef == presetRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "outcomeUnknown", "workspace preset update could not be verified")
        }
        return try presetResource(published)
      }
    }
  }

  package func removePreset(
    requestID: String, projectRef: String, presetRef: String,
    expectedGeneration: UInt64, requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspacePresetResource {
    try validateRequestID(requestID)
    try validateProjectRef(projectRef)
    try validatePresetRef(presetRef)
    try validateGeneration(expectedGeneration)
    let mutationDigest = Self.removalDigest(
      requestID: requestID, projectRef: projectRef, presetRef: presetRef,
      expectedGeneration: expectedGeneration)
    return try processLock.withLock {
      try requireNoPresetUse(presetRef)
      try requireNoActiveReference(presetRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.presets.firstIndex(where: {
          $0.projectRef == projectRef && $0.presetRef == presetRef
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace preset is not registered")
        }
        let current = next.presets[index]
        if current.lastMutationRequestID == requestID {
          guard current.lastMutationDigest == mutationDigest else {
            throw RuntimeWorkspaceProjectFailure(
              "idempotencyConflict", "mutation request identity belongs to another preset removal")
          }
          return try presetResource(current)
        }
        guard current.state == "available", current.generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset generation changed")
        }
        let advanced = expectedGeneration.addingReportingOverflow(1)
        guard !advanced.overflow, advanced.partialValue <= UInt64(Int64.max) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset generation is exhausted")
        }
        next.presets[index].generation = advanced.partialValue
        next.presets[index].state = "removed"
        next.presets[index].updatedAtUTC = try validTimestamp()
        next.presets[index].lastMutationRequestID = requestID
        next.presets[index].lastMutationDigest = mutationDigest
        if let toolchainRef = current.toolchainRef {
          try requireToolchainOwner()
          next.pendingToolchainMutation = PendingToolchainMutation(
            action: "release", toolchainRef: toolchainRef,
            toolchainGeneration: current.toolchainGeneration ?? 1,
            presetRef: presetRef, proposedRecord: nil, releaseAfterAcquireRef: nil)
        }
        try save(next, rootFD: rootFD)
        next = try reconcileToolchainMutation(next, rootFD: rootFD)
        appliedPresetGenerations.removeValue(forKey: presetRef)
        return try presetResource(next.presets[index])
      }
    }
  }

  package func compositionRecords() throws -> [RuntimeWorkspaceProjectComposition] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { record in
          let current = try Self.inspectRoot(record.root.path)
          guard current == record.root else {
            throw RuntimeWorkspaceProjectFailure(
              "factsDrifted", "workspace root identity changed after registration")
          }
          return RuntimeWorkspaceProjectComposition(
            resource: try resource(record), rootPath: record.root.path,
            rootDevice: record.root.device, rootInode: record.root.inode)
        }.sorted { $0.resource.projectRef < $1.resource.projectRef }
      }
    }
  }

  /// A changed root is an unavailable project, not a corrupt owner store.
  /// Production startup uses this projection so the daemon can still expose
  /// and repair/remove the failed registration while every Job acquisition
  /// continues to revalidate the same pinned identity.
  package func startupRecords() throws -> [RuntimeWorkspaceProjectStartupRecord] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { record in
          let publicResource = try resource(record)
          do {
            let current = try Self.inspectRoot(record.root.path)
            guard current == record.root else {
              throw RuntimeWorkspaceProjectFailure(
                "factsDrifted", "workspace root identity changed after registration")
            }
            return RuntimeWorkspaceProjectStartupRecord(
              resource: publicResource,
              composition: RuntimeWorkspaceProjectComposition(
                resource: publicResource, rootPath: record.root.path,
                rootDevice: record.root.device, rootInode: record.root.inode),
              failure: nil)
          } catch let failure as RuntimeWorkspaceProjectFailure {
            return RuntimeWorkspaceProjectStartupRecord(
              resource: publicResource, composition: nil, failure: failure)
          }
        }.sorted { $0.resource.projectRef < $1.resource.projectRef }
      }
    }
  }

  package func register(
    requestID: String, kind: String, rootPath: String,
    projectRef suppliedProjectRef: String? = nil
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateRequestID(requestID)
    try validateKind(kind)
    let root = try Self.inspectRoot(rootPath)
    let digest = Self.registrationDigest(kind: kind, root: root)
    let projectRef = suppliedProjectRef ?? Self.projectRef(requestID: requestID)
    try validateProjectRef(projectRef)
    return try processLock.withLock {
      try withDocument { rootFD, document in
        var next = document
        if let existing = next.records.first(where: { $0.registrationRequestID == requestID }) {
          guard existing.registrationDigest == digest, existing.projectRef == projectRef else {
            throw RuntimeWorkspaceProjectFailure(
              "idempotencyConflict", "registration request identity belongs to another project")
          }
          return try resource(existing)
        }
        guard next.records.count < Self.maximumProjects else {
          throw RuntimeWorkspaceProjectFailure(
            "quotaExceeded", "workspace project registration limit is reached")
        }
        guard !next.records.contains(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project reference is already registered")
        }
        guard !next.records.contains(where: { $0.root == root }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace root is already registered")
        }
        let timestamp = try validTimestamp()
        let record = Record(
          projectRef: projectRef, generation: 1, kind: kind, root: root,
          registrationRequestID: requestID,
          registrationKind: kind, registrationRoot: root,
          registrationDigest: digest,
          registeredAtUTC: timestamp, updatedAtUTC: timestamp)
        next.records.append(record)
        next.records.sort { $0.projectRef < $1.projectRef }
        try save(next, rootFD: rootFD)
        return try resource(record)
      }
    }
  }

  package func update(
    projectRef: String, expectedGeneration: UInt64, kind: String, rootPath: String,
    requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    try validateGeneration(expectedGeneration)
    try validateKind(kind)
    let root = try Self.inspectRoot(rootPath)
    return try processLock.withLock {
      try requireNoUse(projectRef)
      try requireNoActiveReference(projectRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.records.firstIndex(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        guard next.records[index].generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation changed")
        }
        guard next.records[index].kind == kind
          || !next.presets.contains(where: {
            $0.projectRef == projectRef && $0.state == "available"
          })
        else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "remove project presets before changing the project kind")
        }
        guard !next.records.enumerated().contains(where: { offset, record in
          offset != index && record.root == root
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace root is already registered")
        }
        let advanced = expectedGeneration.addingReportingOverflow(1)
        guard !advanced.overflow, advanced.partialValue <= UInt64(Int64.max) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation is exhausted")
        }
        next.records[index].generation = advanced.partialValue
        next.records[index].kind = kind
        next.records[index].root = root
        next.records[index].updatedAtUTC = try validTimestamp()
        try save(next, rootFD: rootFD)
        return try resource(next.records[index])
      }
    }
  }

  package func remove(
    projectRef: String, expectedGeneration: UInt64,
    requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    try validateGeneration(expectedGeneration)
    return try processLock.withLock {
      try requireNoUse(projectRef)
      try requireNoActiveReference(projectRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.records.firstIndex(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        let removed = next.records[index]
        guard removed.generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation changed")
        }
        guard !next.presets.contains(where: {
          $0.projectRef == projectRef && $0.state == "available"
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "remove project presets before removing the project")
        }
        next.records.remove(at: index)
        try save(next, rootFD: rootFD)
        appliedGenerations.removeValue(forKey: projectRef)
        return try resource(removed, forcedStatus: "removed")
      }
    }
  }

  package func acquireUse(
    projectRef: String, presetRefs: [String] = []
  ) throws -> RuntimeWorkspaceProjectUseToken {
    try validateProjectRef(projectRef)
    for presetRef in presetRefs { try validatePresetRef(presetRef) }
    guard Set(presetRefs).count == presetRefs.count else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace Job repeats a preset reference")
    }
    return try processLock.withLock {
      try withDocument { _, document in
        guard let record = document.records.first(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        let currentRoot = try Self.inspectRoot(record.root.path)
        guard currentRoot == record.root else {
          throw RuntimeWorkspaceProjectFailure(
            "factsDrifted", "workspace root identity changed after registration")
        }
        guard appliedGenerations[projectRef] == record.generation else {
          throw RuntimeWorkspaceProjectFailure(
            "operationUnavailable",
            "workspace project configuration changed; restart the Runtime before submitting a Job")
        }
        let registered = document.presets.filter {
          $0.projectRef == projectRef && $0.state == "available"
        }
        for presetRef in presetRefs {
          guard let preset = registered.first(where: { $0.presetRef == presetRef }) else {
            throw RuntimeWorkspaceProjectFailure(
              "workspaceReferenceNotFound", "workspace preset is not registered for this project")
          }
          guard appliedPresetGenerations[presetRef] == preset.generation else {
            throw RuntimeWorkspaceProjectFailure(
              "operationUnavailable",
              "workspace preset configuration changed; restart the Runtime before submitting a Job")
          }
        }
      }
      let token = RuntimeWorkspaceProjectUseToken(
        id: UUID(), projectRef: projectRef, presetRefs: presetRefs.sorted())
      uses[projectRef, default: []].insert(token.id)
      for presetRef in presetRefs { presetUses[presetRef, default: []].insert(token.id) }
      return token
    }
  }

  package func endUse(_ token: RuntimeWorkspaceProjectUseToken) {
    processLock.withLock {
      uses[token.projectRef]?.remove(token.id)
      if uses[token.projectRef]?.isEmpty == true { uses.removeValue(forKey: token.projectRef) }
      for presetRef in token.presetRefs {
        presetUses[presetRef]?.remove(token.id)
        if presetUses[presetRef]?.isEmpty == true { presetUses.removeValue(forKey: presetRef) }
      }
    }
  }

  private func requireNoUse(_ projectRef: String) throws {
    guard uses[projectRef]?.isEmpty != false else {
      throw RuntimeWorkspaceProjectFailure(
        "resourceConflict", "workspace project is being materialized by a Job")
    }
  }

  private func requireNoPresetUse(_ presetRef: String) throws {
    guard presetUses[presetRef]?.isEmpty != false else {
      throw RuntimeWorkspaceProjectFailure(
        "resourceConflict", "workspace preset is being materialized by a Job")
    }
  }

  private func resource(
    _ record: Record, forcedStatus: String? = nil
  ) throws -> RuntimeWorkspaceProjectResource {
    guard ISO8601Timestamps.parse(record.registeredAtUTC) != nil,
      ISO8601Timestamps.parse(record.updatedAtUTC) != nil
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project timestamps are invalid")
    }
    return RuntimeWorkspaceProjectResource(
      projectRef: record.projectRef, generation: record.generation, kind: record.kind,
      registeredAtUTC: record.registeredAtUTC, updatedAtUTC: record.updatedAtUTC,
      configurationStatus: forcedStatus
        ?? (appliedGenerations[record.projectRef] == record.generation
          ? "active" : "runtimeRestartRequired"))
  }

  private func presetResource(
    _ record: PresetRecord
  ) throws -> RuntimeWorkspacePresetResource {
    guard ISO8601Timestamps.parse(record.registeredAtUTC) != nil,
      ISO8601Timestamps.parse(record.updatedAtUTC) != nil
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace preset timestamps are invalid")
    }
    return RuntimeWorkspacePresetResource(
      presetRef: record.presetRef, generation: record.generation,
      projectRef: record.projectRef, kind: record.kind, templateRef: record.templateRef,
      toolchainRef: record.toolchainRef, toolchainGeneration: record.toolchainGeneration,
      credentialRef: record.credentialRef, timeoutSeconds: record.timeoutSeconds,
      constraints: record.constraints, registeredAtUTC: record.registeredAtUTC,
      updatedAtUTC: record.updatedAtUTC,
      configurationStatus: record.state == "removed"
        ? "removed"
        : (appliedPresetGenerations[record.presetRef] == record.generation
          ? "active" : "runtimeRestartRequired"))
  }

  private func requireToolchainOwner() throws {
    guard toolchainPinning != nil else {
      throw RuntimeWorkspaceProjectFailure(
        "operationUnavailable", "DevEco toolchain reference owner is unavailable")
    }
  }

  private func reconcileToolchainMutation(
    _ document: Document, rootFD: Int32
  ) throws -> Document {
    guard let pending = document.pendingToolchainMutation else { return document }
    guard let toolchainPinning else {
      throw RuntimeWorkspaceProjectFailure(
        "operationUnavailable", "DevEco toolchain reference owner is unavailable")
    }
    var next = document
    switch pending.action {
    case "acquire":
      guard let proposed = pending.proposedRecord,
        proposed.presetRef == pending.presetRef,
        proposed.toolchainRef == pending.toolchainRef,
        proposed.toolchainGeneration == pending.toolchainGeneration,
        proposed.state == "available"
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace preset acquire transaction is inconsistent")
      }
      try validatePresetRecord(proposed, projects: document.records)
      try toolchainPinning.acquire(
        pending.toolchainRef, pending.toolchainGeneration, pending.presetRef)
      if let index = next.presets.firstIndex(where: { $0.presetRef == pending.presetRef }) {
        next.presets[index] = proposed
      } else {
        next.presets.append(proposed)
        next.presets.sort { $0.presetRef < $1.presetRef }
      }
      if let old = pending.releaseAfterAcquireRef, old != pending.toolchainRef {
        next.pendingToolchainMutation = PendingToolchainMutation(
          action: "release", toolchainRef: old, toolchainGeneration: 1,
          presetRef: pending.presetRef, proposedRecord: nil,
          releaseAfterAcquireRef: nil)
      } else {
        next.pendingToolchainMutation = nil
      }
      try save(next, rootFD: rootFD)
      if next.pendingToolchainMutation != nil {
        return try reconcileToolchainMutation(next, rootFD: rootFD)
      }
      return next
    case "release":
      guard pending.proposedRecord == nil, pending.releaseAfterAcquireRef == nil else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace preset release transaction is inconsistent")
      }
      guard let retained = document.presets.first(where: {
        $0.presetRef == pending.presetRef
      }),
        (retained.state == "removed" && retained.toolchainRef == pending.toolchainRef)
          || (retained.state == "available" && retained.toolchainRef != pending.toolchainRef)
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace preset release does not match its durable record")
      }
      try toolchainPinning.release(pending.toolchainRef, pending.presetRef)
      next.pendingToolchainMutation = nil
      try save(next, rootFD: rootFD)
      return next
    default:
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace preset transaction action is invalid")
    }
  }

  private func validatePresetDefinition(
    kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws {
    try validatePresetKind(kind)
    guard Self.presetTemplates[kind] == templateRef else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset template does not match its kind")
    }
    guard (1...3_600).contains(timeoutSeconds) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset timeout must be between 1 and 3600 seconds")
    }
    if let toolchainGeneration { try validateGeneration(toolchainGeneration) }
    guard (toolchainRef == nil) == (toolchainGeneration == nil) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset toolchain reference and generation are inseparable")
    }
    if let toolchainRef {
      guard Self.validToolchainRef(toolchainRef) else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "workspace preset toolchain reference is malformed")
      }
    }
    if let credentialRef {
      guard Self.validCredentialRef(credentialRef) else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "workspace preset credential reference is malformed")
      }
    }
    switch kind {
    case "build", "test":
      guard toolchainRef != nil, credentialRef == nil,
        constraints.module.map({ Self.validIdentifier($0, maximumBytes: 128) }) == true,
        constraints.product.map({ Self.validIdentifier($0, maximumBytes: 128) }) == true,
        constraints.buildMode.map({ Self.validIdentifier($0, maximumBytes: 64) }) == true,
        constraints.relativeSourceMap == nil
      else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput",
          "build and test presets require a toolchain, module, product and build mode")
      }
    case "signing":
      guard toolchainRef != nil, credentialRef != nil,
        constraints.module == nil, constraints.product == nil,
        constraints.buildMode == nil, constraints.relativeSourceMap == nil
      else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "signing presets require only toolchain and credential references")
      }
    case "symbol":
      guard toolchainRef == nil, credentialRef == nil,
        constraints.module == nil, constraints.product == nil,
        constraints.buildMode == nil,
        constraints.relativeSourceMap.map(Self.validRelativePath) == true
      else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "symbol presets require one bounded relative source-map path")
      }
    default:
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset kind is unsupported")
    }
  }

  private func validatePresetRecord(
    _ preset: PresetRecord, projects: [Record]
  ) throws {
    try validatePresetRef(preset.presetRef)
    try validateProjectRef(preset.projectRef)
    try validateGeneration(preset.generation)
    try validateRequestID(preset.registrationRequestID)
    try validateRequestID(preset.lastMutationRequestID)
    try validatePresetDefinition(
      kind: preset.registrationKind, templateRef: preset.registrationTemplateRef,
      toolchainRef: preset.registrationToolchainRef,
      toolchainGeneration: preset.registrationToolchainGeneration,
      credentialRef: preset.registrationCredentialRef,
      timeoutSeconds: preset.registrationTimeoutSeconds,
      constraints: preset.registrationConstraints)
    try validatePresetDefinition(
      kind: preset.kind, templateRef: preset.templateRef,
      toolchainRef: preset.toolchainRef,
      toolchainGeneration: preset.toolchainGeneration,
      credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
      constraints: preset.constraints)
    guard (preset.state == "available" && preset.generation >= 1)
      || (preset.state == "removed" && preset.generation >= 2)
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace preset state and generation are inconsistent")
    }
    let registrationDigest = try Self.presetDigest(
      projectRef: preset.registrationProjectRef, kind: preset.registrationKind,
      templateRef: preset.registrationTemplateRef,
      toolchainRef: preset.registrationToolchainRef,
      toolchainGeneration: preset.registrationToolchainGeneration,
      credentialRef: preset.registrationCredentialRef,
      timeoutSeconds: preset.registrationTimeoutSeconds,
      constraints: preset.registrationConstraints)
    let currentDigest = try Self.presetDigest(
      projectRef: preset.projectRef, kind: preset.kind,
      templateRef: preset.templateRef, toolchainRef: preset.toolchainRef,
      toolchainGeneration: preset.toolchainGeneration,
      credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
      constraints: preset.constraints)
    let lastMutationDigest: String
    if preset.state == "removed" {
      lastMutationDigest = Self.removalDigest(
        requestID: preset.lastMutationRequestID, projectRef: preset.projectRef,
        presetRef: preset.presetRef, expectedGeneration: preset.generation - 1)
    } else if preset.generation == 1 {
      lastMutationDigest = registrationDigest
    } else {
      lastMutationDigest = try Self.presetMutationDigest(
        verb: "update", projectRef: preset.projectRef, presetRef: preset.presetRef,
        expectedGeneration: preset.generation - 1,
        kind: preset.kind, templateRef: preset.templateRef,
        toolchainRef: preset.toolchainRef,
        toolchainGeneration: preset.toolchainGeneration,
        credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
        constraints: preset.constraints)
    }
    guard projects.contains(where: { $0.projectRef == preset.projectRef }),
      preset.registrationProjectRef == preset.projectRef,
      preset.registrationDigest == registrationDigest,
      preset.currentDefinitionDigest == currentDigest,
      preset.lastMutationDigest == lastMutationDigest,
      preset.generation > 1 || preset.lastMutationRequestID == preset.registrationRequestID,
      let registered = ISO8601Timestamps.parse(preset.registeredAtUTC),
      let updated = ISO8601Timestamps.parse(preset.updatedAtUTC), updated >= registered
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace preset store record is inconsistent")
    }
  }

  private static func presetDigest(
    projectRef: String, kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws -> String {
    try SHA256Hex.string(of: PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.workspace-preset-definition/1"),
      "projectRef": .string(projectRef), "kind": .string(kind),
      "templateRef": .string(templateRef),
      "toolchainRef": toolchainRef.map(JSONValue.string) ?? .null,
      "toolchainGeneration": toolchainGeneration.map { .string(String($0)) } ?? .null,
      "credentialRef": credentialRef.map(JSONValue.string) ?? .null,
      "timeoutSeconds": .integer(Int64(timeoutSeconds)),
      "constraints": constraints.projection,
    ])))
  }

  private static func presetMutationDigest(
    verb: String, projectRef: String, presetRef: String, expectedGeneration: UInt64,
    kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws -> String {
    let definition = try presetDigest(
      projectRef: projectRef, kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
    return SHA256Hex.string(of: Data(
      "\(verb)\u{0}\(projectRef)\u{0}\(presetRef)\u{0}\(expectedGeneration)\u{0}\(definition)".utf8))
  }

  private static func removalDigest(
    requestID: String, projectRef: String, presetRef: String, expectedGeneration: UInt64
  ) -> String {
    SHA256Hex.string(of: Data(
      "remove\u{0}\(requestID)\u{0}\(projectRef)\u{0}\(presetRef)\u{0}\(expectedGeneration)".utf8))
  }

  private static func presetRef(requestID: String) -> String {
    let digest = SHA256.hash(data: Data(requestID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "preset-" + String(digest.prefix(24))
  }

  private func validTimestamp() throws -> String {
    let timestamp = nowUTC()
    guard ISO8601Timestamps.parse(timestamp) != nil else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project clock is unavailable")
    }
    return timestamp
  }

  private func withDocument<T>(_ body: (Int32, Document) throws -> T) throws -> T {
    let rootFD = Darwin.open(
      directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootFD >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store cannot be opened")
    }
    defer { Darwin.close(rootFD) }
    try Self.validateDirectoryDescriptor(rootFD)
    let lockFD = Darwin.openat(
      rootFD, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store lock cannot be opened")
    }
    defer { Darwin.close(lockFD) }
    try Self.validateRegularDescriptor(lockFD, label: "workspace project store lock")
    while flock(lockFD, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeWorkspaceProjectFailure(
        "resourceConflict", "workspace project store lock cannot be acquired")
    }
    defer { _ = flock(lockFD, LOCK_UN) }
    let loaded = try load(rootFD: rootFD)
    let reconciled = try reconcileToolchainMutation(loaded, rootFD: rootFD)
    return try body(rootFD, reconciled)
  }

  private func load(rootFD: Int32) throws -> Document {
    let descriptor = Darwin.openat(
      rootFD, Self.documentName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return Document() }
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try Self.validateRegularDescriptor(descriptor, label: "workspace project store document")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document exceeds its bound")
    }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    try data.withUnsafeMutableBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.read(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store document cannot be read")
      }
    }
    do {
      var duplicateValidator = StrictJSONDuplicateValidator(data: data)
      try duplicateValidator.validate()
      let document = try JSONDecoder().decode(Document.self, from: data)
      guard ["arkdeck.workspace-project-store/1", "arkdeck.workspace-project-store/2"]
        .contains(document.schemaVersion),
        document.records.count <= Self.maximumProjects,
        document.presets.count <= Self.maximumPresets,
        Set(document.records.map(\.projectRef)).count == document.records.count,
        Set(document.records.map(\.registrationRequestID)).count == document.records.count,
        Set(document.presets.map(\.presetRef)).count == document.presets.count,
        Set(document.presets.map(\.registrationRequestID)).count == document.presets.count,
        document.schemaVersion == "arkdeck.workspace-project-store/2"
          || (document.presets.isEmpty && document.pendingToolchainMutation == nil)
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store document has an invalid shape")
      }
      for record in document.records {
        try validateProjectRef(record.projectRef)
        try validateGeneration(record.generation)
        try validateKind(record.kind)
        try validateRequestID(record.registrationRequestID)
        try validateKind(record.registrationKind)
        guard Self.isCanonicalAbsoluteRootPath(record.root.path), record.root.inode > 0,
          Self.isCanonicalAbsoluteRootPath(record.registrationRoot.path),
          record.registrationRoot.inode > 0,
          record.registrationDigest == Self.registrationDigest(
            kind: record.registrationKind, root: record.registrationRoot),
          let registeredAt = ISO8601Timestamps.parse(record.registeredAtUTC),
          let updatedAt = ISO8601Timestamps.parse(record.updatedAtUTC),
          updatedAt >= registeredAt
        else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "workspace project store record is inconsistent")
        }
      }
      guard Set(document.records.map(\.root)).count == document.records.count else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store contains duplicate roots")
      }
      for preset in document.presets {
        try validatePresetRef(preset.presetRef)
        try validateGeneration(preset.generation)
        try validateRequestID(preset.registrationRequestID)
        try validateRequestID(preset.lastMutationRequestID)
        guard (preset.state == "available" && preset.generation >= 1)
          || (preset.state == "removed" && preset.generation >= 2)
        else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "workspace preset state and generation are inconsistent")
        }
        try validatePresetDefinition(
          kind: preset.registrationKind,
          templateRef: preset.registrationTemplateRef,
          toolchainRef: preset.registrationToolchainRef,
          toolchainGeneration: preset.registrationToolchainGeneration,
          credentialRef: preset.registrationCredentialRef,
          timeoutSeconds: preset.registrationTimeoutSeconds,
          constraints: preset.registrationConstraints)
        let expectedRegistrationDigest = try Self.presetDigest(
          projectRef: preset.registrationProjectRef, kind: preset.registrationKind,
          templateRef: preset.registrationTemplateRef,
          toolchainRef: preset.registrationToolchainRef,
          toolchainGeneration: preset.registrationToolchainGeneration,
          credentialRef: preset.registrationCredentialRef,
          timeoutSeconds: preset.registrationTimeoutSeconds,
          constraints: preset.registrationConstraints)
        let expectedCurrentDigest = try Self.presetDigest(
          projectRef: preset.projectRef, kind: preset.kind,
          templateRef: preset.templateRef, toolchainRef: preset.toolchainRef,
          toolchainGeneration: preset.toolchainGeneration,
          credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
          constraints: preset.constraints)
        let expectedLastMutationDigest: String
        if preset.state == "removed" {
          expectedLastMutationDigest = Self.removalDigest(
            requestID: preset.lastMutationRequestID, projectRef: preset.projectRef,
            presetRef: preset.presetRef, expectedGeneration: preset.generation - 1)
        } else if preset.generation == 1 {
          expectedLastMutationDigest = expectedRegistrationDigest
        } else {
          expectedLastMutationDigest = try Self.presetMutationDigest(
            verb: "update", projectRef: preset.projectRef, presetRef: preset.presetRef,
            expectedGeneration: preset.generation - 1,
            kind: preset.kind, templateRef: preset.templateRef,
            toolchainRef: preset.toolchainRef,
            toolchainGeneration: preset.toolchainGeneration,
            credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
            constraints: preset.constraints)
        }
        guard document.records.contains(where: { $0.projectRef == preset.projectRef }),
          ["available", "removed"].contains(preset.state),
          preset.registrationProjectRef == preset.projectRef,
          preset.registrationDigest == expectedRegistrationDigest,
          preset.currentDefinitionDigest == expectedCurrentDigest,
          preset.lastMutationDigest == expectedLastMutationDigest,
          (preset.state == "available" && preset.generation >= 1)
            || (preset.state == "removed" && preset.generation >= 2),
          preset.generation > 1 || preset.lastMutationRequestID == preset.registrationRequestID,
          ISO8601Timestamps.parse(preset.registeredAtUTC) != nil,
          let updated = ISO8601Timestamps.parse(preset.updatedAtUTC),
          let registered = ISO8601Timestamps.parse(preset.registeredAtUTC),
          updated >= registered
        else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "workspace preset store record is inconsistent")
        }
        try validateProjectRef(preset.projectRef)
        try validatePresetDefinition(
          kind: preset.kind, templateRef: preset.templateRef,
          toolchainRef: preset.toolchainRef,
          toolchainGeneration: preset.toolchainGeneration,
          credentialRef: preset.credentialRef, timeoutSeconds: preset.timeoutSeconds,
          constraints: preset.constraints)
      }
      if let pending = document.pendingToolchainMutation {
        try validatePresetRef(pending.presetRef)
        try validateGeneration(pending.toolchainGeneration)
        guard ["acquire", "release"].contains(pending.action),
          Self.validToolchainRef(pending.toolchainRef),
          pending.releaseAfterAcquireRef.map(Self.validToolchainRef) ?? true
        else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "workspace preset transaction is inconsistent")
        }
      }
      var migrated = document
      migrated.schemaVersion = "arkdeck.workspace-project-store/2"
      return migrated
    } catch let failure as RuntimeWorkspaceProjectFailure {
      throw failure
    } catch {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document is malformed")
    }
  }

  private func save(_ document: Document, rootFD: Int32) throws {
    let data: Data
    do { data = try CanonicalJSONEncoders.canonical().encode(document) }
    catch {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document cannot be encoded")
    }
    guard data.count <= Self.maximumDocumentBytes else {
      throw RuntimeWorkspaceProjectFailure(
        "quotaExceeded", "workspace project store document exceeds its bound")
    }
    let temporaryName = ".projects.\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      rootFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "ioFailure", "workspace project store staging file cannot be created")
    }
    var renamed = false
    defer {
      Darwin.close(descriptor)
      if !renamed { _ = unlinkat(rootFD, temporaryName, 0) }
    }
    try Self.validateRegularDescriptor(descriptor, label: "workspace project store staging file")
    var offset = 0
    try data.withUnsafeBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        throw RuntimeWorkspaceProjectFailure(
          "ioFailure", "workspace project store staging file cannot be written")
      }
    }
    guard fsync(descriptor) == 0,
      renameat(rootFD, temporaryName, rootFD, Self.documentName) == 0,
      fsync(rootFD) == 0
    else {
      throw RuntimeWorkspaceProjectFailure(
        "outcomeUnknown", "workspace project store publication could not be verified")
    }
    renamed = true
  }

  private static func inspectRoot(_ path: String) throws -> RootIdentity {
    // `standardizedFileURL` resolves macOS's `/var -> /private/var` system
    // link for an existing path. Using it here would make the lexical check
    // demand `/var/...` and the next no-follow check correctly reject the same
    // path. `standardized` only removes lexical `.`/`..`; the descriptor and
    // `lstat` checks below own physical canonicalization.
    guard isCanonicalAbsoluteRootPath(path) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace root must be a canonical absolute directory")
    }
    var cursor = URL(filePath: "/", directoryHint: .isDirectory)
    for component in path.split(separator: "/") {
      cursor.append(path: String(component))
      var metadata = stat()
      guard lstat(cursor.path, &metadata) == 0,
        metadata.st_mode & S_IFMT != S_IFLNK
      else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "workspace root ancestry cannot contain a symbolic link")
      }
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace root cannot be opened as a directory")
    }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
    else {
      throw RuntimeWorkspaceProjectFailure(
        "factsDrifted", "workspace root changed while it was being registered")
    }
    return RootIdentity(
      path: path, device: UInt64(bitPattern: Int64(opened.st_dev)),
      inode: UInt64(opened.st_ino))
  }

  private static func isCanonicalAbsoluteRootPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path != "/" && path.utf8.count <= 4_096
      && !path.utf8.contains(0) && URL(filePath: path).standardized.path == path
  }

  private static func registrationDigest(kind: String, root: RootIdentity) -> String {
    let bytes = Data("\(kind)\u{0}\(root.path)\u{0}\(root.device)\u{0}\(root.inode)".utf8)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func projectRef(requestID: String) -> String {
    let digest = SHA256.hash(data: Data(requestID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "project-" + String(digest.prefix(24))
  }

  private func validateProjectRef(_ value: String) throws {
    guard Self.validIdentifier(value, maximumBytes: 128) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project reference is malformed")
    }
  }

  private func validateRequestID(_ value: String) throws {
    guard Self.validIdentifier(value, maximumBytes: 128) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "registration request identity is malformed")
    }
  }

  private func validateKind(_ value: String) throws {
    guard Self.kinds.contains(value) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project kind must be arkdeck or openharmony")
    }
  }

  private func validatePresetKind(_ value: String) throws {
    guard Self.presetTemplates[value] != nil else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset kind must be build, test, signing or symbol")
    }
  }

  private func validatePresetRef(_ value: String) throws {
    guard value.hasPrefix("preset-"), Self.validIdentifier(value, maximumBytes: 128) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace preset reference is malformed")
    }
  }

  private func validateGeneration(_ value: UInt64) throws {
    guard value > 0, value <= UInt64(Int64.max) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project generation must be a canonical positive integer")
    }
  }

  private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
          || scalar == "-" || scalar == "_" || scalar == ".")
      }
  }

  private static func validToolchainRef(_ value: String) -> Bool {
    let prefix = "toolchain:sha256:"
    let digest = String(value.dropFirst(prefix.count))
    return value.hasPrefix(prefix) && validSHA256(digest)
  }

  private static func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func validCredentialRef(_ value: String) -> Bool {
    let prefix = "credential:"
    return value.hasPrefix(prefix)
      && validIdentifier(String(value.dropFirst(prefix.count)), maximumBytes: 128)
  }

  private static func validRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.hasPrefix("/"),
      !value.utf8.contains(0), URL(filePath: value).standardized.path == value
    else { return false }
    return !value.split(separator: "/").contains("..")
  }

  private static func validateOwnerDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store directory cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateDirectoryDescriptor(descriptor)
  }

  private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store directory is not owner-private")
    }
  }

  private static func validateRegularDescriptor(_ descriptor: Int32, label: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0, metadata.st_nlink == 1
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "\(label) is not an owner-only regular file")
    }
  }
}
