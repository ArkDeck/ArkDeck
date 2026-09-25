import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime

/// What Swift's `workspace continuation` leaves decide, recorded for the Rust
/// CLI to replay (`rust/crates/arkdeck-cli/tests/workspace_continuation.rs`).
///
/// Each source case hands `CLIWorkspaceContinuationDraft` the Runtime answers
/// a continuation reads: the source Job's `job.show`, `health` and, for a
/// device-bound source, the Target's `target.show`. It records whether Swift
/// reads the Target, and the draft Swift prepares or its refusal. Prepared
/// sources then record the fresh request each continuation identity makes, as
/// the `requestJson` text `job.submit` carries. They also record what Swift
/// makes of the Job that identity resolves to, and the projection each leaf
/// emits. A refusal is its code, its words and its `details`. A source case
/// names its own `health` only where it differs from the oracle's.
///
/// Record a new oracle with
/// `ARKDECK_RUST_WORKSPACE_CONTINUATION_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIWorkspaceContinuationOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-continuation", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_CONTINUATION_RECORD"

  private static let sourceJobID = "job-source-continuation"
  private static let newJobID = "job-continuation-new"
  private static let targetID = "target-continuation"
  private static let hostTargetID = "host-workspace"
  private static let identity = String(repeating: "b", count: 64)
  private static let threadID = "thread-continuation"

  private static func session() -> CLIRuntimeSession {
    var arguments = ["--output", "json", "--socket", "/tmp/arkdeck-continuation-no-daemon"]
    return RuntimeCLI.runtimeSession(&arguments, command: "workspace.continuation.inspect")
  }

  private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(
      JSONValue.self, from: CanonicalJSONEncoders.canonical().encode(value))
  }

  /// `value` with the member at `path` replaced, or removed for `nil`.
  private static func with(_ value: JSONValue, _ path: [String], _ replacement: JSONValue?)
    -> JSONValue
  {
    guard case .object(var fields) = value, let key = path.first else { return value }
    if path.count == 1 {
      fields[key] = replacement
    } else {
      fields[key] = with(fields[key] ?? .object([:]), Array(path.dropFirst()), replacement)
    }
    return .object(fields)
  }

  private static func request(
    operation: String = "observe.device",
    version: Int? = 1,
    target: String = targetID,
    binding: Int? = 3,
    inputs: [String: JSONValue] = [:],
    authorization: RuntimeCapabilityReference? = nil,
    thread: String? = threadID
  ) throws -> JSONValue {
    var provenance = ["fixture": "continuation"]
    if let thread { provenance[RuntimeClientContext.threadProvenanceKey] = thread }
    return try json(
      RuntimeOperationRequest(
        requestID: "source-request-001",
        idempotencyKey: "source-request-001",
        target: DurableTargetReference(targetID: target, expectedBindingRevision: binding),
        operation: RuntimeOperationReference(id: operation, version: version),
        inputs: inputs,
        authorization: authorization,
        clientContext: RuntimeClientContext(clientName: "source-client", provenance: provenance)))
  }

  private static func status(
    jobID: String = sourceJobID,
    operation: String = "observe.device@1",
    target: String = targetID,
    effect: String? = "readOnly",
    state: String = "succeeded",
    unknown: Bool = false,
    human: Bool = false,
    residue: Int64 = 0,
    superseded: String? = nil,
    thread: String? = threadID
  ) -> JSONValue {
    let owner = JSONValue.object(["kind": .string("job"), "id": .string(jobID)])
    let terminal = JobState(rawValue: state)?.isTerminal ?? false
    let nextAction: JSONValue
    if human {
      nextAction = .object([
        "kind": .string("humanAction"), "owner": owner,
        "resource": .object([
          "kind": .string("humanAction"), "id": .string("human-action-source"),
        ]),
        "reasonCode": .string("device.notObserved"),
        "resumeReference": .string("resume-source-action"),
        "expiresAt": .null,
      ])
    } else if unknown {
      nextAction = .object([
        "kind": .string("reconcile"), "owner": owner, "resource": owner,
        "reasonCode": .string("recovery.outcomeUnknown"),
      ])
    } else if terminal {
      nextAction = .object([
        "kind": .string("readResult"), "owner": owner, "resource": owner,
        "reasonCode": .string("job.resultAvailable"),
      ])
    } else {
      nextAction = .object([
        "kind": .string("wait"), "owner": owner, "resource": owner,
        "reasonCode": .string("job.running"), "retryAfter": .string("1s"),
      ])
    }
    return .object([
      "schemaVersion": .string("arkdeck.job-status/1"),
      "jobId": .string(jobID),
      "operation": .string(operation),
      "targetId": .string(target),
      "state": .string(state),
      "outcome": .string(unknown ? "outcomeUnknown" : state),
      "waitingForHuman": .bool(human),
      "outcomeUnknown": .bool(unknown),
      "outstandingResidueCount": .integer(residue),
      "executionMode": .string("execute"),
      "sessionId": .string("session-continuation"),
      "threadId": thread.map(JSONValue.string) ?? .null,
      "workspaceKind": .null,
      "actualEffect": effect.map(JSONValue.string) ?? .null,
      "createdAtUtc": .string("2026-09-01T00:00:00Z"),
      "startedAtUtc": .string("2026-09-01T00:00:01Z"),
      "finishedAtUtc": terminal ? .string("2026-09-01T00:00:02Z") : .null,
      "supersededByRecoveryEpochId": superseded.map(JSONValue.string) ?? .null,
      "recoveryEpochId": .null,
      "resolvedByTargetAliasResolutionId": .null,
      "sessionPublication": .object([
        "state": .string("unavailable"), "manifestSha256": .null,
        "catalogGeneration": .null, "reasonCode": .string("noCurrentPublicationRecord"),
      ]),
      "nextAction": nextAction,
      "failure": .null,
      "processProgress": .null,
    ])
  }

  private static func show(
    jobID: String = sourceJobID,
    request: JSONValue,
    status: JSONValue,
    catalogDigest: String = RuntimeOperationCatalog.catalogDigest,
    provider: String = "hdc",
    binding: Int64? = 3,
    stableIdentity: String? = identity
  ) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.job/1"),
      "job": status,
      "request": request,
      "catalogDigest": .string(catalogDigest),
      "providerId": .string(provider),
      // The published `job.show` answer always carries a plan digest; the
      // continuation never reads it.
      "materializedPlanDigest": .string(String(repeating: "f", count: 64)),
      "materializedBindingRevision": binding.map(JSONValue.integer) ?? .null,
      "materializedStableIdentitySha256": stableIdentity.map(JSONValue.string) ?? .null,
      "actualStepKinds": .array([]),
      "timeline": .object(["kind": .string("inline"), "entries": .array([])]),
      "events": .object(["method": .string("job.events"), "jobId": .string(jobID)]),
      "evidence": .object(["method": .string("job.evidence"), "jobId": .string(jobID)]),
      "ringCoverage": .null,
      "screenSequence": .null,
    ])
  }

  private static func health(
    digest: String = RuntimeOperationCatalog.catalogDigest,
    providers: [String] = ["hdc", "workspace"]
  ) -> JSONValue {
    .object([
      "status": .string("ok"),
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "publishedMethods": .array(
        ArkDeckControlProtocol.methods.sorted().map(JSONValue.string)),
      "catalogDigest": .string(digest),
      "providers": .array(providers.map(JSONValue.string)),
    ])
  }

  /// The published `target.show` answer, which carries both display-name
  /// members; `displayName: nil` leaves both out.
  private static func target(
    revision: Int64 = 3,
    stableIdentity: String = identity,
    displayName: JSONValue? = JSONValue.null,
    generation: String = "2"
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.target/1"),
      "targetId": .string(targetID),
      "bindingRevision": .integer(revision),
      "toolVersion": .string("3.2.0f"),
      "adoptedAtUtc": .string("2026-09-01T00:00:00Z"),
      "connectKey": .string("fixture-connect-key"),
      "stablePhysicalIdentitySha256": .string(stableIdentity),
      "live": .null,
      "observedFacts": .null,
    ]
    if let displayName {
      fields["displayName"] = displayName
      fields["displayNameGeneration"] = .string(generation)
    }
    return .object(fields)
  }

  /// What Swift answered: `{value}`, or `{error: {code, message, details}}`.
  private static func outcome(_ body: () throws -> JSONValue) -> JSONValue {
    do {
      return .object(["value": try body()])
    } catch let error as CLIRegistryError {
      return .object([
        "error": .object([
          "code": .string(error.code.rawValue),
          "message": .string(error.message),
          "details": .object(error.details),
        ])
      ])
    } catch {
      return .object(["thrown": .string(String(describing: error))])
    }
  }

  func testSwiftDecidesTheContinuationsTheRustCLIReplays() throws {
    var sources: [JSONValue] = []
    var drafts: [String: CLIWorkspaceContinuationDraft] = [:]
    func source(
      _ name: String, sourceJobID: String = Self.sourceJobID, show: JSONValue,
      health: JSONValue = Self.health(), target: JSONValue? = nil
    ) {
      let session = Self.session()
      let requiresTarget = Self.outcome {
        .bool(
          try CLIWorkspaceContinuationDraft.sourceRequiresCurrentTarget(
            show, sourceJobID: sourceJobID, session: session))
      }
      var draft: CLIWorkspaceContinuationDraft?
      let prepared = Self.outcome {
        let prepared = try CLIWorkspaceContinuationDraft.prepare(
          sourceJobID: sourceJobID, jobShow: show, health: health, targetShow: target,
          session: session)
        draft = prepared
        return prepared.projection()
      }
      if let draft { drafts[name] = draft }
      var row: [String: JSONValue] = [
        "name": .string(name), "sourceJobId": .string(sourceJobID), "show": show,
        "target": target ?? .null, "requiresTarget": requiresTarget, "prepared": prepared,
      ]
      // The oracle's own `health` unless the case names another.
      if health != Self.health() { row["health"] = health }
      sources.append(.object(row))
    }

    // Sources a continuation accepts.
    let device = try Self.request()
    let deviceStatus = Self.status()
    let deviceShow = Self.show(request: device, status: deviceStatus)
    source("deviceReadOnly", show: deviceShow, target: Self.target())
    source(
      "displayNamed", show: deviceShow,
      target: Self.target(displayName: .string("Bench device")))
    source("displayNameNull", show: deviceShow, target: Self.target(displayName: .null))
    source("targetWithoutDisplayName", show: deviceShow, target: Self.target(displayName: nil))
    let host = try Self.request(
      operation: "workspace.inspect-git-status", target: Self.hostTargetID, binding: nil,
      inputs: ["projectRef": .string("project-1")])
    let hostStatus = Self.status(
      operation: "workspace.inspect-git-status@1", target: Self.hostTargetID,
      effect: "hostOnly")
    let hostShow = Self.show(
      request: host, status: hostStatus, provider: "workspace", binding: nil,
      stableIdentity: nil)
    source("hostOnly", show: hostShow)
    let diagnosticsInputs: [String: JSONValue] = [
      "durationSeconds": .integer(30),
      "hilogFilters": .array(
        [
          "a/b", "tab\there", "\u{1}", "é", "quote\"", "back\\slash", "\u{7f}", "\u{2028}",
          "line\nbreak",
        ].map(JSONValue.string)),
      "screenshotImageType": .string("jpeg"),
      "bundleName": .string("com.example.app"),
      "uiDump": .bool(false),
    ]
    let diagnostics = try Self.request(
      operation: "capture.diagnostics", inputs: diagnosticsInputs, thread: nil)
    let diagnosticsStatus = Self.status(operation: "capture.diagnostics@1", thread: nil)
    source(
      "diagnosticsReadOnly",
      show: Self.show(request: diagnostics, status: diagnosticsStatus),
      target: Self.target())
    source(
      "requestReviewedDigest",
      show: Self.with(
        deviceShow, ["request", "reviewedPlanDigest"],
        .string(String(repeating: "a", count: 64))),
      target: Self.target())
    var sparse = device
    for member in ["documentType", "inputs", "requestedOutputs"] {
      sparse = Self.with(sparse, [member], nil)
    }
    source(
      "requestDefaults", show: Self.with(deviceShow, ["request"], sparse),
      target: Self.target())

    // The source Job read itself.
    source("sourceIdentityInvalid", sourceJobID: "job:source", show: deviceShow)
    source(
      "showSchema", show: Self.with(deviceShow, ["schemaVersion"], .string("arkdeck.job/2")))
    source("showRequestNotObject", show: Self.with(deviceShow, ["request"], .string("x")))
    source(
      "showEvents",
      show: Self.with(deviceShow, ["events", "jobId"], .string("job-other")))
    source(
      "statusDate",
      show: Self.with(deviceShow, ["job", "createdAtUtc"], .string("yesterday")))
    source(
      "statusState",
      show: Self.with(
        Self.with(deviceShow, ["job", "state"], .string("exploded")), ["job", "outcome"],
        .string("exploded")))
    source(
      "statusPublication",
      show: Self.with(
        deviceShow, ["job", "sessionPublication", "reasonCode"], .string("bogus")))
    source(
      "timelineKind",
      show: Self.with(deviceShow, ["timeline"], .object(["kind": .string("pages")])))
    source(
      "timelineReference",
      show: Self.with(
        deviceShow, ["timeline"],
        .object([
          "kind": .string("snapshotPages"), "jobId": .string("job-other"),
          "method": .string("job.timeline"),
        ])))
    source(
      "timelineEntries",
      show: Self.with(
        deviceShow, ["timeline"],
        .object(["kind": .string("inline"), "entries": .array([.integer(1)])])))

    // Health and the Catalog.
    source(
      "healthOpen", show: deviceShow, health: Self.with(Self.health(), ["extra"], .bool(true)),
      target: Self.target())
    source(
      "healthStatus", show: deviceShow,
      health: Self.with(Self.health(), ["status"], .string("degraded")), target: Self.target())
    source(
      "healthMethods", show: deviceShow,
      health: Self.with(
        Self.health(), ["publishedMethods"],
        .array(ArkDeckControlProtocol.methods.sorted().reversed().map(JSONValue.string))),
      target: Self.target())
    source(
      "healthProvidersDuplicate", show: deviceShow,
      health: Self.health(providers: ["hdc", "hdc"]), target: Self.target())
    source(
      "healthProvidersEmpty", show: deviceShow, health: Self.health(providers: ["hdc", ""]),
      target: Self.target())
    source(
      "runtimeCatalogDrift", show: deviceShow,
      health: Self.health(digest: String(repeating: "c", count: 64)), target: Self.target())
    source(
      "sourceCatalogDrift",
      show: Self.show(
        request: device, status: deviceStatus,
        catalogDigest: String(repeating: "d", count: 64)),
      target: Self.target())
    source(
      "providerUnpublished", show: deviceShow, health: Self.health(providers: ["workspace"]),
      target: Self.target())
    source(
      "providerMissing", show: Self.with(deviceShow, ["providerId"], .null),
      target: Self.target())

    // The typed request.
    source(
      "requestAuthority",
      show: Self.show(
        request: try Self.request(
          authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-FIXTURE")),
        status: deviceStatus),
      target: Self.target())
    let malformedRequests: [(String, [String], JSONValue)] = [
      ("requestIdempotencyShort", ["idempotencyKey"], .string("short")),
      ("requestGovernance", ["change_ID"], .string("CHG-1")),
      ("requestRetiredAuthority", ["campaignReservation"], .object([:])),
      ("requestUnknownMember", ["sessionId"], .string("session-1")),
      ("requestSchemaVersion", ["schemaVersion"], .string("2.0.0")),
      ("requestTargetMember", ["target", "sessionId"], .string("session-1")),
      (
        "requestThread", ["clientContext", "provenance", "arkdeck.threadId"],
        .string("bad thread")
      ),
      ("requestClientName", ["clientContext", "clientName"], .string("")),
      (
        "requestOutputsDuplicate", ["requestedOutputs"],
        .array([.string("rawArtifacts"), .string("rawArtifacts")])
      ),
      ("requestOutputUnknown", ["requestedOutputs"], .array([.string("everything")])),
      ("requestInputUppercase", ["inputs", "RefreshServerFacts"], .bool(true)),
      ("requestInputForbidden", ["inputs", "argv"], .bool(true)),
      ("requestReviewedDigestMalformed", ["reviewedPlanDigest"], .string("A")),
      ("requestBindingZero", ["target", "expectedBindingRevision"], .integer(0)),
      ("requestVersionZero", ["operation", "version"], .integer(0)),
      ("requestOperationUppercase", ["operation", "id"], .string("Observe.device")),
    ]
    for (name, path, value) in malformedRequests {
      source(
        name, show: Self.with(deviceShow, ["request"] + path, value), target: Self.target())
    }
    let versionless = try Self.request(version: nil)
    source(
      "requestVersionless",
      show: Self.show(
        request: versionless, status: Self.status(operation: "observe.device")),
      target: Self.target())
    let absent = try Self.request(operation: "observe.nothing")
    source(
      "operationAbsent",
      show: Self.show(request: absent, status: Self.status(operation: "observe.nothing@1")),
      target: Self.target())

    // The source Job's own facts.
    source(
      "identitiesDisagree",
      show: Self.show(request: device, status: Self.status(target: "target-other")),
      target: Self.target())
    source(
      "running",
      show: Self.show(request: device, status: Self.status(state: "running")),
      target: Self.target())
    source(
      "outcomeUnknown", show: Self.show(request: device, status: Self.status(unknown: true)),
      target: Self.target())
    source(
      "waitingForHuman", show: Self.show(request: device, status: Self.status(human: true)),
      target: Self.target())
    source(
      "residue", show: Self.show(request: device, status: Self.status(residue: 1)),
      target: Self.target())
    source(
      "superseded",
      show: Self.show(request: device, status: Self.status(superseded: "epoch-1")),
      target: Self.target())
    source(
      "effectDisagrees",
      show: Self.show(request: device, status: Self.status(effect: "hostOnly")),
      target: Self.target())
    source(
      "effectAbsent", show: Self.show(request: device, status: Self.status(effect: nil)),
      target: Self.target())

    // Typed inputs against the current Catalog.
    source(
      "inputWrongType",
      show: Self.show(
        request: try Self.request(inputs: ["refreshServerFacts": .string("yes")]),
        status: deviceStatus),
      target: Self.target())
    source(
      "inputUnknown",
      show: Self.show(
        request: try Self.request(inputs: ["unknownInput": .bool(true)]), status: deviceStatus),
      target: Self.target())
    let diagnosticsCases: [(String, [String: JSONValue], String)] = [
      ("diagnosticsDurationAbsent", [:], "readOnly"),
      ("diagnosticsDurationFraction", ["durationSeconds": .number(5.5)], "readOnly"),
      ("diagnosticsDurationHuge", ["durationSeconds": .unsignedInteger(UInt64.max)], "readOnly"),
      ("diagnosticsDurationBelow", ["durationSeconds": .integer(0)], "readOnly"),
      (
        "diagnosticsFiltersTooMany",
        [
          "durationSeconds": .integer(30),
          "hilogFilters": .array(Array(repeating: .string("x"), count: 17)),
        ], "readOnly"
      ),
      (
        "diagnosticsEnum",
        ["durationSeconds": .integer(30), "screenshotImageType": .string("gif")], "readOnly"
      ),
      (
        "diagnosticsPattern",
        ["durationSeconds": .integer(30), "bundleName": .string("app")], "readOnly"
      ),
      (
        "diagnosticsCategoryBytes",
        [
          "durationSeconds": .integer(30),
          "traceCategories": .array([.string(String(repeating: "é", count: 33))]),
        ], "readOnly"
      ),
      (
        "diagnosticsScreenshot",
        ["durationSeconds": .integer(30), "uiScreenshot": .bool(true)], "deviceMutation"
      ),
      (
        "diagnosticsMarkers",
        [
          "durationSeconds": .integer(30),
          "markers": .array([.string("2026-09-01T00:00:00Z#start")]),
        ], "readOnly"
      ),
    ]
    for (name, inputs, effect) in diagnosticsCases {
      source(
        name,
        show: Self.show(
          request: try Self.request(operation: "capture.diagnostics", inputs: inputs),
          status: Self.status(operation: "capture.diagnostics@1", effect: effect)),
        target: Self.target())
    }
    source(
      "mutation",
      show: Self.show(
        request: try Self.request(
          operation: "workspace.build-openharmony", target: Self.hostTargetID, binding: nil,
          inputs: [
            "projectRef": .string("project-1"), "buildPresetRef": .string("build-preset-1"),
          ]),
        status: Self.status(
          operation: "workspace.build-openharmony@1", target: Self.hostTargetID,
          effect: "deviceMutation"),
        provider: "workspace", binding: nil, stableIdentity: nil))

    // The device binding, current or not.
    source("targetRevision", show: deviceShow, target: Self.target(revision: 4))
    source(
      "targetIdentity", show: deviceShow,
      target: Self.target(stableIdentity: String(repeating: "c", count: 64)))
    source(
      "targetSchema", show: deviceShow,
      target: Self.with(Self.target(), ["schemaVersion"], .string("arkdeck.target/2")))
    source(
      "targetOther", show: deviceShow,
      target: Self.with(Self.target(), ["targetId"], .string("target-other")))
    source("targetAbsent", show: deviceShow)
    source(
      "materializedRevision",
      show: Self.show(request: device, status: deviceStatus, binding: 2), target: Self.target())
    source(
      "materializedIdentityAbsent",
      show: Self.show(request: device, status: deviceStatus, stableIdentity: nil),
      target: Self.target())
    source(
      "materializedIdentityUppercase",
      show: Self.show(
        request: device, status: deviceStatus,
        stableIdentity: String(repeating: "B", count: 64)),
      target: Self.target())
    source(
      "requestBindingAbsent",
      show: Self.show(request: try Self.request(binding: nil), status: deviceStatus),
      target: Self.target())
    let displayNames: [(String, JSONValue, String)] = [
      ("displayNameGenerationPadded", .string("Bench"), "02"),
      ("displayNameGenerationZero", .string("Bench"), "0"),
      ("displayNameUntrimmed", .string(" Bench"), "2"),
      ("displayNameDecomposed", .string("Cafe\u{301}"), "2"),
      ("displayNameControl", .string("Bench\u{7}"), "2"),
      ("displayNameLong", .string(String(repeating: "a", count: 257)), "2"),
      ("displayNameNumber", .integer(1), "2"),
    ]
    for (name, displayName, generation) in displayNames {
      source(
        name, show: deviceShow,
        target: Self.target(displayName: displayName, generation: generation))
    }
    source(
      "displayNameAlone", show: deviceShow,
      target: Self.with(Self.target(displayName: nil), ["displayName"], .string("Bench")))
    source("hostWithTarget", show: hostShow, target: Self.target())
    source(
      "hostMaterialized",
      show: Self.show(
        request: host, status: hostStatus, provider: "workspace", binding: 1,
        stableIdentity: nil))
    source(
      "hostRequestBinding",
      show: Self.show(
        request: try Self.request(
          operation: "workspace.inspect-git-status", target: Self.hostTargetID, binding: 2,
          inputs: ["projectRef": .string("project-1")]),
        status: hostStatus, provider: "workspace", binding: nil, stableIdentity: nil))

    // The fresh request each continuation identity makes.
    var requests: [JSONValue] = []
    let identities: [(String, [String])] = [
      (
        "deviceReadOnly",
        [
          "continue-001", "sample", "continue:bad", "continue 001",
          String(repeating: "c", count: 128), String(repeating: "c", count: 129),
        ]
      ),
      ("displayNamed", ["continue-004"]),
      ("hostOnly", ["continue-host-001"]),
      ("diagnosticsReadOnly", ["continue-diagnostics-001"]),
      ("requestReviewedDigest", ["continue-002"]),
      ("requestDefaults", ["continue-003"]),
    ]
    for (name, continuations) in identities {
      let draft = try XCTUnwrap(drafts[name], name)
      for identity in continuations {
        requests.append(
          .object([
            "source": .string(name), "continuationRequestId": .string(identity),
            "outcome": Self.outcome {
              let fresh = try draft.request(
                continuationRequestID: identity, session: Self.session())
              return .string(
                String(decoding: try CanonicalJSONEncoders.canonical().encode(fresh), as: UTF8.self))
            },
          ]))
      }
    }

    // The Job a continuation identity resolves to.
    var accepted: [JSONValue] = []
    var projections: [JSONValue] = []
    func accept(
      _ name: String, source: String, identity: String, jobID: String = Self.newJobID,
      show: JSONValue
    ) throws {
      let draft = try XCTUnwrap(drafts[source], source)
      let expected = try draft.request(continuationRequestID: identity, session: Self.session())
      accepted.append(
        .object([
          "name": .string(name), "source": .string(source),
          "continuationRequestId": .string(identity), "jobId": .string(jobID), "show": show,
          "outcome": Self.outcome {
            try draft.validateAcceptedJob(
              show, jobID: jobID, expectedRequest: expected, session: Self.session())
          },
        ]))
    }
    let fresh = try Self.json(
      drafts["deviceReadOnly"]!.request(
        continuationRequestID: "continue-001", session: Self.session()))
    let other = try Self.json(
      drafts["deviceReadOnly"]!.request(
        continuationRequestID: "continue-002", session: Self.session()))
    func freshShow(
      request: JSONValue? = nil, status: JSONValue? = nil,
      catalogDigest: String = RuntimeOperationCatalog.catalogDigest, binding: Int64? = 3,
      stableIdentity: String? = Self.identity
    ) -> JSONValue {
      Self.show(
        jobID: Self.newJobID, request: request ?? fresh,
        status: status ?? Self.status(jobID: Self.newJobID), catalogDigest: catalogDigest,
        binding: binding, stableIdentity: stableIdentity)
    }
    let device001 = ("deviceReadOnly", "continue-001")
    try accept("accepted", source: device001.0, identity: device001.1, show: freshShow())
    try accept(
      "acceptedPreflight", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, effect: nil, state: "preflight")))
    try accept(
      "acceptedRunning", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, state: "running")))
    try accept(
      "acceptedFailed", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, state: "failed")))
    try accept(
      "acceptedWaitingForHuman", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, human: true)))
    try accept(
      "sameIdentity", source: device001.0, identity: device001.1, jobID: Self.sourceJobID,
      show: Self.show(request: fresh, status: deviceStatus))
    try accept(
      "identityInvalid", source: device001.0, identity: device001.1, jobID: "job:new",
      show: freshShow())
    try accept(
      "showEvents", source: device001.0, identity: device001.1,
      show: Self.with(freshShow(), ["events", "jobId"], .string("job-other")))
    try accept(
      "catalogDiffers", source: device001.0, identity: device001.1,
      show: freshShow(catalogDigest: String(repeating: "e", count: 64)))
    try accept(
      "operationDiffers", source: device001.0, identity: device001.1,
      show: freshShow(
        status: Self.status(jobID: Self.newJobID, operation: "observe.other@1")))
    try accept(
      "targetDiffers", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, target: "target-other")))
    try accept(
      "outcomeUnknown", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, unknown: true)))
    try accept(
      "superseded", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, superseded: "epoch-1")))
    try accept(
      "requestConflict", source: device001.0, identity: device001.1,
      show: freshShow(request: other))
    try accept(
      "requestUnreadable", source: device001.0, identity: device001.1,
      show: freshShow(request: Self.with(fresh, ["requestId"], nil)))
    try accept(
      "requestReviewedDigest", source: device001.0, identity: device001.1,
      show: freshShow(
        request: Self.with(
          fresh, ["reviewedPlanDigest"], .string(String(repeating: "a", count: 64)))))
    try accept(
      "requestProvenance", source: device001.0, identity: device001.1,
      show: freshShow(
        request: Self.with(fresh, ["clientContext", "provenance", "extra"], .string("x"))))
    try accept(
      "requestOutputsDefault", source: device001.0, identity: device001.1,
      show: freshShow(request: Self.with(fresh, ["requestedOutputs"], nil)))
    try accept(
      "bindingDiffers", source: device001.0, identity: device001.1,
      show: freshShow(binding: 4))
    try accept(
      "identityDiffers", source: device001.0, identity: device001.1,
      show: freshShow(stableIdentity: String(repeating: "c", count: 64)))
    try accept(
      "effectDrift", source: device001.0, identity: device001.1,
      show: freshShow(status: Self.status(jobID: Self.newJobID, effect: "deviceMutation")))
    let hostFresh = try Self.json(
      drafts["hostOnly"]!.request(
        continuationRequestID: "continue-host-001", session: Self.session()))
    let hostAccepted = Self.show(
      jobID: Self.newJobID, request: hostFresh,
      status: Self.status(
        jobID: Self.newJobID, operation: "workspace.inspect-git-status@1",
        target: Self.hostTargetID, effect: "hostOnly"),
      provider: "workspace", binding: nil, stableIdentity: nil)
    try accept(
      "hostAccepted", source: "hostOnly", identity: "continue-host-001", show: hostAccepted)
    try accept(
      "hostGainedBinding", source: "hostOnly", identity: "continue-host-001",
      show: Self.with(
        Self.with(hostAccepted, ["materializedBindingRevision"], .integer(1)),
        ["materializedStableIdentitySha256"], .string(Self.identity)))

    // What `submit` and `run` emit.
    let emitted: [(String, String, JSONValue)] = [
      ("deviceReadOnly", "continue-001", Self.status(jobID: Self.newJobID)),
      (
        "hostOnly", "continue-host-001",
        Self.status(
          jobID: Self.newJobID, operation: "workspace.inspect-git-status@1",
          target: Self.hostTargetID, effect: "hostOnly")
      ),
    ]
    for (name, identity, job) in emitted {
      let draft = try XCTUnwrap(drafts[name], name)
      for (deduplicated, dispatched) in [(false, false), (true, true)] {
        projections.append(
          .object([
            "source": .string(name), "continuationRequestId": .string(identity),
            "jobId": .string(Self.newJobID), "deduplicated": .bool(deduplicated),
            "dispatched": .bool(dispatched), "job": job,
            "value": draft.projection(
              continuationRequestID: identity, jobID: Self.newJobID,
              deduplicated: deduplicated, dispatched: dispatched, job: job),
          ]))
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "cliCatalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
          "health": Self.health(),
          "sources": .array(sources),
          "requests": .array(requests),
          "accepted": .array(accepted),
          "projections": .array(projections),
        ])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIWorkspaceContinuationOracleContractTests"),
          "owners": .array([
            .string("CLIWorkspaceContinuationDraft.sourceRequiresCurrentTarget"),
            .string("CLIWorkspaceContinuationDraft.prepare"),
            .string("CLIWorkspaceContinuationDraft.request"),
            .string("CLIWorkspaceContinuationDraft.validateAcceptedJob"),
            .string("CLIWorkspaceContinuationDraft.projection"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
