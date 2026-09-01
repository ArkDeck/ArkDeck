import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckWorkflows
import Foundation

extension RuntimeCLI {
  static func runDiagnosticsResource(
    _ verb: String,
    rest original: [String]
  ) throws {
    if verb == "export" {
      try runArtifactResource(
        "export",
        rest: original,
        command: "diagnostics.export",
        requiredSourceOperation:
          DiagnosticSessionOfflineInspector.operationReference)
      return
    }

    var rest = original
    var session = runtimeSession(
      &rest,
      command: "diagnostics.\(verb)")
    let options = try CLIOptions(
      rest.filter { $0 != "--allow-sensitive" })
    guard let jobID = options.value("--job") else {
      throw session.fail(
        .invalidInput,
        "diagnostics \(verb) requires --job <id>")
    }
    let owner: ArtifactOwnerReference
    do {
      owner = try ArtifactOwnerReference(
        .object([
          "kind": .string("job"),
          "id": .string(jobID),
        ]))
    } catch let failure as AgentExecutionControlFailure {
      throw session.fail(.invalidInput, failure.message)
    }
    let timeout = options.value("--timeout") ?? "30s"
    guard
      let duration = CLIDuration.parse(
        timeout,
        maximumMilliseconds: 86_400_000)
    else {
      throw session.fail(
        .invalidInput,
        "diagnostics timeout must be a bounded duration")
    }
    session.client = session.client.bounded(
      by: try AgentClientWaitDeadline(
        milliseconds: duration.milliseconds))

    do {
      try session.negotiate(
        requiredMajor: 2,
        forMethod: "artifact.list")
      let inventory = try diagnosticsInventory(
        owner: owner,
        session: session)
      switch verb {
      case "inspect":
        let request = try diagnosticsJobRequest(
          jobID: jobID,
          session: session)
        let documentNames = [
          DiagnosticSessionOfflineInspector.indexArtifactName,
          DiagnosticSessionOfflineInspector.summaryArtifactName,
          DiagnosticSessionOfflineInspector.markersArtifactName,
        ]
        var documents: [String: DiagnosticOfflineArtifact] = [:]
        for name in documentNames {
          guard
            let metadata = inventory.first(where: {
              $0.name == name && $0.status == "published"
            })
          else {
            if name == DiagnosticSessionOfflineInspector.markersArtifactName {
              continue
            }
            throw session.fail(
              .resourceNotFound,
              "diagnostic Job \(jobID) did not publish \(name)")
          }
          guard metadata.mediaType == "application/json",
            metadata.privacy == "standard",
            metadata.byteCount > 0,
            metadata.byteCount
              <= DiagnosticSessionOfflineInspector.documentMaximumBytes
          else {
            throw session.fail(
              .recordUnreadable,
              "diagnostic document \(name) has unsafe metadata")
          }
          let bytes = try diagnosticsReadWholeArtifact(
            owner: owner,
            metadata: metadata,
            maximumBytes:
              DiagnosticSessionOfflineInspector.documentMaximumBytes,
            allowSensitive: false,
            session: session)
          documents[name] = try DiagnosticOfflineArtifact(
            metadata: metadata,
            data: bytes)
        }
        let inspection = try DiagnosticSessionOfflineInspector().inspect(
          DiagnosticSessionOfflineInput(
            jobID: jobID,
            operationReference: request.operation.reference,
            typedParameters: request.inputs,
            inventory: inventory,
            documents: documents))
        session.emit(diagnosticsInspectionValue(inspection))
      case "preview":
        guard let artifactID = options.value("--artifact"),
          let metadata = inventory.first(where: {
            $0.artifactID == artifactID
          })
        else {
          throw session.fail(
            .resourceNotFound,
            "diagnostic Job \(jobID) has no selected Artifact")
        }
        let maximumCharacters =
          options.value("--max-characters").flatMap(Int.init)
          ?? DiagnosticSessionOfflineInspector.previewMaximumCharacters
        let explicit = rest.contains("--allow-sensitive")
        guard metadata.privacy != "sensitive" || explicit else {
          throw session.fail(
            .sensitiveAccessDenied,
            "sensitive diagnostics preview requires --allow-sensitive")
        }
        let bytes = try diagnosticsReadWholeArtifact(
          owner: owner,
          metadata: metadata,
          maximumBytes:
            DiagnosticSessionOfflineInspector.previewMaximumBytes,
          allowSensitive: explicit,
          session: session)
        let preview = try DiagnosticSessionOfflineInspector().preview(
          DiagnosticOfflineArtifact(
            metadata: metadata,
            data: bytes),
          maximumCharacters: maximumCharacters,
          contentAccessExplicit: explicit)
        session.emit(diagnosticsPreviewValue(preview))
      default:
        throw session.fail(
          .invalidCommand,
          "unsupported diagnostics subcommand")
      }
    } catch let failure as AgentExecutionControlFailure {
      throw session.fail(
        CLIErrorCode(rawValue: failure.code) ?? .recordUnreadable,
        failure.message)
    } catch let failure as DiagnosticSessionOfflineInspectorError {
      let code: CLIErrorCode
      switch failure {
      case .byteCountMismatch, .digestMismatch:
        code = .artifactIntegrityFailed
      case .contentTooLarge:
        code = .inputTooLarge
      case .sensitiveContentRequiresExplicitAccess:
        code = .sensitiveAccessDenied
      case .invalid:
        code = .recordUnreadable
      }
      throw session.fail(code, failure.reason)
    } catch let failure as CLIRegistryError {
      throw session.stamped(failure)
    } catch {
      throw session.fail(
        .recordUnreadable,
        "diagnostic session could not be decoded")
    }
  }

  private static func diagnosticsJobRequest(
    jobID: String,
    session: CLIRuntimeSession
  ) throws -> RuntimeOperationRequest {
    let value = try session.request(
      "job.show",
      ["jobId": .string(jobID)])
    _ = try CLIJobReadValidation.validate(
      value,
      verb: "show",
      jobID: jobID,
      options: [:],
      session: session)
    guard case .object(let fields) = value,
      case .object(let status)? = fields["job"],
      status["jobId"] == .string(jobID),
      status["operation"]
        == .string(
          DiagnosticSessionOfflineInspector.operationReference),
      case .string(let targetID)? = status["targetId"],
      let requestValue = fields["request"]
    else {
      throw session.fail(
        .recordUnreadable,
        "Job is not an exact diagnostics capture")
    }
    let request = try JSONDecoder().decode(
      RuntimeOperationRequest.self,
      from: PortableCanonicalJSON.canonicalBytes(requestValue))
    guard
      request.operation.reference
        == DiagnosticSessionOfflineInspector.operationReference,
      request.target.targetID == targetID
    else {
      throw session.fail(
        .recordUnreadable,
        "diagnostic Job request does not match its status")
    }
    return request
  }

  private static func diagnosticsInventory(
    owner: ArtifactOwnerReference,
    session: CLIRuntimeSession
  ) throws -> [DiagnosticOfflineArtifactMetadata] {
    var values: [JSONValue] = []
    var cursor: String?
    var snapshotRevision: String?
    var seenCursors = Set<String>()
    repeat {
      var fields: [String: JSONValue] = [
        "owner": owner.value,
        "pageSize": .integer(1_000),
      ]
      if let cursor {
        fields["cursor"] = .string(cursor)
      }
      let page = try session.request("artifact.list", fields)
      try ArtifactResourceProjection.validatePage(
        page,
        owner: owner,
        pageSize: 1_000)
      guard case .object(let pageFields) = page,
        case .array(let items)? = pageFields["items"],
        case .string(let revision)? = pageFields["snapshotRevision"],
        case .bool(let hasMore)? = pageFields["hasMore"]
      else {
        throw session.fail(
          .recordUnreadable,
          "diagnostic Artifact inventory is malformed")
      }
      guard snapshotRevision == nil || snapshotRevision == revision else {
        throw session.fail(
          .factsDrifted,
          "diagnostic Artifact snapshot changed while paging")
      }
      snapshotRevision = revision
      values.append(contentsOf: items)
      guard
        values.count
          <= DiagnosticSessionOfflineInspector.inventoryMaximumCount
      else {
        throw session.fail(
          .inputTooLarge,
          "diagnostic Artifact inventory exceeds its bound")
      }
      if hasMore {
        guard case .string(let next)? = pageFields["nextCursor"],
          seenCursors.insert(next).inserted
        else {
          throw session.fail(
            .recordUnreadable,
            "diagnostic Artifact pagination stopped advancing")
        }
        cursor = next
      } else {
        cursor = nil
      }
    } while cursor != nil

    guard !values.isEmpty else {
      throw session.fail(
        .resourceNotFound,
        "diagnostic Job \(owner.id) published no Artifacts")
    }
    return try values.map { value in
      guard case .object(let fields) = value,
        case .string(let artifactID)? = fields["artifactId"],
        case .string(let name)? = fields["name"],
        case .string(let mediaType)? = fields["mediaType"],
        case .string(let privacy)? = fields["privacy"],
        case .string(let status)? = fields["status"],
        case .string(let operation)? = fields["sourceOperation"],
        case .integer(let rawCount)? = fields["byteCount"],
        rawCount >= 0,
        rawCount <= Int64(Int.max)
      else {
        throw session.fail(
          .recordUnreadable,
          "diagnostic Artifact metadata is malformed")
      }
      let digest: String?
      if case .string(let value)? = fields["artifactDigest"] {
        digest = value
      } else {
        digest = nil
      }
      return try DiagnosticOfflineArtifactMetadata(
        artifactID: artifactID,
        name: name,
        mediaType: mediaType,
        privacy: privacy,
        status: status,
        sourceOperation: operation,
        byteCount: Int(rawCount),
        sha256: digest)
    }
  }

  private static func diagnosticsReadWholeArtifact(
    owner: ArtifactOwnerReference,
    metadata: DiagnosticOfflineArtifactMetadata,
    maximumBytes: Int,
    allowSensitive: Bool,
    session: CLIRuntimeSession
  ) throws -> Data {
    guard metadata.status == "published",
      metadata.byteCount <= maximumBytes,
      let digest = metadata.sha256
    else {
      throw session.fail(
        .inputTooLarge,
        "diagnostic Artifact exceeds the bounded read or is unpublished")
    }
    var data = Data()
    var offset = 0
    repeat {
      let value = try session.request(
        "artifact.read",
        [
          "owner": owner.value,
          "artifactId": .string(metadata.artifactID),
          "offset": .integer(Int64(offset)),
          "maxBytes": .integer(
            Int64(ArtifactReadProjection.maximumBytes)),
          "allowSensitive": .bool(allowSensitive),
        ])
      let page = try ArtifactReadProjection(value)
      guard page.artifactID == metadata.artifactID,
        page.digest == digest,
        page.totalByteCount == metadata.byteCount,
        page.offset == offset
      else {
        throw session.fail(
          .recordUnreadable,
          "diagnostic Artifact range changed identity")
      }
      data.append(page.bytes)
      if page.nextOffset == page.totalByteCount {
        break
      }
      guard page.nextOffset > offset else {
        throw session.fail(
          .recordUnreadable,
          "diagnostic Artifact read stopped advancing")
      }
      offset = page.nextOffset
    } while true
    guard data.count == metadata.byteCount,
      SHA256Hex.string(of: data) == digest
    else {
      throw session.fail(
        .artifactIntegrityFailed,
        "diagnostic Artifact bytes do not match immutable metadata")
    }
    return data
  }

  private static func diagnosticsInspectionValue(
    _ inspection: DiagnosticSessionOfflineInspection
  ) -> JSONValue {
    .object([
      "schemaVersion": .string(inspection.schemaVersion),
      "jobId": .string(inspection.jobID),
      "operationReference": .string(
        inspection.operationReference),
      "derivation": diagnosticsProvenanceValue(
        inspection.provenance),
      "partial": .bool(inspection.reading.isPartial),
      "alignment": diagnosticsAlignmentValue(
        inspection.reading.alignment),
      "markers": .array(
        inspection.reading.marks.map(diagnosticsMarkValue)),
      "missingProducts": .array(
        inspection.reading.missingProducts.map {
          .object([
            "name": .string($0.name),
            "reason": .string($0.reason),
          ])
        }),
      "notDerived": .array(
        inspection.reading.notDerived.map(JSONValue.string)),
      "ringHeldAnchor":
        inspection.ringHeldAnchor.map(JSONValue.bool) ?? .null,
      "artifacts": .array(
        inspection.inventory.map(diagnosticsMetadataValue)),
    ])
  }

  private static func diagnosticsPreviewValue(
    _ preview: DiagnosticArtifactOfflinePreview
  ) -> JSONValue {
    .object([
      "schemaVersion": .string(preview.schemaVersion),
      "derivation": diagnosticsProvenanceValue(
        preview.provenance),
      "text": .string(preview.text),
      "replacedInvalidUtf8": .bool(
        preview.replacedInvalidUTF8),
      "clipped": .bool(preview.wasClipped),
    ])
  }

  private static func diagnosticsProvenanceValue(
    _ provenance: DiagnosticSessionOfflineProvenance
  ) -> JSONValue {
    .object([
      "kind": .string(provenance.kind),
      "parser": .string(provenance.parser),
      "parserVersion": .string(provenance.parserVersion),
      "sources": .array(
        provenance.sources.map(diagnosticsMetadataValue)),
    ])
  }

  private static func diagnosticsMetadataValue(
    _ metadata: DiagnosticOfflineArtifactMetadata
  ) -> JSONValue {
    .object([
      "artifactId": .string(metadata.artifactID),
      "name": .string(metadata.name),
      "mediaType": .string(metadata.mediaType),
      "privacy": .string(metadata.privacy),
      "status": .string(metadata.status),
      "statusDetail":
        metadata.statusDetail.map(JSONValue.string) ?? .null,
      "sourceOperation": .string(metadata.sourceOperation),
      "byteCount": .integer(Int64(metadata.byteCount)),
      "artifactDigest":
        metadata.sha256.map(JSONValue.string) ?? .null,
    ])
  }

  private static func diagnosticsAlignmentValue(
    _ alignment: DiagnosticSessionReading.Alignment
  ) -> JSONValue {
    switch alignment {
    case .sameClock:
      return .object([
        "kind": .string("sameClock"),
        "toleranceMs": .null,
        "reason": .null,
      ])
    case .calibrated(let tolerance):
      return .object([
        "kind": .string("calibrated"),
        "toleranceMs": .integer(Int64(tolerance)),
        "reason": .null,
      ])
    case .cannotAlign(let reason):
      return .object([
        "kind": .string("cannotAlign"),
        "toleranceMs": .null,
        "reason": .string(reason),
      ])
    }
  }

  private static func diagnosticsMarkValue(
    _ mark: DiagnosticSessionReading.Mark
  ) -> JSONValue {
    let screenshot: JSONValue
    if let value = mark.screenshot {
      screenshot = .object([
        "artifactName": .string(value.artifactName),
        "capturedAtUtc": .string(value.capturedAtUTC),
        "takenAfterMarkMs": .integer(
          Int64(value.takenAfterMarkMs)),
      ])
    } else {
      screenshot = .null
    }
    return .object([
      "ordinal": .integer(Int64(mark.ordinal)),
      "kind": .string(
        mark.isAutomatic ? "automatic" : "manual"),
      "atHostUtc": .string(mark.atHostUTC),
      "label": mark.label.map(JSONValue.string) ?? .null,
      "trigger": mark.trigger.map(JSONValue.string) ?? .null,
      "screenshot": screenshot,
      "screenshotAbsence":
        diagnosticsScreenshotAbsenceValue(
          mark.screenshotAbsence),
    ])
  }

  private static func diagnosticsScreenshotAbsenceValue(
    _ absence: DiagnosticSessionReading.ScreenshotAbsence?
  ) -> JSONValue {
    guard let absence else { return .null }
    switch absence {
    case .takenTooFarFromTheMark(let offset):
      return .object([
        "kind": .string("takenTooFarFromMark"),
        "milliseconds": .integer(Int64(offset)),
        "reason": .null,
      ])
    case .shutterWindowWiderThanTheRule(let window):
      return .object([
        "kind": .string("shutterWindowUncertain"),
        "milliseconds": .integer(Int64(window)),
        "reason": .null,
      ])
    case .captureFailed(let reason):
      return .object([
        "kind": .string("captureFailed"),
        "milliseconds": .null,
        "reason": .string(reason),
      ])
    case .notCaptured:
      return .object([
        "kind": .string("notCaptured"),
        "milliseconds": .null,
        "reason": .null,
      ])
    }
  }
}
