import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

/// Real process death over private fixture bytes; never device transport.
func runImportCrashFixture(window: String, directory: URL) async throws {
  let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x61, count: 4092)
  let intent = try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
    "importRequestId": .string("crash-upload"), "kind": .string("hap"), "targetId": .string("TGT-fixture"),
    "bindingRevision": .string("1"), "deviceProfile": .null, "name": .string("fixture.hap"),
    "byteCount": .string(String(bytes.count)), "sha256": .string(SHA256Hex.string(of: bytes))])
  let root = directory.appending(path: "artifacts")
  let initial = try RuntimeArtifactStore(rootURL: root, nowUTC: { "2026-09-01T00:00:00Z" })
  let record = try ArtifactImportProjection(await initial.beginImport(intent,
    binding: .init(targetID: "TGT-fixture", bindingRevision: 1, stableIdentitySHA256: nil)))
  let prefix = Data(bytes.prefix(32))
  _ = try await initial.appendImport(id: record.id, generation: 1, offset: 0, chunk: prefix, sha256: SHA256Hex.string(of: prefix))
  let fault: RuntimeImportStore.Fault = { point in
    let selected: Bool
    switch point {
    case .afterPartialChunk: selected = window == "import-partial"
    case .afterChunkSync: selected = window == "import-synced"
    case .afterCommitIntent: selected = window == "import-committing"
    case .afterPublication: selected = window == "import-published"
    }
    if selected {
      try DurableFileWriter.createOrReplaceAtomically(destination: directory.appending(path: "ready"), data: Data(window.utf8))
      raise(SIGSTOP)
      while true { pause() }
    }
  }
  let owner = try RuntimeArtifactStore(rootURL: root, importFault: fault, nowUTC: { "2026-09-01T00:00:01Z" })
  let suffix = Data(bytes.dropFirst(32))
  _ = try await owner.appendImport(id: record.id, generation: 1, offset: 32, chunk: suffix, sha256: SHA256Hex.string(of: suffix))
  _ = try await owner.commitImport(id: record.id, generation: 1) { _, _ in ["kind": .string("hap"), "container": .string("zip")] }
}
