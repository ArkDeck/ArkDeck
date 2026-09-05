import ArkDeckCore
import Darwin
import Foundation

/// The production composition calls this before mutation admission and again
/// before capability consumption. Test/diagnostic roots may serve reads, but
/// switching directories cannot replace the configured Runtime's authority.
package enum RuntimeStateContinuity {
  package static func requireMutationState(
    selectedRoot: URL, defaultRoot: URL, sessionRoots: [URL] = []
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(selectedRoot)
    try DurableFilePrimitives.requireAbsoluteFileURL(defaultRoot)
    guard selectedRoot.standardizedFileURL == defaultRoot.standardizedFileURL else {
      throw RuntimeJobRepositoryError.corrupt(
        "mutation is unavailable for a state-root override; current Runtime state remains at \(defaultRoot.path)"
      )
    }
    try DurableFilePrimitives.rejectSymbolicLink(selectedRoot)
    let retiredRoot = defaultRoot.deletingLastPathComponent().appending(path: "AuthorizationUsage")
    var metadata = stat()
    let result = lstat(retiredRoot.path, &metadata)
    if result == 0 {
      throw RuntimeJobRepositoryError.corrupt(
        "retired authority state is unsupported; original files remain at \(retiredRoot.path)")
    }
    guard errno == ENOENT else {
      throw RuntimeJobRepositoryError.corrupt(
        "cannot prove retired authority state absent at \(retiredRoot.path)")
    }
    let checkpoint = selectedRoot.appending(path: "capabilities/runtime-capabilities.json")
    if try !exists(checkpoint) {
      let jobs = selectedRoot.appending(path: "jobs")
      if try exists(jobs) {
        try DurableFilePrimitives.rejectSymbolicLink(jobs)
        for job in try FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil) {
          try DurableFilePrimitives.rejectSymbolicLink(job)
          let record = job.appending(path: "job-record.json")
          try DurableFilePrimitives.rejectSymbolicLink(record)
          try requireReadOnlyHistory(Data(contentsOf: record), source: record.path)
        }
      }
      // The admission transaction may be the only surviving copy of a Job.
      // Losing its directory must not turn retained SQLite history into a
      // fresh capability budget.
      let index = selectedRoot.appending(path: RuntimeJobRepository.filename)
      if try exists(index) {
        let repository = try RuntimeJobRepository(stateDirectory: selectedRoot)
        var cursor: String?
        repeat {
          let page = try repository.listJobs(pageSize: 256, cursor: cursor)
          for job in page.jobs {
            guard let bytes = job.initialRecordData else {
              throw RuntimeJobRepositoryError.corrupt(
                "cannot prove indexed Job \(job.jobID) read-only without capability state; original index remains at \(index.path)")
            }
            try requireReadOnlyHistory(bytes, source: "\(index.path) Job \(job.jobID)")
          }
          cursor = page.nextCursor
        } while cursor != nil
      }
    }
    let roots = Set((sessionRoots + [
      defaultRoot.deletingLastPathComponent().appending(path: "Sessions")
    ]).map(\.standardizedFileURL))
    for root in roots {
      try DurableFilePrimitives.requireAbsoluteFileURL(root)
      guard try exists(root) else { continue }
      try DurableFilePrimitives.rejectSymbolicLink(root)
      for session in try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      {
        try DurableFilePrimitives.rejectSymbolicLink(session)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else { continue }
        let manifest = session.appending(path: "manifest.json")
        if try exists(manifest) {
          try DurableFilePrimitives.rejectSymbolicLink(manifest)
          _ = try SessionManifestDocument(data: Data(contentsOf: manifest))
        }
        let journal = session.appending(path: "journal.jsonl")
        if try exists(journal) {
          try DurableFilePrimitives.rejectSymbolicLink(journal)
          let replay = try DurableJournalRecovery.inspect(url: journal)
          guard !replay.hasTornTail,
            !replay.outstandingIntents.contains(where: { $0.effect >= .deviceMutation }),
            !replay.unknownOutcomes.contains(where: { $0.effect >= .deviceMutation })
          else {
            throw RuntimeJobRepositoryError.corrupt(
              "unresolved Session mutation blocks new authority; original state remains at \(session.path)")
          }
        }
      }
    }
  }

  private static func requireReadOnlyHistory(_ bytes: Data, source: String) throws {
    var validator = StrictJSONDuplicateValidator(data: bytes)
    try validator.validate()
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: bytes),
      case .object(let request)? = fields["request"],
      request["authorization"] == nil,
      fields["actualEffect"] == .string("hostOnly") || fields["actualEffect"] == .string("readOnly")
    else {
      throw RuntimeJobRepositoryError.corrupt(
        "capability state is missing beside mutation history; original Job remains at \(source)")
    }
  }

  private static func exists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    guard errno == ENOENT else {
      throw RuntimeJobRepositoryError.corrupt("cannot establish durable state at \(url.path)")
    }
    return false
  }
}
