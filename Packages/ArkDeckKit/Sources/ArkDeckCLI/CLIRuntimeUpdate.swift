import AppKit
import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// The narrow command seam used by `runtime update`.
///
/// The App and CLI both use `RuntimeUpdateApplicationFacade`; this protocol only makes the CLI
/// transition selection testable without a production network request or Finder activation. It
/// does not add another state owner, path input, or update implementation.
protocol RuntimeUpdateCommandOperating: Sendable {
  func recoverOrphanPartials() async throws
  func checkManually(identity: UpdateProductIdentity, now: Date) async throws -> AutoUpdateState
  func downloadAvailableUpdate() async throws -> AutoUpdateState
  func handoff(
    explicitConsent: Bool,
    revealer: any UpdateArtifactRevealing
  ) async throws -> AutoUpdateState
  func status() async throws -> RuntimeUpdateStatusProjection
  func cancel() async throws -> RuntimeUpdateStatusProjection
  func cleanup() async throws -> RuntimeUpdateCleanupReceipt
}

extension RuntimeUpdateApplicationFacade: RuntimeUpdateCommandOperating {}

extension RuntimeCLI {
  static func runRuntimeUpdate(_ arguments: [String]) async throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing runtime update subcommand (check|download|handoff|status|cancel|cleanup)")
    }
    var rest = Array(arguments.dropFirst())
    let session = runtimeSession(
      &rest, command: "runtime.update.\(subcommand)", connectsToRuntime: false)
    let options = try CLIOptions(rest)
    let owner: RuntimeUpdateApplicationFacade
    do {
      owner = try AutoUpdateApplicationFacade.make()
    } catch {
      throw session.stamped(runtimeUpdateError(error, command: session.command))
    }

    do {
      let result = try await runtimeUpdateResult(
        subcommand: subcommand,
        options: options,
        owner: owner,
        identity: AutoUpdateApplicationFacade.currentProductIdentity(),
        revealer: CLIFinderUpdateArtifactRevealer())
      session.emit(result)
    } catch let error as CLIRegistryError {
      throw session.stamped(error)
    } catch {
      throw session.stamped(runtimeUpdateError(error, command: session.command))
    }
  }

  /// Executes one local update transition and returns its path-free durable projection.
  ///
  /// Recovery runs before every leaf. If another process still owns an operation, its lease makes
  /// recovery a no-op; if the process died, the stale transition is settled before this invocation
  /// observes or mutates it. `cleanup` performs that same proof internally and therefore does not
  /// need a duplicate pre-pass.
  static func runtimeUpdateResult(
    subcommand: String,
    options: CLIOptions,
    owner: any RuntimeUpdateCommandOperating,
    identity: UpdateProductIdentity,
    revealer: any UpdateArtifactRevealing,
    now: Date = Date()
  ) async throws -> JSONValue {
    switch subcommand {
    case "check":
      try options.validateAllowed([])
      try await owner.recoverOrphanPartials()
      _ = try await owner.checkManually(identity: identity, now: now)
      return runtimeUpdateStatusJSON(try await owner.status())
    case "download":
      try options.validateAllowed([])
      try await owner.recoverOrphanPartials()
      _ = try await owner.downloadAvailableUpdate()
      return runtimeUpdateStatusJSON(try await owner.status())
    case "handoff":
      try options.validateAllowed(["--consent"])
      guard options.value("--consent") == "reveal-in-finder" else {
        throw AutoUpdateServiceError.explicitConsentRequired
      }
      try await owner.recoverOrphanPartials()
      _ = try await owner.handoff(explicitConsent: true, revealer: revealer)
      return runtimeUpdateStatusJSON(try await owner.status())
    case "status":
      try options.validateAllowed([])
      try await owner.recoverOrphanPartials()
      return runtimeUpdateStatusJSON(try await owner.status())
    case "cancel":
      try options.validateAllowed([])
      try await owner.recoverOrphanPartials()
      return runtimeUpdateStatusJSON(try await owner.cancel())
    case "cleanup":
      try options.validateAllowed([])
      return runtimeUpdateCleanupJSON(try await owner.cleanup())
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported runtime update subcommand")
    }
  }

  static func runtimeUpdateStatusJSON(_ status: RuntimeUpdateStatusProjection) -> JSONValue {
    .object([
      "schemaVersion": .string(RuntimeUpdateStatusProjection.schemaVersion),
      "generation": .unsignedInteger(status.generation),
      "phase": .string(status.phase),
      "isBusy": .bool(status.isBusy),
      "cancellationRequested": .bool(status.cancellationRequested),
      "canCheck": .bool(status.canCheck),
      "canDownload": .bool(status.canDownload),
      "canHandoff": .bool(status.canHandoff),
      "updateVersion": status.updateVersion.map(JSONValue.string) ?? .null,
      "releaseNotesSummary": status.releaseNotesSummary.map(JSONValue.string) ?? .null,
      "artifactSha256": status.artifactSHA256.map(JSONValue.string) ?? .null,
      "artifactByteLength": status.artifactByteLength.map(JSONValue.unsignedInteger) ?? .null,
      "noUpdateReason": status.noUpdateReason.map(JSONValue.string) ?? .null,
      "failureCode": status.failureCode.map(JSONValue.string) ?? .null,
      "updatedAtUtc": .string(status.updatedAtUTC),
    ])
  }

  static func runtimeUpdateCleanupJSON(_ receipt: RuntimeUpdateCleanupReceipt) -> JSONValue {
    .object([
      "schemaVersion": .string(RuntimeUpdateCleanupReceipt.schemaVersion),
      "removedVerifiedArtifactCount": .integer(Int64(receipt.removedVerifiedArtifacts)),
      "status": runtimeUpdateStatusJSON(receipt.status),
    ])
  }

  /// Maps the closed update failures onto the existing CLI error registry. Messages deliberately
  /// omit `String(describing:)`: URL and filesystem errors can carry private request/cache paths.
  static func runtimeUpdateError(_ error: any Error, command: String) -> CLIRegistryError {
    let code: CLIErrorCode
    let message: String
    switch error {
    case RuntimeUpdateStateStoreError.operationInProgress:
      code = .resourceConflict
      message = "another process owns the active update operation"
    case RuntimeUpdateStateStoreError.resourceConflict:
      code = .resourceConflict
      message = "the durable update lifecycle changed during this request"
    case RuntimeUpdateStateStoreError.recordUnreadable:
      code = .recordUnreadable
      message = "the durable update lifecycle record is not trustworthy"
    case RuntimeUpdateStateStoreError.unsafeDirectory,
      RuntimeUpdateStateStoreError.writeFailed:
      code = .ioFailure
      message = "the owner-only update lifecycle store is unavailable"
    case AutoUpdateServiceError.invalidTransition:
      code = .resourceConflict
      message = "the update lifecycle is not in a state that accepts this transition"
    case AutoUpdateServiceError.explicitConsentRequired:
      code = .admissionDenied
      message = "Finder handoff requires explicit --consent reveal-in-finder"
    case AutoUpdateServiceError.artifactChangedAfterVerification:
      code = .artifactIntegrityFailed
      message = "the update artifact changed after verification"
    case AutoUpdateServiceError.automaticChecksDisabled,
      AutoUpdateServiceError.automaticCheckNotDue:
      code = .resourceConflict
      message = "the automatic update check is not eligible"
    case UpdateFeedError.replayStateCorrupt:
      code = .recordUnreadable
      message = "the signed update replay record is not trustworthy"
    case UpdateFeedError.replayStateWriteFailed:
      code = .ioFailure
      message = "the signed update replay record could not be persisted"
    case is UpdateFeedError:
      code = .artifactIntegrityFailed
      message = "the signed update feed failed verification"
    case is UpdateArtifactSecurityError:
      code = .artifactIntegrityFailed
      message = "the downloaded update failed code-signing verification"
    case UpdateDownloadError.cancelled:
      code = .clientInterrupted
      message = "the active update operation was cancelled"
    case UpdateDownloadError.fileOperationFailed,
      UpdateDownloadError.unsafeDirectory:
      code = .ioFailure
      message = "the owner-only update cache is unavailable"
    case is UpdateDownloadError:
      code = .artifactIntegrityFailed
      message = "the downloaded update failed content verification"
    case is UpdateNetworkError, is URLError:
      code = .operationFailed
      message = "the update network request failed"
    default:
      code = command.hasSuffix(".handoff") ? .ioFailure : .operationFailed
      message = command.hasSuffix(".handoff")
        ? "Finder could not reveal the verified update artifact"
        : "the update operation failed"
    }
    return CLIRegistryError(
      code: code,
      message: message,
      details: ["phase": .string(String(command.split(separator: ".").last ?? "update"))],
      command: command)
  }
}

private struct CLIFinderUpdateArtifactRevealer: UpdateArtifactRevealing, Sendable {
  @MainActor
  func revealInFinder(_ url: URL) throws {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
