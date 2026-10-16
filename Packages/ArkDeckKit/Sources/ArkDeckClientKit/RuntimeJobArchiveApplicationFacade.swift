import ArkDeckCore
import Foundation

public struct RuntimeJobArchiveReview: Sendable, Equatable, Identifiable {
  public var id: String { reviewSHA256 }
  public let job: RuntimeJobSummaryPresentation
  public let reviewSHA256: String
  public let mode: String
  public let blockers: [String]
  public let canArchive: Bool
  public let originalUserConfirmationID: String?
  public let lastConfirmedStepID: String?
  public let retainedHazards: [String]
  public let resourceReleaseAuthorized: Bool
  public var retainsRisks: Bool { job.outcomeUnknown && !retainedHazards.isEmpty }
}

public enum RuntimeJobArchivePreviewResult: Sendable, Equatable {
  case review(RuntimeJobArchiveReview)
  case unavailable
}
public enum RuntimeJobArchiveResult: Sendable, Equatable {
  case archived(sessionPublished: Bool)
  case refused
  /// Refresh the Runtime preview. Never replay this decision on a lost response.
  case unconfirmed
}
public protocol RuntimeJobArchiveApplicationProviding: Sendable {
  func preview(_ job: RuntimeJobSummaryPresentation) async -> RuntimeJobArchivePreviewResult
  func archive(_ review: RuntimeJobArchiveReview) async -> RuntimeJobArchiveResult
}
public enum RuntimeJobArchiveApplicationFacade {
  public static func make(arguments: [String] = ProcessInfo.processInfo.arguments)
    -> any RuntimeJobArchiveApplicationProviding
  {
    RuntimeJobArchiveXPCProvider(request: { method, params in
      if arguments.contains("--ui-test-runtime-history") { return .failure("fixture_archive_not_dispatched") }
      switch await RuntimeXPCRequestTransport.request(method: method, params: params) {
      case .success(let bytes): return .success(bytes)
      case .failure(let failure): return .failure(failure.message)
      }
    })
  }
  public static func canInspect(_ job: RuntimeJobSummaryPresentation) -> Bool {
    !job.hasEstablishedCurrentEpoch
      && ["waitingForRecovery", "userAbandonRequested", "interrupted"].contains(job.state)
  }
}

actor RuntimeJobArchiveXPCProvider: RuntimeJobArchiveApplicationProviding {
  private let request: @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult
  private var inFlight = Set<String>()
  init(request: @escaping @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult) {
    self.request = request
  }
  func preview(_ job: RuntimeJobSummaryPresentation) async -> RuntimeJobArchivePreviewResult {
    guard RuntimeJobArchiveApplicationFacade.canInspect(job),
      let session = job.sessionID, !session.isEmpty,
      case .success(let bytes) = await request("job.archive.preview", ["jobId": .string(job.id)]),
      let result = Self.object(bytes),
      result["jobId"] as? String == job.id, result["operation"] as? String == job.operationReference,
      result["targetId"] as? String == job.targetID, result["sessionId"] as? String == session,
      result["state"] as? String == job.state, result["outcomeUnknown"] as? Bool == job.outcomeUnknown,
      let hash = result["reviewSha256"] as? String, hash.utf8.count == 64,
      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let mode = result["mode"] as? String, ["archive", "archiveWithHazards", "finishAudit", "finishPublication", "unavailable"].contains(mode),
      let canArchive = result["canArchive"] as? Bool, let blockers = result["blockers"] as? [String],
      let hazards = result["retainedHazards"] as? [String], hazards.allSatisfy({ !$0.isEmpty }),
      Set(hazards).count == hazards.count,
      let release = result["resourceReleaseAuthorized"] as? Bool,
      !job.outcomeUnknown || !release,
      canArchive == blockers.isEmpty, canArchive == (mode != "unavailable"),
      !canArchive || (job.outcomeUnknown
        ? (!hazards.isEmpty && mode != "archive"
          && ["flash.full-restore@1", "flash.dayu200", "flash.dayu200@1"].contains(job.operationReference))
        : (hazards.isEmpty && mode != "archiveWithHazards")),
      let confirmation = Self.optionalText(result["userConfirmationId"]),
      let lastStep = Self.optionalText(result["lastConfirmedStepId"]),
      !["archive", "archiveWithHazards"].contains(mode) || confirmation == nil,
      !["finishAudit", "finishPublication"].contains(mode) || confirmation != nil
    else { return .unavailable }
    return .review(RuntimeJobArchiveReview(job: job, reviewSHA256: hash, mode: mode, blockers: blockers,
      canArchive: canArchive, originalUserConfirmationID: confirmation, lastConfirmedStepID: lastStep,
      retainedHazards: hazards, resourceReleaseAuthorized: release))
  }
  func archive(_ review: RuntimeJobArchiveReview) async -> RuntimeJobArchiveResult {
    guard review.canArchive, review.blockers.isEmpty,
      RuntimeJobArchiveApplicationFacade.canInspect(review.job),
      inFlight.insert(review.job.id).inserted else { return .refused }
    defer { inFlight.remove(review.job.id) }
    // This label records the user's explicit sheet action. Runtime derives all
    // quiescence or retained-risk facts and checks the exact review again itself.
    let confirmation = review.originalUserConfirmationID ?? "user-archive-\(UUID().uuidString.lowercased())"
    guard case .success(let bytes) = await request("job.archive", [
      "jobId": .string(review.job.id), "expectedReviewSha256": .string(review.reviewSHA256),
      "userConfirmationId": .string(confirmation),
    ]) else { return .unconfirmed }
    guard let result = Self.object(bytes) else { return .unconfirmed }
    guard result["jobId"] as? String == review.job.id,
      result["sessionId"] as? String == review.job.sessionID,
      result["userConfirmationId"] as? String == confirmation,
      result["state"] as? String == "interrupted",
      result["outcomeUnknown"] as? Bool == review.job.outcomeUnknown,
      result["retainedHazards"] as? [String] == review.retainedHazards,
      result["resourceReleaseAuthorized"] as? Bool == !review.job.outcomeUnknown,
      let published = result["sessionPublished"] as? Bool,
      let publication = result["publication"] as? [String: Any],
      published == (publication["phase"] as? String == "catalogPublished"),
      let manifest = Self.optionalText(publication["manifestSha256"]),
      let failure = Self.optionalText(publication["failureCode"]),
      !published || (failure == nil && manifest?.utf8.count == 64
        && manifest?.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) == true)
    else { return .unconfirmed }
    return .archived(sessionPublished: published)
  }
  private static func object(_ bytes: Data) -> [String: Any]? {
    guard let value = try? RuntimeAppReadResources.result(bytes),
      let data = try? CanonicalJSONEncoders.canonical().encode(value)
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
  /// The outer optional rejects an omitted/malformed member; inner nil is the
  /// Runtime's explicit null. Missing evidence is never an affirmative proof.
  private static func optionalText(_ value: Any?) -> String?? {
    if value is NSNull { return .some(nil) }
    guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return .some(text)
  }
}
