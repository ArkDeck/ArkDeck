// Isolated workspace lifecycle for Runtime-owned evolution copies.
//
// This is deliberately a lifecycle adapter for the existing workspace
// provider. It owns directories and ProjectProfile registration only; all
// build/test/patch effects still travel through RuntimeJobEngine.

import ArkDeckCore
import ArkDeckWorkflows
import CryptoKit
import Darwin
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

package final class EvolutionWorkspaceManager: EvolutionWorkspacePort,
  WorkspaceIsolationManaging, @unchecked Sendable
{
  private struct Manifest: Codable, Equatable {
    let workspace: EvolutionWorkspaceRecord
    /// Present on manifests written by the current implementation. Keeping it
    /// optional preserves exact decoding of older manifests from the removed
    /// in-process task plane, whose task record supplied the policy instead.
    let allowedPaths: [String]?

    init(workspace: EvolutionWorkspaceRecord, allowedPaths: [String]? = nil) {
      self.workspace = workspace
      self.allowedPaths = allowedPaths?.sorted()
    }
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
  private let patchLineage: (any WorkspacePatchLineageReading)?
  private let lock = NSLock()

  public init(
    rootURL: URL,
    profileRegistry: WorkspaceProjectProfileRegistry,
    patchLineage: (any WorkspacePatchLineageReading)? = nil
  ) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.profiles = profileRegistry
    self.patchLineage = patchLineage
    try FileManager.default.createDirectory(
      at: self.rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  /// Folds the durable patch lineage into the revision the tree should
  /// measure right now. `nil` means the chain cannot vouch — a broken link,
  /// a fork, or a record whose `before` does not extend the current state —
  /// and adoption must keep its named refusal (RWL-REQ-001).
  package static func lineageDerivedRevision(
    base: String, attempts: [WorkspacePatchAttempt]
  ) -> String? {
    var current = base
    for attempt in attempts.sorted(by: { $0.appliedAtUTC < $1.appliedAtUTC }) {
      guard let before = attempt.workspaceRevisionBefore,
        let after = attempt.workspaceRevisionAfter,
        before == current
      else { return nil }
      // A reverted attempt restored `before`, which is already `current`;
      // an applied one advanced the tree to `after`.
      if attempt.revertedAtUTC == nil { current = after }
    }
    return current
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
  package func adoptPersistedWorkspace(
    _ workspace: EvolutionWorkspaceRecord,
    policy: EvolutionWorkspacePolicy
  ) async throws {
    try lock.withLock {
      guard let source = profiles.profile(for: workspace.sourceProjectRef),
        source.kind == .primary
      else {
        throw EvolutionWorkspaceError.sourceProfileUnavailable(workspace.sourceProjectRef)
      }
      let taskRoot = rootURL.appending(
        path:
          workspace.workspaceID, directoryHint: .isDirectory)
      let workspaceRoot = taskRoot.appending(path: "workspace", directoryHint: .isDirectory)
      let manifestURL = taskRoot.appending(path: "workspace.json")
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
          atPath: taskRoot.appending(path: "teardown.json").path)
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

  package func prepareWorkspace(
    htaskID: String,
    sourceProjectRef: String,
    policy: EvolutionWorkspacePolicy,
    createdAtUTC: String
  ) async throws -> EvolutionWorkspaceRecord {
    try await prepareWorkspaceBound(
      htaskID: htaskID,
      sourceProjectRef: sourceProjectRef,
      policy: policy,
      expectedSourceRevision: nil,
      createdAtUTC: createdAtUTC)
  }

  private func prepareWorkspaceBound(
    htaskID: String,
    sourceProjectRef: String,
    policy: EvolutionWorkspacePolicy,
    expectedSourceRevision: String?,
    createdAtUTC: String
  ) async throws -> EvolutionWorkspaceRecord {
    try lock.withLock {
      guard WorkspaceProviderSupport.isIdentifier(htaskID) else {
        throw EvolutionWorkspaceError.malformedTaskID
      }
      guard let source = profiles.profile(for: sourceProjectRef), source.kind == .primary else {
        throw EvolutionWorkspaceError.sourceProfileUnavailable(sourceProjectRef)
      }
      if let expectedSourceRevision {
        let actualSourceRevision = try WorkspaceProviderSupport.workspaceRevision(
          root: source.projectRoot, profileVersion: source.profileID,
          globs: source.allowedFileGlobs)
        guard actualSourceRevision == expectedSourceRevision else {
          throw EvolutionWorkspaceError.baseRevisionMismatch(
            expected: expectedSourceRevision, actual: actualSourceRevision)
        }
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
      let digest = SHA256Hex.string(of: seed)
      let workspaceID = "evo-\(digest.prefix(24))"
      let projectRef = "evolution-\(digest.prefix(20))"
      let taskRoot = rootURL.appending(path: workspaceID, directoryHint: .isDirectory)
      let workspaceRoot = taskRoot.appending(path: "workspace", directoryHint: .isDirectory)
      let manifestURL = taskRoot.appending(path: "workspace.json")
      let allowedDigest = Self.allowedPathsDigest(policy.allowedPaths)
      let workspace = EvolutionWorkspaceRecord(
        workspaceID: workspaceID, htaskID: htaskID,
        sourceProjectRef: sourceProjectRef, projectRef: projectRef,
        baseRevision: policy.baseRevision, allowedPathsDigest: allowedDigest,
        createdAtUTC: createdAtUTC)

      if FileManager.default.fileExists(atPath: manifestURL.path) {
        let stored = try JSONDecoder().decode(
          Manifest.self, from: Data(contentsOf: manifestURL))
        guard stored.workspace == workspace,
          stored.allowedPaths == nil || stored.allowedPaths == policy.allowedPaths.sorted()
        else {
          throw EvolutionWorkspaceError.workspaceManifestConflict
        }
        guard FileManager.default.fileExists(atPath: workspaceRoot.path) else {
          // A swept workspace keeps its manifest for audit. Reopening it is a
          // terminal-task identity being reused, never a recovery path.
          if FileManager.default.fileExists(
            atPath: taskRoot.appending(path: "teardown.json").path)
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
      let temporary = taskRoot.appending(path: ".workspace.tmp", directoryHint: .isDirectory)
      do {
        try Self.copyIsolatedTree(
          from: URL(filePath: source.projectRoot, directoryHint: .isDirectory),
          to: temporary)
        try FileManager.default.moveItem(at: temporary, to: workspaceRoot)
        let copiedRevision = try WorkspaceProviderSupport.workspaceRevision(
          root: workspaceRoot.path, profileVersion: source.profileID,
          globs: policy.allowedPaths)
        guard copiedRevision == policy.baseRevision else {
          throw EvolutionWorkspaceError.baseRevisionMismatch(
            expected: policy.baseRevision, actual: copiedRevision)
        }
        if let expectedSourceRevision {
          let copiedSourceRevision = try WorkspaceProviderSupport.workspaceRevision(
            root: workspaceRoot.path, profileVersion: source.profileID,
            globs: source.allowedFileGlobs)
          guard copiedSourceRevision == expectedSourceRevision else {
            throw EvolutionWorkspaceError.baseRevisionMismatch(
              expected: expectedSourceRevision, actual: copiedSourceRevision)
          }
        }
        let profile = try Self.derivedProfile(
          from: source, workspaceRoot: workspaceRoot,
          projectRef: projectRef, allowedPaths: policy.allowedPaths)
        try profiles.register(profile)
        try Self.write(
          Manifest(workspace: workspace, allowedPaths: policy.allowedPaths),
          to: manifestURL)
        try FileManager.default.createDirectory(
          at: taskRoot.appending(path: "attempts", directoryHint: .isDirectory),
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

  package func prepare(_ intent: WorkspaceIsolationIntent) async throws
    -> WorkspaceIsolationResult
  {
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: intent.isolatedWorkspaceRevision,
      allowedPaths: intent.allowedFileGlobs,
      maxAttempts: 1,
      maxChangedFiles: min(intent.allowedFileGlobs.count, 64),
      maxDiffLines: 100_000,
      allowedOperations: [
        "workspace.apply-patch@1",
        "workspace.build-openharmony@1",
        "workspace.run-tests@1",
        "workspace.revert-patch@1",
      ])
    let workspace = try await prepareWorkspaceBound(
      htaskID: intent.runtimeOwnerID,
      sourceProjectRef: intent.sourceProjectRef,
      policy: policy,
      expectedSourceRevision: intent.expectedWorkspaceRevision,
      createdAtUTC: intent.createdAtUTC)
    guard workspace.workspaceID == intent.workspaceID,
      workspace.projectRef == intent.workspaceProjectRef,
      workspace.allowedPathsDigest == intent.allowedFileScopesDigest
    else {
      throw EvolutionWorkspaceError.workspaceManifestConflict
    }
    guard case .prepared(let result) = try inspect(intent) else {
      throw EvolutionWorkspaceError.workspaceManifestConflict
    }
    return result
  }

  package func inspect(
    _ intent: WorkspaceIsolationIntent
  ) throws -> WorkspaceIsolationInspection {
    lock.withLock {
      let taskRoot = rootURL.appending(
        path: intent.workspaceID, directoryHint: .isDirectory)
      let manifestURL = taskRoot.appending(path: "workspace.json")
      let workspaceRoot = taskRoot.appending(
        path: "workspace", directoryHint: .isDirectory)
      let anyMaterial = FileManager.default.fileExists(atPath: taskRoot.path)
      guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        return anyMaterial ? .conflicted("workspace isolation manifest is absent") : .absent
      }
      let stored: Manifest
      do {
        stored = try JSONDecoder().decode(
          Manifest.self, from: Data(contentsOf: manifestURL))
      } catch {
        return .conflicted("workspace isolation manifest is unreadable")
      }
      guard stored.workspace.workspaceID == intent.workspaceID,
        stored.workspace.htaskID == intent.runtimeOwnerID,
        stored.workspace.sourceProjectRef == intent.sourceProjectRef,
        stored.workspace.projectRef == intent.workspaceProjectRef,
        stored.workspace.baseRevision == intent.isolatedWorkspaceRevision,
        stored.workspace.allowedPathsDigest == intent.allowedFileScopesDigest,
        stored.allowedPaths == intent.allowedFileGlobs.sorted(),
        FileManager.default.fileExists(atPath: workspaceRoot.path),
        let source = profiles.profile(for: intent.sourceProjectRef),
        source.kind == .primary
      else {
        return .conflicted("workspace isolation identity disagrees with its typed action")
      }
      let revision: String
      do {
        revision = try WorkspaceProviderSupport.workspaceRevision(
          root: workspaceRoot.path, profileVersion: source.profileID,
          globs: intent.allowedFileGlobs)
        guard revision == intent.isolatedWorkspaceRevision else {
          return .conflicted("workspace isolation copied revision drifted")
        }
        let profile = try Self.derivedProfile(
          from: source, workspaceRoot: workspaceRoot,
          projectRef: intent.workspaceProjectRef,
          allowedPaths: intent.allowedFileGlobs)
        try profiles.register(profile)
      } catch {
        return .conflicted("workspace isolation cannot be revalidated")
      }
      return .prepared(
        WorkspaceIsolationResult(
          workspaceID: intent.workspaceID,
          projectRef: intent.workspaceProjectRef,
          sourceProjectRef: intent.sourceProjectRef,
          sourceWorkspaceRevision: intent.expectedWorkspaceRevision,
          workspaceRevision: revision,
          allowedFileScopesDigest: intent.allowedFileScopesDigest))
    }
  }

  /// Daemon startup adoption for Runtime-owned copies. Copies made by the
  /// removed in-process task plane carried their policy in task records;
  /// these copies have no such record, so their complete narrowing policy
  /// lives in the versioned manifest instead.
  /// One read-only row per persisted Runtime-owned workspace, with the same
  /// vouching the adoption path applies (metadata, scopes, base-or-lineage
  /// revision). The sweep dispatcher composes testimony only for vouched
  /// rows; everything else stays untouched by construction (RWL-REQ-003).
  package struct RuntimeWorkspaceInventoryEntry: Sendable, Equatable {
    package let workspaceID: String
    package let runtimeOwnerID: String
    package let derivedProjectRef: String
    package let createdAtUTC: String
    package let vouched: Bool
  }

  package func runtimeWorkspaceInventory() -> [RuntimeWorkspaceInventoryEntry] {
    lock.withLock {
      let entries =
        (try? FileManager.default.contentsOfDirectory(
          at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []))
        ?? []
      guard entries.count <= 4_096 else { return [] }
      var inventory: [RuntimeWorkspaceInventoryEntry] = []
      for enumerated in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let entry = rootURL.appending(
          path: enumerated.lastPathComponent, directoryHint: .isDirectory)
        let manifestURL = entry.appending(path: "workspace.json")
        guard let data = try? Data(contentsOf: manifestURL),
          let stored = try? JSONDecoder().decode(Manifest.self, from: data),
          stored.workspace.htaskID.hasPrefix("runtime-")
        else { continue }
        var vouched = false
        if let allowedPaths = stored.allowedPaths,
          let source = profiles.profile(for: stored.workspace.sourceProjectRef),
          source.kind == .primary,
          Self.allowedPathsDigest(allowedPaths) == stored.workspace.allowedPathsDigest,
          let revision = try? WorkspaceProviderSupport.workspaceRevision(
            root: entry.appending(path: "workspace", directoryHint: .isDirectory).path,
            profileVersion: source.profileID, globs: allowedPaths)
        {
          // Same acceptance as adoption: the base vouches for an unpatched
          // tree, the durable patch lineage for every revision it derives.
          if revision == stored.workspace.baseRevision {
            vouched = true
          } else if let lineage = patchLineage,
            let derived =
              (try? lineage.patchAttempts(forProjectRef: stored.workspace.projectRef))
              .flatMap({
                Self.lineageDerivedRevision(
                  base: stored.workspace.baseRevision, attempts: $0)
              }),
            derived == revision
          {
            vouched = true
          }
        }
        inventory.append(
          RuntimeWorkspaceInventoryEntry(
            workspaceID: stored.workspace.workspaceID,
            runtimeOwnerID: stored.workspace.htaskID,
            derivedProjectRef: stored.workspace.projectRef,
            createdAtUTC: stored.workspace.createdAtUTC,
            vouched: vouched))
      }
      return inventory
    }
  }

  package func adoptRuntimeWorkspaces() -> [String] {
    lock.withLock {
      let entries =
        (try? FileManager.default.contentsOfDirectory(
          at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []))
        ?? []
      guard entries.count <= 4_096 else {
        return ["runtime workspace entry bound exceeded"]
      }
      var failures: [String] = []
      for enumerated in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        // FileManager may canonicalize `/var` to `/private/var` (and `/tmp`
        // likewise) while enumerating. Workspace revisions are intentionally
        // relative to the configured namespace, so re-anchor the trusted leaf
        // name below the same root URL used during creation.
        let entry = rootURL.appending(
          path: enumerated.lastPathComponent, directoryHint: .isDirectory)
        let manifestURL = entry.appending(path: "workspace.json")
        guard let data = try? Data(contentsOf: manifestURL),
          let stored = try? JSONDecoder().decode(Manifest.self, from: data),
          stored.workspace.htaskID.hasPrefix("runtime-")
        else { continue }
        guard let allowedPaths = stored.allowedPaths,
          let source = profiles.profile(for: stored.workspace.sourceProjectRef),
          source.kind == .primary
        else {
          failures.append("\(stored.workspace.workspaceID):metadata")
          continue
        }
        let workspaceRoot = entry.appending(path: "workspace", directoryHint: .isDirectory)
        do {
          let revision = try WorkspaceProviderSupport.workspaceRevision(
            root: workspaceRoot.path, profileVersion: source.profileID,
            globs: allowedPaths)
          // The base revision vouches for an unpatched tree; the durable
          // patch lineage vouches for every revision it derives from that
          // base. Anything else — including a lineage the store cannot read —
          // keeps the named refusal (RWL-REQ-001).
          let lineageDerived: String? =
            revision == stored.workspace.baseRevision
            ? revision
            : patchLineage.flatMap { lineage in
              (try? lineage.patchAttempts(forProjectRef: stored.workspace.projectRef))
                .flatMap {
                  Self.lineageDerivedRevision(
                    base: stored.workspace.baseRevision, attempts: $0)
                }
            }
          guard lineageDerived == revision else {
            failures.append("\(stored.workspace.workspaceID):revision")
            continue
          }
          guard Self.allowedPathsDigest(allowedPaths) == stored.workspace.allowedPathsDigest else {
            failures.append("\(stored.workspace.workspaceID):scopes")
            continue
          }
          try profiles.register(
            Self.derivedProfile(
              from: source, workspaceRoot: workspaceRoot,
              projectRef: stored.workspace.projectRef,
              allowedPaths: allowedPaths))
        } catch {
          failures.append("\(stored.workspace.workspaceID):profile")
        }
      }
      return failures
    }
  }

  package func prepareAttemptDirectory(
    workspace: EvolutionWorkspaceRecord,
    attemptID: String,
    ordinal: Int,
    createdAtUTC: String
  ) async throws {
    try lock.withLock {
      guard WorkspaceProviderSupport.isIdentifier(attemptID), ordinal > 0 else {
        throw EvolutionWorkspaceError.attemptManifestConflict
      }
      let taskRoot = rootURL.appending(path: workspace.workspaceID, directoryHint: .isDirectory)
      let workspaceManifest = try JSONDecoder().decode(
        Manifest.self,
        from: Data(contentsOf: taskRoot.appending(path: "workspace.json")))
      guard workspaceManifest.workspace == workspace else {
        throw EvolutionWorkspaceError.workspaceManifestConflict
      }
      let directory = taskRoot.appending(path: "attempts", directoryHint: .isDirectory)
        .appending(path: String(format: "attempt-%03d", ordinal), directoryHint: .isDirectory)
      let manifestURL = directory.appending(path: "attempt.json")
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

  package func sweepTerminalWorkspaces(
    tasks: [EvolutionWorkspaceGCTaskReference],
    retention: EvolutionWorkspaceRetention,
    nowUTC: String
  ) async throws -> [EvolutionWorkspaceGCFinding] {
    try lock.withLock {
      // A workspaceID the store claims twice is vouched for by nobody.
      var references: [String: EvolutionWorkspaceGCTaskReference] = [:]
      var conflicted: Set<String> = []
      for task in tasks where references.updateValue(task, forKey: task.workspaceID) != nil {
        conflicted.insert(task.workspaceID)
      }

      struct Candidate {
        let taskRoot: URL
        let reference: EvolutionWorkspaceGCTaskReference
        let projectRef: String
        let hasMaterial: Bool
      }
      var findings: [EvolutionWorkspaceGCFinding] = []
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
            from: Data(contentsOf: entry.appending(path: "workspace.json"))),
          manifest.workspace.workspaceID == name,
          manifest.workspace.htaskID == reference.htaskID
        else {
          findings.append(
            EvolutionWorkspaceGCFinding(
              workspaceID: name, htaskID: references[name]?.htaskID,
              disposition: .unknownTaskRetained, reclaimedBytes: 0))
          continue
        }
        guard reference.lifecycle.isTerminal else {
          findings.append(
            EvolutionWorkspaceGCFinding(
              workspaceID: name, htaskID: reference.htaskID,
              disposition: .activeRetained, reclaimedBytes: 0))
          continue
        }
        let hasMaterial = Self.destroyableEntries(under: entry)
          .contains { FileManager.default.fileExists(atPath: $0.path) }
        if !hasMaterial,
          FileManager.default.fileExists(
            atPath: entry.appending(path: "teardown.json").path)
        {
          findings.append(
            EvolutionWorkspaceGCFinding(
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
            EvolutionWorkspaceGCFinding(
              workspaceID: candidate.reference.workspaceID,
              htaskID: candidate.reference.htaskID,
              disposition: .retainedByPolicy, reclaimedBytes: 0))
          continue
        }
        let reclaimed = Self.measureBytes(Self.destroyableEntries(under: candidate.taskRoot))
        if retention.dryRun {
          findings.append(
            EvolutionWorkspaceGCFinding(
              workspaceID: candidate.reference.workspaceID,
              htaskID: candidate.reference.htaskID,
              disposition: .wouldDestroy, reclaimedBytes: reclaimed))
          continue
        }
        try Self.destroyIsolatedTree(under: candidate.taskRoot)
        profiles.unregisterEvolutionProfile(projectRef: candidate.projectRef)
        let teardownURL = candidate.taskRoot.appending(path: "teardown.json")
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
          EvolutionWorkspaceGCFinding(
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
      taskRoot.appending(path: "workspace", directoryHint: .isDirectory),
      taskRoot.appending(path: ".workspace.doomed", directoryHint: .isDirectory),
      taskRoot.appending(path: ".workspace.tmp", directoryHint: .isDirectory),
    ]
  }

  private static func destroyIsolatedTree(under taskRoot: URL) throws {
    let workspaceRoot = taskRoot.appending(path: "workspace", directoryHint: .isDirectory)
    let doomed = taskRoot.appending(path: ".workspace.doomed", directoryHint: .isDirectory)
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
    ISO8601Timestamps.parse(value)
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
    let maximumEntries = 100_000
    let maximumFileBytes: Int64 = 512 * 1_024 * 1_024
    let maximumTreeBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    let maximumRelativePathBytes = 4_096
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalSource = URL(filePath: sourcePath, directoryHint: .isDirectory)
    let destinationParent = destination.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL
    let canonicalDestination = destinationParent.appending(
      path: destination.lastPathComponent, directoryHint: .isDirectory)
    let destinationPath = canonicalDestination.path
    guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
      throw EvolutionWorkspaceError.unsafeSourceEntry("destinationInsideSource")
    }
    try FileManager.default.createDirectory(
      at: canonicalDestination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var enumerationFailed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: canonicalSource,
        includingPropertiesForKeys: [
          .fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ],
        options: [],
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        })
    else { throw EvolutionWorkspaceError.unsafeSourceEntry("enumerationUnavailable") }
    var enumeratedRootPath: String?
    var entryCount = 0
    var totalBytes: Int64 = 0
    for case let entry as URL in enumerator {
      try Task.checkCancellation()
      entryCount += 1
      guard entryCount <= maximumEntries else {
        throw EvolutionWorkspaceError.unsafeSourceEntry("entryCountExceeded")
      }
      if enumeratedRootPath == nil {
        enumeratedRootPath = entry.deletingLastPathComponent().path
      }
      guard let enumeratedRootPath,
        entry.path.hasPrefix(enumeratedRootPath + "/")
      else { throw EvolutionWorkspaceError.unsafeSourceEntry("enumerationEscapedRoot") }
      let relative = String(entry.path.dropFirst(enumeratedRootPath.count + 1))
      guard !relative.isEmpty, relative.utf8.count <= maximumRelativePathBytes else {
        throw EvolutionWorkspaceError.unsafeSourceEntry("relativePathExceeded")
      }
      if relative == ".build" || relative.hasPrefix(".build/") {
        if relative == ".build" { enumerator.skipDescendants() }
        continue
      }
      let values = try entry.resourceValues(forKeys: [
        .fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      // A Git worktree's `.git` is a pointer file into another checkout.
      // Copying it would make the isolated tree address primary metadata.
      // A self-contained `.git` directory is copied by value and remains
      // unreachable from typed source-control operations in the derived profile.
      if relative == ".git", values.isDirectory != true { continue }
      if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        // Absolute and relative targets are admitted by one criterion: the
        // resolved destination must stay inside the source tree. An admitted
        // absolute target is rewritten to a relative one when the link is
        // recreated below, so the copy never addresses the primary tree.
        let resolvedTarget =
          target.hasPrefix("/")
          ? URL(filePath: target)
          : entry.deletingLastPathComponent().appending(path: target)
        let resolvedPath = resolvedTarget.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == sourcePath || resolvedPath.hasPrefix(sourcePath + "/") else {
          throw EvolutionWorkspaceError.unsafeSourceEntry(relative)
        }
      }
      let output = canonicalDestination.appending(path: relative)
      if values.isDirectory == true, values.isSymbolicLink != true {
        try FileManager.default.createDirectory(
          at: output, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } else if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        let destinationTarget: String
        if target.hasPrefix("/") {
          let resolvedPath = URL(filePath: target)
            .resolvingSymlinksInPath().standardizedFileURL.path
          let treeRelativeTarget =
            resolvedPath == sourcePath
            ? "" : String(resolvedPath.dropFirst(sourcePath.count + 1))
          destinationTarget = Self.relativeLinkTarget(
            fromLinkAt: relative, toTreeRelativeTarget: treeRelativeTarget)
        } else {
          destinationTarget = target
        }
        try FileManager.default.createSymbolicLink(
          atPath: output.path, withDestinationPath: destinationTarget)
      } else if values.isRegularFile == true {
        let copiedBytes = try copyBoundedRegularFile(
          from: entry, to: output, maximumBytes: maximumFileBytes)
        let (nextTotal, overflow) = totalBytes.addingReportingOverflow(copiedBytes)
        guard !overflow, nextTotal <= maximumTreeBytes else {
          throw EvolutionWorkspaceError.unsafeSourceEntry("treeBytesExceeded")
        }
        totalBytes = nextTotal
      } else {
        throw EvolutionWorkspaceError.unsafeSourceEntry(relative)
      }
    }
    guard !enumerationFailed else {
      throw EvolutionWorkspaceError.unsafeSourceEntry("enumerationFailed")
    }
  }

  /// Relative link target from the directory holding `linkRelativePath` to
  /// `treeRelativeTarget`; both inputs are tree-root-relative. The rewritten
  /// link keeps the isolated copy self-contained wherever it lives on disk.
  private static func relativeLinkTarget(
    fromLinkAt linkRelativePath: String, toTreeRelativeTarget treeRelativeTarget: String
  ) -> String {
    let linkDirectory = linkRelativePath.split(separator: "/").dropLast()
    let target = treeRelativeTarget.split(separator: "/")
    var shared = 0
    while shared < linkDirectory.count, shared < target.count,
      linkDirectory[shared] == target[shared]
    { shared += 1 }
    let climbs = Array(repeating: "..", count: linkDirectory.count - shared)
    let descents = target.dropFirst(shared).map(String.init)
    let components = climbs + descents
    return components.isEmpty ? "." : components.joined(separator: "/")
  }

  private static func copyBoundedRegularFile(
    from source: URL, to destination: URL, maximumBytes: Int64
  ) throws -> Int64 {
    let sourceDescriptor = Darwin.open(
      source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard sourceDescriptor >= 0 else {
      throw EvolutionWorkspaceError.unsafeSourceEntry(source.lastPathComponent)
    }
    defer { Darwin.close(sourceDescriptor) }
    var initial = stat()
    guard Darwin.fstat(sourceDescriptor, &initial) == 0,
      (initial.st_mode & S_IFMT) == S_IFREG,
      initial.st_size >= 0, initial.st_size <= maximumBytes
    else {
      throw EvolutionWorkspaceError.unsafeSourceEntry(source.lastPathComponent)
    }

    let mode = mode_t(initial.st_mode & 0o777)
    let destinationDescriptor = Darwin.open(
      destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
    guard destinationDescriptor >= 0 else {
      throw EvolutionWorkspaceError.unsafeSourceEntry(destination.lastPathComponent)
    }
    defer { Darwin.close(destinationDescriptor) }

    var remaining = initial.st_size
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while remaining > 0 {
      try Task.checkCancellation()
      let requested = min(buffer.count, Int(remaining))
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(sourceDescriptor, $0.baseAddress, requested)
      }
      guard readCount > 0 else {
        throw EvolutionWorkspaceError.unsafeSourceEntry(source.lastPathComponent)
      }
      var written = 0
      while written < readCount {
        let writeCount = buffer.withUnsafeBytes {
          Darwin.write(
            destinationDescriptor, $0.baseAddress?.advanced(by: written), readCount - written)
        }
        guard writeCount > 0 else {
          throw EvolutionWorkspaceError.unsafeSourceEntry(destination.lastPathComponent)
        }
        written += writeCount
      }
      remaining -= Int64(readCount)
    }
    var extra: UInt8 = 0
    guard Darwin.read(sourceDescriptor, &extra, 1) == 0 else {
      throw EvolutionWorkspaceError.unsafeSourceEntry(source.lastPathComponent)
    }
    var final = stat()
    guard Darwin.fstat(sourceDescriptor, &final) == 0,
      final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
      final.st_mode == initial.st_mode, final.st_size == initial.st_size,
      final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
      final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
      Darwin.fchmod(destinationDescriptor, mode) == 0
    else {
      throw EvolutionWorkspaceError.unsafeSourceEntry(source.lastPathComponent)
    }
    return initial.st_size
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
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}
