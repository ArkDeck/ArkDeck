// Isolated Workspace lifecycle for Harness Evolution Mode.
//
// This is deliberately a lifecycle adapter for the existing workspace
// provider. It owns directories and ProjectProfile registration only; all
// build/test/patch effects still travel through RuntimeJobEngine.

import ArkDeckCore
import ArkDeckHarness
import CryptoKit
import Foundation

public enum EvolutionWorkspaceError: Error, Equatable, Sendable {
  case malformedTaskID
  case sourceProfileUnavailable(String)
  case policyScopeOutsideProfile(String)
  case baseRevisionMismatch(expected: String, actual: String)
  case unsafeSourceEntry(String)
  case workspaceManifestConflict
  case attemptManifestConflict
}

public final class EvolutionWorkspaceManager: HarnessEvolutionWorkspacePort, @unchecked Sendable {
  private struct Manifest: Codable, Equatable {
    let workspace: HarnessEvolutionWorkspace
  }

  private struct AttemptManifest: Codable, Equatable {
    let attemptID: String
    let ordinal: Int
    let workspaceID: String
    let createdAtUTC: String
  }

  private let rootURL: URL
  private let profiles: WorkspaceProjectProfileRegistry
  private let lock = NSLock()

  public init(
    rootURL: URL,
    profileRegistry: WorkspaceProjectProfileRegistry
  ) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.profiles = profileRegistry
    try FileManager.default.createDirectory(
      at: self.rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  public func prepareWorkspace(
    htaskID: String,
    sourceProjectRef: String,
    policy: HarnessEvolutionPolicy,
    createdAtUTC: String
  ) async throws -> HarnessEvolutionWorkspace {
    try lock.withLock {
      guard WorkspaceProviderSupport.isIdentifier(htaskID) else {
        throw EvolutionWorkspaceError.malformedTaskID
      }
      guard let source = profiles.profile(for: sourceProjectRef), source.kind == .primary else {
        throw EvolutionWorkspaceError.sourceProfileUnavailable(sourceProjectRef)
      }
      for scope in policy.allowedPaths
      where !Self.isNarrower(scope, thanAny: source.allowedFileGlobs) {
        throw EvolutionWorkspaceError.policyScopeOutsideProfile(scope)
      }
      let actualRevision = try WorkspaceProviderSupport.workspaceRevision(
        root: source.projectRoot, profileVersion: source.profileID,
        globs: policy.allowedPaths)
      guard actualRevision == policy.baseRevision else {
        throw EvolutionWorkspaceError.baseRevisionMismatch(
          expected: policy.baseRevision, actual: actualRevision)
      }

      let seed = Data("\(htaskID)|\(sourceProjectRef)|\(policy.baseRevision)".utf8)
      let digest = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
      let workspaceID = "evo-\(digest.prefix(24))"
      let projectRef = "evolution-\(digest.prefix(20))"
      let taskRoot = rootURL.appendingPathComponent(workspaceID, isDirectory: true)
      let workspaceRoot = taskRoot.appendingPathComponent("workspace", isDirectory: true)
      let manifestURL = taskRoot.appendingPathComponent("workspace.json")
      let allowedDigest = WorkspaceProviderSupport.sha256(
        Data(policy.allowedPaths.sorted().joined(separator: "\n").utf8))
      let workspace = HarnessEvolutionWorkspace(
        workspaceID: workspaceID, htaskID: htaskID,
        sourceProjectRef: sourceProjectRef, projectRef: projectRef,
        baseRevision: policy.baseRevision, allowedPathsDigest: allowedDigest,
        createdAtUTC: createdAtUTC)

      if FileManager.default.fileExists(atPath: manifestURL.path) {
        let stored = try JSONDecoder().decode(
          Manifest.self, from: Data(contentsOf: manifestURL))
        guard stored.workspace == workspace,
          FileManager.default.fileExists(atPath: workspaceRoot.path)
        else { throw EvolutionWorkspaceError.workspaceManifestConflict }
        let profile = try Self.derivedProfile(
          from: source, workspaceRoot: workspaceRoot,
          projectRef: projectRef, allowedPaths: policy.allowedPaths)
        try profiles.register(profile)
        return workspace
      }

      try FileManager.default.createDirectory(
        at: taskRoot, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let temporary = taskRoot.appendingPathComponent(".workspace.tmp", isDirectory: true)
      do {
        try Self.copyIsolatedTree(
          from: URL(fileURLWithPath: source.projectRoot, isDirectory: true),
          to: temporary)
        try FileManager.default.moveItem(at: temporary, to: workspaceRoot)
        let copiedRevision = try WorkspaceProviderSupport.workspaceRevision(
          root: workspaceRoot.path, profileVersion: source.profileID,
          globs: policy.allowedPaths)
        guard copiedRevision == policy.baseRevision else {
          throw EvolutionWorkspaceError.baseRevisionMismatch(
            expected: policy.baseRevision, actual: copiedRevision)
        }
        let profile = try Self.derivedProfile(
          from: source, workspaceRoot: workspaceRoot,
          projectRef: projectRef, allowedPaths: policy.allowedPaths)
        try profiles.register(profile)
        try Self.write(Manifest(workspace: workspace), to: manifestURL)
        try FileManager.default.createDirectory(
          at: taskRoot.appendingPathComponent("attempts", isDirectory: true),
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        return workspace
      } catch {
        if FileManager.default.fileExists(atPath: temporary.path) {
          try? FileManager.default.removeItem(at: temporary)
        }
        throw error
      }
    }
  }

  public func prepareAttemptDirectory(
    workspace: HarnessEvolutionWorkspace,
    attemptID: String,
    ordinal: Int,
    createdAtUTC: String
  ) async throws {
    try lock.withLock {
      guard WorkspaceProviderSupport.isIdentifier(attemptID), ordinal > 0 else {
        throw EvolutionWorkspaceError.attemptManifestConflict
      }
      let taskRoot = rootURL.appendingPathComponent(workspace.workspaceID, isDirectory: true)
      let workspaceManifest = try JSONDecoder().decode(
        Manifest.self,
        from: Data(contentsOf: taskRoot.appendingPathComponent("workspace.json")))
      guard workspaceManifest.workspace == workspace else {
        throw EvolutionWorkspaceError.workspaceManifestConflict
      }
      let directory = taskRoot.appendingPathComponent("attempts", isDirectory: true)
        .appendingPathComponent(String(format: "attempt-%03d", ordinal), isDirectory: true)
      let manifestURL = directory.appendingPathComponent("attempt.json")
      let manifest = AttemptManifest(
        attemptID: attemptID, ordinal: ordinal,
        workspaceID: workspace.workspaceID, createdAtUTC: createdAtUTC)
      if FileManager.default.fileExists(atPath: manifestURL.path) {
        let stored = try JSONDecoder().decode(
          AttemptManifest.self, from: Data(contentsOf: manifestURL))
        guard stored.attemptID == manifest.attemptID,
          stored.ordinal == manifest.ordinal,
          stored.workspaceID == manifest.workspaceID
        else {
          throw EvolutionWorkspaceError.attemptManifestConflict
        }
        return
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try Self.write(manifest, to: manifestURL)
    }
  }

  private static func derivedProfile(
    from source: WorkspaceProjectProfile,
    workspaceRoot: URL,
    projectRef: String,
    allowedPaths: [String]
  ) throws -> WorkspaceProjectProfile {
    func rebased(_ preset: WorkspaceCommandPreset?) throws -> WorkspaceCommandPreset? {
      guard let preset else { return nil }
      let arguments = preset.fixedArguments.map {
        Self.rebase($0, from: source.projectRoot, to: workspaceRoot.path)
      }
      return try WorkspaceCommandPreset(
        presetID: preset.presetID, executable: preset.executable,
        argumentZero: preset.argumentZero, fixedArguments: arguments,
        timeoutSeconds: preset.timeoutSeconds)
    }
    func rebasedMap(
      _ presets: [String: WorkspaceCommandPreset]
    ) throws -> [String: WorkspaceCommandPreset] {
      try Dictionary(
        uniqueKeysWithValues: presets.map { key, value in
          (key, try rebased(value)!)
        })
    }
    return try WorkspaceProjectProfile(
      profileID: source.profileID, projectRef: projectRef,
      projectRoot: workspaceRoot.path, allowedFileGlobs: allowedPaths,
      inspectionPreset: try rebased(source.inspectionPreset)!,
      // The copied tree is never a source-control authority. No typed
      // operation can push, merge, move a ref or address the primary tree.
      sourceControlPreset: nil,
      sourceReaderPreset: try rebased(source.sourceReaderPreset),
      archiveCheckpointPreset: try rebased(source.archiveCheckpointPreset),
      patchPreset: try rebased(source.patchPreset)!,
      buildPresets: try rebasedMap(source.buildPresets),
      testPresets: try rebasedMap(source.testPresets),
      symbolPresets: try rebasedMap(source.symbolPresets),
      buildProducts: source.buildProducts, kind: .evolution)
  }

  private static func rebase(_ value: String, from source: String, to destination: String) -> String
  {
    if value == source { return destination }
    if value.hasPrefix(source + "/") {
      return destination + value.dropFirst(source.count)
    }
    return value
  }

  private static func copyIsolatedTree(from source: URL, to destination: URL) throws {
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalSource = URL(fileURLWithPath: sourcePath, isDirectory: true)
    let destinationPath = destination.standardizedFileURL.path
    guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
      throw EvolutionWorkspaceError.unsafeSourceEntry("destinationInsideSource")
    }
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard
      let enumerator = FileManager.default.enumerator(
        at: canonicalSource,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [], errorHandler: { _, _ in false })
    else { throw EvolutionWorkspaceError.unsafeSourceEntry("enumerationUnavailable") }
    var enumeratedRootPath: String?
    for case let entry as URL in enumerator {
      if enumeratedRootPath == nil {
        enumeratedRootPath = entry.deletingLastPathComponent().path
      }
      guard let enumeratedRootPath,
        entry.path.hasPrefix(enumeratedRootPath + "/")
      else { throw EvolutionWorkspaceError.unsafeSourceEntry("enumerationEscapedRoot") }
      let relative = String(entry.path.dropFirst(enumeratedRootPath.count + 1))
      if relative == ".build" || relative.hasPrefix(".build/") {
        if relative == ".build" { enumerator.skipDescendants() }
        continue
      }
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      // A Git worktree's `.git` is a pointer file into another checkout.
      // Copying it would make the isolated tree address primary metadata.
      // A self-contained `.git` directory is copied by value and remains
      // unreachable from typed source-control operations in the derived profile.
      if relative == ".git", values.isDirectory != true { continue }
      if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        let resolvedTarget: URL
        if target.hasPrefix("/") {
          resolvedTarget = URL(fileURLWithPath: target)
        } else {
          resolvedTarget = entry.deletingLastPathComponent().appendingPathComponent(target)
        }
        let resolvedPath = resolvedTarget.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == sourcePath || resolvedPath.hasPrefix(sourcePath + "/") else {
          throw EvolutionWorkspaceError.unsafeSourceEntry(relative)
        }
      }
      let output = destination.appendingPathComponent(relative)
      if values.isDirectory == true, values.isSymbolicLink != true {
        try FileManager.default.createDirectory(
          at: output, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } else {
        try FileManager.default.copyItem(at: entry, to: output)
      }
    }
  }

  private static func isNarrower(_ requested: String, thanAny permitted: [String]) -> Bool {
    permitted.contains { parent in
      if requested == parent { return true }
      if parent.hasSuffix("/**") {
        return requested.hasPrefix(String(parent.dropLast(3)) + "/")
      }
      return false
    }
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}
