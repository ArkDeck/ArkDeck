// Evolution workspace domain model.
//
// The typed facts behind Runtime-owned isolated workspaces: the policy that
// narrows a source profile, the durable record of one isolated tree, the port
// the manager implements, and the retention/GC vocabulary for sweeping
// terminal trees. Decisions come from external agents through the published
// caller surface (CHG-2026-064); none of these types can execute a command,
// push a branch or merge code.

import ArkDeckCore
import CryptoKit
import Foundation

package enum EvolutionWorkspacePolicyError: Error, Equatable, Sendable {
  case invalidBaseRevision
  case emptyAllowedPaths
  case unsafeAllowedPath(String)
  case invalidBudget(String)
  case emptyAllowedOperations
  case unknownOperation(String)
  case destructiveOperationNotAllowed(String)
  case operationOutsideTaskPolicy(String)
  case invalidCandidate(String)
  case candidateBaseRevisionMismatch
  case tooManyChangedFiles(actual: Int, limit: Int)
  case diffLineBudgetExceeded(actual: Int, limit: Int)
  case pathOutsideScope(String)
}

/// The exploration envelope.  It narrows an existing task policy; it is not
/// a RuntimeCapability and can never authorize a device effect by itself.
package struct EvolutionWorkspacePolicy: Equatable, Codable, Sendable {
  package let baseRevision: String
  package let allowedPaths: [String]
  package let maxAttempts: Int
  package let maxChangedFiles: Int
  package let maxDiffLines: Int
  package let allowedOperations: [String]

  private enum CodingKeys: String, CodingKey {
    case baseRevision
    case allowedPaths
    case maxAttempts
    case maxChangedFiles
    case maxDiffLines
    case allowedOperations
  }

  package init(
    baseRevision: String,
    allowedPaths: [String],
    maxAttempts: Int = 20,
    maxChangedFiles: Int = 20,
    maxDiffLines: Int = 2_000,
    allowedOperations: [String]
  ) throws {
    guard Self.isSHA256(baseRevision) else {
      throw EvolutionWorkspacePolicyError.invalidBaseRevision
    }
    let normalizedPaths = Array(Set(allowedPaths)).sorted()
    guard !normalizedPaths.isEmpty else {
      throw EvolutionWorkspacePolicyError.emptyAllowedPaths
    }
    for path in normalizedPaths where !Self.isSafeScope(path) {
      throw EvolutionWorkspacePolicyError.unsafeAllowedPath(path)
    }
    guard (1...64).contains(maxAttempts) else {
      throw EvolutionWorkspacePolicyError.invalidBudget("maxAttempts")
    }
    guard (1...64).contains(maxChangedFiles) else {
      throw EvolutionWorkspacePolicyError.invalidBudget("maxChangedFiles")
    }
    guard (1...100_000).contains(maxDiffLines) else {
      throw EvolutionWorkspacePolicyError.invalidBudget("maxDiffLines")
    }
    let normalizedOperations = Array(Set(allowedOperations)).sorted()
    guard !normalizedOperations.isEmpty else {
      throw EvolutionWorkspacePolicyError.emptyAllowedOperations
    }
    for operation in normalizedOperations {
      guard let descriptor = RuntimeOperationCatalog.descriptor(reference: operation) else {
        throw EvolutionWorkspacePolicyError.unknownOperation(operation)
      }
      guard descriptor.minimumEffect != .destructive,
        !descriptor.permittedEffects.contains(.destructive)
      else {
        throw EvolutionWorkspacePolicyError.destructiveOperationNotAllowed(operation)
      }
    }
    self.baseRevision = baseRevision
    self.allowedPaths = normalizedPaths
    self.maxAttempts = maxAttempts
    self.maxChangedFiles = maxChangedFiles
    self.maxDiffLines = maxDiffLines
    self.allowedOperations = normalizedOperations
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      baseRevision: container.decode(String.self, forKey: .baseRevision),
      allowedPaths: container.decode([String].self, forKey: .allowedPaths),
      maxAttempts: container.decode(Int.self, forKey: .maxAttempts),
      maxChangedFiles: container.decode(Int.self, forKey: .maxChangedFiles),
      maxDiffLines: container.decode(Int.self, forKey: .maxDiffLines),
      allowedOperations: container.decode([String].self, forKey: .allowedOperations))
  }

  /// Closed, intentionally small glob matcher: `*` stays within a component
  /// and `**` may cross `/`.  Requests cannot use character classes or path
  /// traversal, so policy matching does not accidentally acquire filesystem
  /// semantics from Foundation or the host shell.
  package static func matches(_ path: String, _ pattern: String) -> Bool {
    guard isSafeRelativePath(path), isSafeScope(pattern) else { return false }
    var expression = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      if character == "*" {
        let next = pattern.index(after: index)
        if next < pattern.endIndex, pattern[next] == "*" {
          expression += ".*"
          index = pattern.index(after: next)
        } else {
          expression += "[^/]*"
          index = next
        }
        continue
      }
      if character == "?" {
        expression += "[^/]"
      } else {
        expression += NSRegularExpression.escapedPattern(for: String(character))
      }
      index = pattern.index(after: index)
    }
    expression += "$"
    return path.range(of: expression, options: .regularExpression) != nil
  }

  private static func isSafeScope(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("/"),
      !value.contains("\\"), !value.contains("[") && !value.contains("]"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return false }
    let literal = value.replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "?", with: "")
    let components = literal.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains(where: { $0 == "." || $0 == ".." })
      && value != ".git" && !value.hasPrefix(".git/") && !value.contains("/.git/")
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
      !value.contains(where: { "*?[]".contains($0) })
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      && value != ".git" && !value.hasPrefix(".git/") && !value.contains("/.git/")
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private static func isArtifactIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:@-".contains($0))
      }
  }
}

/// Opaque reference to a provider-owned isolated tree.  The host path never
/// enters task JSON or model context.
package struct EvolutionWorkspaceRecord: Equatable, Codable, Sendable {
  package let workspaceID: String
  package let htaskID: String
  package let sourceProjectRef: String
  package let projectRef: String
  package let baseRevision: String
  package let allowedPathsDigest: String
  package let createdAtUTC: String

  package init(
    workspaceID: String,
    htaskID: String,
    sourceProjectRef: String,
    projectRef: String,
    baseRevision: String,
    allowedPathsDigest: String,
    createdAtUTC: String
  ) {
    self.workspaceID = workspaceID
    self.htaskID = htaskID
    self.sourceProjectRef = sourceProjectRef
    self.projectRef = projectRef
    self.baseRevision = baseRevision
    self.allowedPathsDigest = allowedPathsDigest
    self.createdAtUTC = createdAtUTC
  }
}

package protocol EvolutionWorkspacePort: Sendable {
  /// Creates or idempotently reopens the task-owned isolated tree and returns
  /// only its opaque provider reference.  It must never return a host path.
  func prepareWorkspace(
    htaskID: String,
    sourceProjectRef: String,
    policy: EvolutionWorkspacePolicy,
    createdAtUTC: String
  ) async throws -> EvolutionWorkspaceRecord

  /// Re-registers a workspace this process did not create, so a task whose
  /// isolated tree outlived the process that made it keeps its identity.
  /// Refuses rather than rebuilds when the stored manifest disagrees: the
  /// caller already holds the reference, so quietly pointing it at another
  /// tree — or at the source — would cancel the isolation without saying so.
  func adoptPersistedWorkspace(
    _ workspace: EvolutionWorkspaceRecord,
    policy: EvolutionWorkspacePolicy
  ) async throws

  /// Records a strategy directory under the already isolated task tree.
  /// Runtime operations continue to target the stable task workspace so one
  /// capability subject cannot silently become another between attempts.
  func prepareAttemptDirectory(
    workspace: EvolutionWorkspaceRecord,
    attemptID: String,
    ordinal: Int,
    createdAtUTC: String
  ) async throws

  /// Destroys the isolated trees of terminal tasks according to `retention`.
  /// Audit metadata (workspace manifest, attempt manifests, teardown record)
  /// always survives; workspaces of non-terminal tasks and workspaces the
  /// caller cannot vouch for are never touched.
  func sweepTerminalWorkspaces(
    tasks: [EvolutionWorkspaceGCTaskReference],
    retention: EvolutionWorkspaceRetention,
    nowUTC: String
  ) async throws -> [EvolutionWorkspaceGCFinding]
}

package enum EvolutionWorkspaceRetentionError: Error, Equatable, Sendable {
  case negativeBound(String)
  case malformedBound(String)
}

/// Bounds for the terminal-workspace sweep. The policy can only choose how
/// long destroyed-eligible trees linger; it cannot widen the sweep to active
/// or unknown workspaces.
package struct EvolutionWorkspaceRetention: Equatable, Codable, Sendable {
  /// A terminal task's tree is destroyed only after its last transition is
  /// at least this old.
  package let minimumTerminalAgeSeconds: Int
  /// The most recently terminal trees stay for post-mortem regardless of age.
  package let retainLatestTerminalCount: Int
  /// Report what would be destroyed without touching the filesystem.
  package let dryRun: Bool

  package init(
    minimumTerminalAgeSeconds: Int,
    retainLatestTerminalCount: Int,
    dryRun: Bool = false
  ) throws {
    guard minimumTerminalAgeSeconds >= 0 else {
      throw EvolutionWorkspaceRetentionError.negativeBound("minimumTerminalAgeSeconds")
    }
    guard retainLatestTerminalCount >= 0 else {
      throw EvolutionWorkspaceRetentionError.negativeBound("retainLatestTerminalCount")
    }
    self.minimumTerminalAgeSeconds = minimumTerminalAgeSeconds
    self.retainLatestTerminalCount = retainLatestTerminalCount
    self.dryRun = dryRun
  }
}

/// The sweep caller's attested view of the task lifecycle owning one
/// workspace: the raw lifecycle word for the audit record, and whether that
/// lifecycle is absorbing-terminal. The in-process task plane that once
/// supplied this attestation was removed by CHG-2026-064; a future GC face
/// derives the same two facts from its own authoritative store.
package struct EvolutionWorkspaceGCLifecycle: Equatable, Codable, Sendable {
  package let rawValue: String
  package let isTerminal: Bool

  package init(rawValue: String, isTerminal: Bool) {
    self.rawValue = rawValue
    self.isTerminal = isTerminal
  }
}

/// What the caller's store can vouch for about one evolution workspace: the
/// authoritative lifecycle attestation and its last transition time. Terminal
/// lifecycles are absorbing, so a reference computed before the sweep cannot
/// go stale in the destructive direction.
package struct EvolutionWorkspaceGCTaskReference: Equatable, Codable, Sendable {
  package let workspaceID: String
  package let htaskID: String
  package let lifecycle: EvolutionWorkspaceGCLifecycle
  package let updatedAtUTC: String

  package init(
    workspaceID: String,
    htaskID: String,
    lifecycle: EvolutionWorkspaceGCLifecycle,
    updatedAtUTC: String
  ) {
    self.workspaceID = workspaceID
    self.htaskID = htaskID
    self.lifecycle = lifecycle
    self.updatedAtUTC = updatedAtUTC
  }
}

package enum EvolutionWorkspaceGCDisposition: String, CaseIterable, Codable, Sendable {
  /// The owning task is not terminal; recoverability is untouched.
  case activeRetained
  /// Terminal, but inside the retention window (age or latest-count).
  case retainedByPolicy
  /// The isolated tree was removed this sweep; metadata survives.
  case destroyed
  /// Dry run: the tree would have been removed.
  case wouldDestroy
  /// A previous sweep already removed the tree; nothing left to reclaim.
  case alreadyDestroyed
  /// The on-disk workspace has no matching store reference (or the manifest
  /// disagrees with it), so the sweep fails closed and keeps it.
  case unknownTaskRetained
}

package struct EvolutionWorkspaceGCFinding: Equatable, Codable, Sendable {
  package let workspaceID: String
  package let htaskID: String?
  package let disposition: EvolutionWorkspaceGCDisposition
  /// Bytes removed by this sweep (or measured for `wouldDestroy`); zero for
  /// every retaining disposition.
  package let reclaimedBytes: Int64

  package init(
    workspaceID: String,
    htaskID: String?,
    disposition: EvolutionWorkspaceGCDisposition,
    reclaimedBytes: Int64
  ) {
    self.workspaceID = workspaceID
    self.htaskID = htaskID
    self.disposition = disposition
    self.reclaimedBytes = reclaimedBytes
  }
}

