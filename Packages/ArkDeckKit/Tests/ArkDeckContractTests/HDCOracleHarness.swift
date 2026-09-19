// What every Swift HDC oracle shares (CHG-2026-074, TASK-XPA-014).

import Darwin
import SQLite3
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The standalone daemon's engine composed in-process over the shared fake
/// HDC (`HDCOracleFake`) — the production daemon refuses an HDC executable
/// whose identity is not a registered one — one control frame at a time
/// through its handler, every answer recorded with the pager's random
/// revision labelled, and the files the Jobs leave recorded with each Job
/// record's machine facts labelled. What is an oracle's own — its cases, its
/// fake answers, its fixture directory and its record variable — stays in its
/// test class; the engine, the clock, the probe and the recording are one.
enum HDCOracleHarness {
  /// One oracle's fixed clock, roots and quota; recorded into its provenance.
  struct Settings {
    let root: URL
    let nowUTC: String
    let nowPreciseUTC: String
    /// Redaction replaces this home directory.
    let home: String
    /// The standalone daemon's Artifact quota.
    let quotaBytes: Int
  }

  struct Composition {
    let handler: RuntimeControlPlaneHandler
    /// The Artifact store the handler serves, for the inputs an oracle
    /// publishes before its Jobs run.
    let artifactStore: RuntimeArtifactStore
    let targets: URL
    let artifacts: URL
    let jobsState: URL
    let sessions: URL
    let owner: URL
    /// The daemon's agent execution owner and its directory, when composed.
    var agentExecutions: (owner: RuntimeAgentExecutionCoordinator, directory: URL)? = nil
    /// The daemon's human-action owner over those executions, when composed.
    var humanActions: RuntimeHumanActionResourceCoordinator? = nil
    /// The host directory received files land in, when an oracle fixed it.
    var receive: URL? = nil
    /// The duration every dispatched child reports, when an oracle fixed it.
    var invocationSeconds: Double? = nil
  }

  /// The process dispatcher with every invocation reported as having run for
  /// exactly `seconds`. How long a child ran is measured on the host's
  /// monotonic clock, so a verdict that keeps it — a screen sequence's
  /// per-frame durations and its rate, which reach the Job record, the
  /// sequence document and its digest — would differ on every run. Nothing
  /// else of the receipt changes: the same children run, in the same order,
  /// with the same exits, output and landed file.
  struct FixedDurationDispatcher: RuntimeProcessDispatching {
    let base: any RuntimeProcessDispatching
    let seconds: Double

    func unavailableReason(providerID: String) -> String? {
      base.unavailableReason(providerID: providerID)
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      fixed(try await base.dispatch(plan))
    }

    func dispatch(
      _ plan: TypedProcessPlan, progress: @escaping RuntimeProcessProgressHandler
    ) async throws -> ProviderProcessReceipt {
      fixed(try await base.dispatch(plan, progress: progress))
    }

    /// A sequence's duration is the sum of its children's, as the process
    /// dispatcher reports it.
    private func fixed(_ receipt: ProviderProcessReceipt) -> ProviderProcessReceipt {
      let subprocesses = receipt.subprocesses.map {
        ProviderSubprocessReceipt(
          exitStatus: $0.exitStatus, stdout: $0.stdout, stderr: $0.stderr,
          stdoutTruncated: $0.stdoutTruncated, durationSeconds: seconds)
      }
      return ProviderProcessReceipt(
        exitStatus: receipt.exitStatus, stdout: receipt.stdout, stderr: receipt.stderr,
        stdoutTruncated: receipt.stdoutTruncated,
        durationSeconds: subprocesses.isEmpty ? seconds : seconds * Double(subprocesses.count),
        hostManagedRecordID: receipt.hostManagedRecordID,
        hostManagedSummary: receipt.hostManagedSummary,
        landedArtifact: receipt.landedArtifact, subprocesses: subprocesses)
    }
  }

  /// The daemon's `TargetStoreFactsPort` with the oracle's clock: the adopted
  /// record's route, the identity its connect key names and the configured
  /// executable's digest.
  struct OracleFactsPort: HDCObservationFactsPort {
    let targetStore: RuntimeTargetStore
    let executableSHA256: String
    let nowUTC: String

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      guard let route = try targetStore.hdcExecutionRoute(targetID: targetID) else {
        throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
      }
      return ProviderFacts(
        providerID: "hdc", toolVersion: route.toolVersion, toolSHA256: executableSHA256,
        serverFacts: [:], targetID: route.targetID, bindingRevision: route.bindingRevision,
        deviceIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: route.connectKey),
        executionConnectKey: route.connectKey, deviceMode: "hdc", buildFingerprint: nil,
        profileID: "openharmony-standard@1",
        collectedAtUTC: nowUTC)
    }
  }

  /// This machine's volume with room for every Session claim.
  struct RoomyStorageProbe: HostStorageProbing {
    static let roomyBytes: UInt64 = 1 << 40

    func snapshot(for url: URL) throws -> HostStorageSnapshot {
      HostStorageSnapshot(
        volumeIdentity: try SystemVolumeIdentityResolver().resolve(url),
        totalBytes: Self.roomyBytes, availableBytes: Self.roomyBytes, isReadOnly: false)
    }
  }

  /// The standalone daemon's engine under the fixed root: the Target store,
  /// the Artifact store, the Job state with its capability store, the
  /// Session publication writer over a Sessions root and storage owner of
  /// the root's own, and the HDC provider over the fake — with the code-sign
  /// helper an oracle names, at a fixed path, when its operation sends one.
  /// With `agentExecutions`, also the daemon's agent execution owner under
  /// `agent-executions` beside them, on the oracle's clock, and the Target
  /// observation owner it is composed with, over the same provider and
  /// dispatcher as in the daemon. That owner brackets every device list with
  /// `usbRelations`, the independent USB observation (none unless an oracle
  /// names one). With `humanActions`, also the daemon's human-action owner
  /// over the executions, its pages under `human-action-snapshots` as the
  /// daemon keeps them. With `hdcRuntimeDiagnostics`, the handler has what
  /// the daemon's managed HDC server reported at startup, as the daemon gives
  /// it (none unless an oracle names it). With `hostReceiveRoot`, received
  /// files land there instead of in this user's temporary directory — the
  /// landing path is in the receive argv, so in the materialized plan and its
  /// digest — and the oracle records what is left in it. With
  /// `fixedInvocationSeconds`, every dispatched child reports that duration
  /// (`FixedDurationDispatcher`). Neither is applied unless an oracle names it.
  static func composition(
    hdc: URL, targetStore: RuntimeTargetStore, targets: URL, settings: Settings,
    nativeCodeSignHelper: HDCNativeCodeSignHelperArtifact? = nil, agentExecutions: Bool = false,
    humanActions: Bool = false,
    usbRelations: @escaping @Sendable () throws -> [TargetUSBRelation] = { [] },
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    hostReceiveRoot: URL? = nil,
    fixedInvocationSeconds: Double? = nil
  ) throws -> Composition {
    let root = settings.root
    let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: settings.quotaBytes),
      redaction: ArtifactRedactionPolicy(homeDirectory: settings.home),
      nowUTC: { settings.nowUTC })
    let jobsState = root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let sessions = root.appending(path: "Sessions", directoryHint: .isDirectory)
    let owner = root.appending(path: "session-owner", directoryHint: .isDirectory)
    let writer = RuntimeSessionPublicationWriter(
      owner: try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions),
      coordinator: HostStorageCoordinator(), probe: RoomyStorageProbe())
    let factsPort = OracleFactsPort(
      targetStore: targetStore, executableSHA256: SHA256Hex.string(of: HDCOracleFake.driver),
      nowUTC: settings.nowUTC)
    let provider: HDCObservationProviderAdapter
    if let nativeCodeSignHelper {
      provider = HDCObservationProviderAdapter(
        factsPort: factsPort,
        hostReceiveRoot: hostReceiveRoot
          ?? root.appending(path: "receive", directoryHint: .isDirectory),
        nativeCodeSignHelper: nativeCodeSignHelper)
    } else if let hostReceiveRoot {
      provider = HDCObservationProviderAdapter(
        factsPort: factsPort, hostReceiveRoot: hostReceiveRoot)
    } else {
      provider = HDCObservationProviderAdapter(factsPort: factsPort)
    }
    let providers = DeviceProviderRegistry(providers: [provider])
    let processes = DescriptorBoundProcessDispatcher(
      resolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc"))
    let dispatcher: any RuntimeProcessDispatching =
      fixedInvocationSeconds.map { FixedDurationDispatcher(base: processes, seconds: $0) }
      ?? processes
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState, sessionPublicationWriter: writer),
      providers: providers,
      dispatcher: dispatcher,
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { settings.nowUTC }, nowPreciseUTC: { settings.nowPreciseUTC })
    var executions: (owner: RuntimeAgentExecutionCoordinator, directory: URL)?
    var observations: TargetObservationCoordinator?
    if agentExecutions {
      let now = RuntimeAgentTime.parse(settings.nowPreciseUTC)
      let observing = TargetObservationCoordinator(
        observation: ProviderBootstrapObservation(
          provider: provider, dispatcher: dispatcher, nowUTC: { settings.nowUTC }),
        targetStore: targetStore, usbRelations: usbRelations, nowUTC: { settings.nowUTC })
      let directory = root.appending(path: "agent-executions", directoryHint: .isDirectory)
      executions = (
        try RuntimeAgentExecutionCoordinator(
          directory: directory, engine: engine, targets: targetStore, observations: observing,
          now: { now }),
        directory
      )
      observations = observing
    }
    var union: RuntimeHumanActionResourceCoordinator?
    if humanActions {
      union = try RuntimeHumanActionResourceCoordinator(
        directory: root.appending(path: "human-action-snapshots", directoryHint: .isDirectory),
        agents: executions?.owner, controlResources: nil)
    }
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: providers.registeredProviderIDs,
      nowUTC: { settings.nowUTC }, targetStore: targetStore, bootstrap: nil,
      targetObservations: observations, agentExecutions: executions?.owner,
      humanActionResources: union, hdcRuntimeDiagnostics: hdcRuntimeDiagnostics,
      artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)
    return Composition(
      handler: handler, artifactStore: store, targets: targets, artifacts: artifacts,
      jobsState: jobsState, sessions: sessions, owner: owner, agentExecutions: executions,
      humanActions: union, receive: hostReceiveRoot, invocationSeconds: fixedInvocationSeconds)
  }

  /// One recorded request and its answer; a run names the fake's mode.
  static func exchange(
    _ name: String, _ method: String, _ params: [String: JSONValue], _ answer: JSONValue,
    mode: String? = nil
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "name": .string(name), "method": .string(method), "params": .object(params),
      "answer": revisionIndependent(answer),
    ]
    if let mode { fields["mode"] = .string(mode) }
    return .object(fields)
  }

  /// An Artifact list names the snapshot it paged by a revision the pager
  /// mints at random, so the oracle keeps its name, not its value.
  static func revisionIndependent(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      return .object(
        fields.reduce(into: [:]) { result, field in
          if field.key == "snapshotRevision", case .string = field.value {
            result[field.key] = .string("<snapshotRevision>")
          } else {
            result[field.key] = revisionIndependent(field.value)
          }
        })
    case .array(let items):
      return .array(items.map(revisionIndependent))
    default:
      return value
    }
  }

  /// One control frame through the handler, answered as the oracle records it.
  static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue],
    frameID: String
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string(frameID), "method": .string(method),
        "params": .object(params),
      ]))
    let response = await handler.handleFrame(frame)
    var fields: [String: JSONValue] = ["ok": .bool(response.ok)]
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var body: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { body["details"] = .object(details) }
      fields["error"] = .object(body)
    }
    return .object(fields)
  }

  /// What the oracle records: the fake and every call it received, the
  /// Target document, the cases, the Job index, every Artifact and the
  /// Artifact store's own ledgers beside the Job directories, every file
  /// below the Job directories, the capability store, the Sessions root, the
  /// storage owner and the agent execution directory when composed (dot
  /// entries included, each Job record's machine facts as labels), every such
  /// entry's kind and mode, and the provenance of all of them.
  static func files(
    _ composition: Composition, target: RuntimeTargetRecord, cases: JSONValue,
    answers: String, producer: String, settings: Settings,
    identities: RandomIdentities? = nil
  ) throws -> [String: Data] {
    let manager = FileManager.default
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "hdc": HDCOracleFake.driver,
      "hdc-answers.sh": Data(answers.utf8),
      "hdc-invocations.log": try HDCOracleFake.invocations(),
      "targets-state/targets.json": try Data(
        contentsOf: composition.targets.appending(path: "targets.json")),
      "cases.json": try encoder.encode(cases) + Data("\n".utf8),
      "store/index.json":
        try encoder.encode(try index(of: composition.jobsState)) + Data("\n".utf8),
    ]
    for entry in try manager.contentsOfDirectory(atPath: composition.artifacts.path).sorted()
    where !entry.hasPrefix(".") {
      let url = composition.artifacts.appending(path: entry)
      var isDirectory: ObjCBool = false
      guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      guard isDirectory.boolValue else {
        files["artifacts/\(entry)"] = try Data(contentsOf: url)
        continue
      }
      for name in try manager.contentsOfDirectory(atPath: url.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(entry)/\(name)"] = try Data(contentsOf: url.appending(path: name))
      }
    }
    var tree: [JSONValue] = []
    var roots = [
      (composition.jobsState.appending(path: "jobs", directoryHint: .isDirectory), "store/jobs"),
      (
        composition.jobsState.appending(path: "capabilities", directoryHint: .isDirectory),
        "store/capabilities"
      ),
      (composition.sessions, "sessions"), (composition.owner, "session-owner"),
    ]
    if let executions = composition.agentExecutions {
      roots.append((executions.directory, "agent-executions"))
    }
    // What the Jobs left where received files land: a published file is the
    // store's, so its landing copy does not outlive the publication.
    if let receive = composition.receive, manager.fileExists(atPath: receive.path) {
      roots.append((receive, "receive"))
    }
    for (directory, prefix) in roots {
      for path in try manager.subpathsOfDirectory(atPath: directory.path).sorted() {
        let url = directory.appending(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        // A pager snapshot is named and filled by a random revision, so the
        // oracle keeps that it exists and its mode, not its name or bytes.
        let snapshot = prefix == "agent-executions" && !isDirectory && isPagerSnapshot(path)
        tree.append(
          .object([
            "path": .string(
              snapshot ? "\(prefix)/snapshots/snapshot-<revision>.json" : "\(prefix)/\(path)"),
            "kind": .string(isDirectory ? "directory" : "file"),
            "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
          ]))
        guard !isDirectory, !snapshot else { continue }
        let data = try Data(contentsOf: url)
        files["\(prefix)/\(path)"] =
          url.lastPathComponent == "job-record.json" ? machineIndependent(data) : data
      }
    }
    files["tree.json"] = try encoder.encode(JSONValue.array(tree)) + Data("\n".utf8)
    // Identities minted at random read as labels, every file in path order
    // after the answers, as a replay reads its own.
    if let identities {
      for path in files.keys.sorted() { files[path] = identities.label(files[path]!) }
    }
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    var provenance: [String: JSONValue] = [
      "producer": .string(producer),
      "root": .string(settings.root.path),
      "sessionsRoot": .string(composition.sessions.path),
      "sessionOwner": .string(composition.owner.path),
      "availableBytes": .integer(Int64(RoomyStorageProbe.roomyBytes)),
      "nowUTC": .string(settings.nowUTC),
      "nowPreciseUTC": .string(settings.nowPreciseUTC),
      "home": .string(settings.home),
      "quotaBytes": .integer(Int64(settings.quotaBytes)),
      "hdcSHA256": .string(SHA256Hex.string(of: HDCOracleFake.driver)),
      "targetId": .string(target.targetID),
      "files": .object(digests),
    ]
    if let executions = composition.agentExecutions {
      provenance["agentExecutions"] = .string(executions.directory.path)
    }
    if let receive = composition.receive {
      provenance["receiveRoot"] = .string(receive.path)
    }
    if let seconds = composition.invocationSeconds {
      provenance["invocationSeconds"] = .number(seconds)
    }
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    return files
  }

  /// `snapshots/snapshot-<revision>.json` below the agent execution directory:
  /// a page snapshot `RuntimeSnapshotPager` wrote under a random revision.
  static func isPagerSnapshot(_ path: String) -> Bool {
    let prefix = "snapshots/snapshot-"
    let suffix = ".json"
    guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
    let revision = String(path.dropFirst(prefix.count).dropLast(suffix.count))
    return UUID(uuidString: revision)?.uuidString.lowercased() == revision
  }

  /// The identities the agent execution and Target observation owners mint
  /// at random — a human action's own, its resume reference and its
  /// selections' values, and the observations they name — read as
  /// `<har-1>`, `<resume-1>`, `<candidate-1>` and `<obs-1>` by the order they
  /// first appear in: each recorded answer's canonical text in exchange
  /// order, then each recorded file's text in path order. A replay labels its
  /// own identities the same way, and a request naming a label sends the
  /// identity it stands for.
  final class RandomIdentities {
    private static let pattern = try! NSRegularExpression(
      pattern:
        "(har|resume|candidate|obs)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private var labels: [String: String] = [:]
    private var counts: [String: Int] = [:]

    func label(_ text: String) -> String {
      let source = text as NSString
      var result = ""
      var last = 0
      for match in Self.pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += source.substring(with: NSRange(location: last, length: match.range.location - last))
        let identity = source.substring(with: match.range)
        if labels[identity] == nil {
          let kind = source.substring(with: match.range(at: 1))
          counts[kind, default: 0] += 1
          labels[identity] = "<\(kind)-\(counts[kind]!)>"
        }
        result += labels[identity]!
        last = match.range.location + match.range.length
      }
      return result + source.substring(from: last)
    }

    /// A recorded file, when it is text naming such an identity; any other
    /// file, bytes included, as it is.
    func label(_ data: Data) -> Data {
      guard let text = String(data: data, encoding: .utf8),
        Self.pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
      else { return data }
      return Data(label(text).utf8)
    }

    /// An answer or a request as the oracle records it: its canonical text
    /// labelled.
    func label(_ value: JSONValue) throws -> JSONValue {
      let text = String(decoding: try CanonicalJSONEncoders.canonical().encode(value), as: UTF8.self)
      return try JSONDecoder().decode(JSONValue.self, from: Data(label(text).utf8))
    }
  }

  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  static func recordOrCompare(_ files: [String: Data], variable: String, oracle: URL) throws {
    if let output = ProcessInfo.processInfo.environment[variable] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    let produced = Set(files.keys)
    XCTAssertEqual(
      Set(recorded), produced,
      "recorded only: \(Set(recorded).subtracting(produced).sorted()); "
        + "produced only: \(produced.subtracting(recorded).sorted())")
    for (path, data) in files.sorted(by: { $0.key < $1.key }) {
      let expected = try Data(contentsOf: oracle.appending(path: path))
      XCTAssertEqual(expected, data, "\(path)\(firstDifference(recorded: expected, produced: data))")
    }
  }

  /// Where two files first differ and what surrounds it, so that a mismatch of
  /// two files of the same size names the value rather than the size.
  static func firstDifference(recorded: Data, produced: Data) -> String {
    guard recorded != produced else { return "" }
    let index =
      zip(recorded, produced).enumerated().first { $0.element.0 != $0.element.1 }?.offset
      ?? min(recorded.count, produced.count)
    func excerpt(_ data: Data) -> String {
      let lower = max(0, index - 60)
      let upper = min(data.count, index + 60)
      let text = String(decoding: data.subdata(in: lower..<upper), as: UTF8.self)
      return text.replacingOccurrences(of: "\n", with: "⏎")
    }
    return " differs at byte \(index) of \(recorded.count)/\(produced.count): recorded «"
      + excerpt(recorded) + "» produced «" + excerpt(produced) + "»"
  }

  /// What a reader observes of the Job index without writing: layout,
  /// pragmas and every row, each row's record by its digest.
  static func index(of state: URL) throws -> JSONValue {
    var handle: OpaquePointer?
    let path = state.appending(path: RuntimeJobRepository.filename).path
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let db = handle
    else {
      if let handle { sqlite3_close_v2(handle) }
      throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close_v2(db) }
    func rows(_ sql: String) throws -> [[JSONValue]] {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
      else { throw CocoaError(.fileReadCorruptFile) }
      defer { sqlite3_finalize(statement) }
      var result: [[JSONValue]] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        result.append(
          (0..<sqlite3_column_count(statement)).map { column -> JSONValue in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
              return .integer(sqlite3_column_int64(statement, column))
            case SQLITE_TEXT:
              return .string(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            case SQLITE_BLOB:
              let count = Int(sqlite3_column_bytes(statement, column))
              let bytes =
                sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) }
                ?? Data()
              return .string(SHA256Hex.string(of: machineIndependent(bytes)))
            default:
              return .null
            }
          })
      }
    }
    let schema = try rows("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name").map {
      JSONValue.object(["name": $0[0], "type": $0[1], "tableName": $0[2], "sql": $0[3]])
    }
    let jobs = try rows(
      """
      SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc,
             created_at_order_key, updated_at_utc, version, initial_record_json
      FROM runtime_job ORDER BY admission_sequence
      """)
    return .object([
      "userVersion": try rows("PRAGMA user_version")[0][0],
      "journalMode": try rows("PRAGMA journal_mode")[0][0],
      "schema": .array(schema),
      "rows": .array(
        jobs.map { row in
          .object([
            "jobId": row[0], "idempotencyKey": row[1], "requestHash": row[2], "state": row[3],
            "admissionSequence": row[4], "createdAtUTC": row[5], "createdAtOrderKey": row[6],
            "updatedAtUTC": row[7], "version": row[8], "recordSHA256": row[9],
          ])
        }),
    ])
  }

  private static let machineFact = try! NSRegularExpression(
    pattern: #""(device|inode|volumeIdentity|admissionGeneration)"( ?: ?)"([^"]*)""#)

  /// A record's facts of this machine's volume, labelled by their names.
  static func machineIndependent(_ data: Data) -> Data {
    let source = String(decoding: data, as: UTF8.self)
    let text = NSMutableString(string: source)
    let matches = machineFact.matches(
      in: source, range: NSRange(location: 0, length: text.length))
    for match in matches.reversed() {
      let value = text.substring(with: match.range(at: 3))
      guard !value.isEmpty, value != "0" else { continue }
      text.replaceCharacters(
        in: match.range(at: 3), with: "<\(text.substring(with: match.range(at: 1)))>")
    }
    return Data((text as String).utf8)
  }
}
