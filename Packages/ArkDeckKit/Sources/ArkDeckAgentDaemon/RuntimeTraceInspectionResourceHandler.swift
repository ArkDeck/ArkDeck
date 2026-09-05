import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Runtime owner for deterministic inspection of one exact raw Trace Artifact.
/// Caller paths, parser paths, executable arguments and cache roots never enter
/// this request surface.
struct RuntimeTraceInspectionResourceHandler {
  let engine: RuntimeJobEngine
  let artifacts: RuntimeArtifactStore?
  let inspector: (any RuntimeTraceInspecting)?

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    func failed(_ code: String, _ message: String) -> AgentWireProtocol.Response {
      .init(
        id: request.id, ok: false, result: nil,
        error: .init(
          code: code, message: message,
          details: [
            "phase": .string("traceInspectionOwner"),
            "newDispatchCount": .integer(0),
            "deviceEvidenceCreated": .bool(false),
          ]))
    }

    do {
      guard let artifacts, let inspector else {
        return failed("operationUnavailable", "Trace inspection is unavailable")
      }
      let fields = request.params ?? [:]
      guard Set(fields.keys) == ["owner", "artifactId", "allowSensitive", "timeoutMs"],
        let ownerValue = fields["owner"],
        let owner = try? ArtifactOwnerReference(ownerValue), owner.kind == "job",
        case .string(let artifactID)? = fields["artifactId"],
        AgentExecutionIntent.validIdentifier(artifactID),
        fields["allowSensitive"] == .bool(true),
        case .integer(let rawTimeout)? = fields["timeoutMs"],
        (1...600_000).contains(rawTimeout),
        let timeoutMs = Int(exactly: rawTimeout)
      else {
        return failed(
          "invalidInput",
          "Trace inspection requires an exact Job/Artifact, sensitive opt-in, and bounded timeout")
      }
      _ = try await engine.jobReadSnapshot(jobID: owner.id)
      let metadata = try await artifacts.inspect(jobID: owner.id, artifactID: artifactID)
      guard metadata.status.isPublished,
        metadata.sourceOperation == "capture.diagnostics@1",
        metadata.name == "trace.htrace",
        metadata.mediaType == "application/octet-stream",
        metadata.privacy == .sensitive,
        !metadata.redactionApplied,
        metadata.byteCount > 0,
        SHA256Hex.isLowercaseSHA256(metadata.sha256)
      else {
        return failed(
          "invalidInput",
          "selected Artifact is not the exact raw capture.diagnostics@1 Trace product")
      }
      let lease = try await artifacts.resolveLease(
        "lease-v1:\(owner.id):\(artifactID)")
      guard lease.artifactID == artifactID,
        lease.sha256 == metadata.sha256,
        lease.byteCount == metadata.byteCount,
        lease.bindingSnapshot == metadata.bindingSnapshot
      else {
        return failed("artifactIntegrityFailed", "Trace Artifact lease identity drifted")
      }
      let report = try await RuntimeTraceInspectionSource.inspect(
        lease: lease,
        inspector: inspector,
        timeoutMs: timeoutMs)
      guard report.sourceSHA256 == lease.sha256,
        report.sourceByteCount == lease.byteCount
      else {
        return failed("artifactIntegrityFailed", "Trace inspection returned another source identity")
      }
      let result = report.projection(owner: owner, artifact: metadata)
      let projection = try RuntimeTraceInspectionProjection(result)
      guard projection.owner == owner, projection.artifactID == artifactID,
        projection.report == report
      else {
        return failed("recordUnreadable", "Trace inspection projection identity drifted")
      }
      return .init(
        id: request.id, ok: true,
        result: try RuntimeJobReadProjection.bounded(
          result, maximumBytes: 8 * 1024 * 1024 - 4_096),
        error: nil)
    } catch RuntimeTraceInspectionFailure.timedOut {
      return failed("operationFailed", "Trace inspection timed out and was drained")
    } catch RuntimeTraceInspectionFailure.artifactIntegrity {
      return failed("artifactIntegrityFailed", "Trace Artifact immutable identity is invalid")
    } catch let error as AgentExecutionControlFailure {
      return failed(error.code, error.message)
    } catch RuntimeJobEngineError.jobNotFound {
      return failed("resourceNotFound", "Trace Job owner does not exist")
    } catch RuntimeArtifactError.artifactNotFound {
      return failed("resourceNotFound", "Trace Artifact does not exist for this Job")
    } catch RuntimeArtifactError.indexCorrupted {
      return failed("artifactIntegrityFailed", "Trace Artifact metadata is inconsistent")
    } catch {
      return failed("operationFailed", "Trace inspection failed without creating evidence")
    }
  }
}
