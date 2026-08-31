import ArkDeckCore
import ArkDeckWorkflows
import Darwin
import Foundation

/// Isolated host-file publication only. The parent actually SIGKILLs this process.
func runArtifactExportCrashFixture(window: String, directory: URL) async throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let point: RuntimeArtifactExport.FaultPoint = window == "artifact-export-before" ? .beforePublication : .afterPublication
  let store = try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), importFault: { _ in }, exportFault: { current in
    if current == point {
      try Data("ready".utf8).write(to: directory.appending(path: "ready"))
      raise(SIGSTOP)
    }
  }, nowUTC: { "2026-09-01T00:00:00Z" })
  let owner = try ArtifactOwnerReference(.object(["kind": .string("job"), "id": .string("job-export-fixture")]))
  let product = try await store.publish(.init(jobID: owner.id, sessionID: "export-fixture", stepID: "fixture",
    name: "fixture.txt", mediaType: "text/plain", privacy: .standard, retentionClass: .default,
    sourceOperation: "observe.device@1", providerID: "hdc",
    bindingSnapshot: .init(targetID: "TGT-fixture", bindingRevision: 1, stableIdentitySHA256: nil), contents: Data("verified crash fixture".utf8)))
  let destination = directory.appending(path: "exports")
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  try Data("original destination".utf8).write(to: destination.appending(path: product.artifactID + "-" + product.name))
  _ = try await store.exportArtifact(owner: owner, artifactID: product.artifactID,
    destinationDirectory: destination, overwrite: true, allowSensitive: false)
}
