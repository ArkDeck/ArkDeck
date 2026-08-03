// Runtime admission and durable-history boundary.
//
// RuntimeJobEngine owns typed authorization and orchestration.  This service
// owns every direct interaction with the SQLite admission/history index so a
// runner cannot accidentally turn a read, update, or idempotency decision
// into an ad-hoc transaction.

import ArkDeckStorage
import Foundation

struct RuntimeAdmissionService {
  private let repository: RuntimeJobRepository

  init(stateDirectory: URL) throws {
    repository = try RuntimeJobRepository(stateDirectory: stateDirectory)
  }

  func lookup(
    idempotencyKey: String, requestHash: String
  ) throws -> RuntimeJobAdmissionVerdict {
    try repository.lookup(idempotencyKey: idempotencyKey, requestHash: requestHash)
  }

  /// Commits the idempotency identity and the exact initial durable record in
  /// one SQLite transaction.  The caller can publish the job-local journal
  /// only after this boundary returns `.admitted`.
  func admit(
    record: RuntimeJobRecord, requestHash: String
  ) throws -> RuntimeJobAdmissionVerdict {
    try repository.admit(
      jobID: record.jobID,
      idempotencyKey: record.request.idempotencyKey,
      requestHash: requestHash,
      initialState: record.state,
      createdAtUTC: record.createdAtUTC,
      initialRecordData: try record.durableData())
  }

  /// The SQLite state is a compact query index; the job-local record remains
  /// the detailed recovery snapshot.  Update both from one typed record so
  /// callers cannot write an index state that disagrees with its snapshot.
  func persist(_ record: RuntimeJobRecord, at timestamp: String) throws {
    try repository.updateJobState(
      jobID: record.jobID,
      state: record.state,
      updatedAtUTC: timestamp,
      recordData: try record.durableData())
  }

  func job(jobID: String) throws -> RuntimePersistedJob? {
    try repository.job(jobID: jobID)
  }

  func allJobs() throws -> [RuntimePersistedJob] {
    try repository.allJobs()
  }

  func activeJobs() throws -> [RuntimePersistedJob] {
    try repository.activeJobs()
  }

  func listJobs(
    pageSize: Int, cursor: String?
  ) throws -> RuntimeJobRepositoryPage {
    try repository.listJobs(pageSize: pageSize, cursor: cursor)
  }
}
