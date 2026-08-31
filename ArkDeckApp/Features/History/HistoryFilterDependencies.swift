import ArkDeckWorkflows
import Foundation

/// The dependencies that are not carried by a History summary or its filter
/// controls. Keep them in the cache key too: an old daemon's detail can resolve
/// a shared capture's category, and time windows change even with identical Jobs.
struct HistoryFilterDependencies: Equatable {
  let workspaceKindsByJobID: [String: RuntimeWorkspaceKind]
  let referenceDate: Date

  init(
    jobs: [RuntimeJobSummaryPresentation],
    detailsByJobID: [String: RuntimeJobDetailPresentation],
    referenceDate: Date
  ) {
    self.referenceDate = referenceDate
    workspaceKindsByJobID = jobs.reduce(into: [:]) { kinds, job in
      kinds[job.id] = Self.workspaceKind(for: job, detail: detailsByJobID[job.id])
    }
  }

  static func workspaceKind(
    for job: RuntimeJobSummaryPresentation,
    detail: RuntimeJobDetailPresentation?
  ) -> RuntimeWorkspaceKind? {
    if let kind = job.resolvedWorkspaceKind { return kind }
    guard let detail, detail.jobID == job.id, let evidence = detail.evidence else { return nil }
    return RuntimeWorkspaceKindProjection.kind(
      forOperation: job.operationReference, parameters: evidence.parameters)
  }

  func includes(_ date: Date?, within interval: TimeInterval?) -> Bool {
    guard let interval else { return true }
    guard let date else { return false }
    return date >= referenceDate.addingTimeInterval(-interval)
  }

  /// Wake only when a row can age out, rather than re-sorting on a periodic
  /// timer. The window includes its lower bound, so expire just after it.
  func nextExpirationDate(
    in jobs: [RuntimeJobSummaryPresentation], within interval: TimeInterval?
  ) -> Date? {
    guard let interval else { return nil }
    return jobs.compactMap { job -> Date? in
      guard let date = job.activityDate else { return nil }
      let expiration = date.addingTimeInterval(interval + 0.001)
      return expiration > referenceDate ? expiration : nil
    }.min()
  }
}
