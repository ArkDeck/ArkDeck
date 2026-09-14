// Shared Swift oracle for the Rust `observe.device@1` engine (CHG-2026-074, TASK-XPA-014).

import Darwin
import SQLite3
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `observe.device@1` over the shared fake HDC (`HDCOracleFake`): the
/// oracle `rust/crates/arkdeck-hoststore/tests/observe_device.rs` replays
/// against the Rust planner, admitter, runner and readers. One device is
/// adopted; each case then plans a request for it, and a case with a mode also
/// admits it and runs its Job while the fake answers in that mode, so the Jobs
/// run in order over one store: one observes the device, one meets a server
/// of another version, one finds another device's row, and one gets no
/// version at all and parks. The other cases are refused before admission: a
/// stale binding revision, a request without one and a target never adopted.
/// A second run of the observed Job is refused, and every Job's result,
/// evidence and Artifact list are read last. The oracle keeps every answer,
/// each call the fake received, and the store the Jobs leave: the Target
/// document, the Job index and files, every Artifact index and payload, the
/// Sessions and the storage owner.
///
/// The production daemon refuses an HDC executable whose identity is not a
/// registered one, so the oracle composes the standalone daemon's engine
/// in-process, with its Session publication writer and with the daemon's
/// Target facts port over the fake. Record a new oracle with
/// `ARKDECK_RUST_OBSERVE_DEVICE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ObserveDeviceOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    /// The fake's mode while this case's Job runs; a case without one only
    /// plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The binding revision the request expects; none is sent when nil.
    var bindingRevision: Int? = 1
    /// A target other than the adopted one.
    var target: String?
  }

  private static let cases: [Case] = [
    Case(name: "observed", mode: "normal", ends: "succeeded"),
    Case(name: "serverMismatch", mode: "serverMismatch", ends: "failed"),
    Case(name: "otherDevice", mode: "otherDevice", ends: "failed"),
    Case(name: "emptyVersion", mode: "emptyVersion", ends: "waitingForRecovery"),
    Case(name: "staleBinding", bindingRevision: 2),
    Case(name: "unboundRequest", bindingRevision: nil),
    Case(name: "unadopted", target: "TGT-000000000000"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/observe-device", directoryHint: .isDirectory)
  private static let root = HDCOracleFake.root
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let nowPreciseUTC = "2026-09-14T00:00:00.000Z"
  /// Redaction replaces this home directory.
  private static let home = "/private/tmp/arkdeck-hdc-oracle/home"
  /// The standalone daemon's Artifact quota.
  private static let quotaBytes = 8 * 1024 * 1024 * 1024
  private static let connectKey = String(repeating: "a", count: 32)

  /// `ArkDeckFakeHDCFixture`'s answers to what `observe.device@1` asks, by
  /// mode: `serverMismatch` reports a server of another version,
  /// `otherDevice` lists another device's row, and `emptyVersion` answers the
  /// version probe with nothing.
  private static let answers = #"""
    # observe.device@1 answers of ArkDeckFakeHDCFixture, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$*" in
    "-v")
      [ "$mode" = emptyVersion ] || printf 'Ver: 3.2.0d\n' ;;
    "checkserver")
      if [ "$mode" = serverMismatch ]; then server=3.2.0f; else server=3.2.0d; fi
      printf 'Client version:Ver: 3.2.0d, server version:Ver: %s\n' "$server" ;;
    "list targets -v")
      if [ "$mode" = otherDevice ]; then row=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else row=$key; fi
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$row" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftObservesTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try Self.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_OBSERVE_DEVICE_RECORD")
  }

  /// The daemon's `TargetStoreFactsPort` with the oracle's clock: the adopted
  /// record's route, the identity its connect key names and the configured
  /// executable's digest.
  private struct OracleFactsPort: HDCObservationFactsPort {
    let targetStore: RuntimeTargetStore
    let executableSHA256: String

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
        collectedAtUTC: ObserveDeviceOracleContractTests.nowUTC)
    }
  }

  /// This machine's volume with room for every Session claim.
  private struct RoomyStorageProbe: HostStorageProbing {
    static let roomyBytes: UInt64 = 1 << 40

    func snapshot(for url: URL) throws -> HostStorageSnapshot {
      HostStorageSnapshot(
        volumeIdentity: try SystemVolumeIdentityResolver().resolve(url),
        totalBytes: Self.roomyBytes, availableBytes: Self.roomyBytes, isReadOnly: false)
    }
  }

  private struct Composition {
    let handler: RuntimeControlPlaneHandler
    let targets: URL
    let artifacts: URL
    let jobsState: URL
    let sessions: URL
    let owner: URL
  }

  /// The standalone daemon's engine under the fixed root: the Target store,
  /// the Artifact store, the Job state with its capability store, the
  /// Session publication writer over a Sessions root and storage owner of
  /// the root's own, and the HDC provider over the fake.
  private static func composition(hdc: URL, targetStore: RuntimeTargetStore, targets: URL) throws
    -> Composition
  {
    let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifacts, quota: ArtifactQuota(totalBytes: quotaBytes),
      redaction: ArtifactRedactionPolicy(homeDirectory: home), nowUTC: { nowUTC })
    let jobsState = root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: jobsState.appending(path: "capabilities", directoryHint: .isDirectory))
    let sessions = root.appending(path: "Sessions", directoryHint: .isDirectory)
    let owner = root.appending(path: "session-owner", directoryHint: .isDirectory)
    let writer = RuntimeSessionPublicationWriter(
      owner: try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions),
      coordinator: HostStorageCoordinator(), probe: RoomyStorageProbe())
    let provider = HDCObservationProviderAdapter(
      factsPort: OracleFactsPort(
        targetStore: targetStore, executableSHA256: SHA256Hex.string(of: HDCOracleFake.driver)))
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: jobsState, sessionPublicationWriter: writer),
      providers: providers,
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc")),
      capabilityStore: capabilities, artifactStore: store,
      nowUTC: { nowUTC }, nowPreciseUTC: { nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: providers.registeredProviderIDs,
      nowUTC: { nowUTC }, targetStore: targetStore, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)
    return Composition(
      handler: handler, targets: targets, artifacts: artifacts, jobsState: jobsState,
      sessions: sessions, owner: owner)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    var bound: [String: JSONValue] = ["targetId": .string(item.target ?? target)]
    if let revision = item.bindingRevision {
      bound["expectedBindingRevision"] = .integer(Int64(revision))
    }
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-observe-\(item.name)"),
      "idempotencyKey": .string("idem-observe-\(item.name)"),
      "target": .object(bound),
      "operation": .object(["id": .string("observe.device"), "version": .integer(1)]),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.root) }
    let targets = Self.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.nowUTC
    ).record
    let composition = try Self.composition(hdc: hdc, targetStore: targetStore, targets: targets)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: adopted.targetID))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(Self.exchange("\(item.name).plan", "job.plan", params, plan))
      guard let mode = item.mode else { continue }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(Self.exchange("\(item.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else { throw CocoaError(.coderInvalidValue) }
      jobs.append((item.name, job))
      try HDCOracleFake.setMode(mode)
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      exchanges.append(
        Self.exchange("\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        throw CocoaError(.coderInvalidValue)
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
    let observed = ["jobId": JSONValue.string(jobs[0].job)]
    exchanges.append(
      Self.exchange(
        "observed.rerun", "job.run", observed,
        try await Self.send(composition.handler, "job.run", observed)))
    for (name, job) in jobs {
      let reads: [(String, String, [String: JSONValue])] = [
        ("result", "job.result", ["jobId": .string(job)]),
        ("evidence", "job.evidence", ["jobId": .string(job)]),
        (
          "artifacts", "artifact.list",
          [
            "owner": .object(["kind": .string("job"), "id": .string(job)]),
            "pageSize": .integer(1000),
          ]
        ),
      ]
      for (read, method, params) in reads {
        let answer = try await Self.send(composition.handler, method, params)
        exchanges.append(Self.exchange("\(name).\(read)", method, params, answer))
      }
    }
    return try Self.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]))
  }

  /// One recorded request and its answer; a run names the fake's mode.
  private static func exchange(
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
  private static func revisionIndependent(_ value: JSONValue) -> JSONValue {
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
  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("observe-device-oracle"), "method": .string(method),
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
  /// Target document, the cases, the Job index, every Artifact, every file
  /// below the Job directories, the Sessions root and the storage owner (dot
  /// entries included, each Job record's machine facts as labels), every such
  /// entry's kind and mode, and the provenance of all of them.
  private static func files(
    _ composition: Composition, target: RuntimeTargetRecord, cases: JSONValue
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
    for job in try manager.contentsOfDirectory(atPath: composition.artifacts.path).sorted()
    where !job.hasPrefix(".") {
      let directory = composition.artifacts.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted()
      where !name.hasPrefix(".") {
        files["artifacts/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    var tree: [JSONValue] = []
    for (directory, prefix) in [
      (composition.jobsState.appending(path: "jobs", directoryHint: .isDirectory), "store/jobs"),
      (composition.sessions, "sessions"), (composition.owner, "session-owner"),
    ] {
      for path in try manager.subpathsOfDirectory(atPath: directory.path).sorted() {
        let url = directory.appending(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        tree.append(
          .object([
            "path": .string("\(prefix)/\(path)"),
            "kind": .string(isDirectory ? "directory" : "file"),
            "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
          ]))
        guard !isDirectory else { continue }
        let data = try Data(contentsOf: url)
        files["\(prefix)/\(path)"] =
          url.lastPathComponent == "job-record.json" ? machineIndependent(data) : data
      }
    }
    files["tree.json"] = try encoder.encode(JSONValue.array(tree)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "ObserveDeviceOracleContractTests.testSwiftObservesTheSharedFakeDevice"),
          "root": .string(root.path),
          "sessionsRoot": .string(composition.sessions.path),
          "sessionOwner": .string(composition.owner.path),
          "availableBytes": .integer(Int64(RoomyStorageProbe.roomyBytes)),
          "nowUTC": .string(nowUTC),
          "nowPreciseUTC": .string(nowPreciseUTC),
          "home": .string(home),
          "quotaBytes": .integer(Int64(quotaBytes)),
          "hdcSHA256": .string(SHA256Hex.string(of: HDCOracleFake.driver)),
          "targetId": .string(target.targetID),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }

  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  private static func recordOrCompare(_ files: [String: Data], variable: String) throws {
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
    XCTAssertEqual(Set(recorded), Set(files.keys))
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: oracle.appending(path: path)), data, path)
    }
  }

  /// What a reader observes of the Job index without writing: layout,
  /// pragmas and every row, each row's record by its digest.
  private static func index(of state: URL) throws -> JSONValue {
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
  private static func machineIndependent(_ data: Data) -> Data {
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
