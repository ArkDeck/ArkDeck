// Isolated Workspace lifecycle for Harness Evolution Mode.
//
// This is deliberately a lifecycle adapter for the existing workspace
// provider. It owns directories and ProjectProfile registration only; all
// build/test/patch effects still travel through RuntimeJobEngine.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckWorkflows
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
  case workspaceAlreadyDestroyed(String)
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

  /// Written once when the isolated tree is destroyed; together with the
  /// surviving workspace and attempt manifests it is the audit record of a
  /// swept workspace.
  private struct TeardownRecord: Codable, Equatable {
    static let currentDocumentType = "evolution-workspace-teardown"
    static let currentSchemaVersion = "1.0.0"

    let documentType: String
    let schemaVersion: String
    let workspaceID: String
    let htaskID: String
    let projectRef: String
    let lifecycle: String
    let destroyedAtUTC: String
    let reclaimedBytes: Int64
    let minimumTerminalAgeSeconds: Int
    let retainLatestTerminalCount: Int
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

  /// Re-registers a workspace this process did not create.
  ///
  /// The tree survives on disk; the identity did not, because registration
  /// only ever happened on the creation path — and a task past its preparation
  /// phase never calls `prepareWorkspace` again. A daemon restart therefore
  /// left `evolution-…` references unresolvable while their files sat intact,
  /// and everything downstream failed naming something else.
  ///
  /// Deliberately not `prepareWorkspace`: preparation re-derives the *source*
  /// revision and refuses when it has moved, which is the right question when
  /// deciding whether to make a copy and the wrong one when deciding whether a
  /// copy that already exists is still itself. Adoption asks only the second.
  public func adoptPersistedWorkspace(
    _ workspace: HarnessEvolutionWorkspace,
    policy: HarnessEvolutionPolicy
  ) async throws {
    try lock.withLock {
      guard let source = profiles.profile(for: workspace.sourceProjectRef),
        source.kind == .primary
      else {
        throw EvolutionWorkspaceError.sourceProfileUnavailable(workspace.sourceProjectRef)
      }
      let taskRoot = rootURL.appendingPathComponent(
        workspace.workspaceID, isDirectory: true)
      let workspaceRoot = taskRoot.appendingPathComponent("workspace", isDirectory: true)
      let manifestURL = taskRoot.appendingPathComponent("workspace.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path),
        let data = try? Data(contentsOf: manifestURL),
        let stored = try? JSONDecoder().decode(Manifest.self, from: data),
        stored.workspace == workspace
      else {
        // Refused, never rebuilt: the caller already holds this reference, so
        // registering a tree the manifest does not describe would substitute
        // one isolated workspace for another underneath it.
        throw EvolutionWorkspaceError.workspaceManifestConflict
      }
      guard FileManager.default.fileExists(atPath: workspaceRoot.path) else {
        // A swept workspace keeps its manifest for audit. Adoption must not
        // bring one back to life.
        if FileManager.default.fileExists(
          atPath: taskRoot.appendingPathComponent("teardown.json").path)
        {
          throw EvolutionWorkspaceError.workspaceAlreadyDestroyed(workspace.workspaceID)
        }
        throw EvolutionWorkspaceError.workspaceManifestConflict
      }
      guard Self.allowedPathsDigest(policy.allowedPaths) == workspace.allowedPathsDigest
      else {
        throw EvolutionWorkspaceError.workspaceManifestConflict
      }
      let profile = try Self.derivedProfile(
        from: source, workspaceRoot: workspaceRoot,
        projectRef: workspace.projectRef, allowedPaths: policy.allowedPaths)
      // `register` is itself fail-loud when the reference already resolves to
      // a different profile, so re-adoption in the same process is a no-op and
      // a disagreement is an error rather than an overwrite.
      try profiles.register(profile)
    }
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
      let allowedDigest = Self.allowedPathsDigest(policy.allowedPaths)
      let workspace = HarnessEvolutionWorkspace(
        workspaceID: workspaceID, htaskID: htaskID,
        sourceProjectRef: sourceProjectRef, projectRef: projectRef,
        baseRevision: policy.baseRevision, allowedPathsDigest: allowedDigest,
        createdAtUTC: createdAtUTC)

      if FileManager.default.fileExists(atPath: manifestURL.path) {
        let stored = try JSONDecoder().decode(
          Manifest.self, from: Data(contentsOf: manifestURL))
        guard stored.workspace == workspace else {
          throw EvolutionWorkspaceError.workspaceManifestConflict
        }
        guard FileManager.default.fileExists(atPath: workspaceRoot.path) else {
          // A swept workspace keeps its manifest for audit. Reopening it is a
          // terminal-task identity being reused, never a recovery path.
          if FileManager.default.fileExists(
            atPath: taskRoot.appendingPathComponent("teardown.json").path)
          {
            throw EvolutionWorkspaceError.workspaceAlreadyDestroyed(workspace.workspaceID)
          }
          throw EvolutionWorkspaceError.workspaceManifestConflict
        }
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

  public func sweepTerminalWorkspaces(
    tasks: [HarnessEvolutionWorkspaceGCTaskReference],
    retention: HarnessEvolutionWorkspaceRetention,
    nowUTC: String
  ) async throws -> [HarnessEvolutionWorkspaceGCFinding] {
    try lock.withLock {
      // A workspaceID the store claims twice is vouched for by nobody.
      var references: [String: HarnessEvolutionWorkspaceGCTaskReference] = [:]
      var conflicted: Set<String> = []
      for task in tasks where references.updateValue(task, forKey: task.workspaceID) != nil {
        conflicted.insert(task.workspaceID)
      }

      struct Candidate {
        let taskRoot: URL
        let reference: HarnessEvolutionWorkspaceGCTaskReference
        let projectRef: String
        let hasMaterial: Bool
      }
      var findings: [HarnessEvolutionWorkspaceGCFinding] = []
      var candidates: [Candidate] = []

      let entries =
        (try? FileManager.default.contentsOfDirectory(
          at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []))
        ?? []
      for entry in entries {
        let name = entry.lastPathComponent
        guard name.hasPrefix("evo-"),
          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { continue }
        guard !conflicted.contains(name),
          let reference = references[name],
          let manifest = try? JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: entry.appendingPathComponent("workspace.json"))),
          manifest.workspace.workspaceID == name,
          manifest.workspace.htaskID == reference.htaskID
        else {
          findings.append(
            HarnessEvolutionWorkspaceGCFinding(
              workspaceID: name, htaskID: references[name]?.htaskID,
              disposition: .unknownTaskRetained, reclaimedBytes: 0))
          continue
        }
        guard reference.lifecycle.isTerminal else {
          findings.append(
            HarnessEvolutionWorkspaceGCFinding(
              workspaceID: name, htaskID: reference.htaskID,
              disposition: .activeRetained, reclaimedBytes: 0))
          continue
        }
        let hasMaterial = Self.destroyableEntries(under: entry)
          .contains { FileManager.default.fileExists(atPath: $0.path) }
        if !hasMaterial,
          FileManager.default.fileExists(
            atPath: entry.appendingPathComponent("teardown.json").path)
        {
          findings.append(
            HarnessEvolutionWorkspaceGCFinding(
              workspaceID: name, htaskID: reference.htaskID,
              disposition: .alreadyDestroyed, reclaimedBytes: 0))
          continue
        }
        candidates.append(
          Candidate(
            taskRoot: entry, reference: reference,
            projectRef: manifest.workspace.projectRef, hasMaterial: hasMaterial))
      }

      // Retention ranks only trees that still exist: an interrupted teardown
      // must not occupy a post-mortem slot it can no longer provide.
      let ranked = candidates.filter(\.hasMaterial).sorted {
        ($0.reference.updatedAtUTC, $0.reference.workspaceID)
          > ($1.reference.updatedAtUTC, $1.reference.workspaceID)
      }
      var retained = Set(
        ranked.prefix(retention.retainLatestTerminalCount).map(\.reference.workspaceID))
      let now = Self.parseUTC(nowUTC)
      for candidate in ranked.dropFirst(retention.retainLatestTerminalCount) {
        guard let now,
          let terminalAt = Self.parseUTC(candidate.reference.updatedAtUTC),
          now.timeIntervalSince(terminalAt)
            >= TimeInterval(retention.minimumTerminalAgeSeconds)
        else {
          // An unreadable clock or timestamp can only fail toward keeping.
          retained.insert(candidate.reference.workspaceID)
          continue
        }
      }

      for candidate in candidates {
        if candidate.hasMaterial, retained.contains(candidate.reference.workspaceID) {
          findings.append(
            HarnessEvolutionWorkspaceGCFinding(
              workspaceID: candidate.reference.workspaceID,
              htaskID: candidate.reference.htaskID,
              disposition: .retainedByPolicy, reclaimedBytes: 0))
          continue
        }
        let reclaimed = Self.measureBytes(Self.destroyableEntries(under: candidate.taskRoot))
        if retention.dryRun {
          findings.append(
            HarnessEvolutionWorkspaceGCFinding(
              workspaceID: candidate.reference.workspaceID,
              htaskID: candidate.reference.htaskID,
              disposition: .wouldDestroy, reclaimedBytes: reclaimed))
          continue
        }
        try Self.destroyIsolatedTree(under: candidate.taskRoot)
        profiles.unregisterEvolutionProfile(projectRef: candidate.projectRef)
        let teardownURL = candidate.taskRoot.appendingPathComponent("teardown.json")
        if !FileManager.default.fileExists(atPath: teardownURL.path) {
          try Self.write(
            TeardownRecord(
              documentType: TeardownRecord.currentDocumentType,
              schemaVersion: TeardownRecord.currentSchemaVersion,
              workspaceID: candidate.reference.workspaceID,
              htaskID: candidate.reference.htaskID,
              projectRef: candidate.projectRef,
              lifecycle: candidate.reference.lifecycle.rawValue,
              destroyedAtUTC: nowUTC,
              reclaimedBytes: reclaimed,
              minimumTerminalAgeSeconds: retention.minimumTerminalAgeSeconds,
              retainLatestTerminalCount: retention.retainLatestTerminalCount),
            to: teardownURL)
        }
        findings.append(
          HarnessEvolutionWorkspaceGCFinding(
            workspaceID: candidate.reference.workspaceID,
            htaskID: candidate.reference.htaskID,
            disposition: .destroyed, reclaimedBytes: reclaimed))
      }

      return findings.sorted { $0.workspaceID < $1.workspaceID }
    }
  }

  /// Everything a sweep may remove under one task root. The workspace
  /// manifest, the attempt manifests and the teardown record are never here.
  private static func destroyableEntries(under taskRoot: URL) -> [URL] {
    [
      taskRoot.appendingPathComponent("workspace", isDirectory: true),
      taskRoot.appendingPathComponent(".workspace.doomed", isDirectory: true),
      taskRoot.appendingPathComponent(".workspace.tmp", isDirectory: true),
    ]
  }

  private static func destroyIsolatedTree(under taskRoot: URL) throws {
    let workspaceRoot = taskRoot.appendingPathComponent("workspace", isDirectory: true)
    let doomed = taskRoot.appendingPathComponent(".workspace.doomed", isDirectory: true)
    // The rename makes the tree disappear from its addressable path first, so
    // a crash mid-removal leaves a resumable `.workspace.doomed`, never a
    // half-deleted `workspace/` that still looks reopenable.
    if FileManager.default.fileExists(atPath: workspaceRoot.path) {
      if FileManager.default.fileExists(atPath: doomed.path) {
        try FileManager.default.removeItem(at: doomed)
      }
      try FileManager.default.moveItem(at: workspaceRoot, to: doomed)
    }
    for entry in destroyableEntries(under: taskRoot)
    where FileManager.default.fileExists(atPath: entry.path) {
      try FileManager.default.removeItem(at: entry)
    }
  }

  private static func measureBytes(_ entries: [URL]) -> Int64 {
    var total: Int64 = 0
    for entry in entries {
      guard FileManager.default.fileExists(atPath: entry.path) else { continue }
      guard
        let enumerator = FileManager.default.enumerator(
          at: entry, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
          options: [], errorHandler: { _, _ in true })
      else { continue }
      for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
      }
    }
    return total
  }

  private static func parseUTC(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  /// One definition, shared by creation and adoption: two copies of this
  /// would drift and adoption would start accepting workspaces whose scope it
  /// no longer actually matches.
  static func allowedPathsDigest(_ allowedPaths: [String]) -> String {
    WorkspaceProviderSupport.sha256(
      Data(allowedPaths.sorted().joined(separator: "\n").utf8))
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
