// Run-grouping threads for the App's workspaces.
//
// A thread answers one product question: which runs belong to the same piece
// of work, so History can offer "continue this line" instead of a flat list
// where every capture looks unrelated to the one before it.
//
// It is deliberately not `RuntimeJobRecord.sessionID`. That value is one Job's
// own durable storage identity — `SessionLayout` uses it as the session
// directory name and `SessionManifest`/`SessionAudit` validate it paired with
// the job id — so it can neither be supplied by a caller nor shared between
// Jobs. A thread instead rides `clientContext.provenance`, which the runtime
// documents as display/audit annotation that never yields authority, scope or
// identity. Nothing here may become an input to admission, capability
// issuance, plan materialization, storage layout or audit identity.

import ArkDeckCore
import ArkDeckRuntime
import Foundation

public enum RuntimeWorkspaceThread {
  /// One salt per App process. Two launches must not silently merge into one
  /// line: the operator did not say they were continuing anything, and a
  /// thread that grows forever is the same as no grouping at all. Continuing
  /// an older line is an explicit act that replays that line's recorded id
  /// through `identifier(of:)`.
  public static let processSalt = UUID().uuidString

  /// The thread a workspace files its next submit under: stable for as long
  /// as the workspace keeps working on the same target within one App launch,
  /// and distinct the moment either the workspace or the target changes.
  ///
  /// Derived rather than stored so every submit path agrees without a shared
  /// mutable registry, and so tests can pin the salt instead of the clock.
  public static func identifier(
    clientName: String,
    targetID: String,
    salt: String = processSalt
  ) -> String {
    let material = Data("\(salt)|\(clientName)|\(targetID)".utf8)
    return "t-" + String(SHA256Hex.string(of: material).prefix(12))
  }

  /// Continues an existing line by reusing the thread a previous run recorded.
  /// Returns nil when that run carried no thread, so a caller cannot invent
  /// one and claim two unrelated runs were the same piece of work.
  public static func identifier(of context: RuntimeClientContext?) -> String? {
    context?.threadID
  }

  /// The client context a workspace submit should carry.
  public static func clientContext(
    clientName: String,
    targetID: String,
    continuing threadID: String? = nil,
    salt: String = processSalt
  ) -> RuntimeClientContext {
    RuntimeClientContext(
      clientName: clientName,
      threadID: threadID
        ?? identifier(clientName: clientName, targetID: targetID, salt: salt))
  }
}
