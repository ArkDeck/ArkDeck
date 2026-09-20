import ArkDeckCore
import Foundation

/// Display-only decoding after Artifact integrity has been checked. Real
/// HiLog buffers can contain invalid UTF-8; replacing those sequences must
/// be disclosed, and must never repair structured evidence or stored bytes.
public struct DiagnosticArtifactTextPreview: Sendable, Equatable {
  public let text: String
  public let replacedInvalidUTF8: Bool
  public let wasClipped: Bool

  public init?(
    bytes: Data,
    mediaType: String,
    maximumCharacters: Int = 120_000
  ) {
    guard bytes.count <= 2 * 1_024 * 1_024,
      (1...120_000).contains(maximumCharacters),
      mediaType == "text/plain" || mediaType == "application/json"
    else { return nil }
    let strict = String(data: bytes, encoding: .utf8)
    guard strict != nil || mediaType == "text/plain" else { return nil }
    let decoded = strict ?? String(decoding: bytes, as: UTF8.self)
    replacedInvalidUTF8 = strict == nil
    wasClipped = decoded.count > maximumCharacters
    text = String(decoded.prefix(maximumCharacters))
  }
}

/// The published bounded capture can be read without a connected device.
/// Correlation and bytes come from one exact Job; viewing it grants no runtime
/// authority and never substitutes the currently attached target.
public struct DiagnosticSessionPresentation: Sendable, Equatable {
  public let reading: DiagnosticSessionReading
  public let artifacts: [RuntimeArtifactPresentation]
  public let timeline: [String]
  public let ringHeldAnchor: Bool?
}

public enum DiagnosticSessionLoadResult: Sendable, Equatable {
  case loaded(DiagnosticSessionPresentation)
  case unavailable(String)
}

/// App transport adapter for the shared, deterministic offline inspector.
/// Runtime owns metadata and bytes; this adapter only binds those values and
/// calls the same parser the CLI uses.
public struct DiagnosticSessionApplicationReader: Sendable {
  private let provider: any RuntimeJobDetailApplicationProviding

  public init(provider: any RuntimeJobDetailApplicationProviding) {
    self.provider = provider
  }

  public func load(
    _ context: RuntimeHistoryWorkspaceContext
  ) async -> DiagnosticSessionLoadResult {
    guard
      context.operationReference
        == DiagnosticSessionOfflineInspector.operationReference
    else {
      return .unavailable("diagnostics_unsupported_operation")
    }
    let detail = await provider.loadJobDetail(
      jobID: context.jobID,
      operationReference: context.operationReference)
    guard detail.jobID == context.jobID,
      let correlation = detail.correlation,
      correlation.jobID == context.jobID,
      correlation.operationReference == context.operationReference,
      correlation.targetID == context.targetID,
      correlation.sessionID == context.sessionID,
      detail.artifactAvailability == .available
    else {
      return .unavailable("diagnostics_job_correlation_unavailable")
    }

    do {
      let inventory = try detail.artifacts.map(Self.metadata)
      guard Set(inventory.map(\.artifactID)).count == inventory.count,
        Set(inventory.map(\.name)).count == inventory.count,
        inventory.allSatisfy({
          $0.sourceOperation == context.operationReference
        })
      else {
        throw Failure("diagnostics_ambiguous_artifact_inventory")
      }

      var documents: [String: DiagnosticOfflineArtifact] = [:]
      for name in [
        DiagnosticSessionOfflineInspector.indexArtifactName,
        DiagnosticSessionOfflineInspector.summaryArtifactName,
      ] {
        documents[name] = try await document(
          name,
          inventory: inventory,
          artifacts: detail.artifacts,
          jobID: context.jobID)
      }
      if inventory.contains(where: {
        $0.name == DiagnosticSessionOfflineInspector.markersArtifactName
          && $0.status == "published"
      }) {
        let name = DiagnosticSessionOfflineInspector.markersArtifactName
        documents[name] = try await document(
          name,
          inventory: inventory,
          artifacts: detail.artifacts,
          jobID: context.jobID)
      }

      let inspection = try DiagnosticSessionOfflineInspector().inspect(
        DiagnosticSessionOfflineInput(
          jobID: context.jobID,
          operationReference: context.operationReference,
          typedParameters: detail.evidence?.typedParameters,
          inventory: inventory,
          documents: documents))
      return .loaded(
        DiagnosticSessionPresentation(
          reading: inspection.reading,
          artifacts: detail.artifacts,
          timeline: detail.timeline,
          ringHeldAnchor: inspection.ringHeldAnchor))
    } catch let failure as Failure {
      return .unavailable(failure.reason)
    } catch let failure as DiagnosticSessionOfflineInspectorError {
      return .unavailable(failure.reason)
    } catch {
      return .unavailable("diagnostics_unreadable_session_document")
    }
  }

  private func document(
    _ name: String,
    inventory: [DiagnosticOfflineArtifactMetadata],
    artifacts: [RuntimeArtifactPresentation],
    jobID: String
  ) async throws -> DiagnosticOfflineArtifact {
    guard let metadata = inventory.first(where: { $0.name == name }),
      let artifact = artifacts.first(where: {
        $0.id == metadata.artifactID && $0.name == name
      }),
      artifact.role == "derived",
      metadata.status == "published",
      metadata.mediaType == "application/json",
      metadata.privacy == "standard",
      metadata.byteCount > 0,
      metadata.byteCount
        <= DiagnosticSessionOfflineInspector.documentMaximumBytes
    else {
      throw Failure("diagnostics_missing_or_unreadable_\(name)")
    }
    switch await provider.readArtifact(
      jobID: jobID,
      artifact: artifact,
      maximumBytes: DiagnosticSessionOfflineInspector.documentMaximumBytes,
      allowSensitive: false)
    {
    case .loaded(let bytes):
      return try DiagnosticOfflineArtifact(
        metadata: metadata,
        data: bytes)
    case .failed(let reason):
      throw Failure(reason)
    }
  }

  private static func metadata(
    _ artifact: RuntimeArtifactPresentation
  ) throws -> DiagnosticOfflineArtifactMetadata {
    guard artifact.byteCount >= 0,
      artifact.byteCount <= Int64(Int.max)
    else {
      throw Failure("diagnostics_invalid_artifact_metadata")
    }
    do {
      return try DiagnosticOfflineArtifactMetadata(
        artifactID: artifact.id,
        name: artifact.name,
        mediaType: artifact.mediaType,
        privacy: artifact.privacy,
        status: artifact.status,
        statusDetail: artifact.statusDetail,
        sourceOperation: artifact.sourceOperation,
        byteCount: Int(artifact.byteCount),
        sha256: artifact.status == "published" ? artifact.sha256 : nil)
    } catch {
      throw Failure("diagnostics_invalid_artifact_metadata")
    }
  }

  private struct Failure: Error {
    let reason: String

    init(_ reason: String) {
      self.reason = reason
    }
  }
}
