import ArkDeckRuntime
import ArkDeckStorage
import Darwin
import XCTest

final class DiagnosticsContractTests: XCTestCase {
  func testTEST_AC_DIAG_001_01_boundedRotationAndCleanup() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-rotation")
    defer { try? FileManager.default.removeItem(at: base) }
    let configuration = try StructuredDiagnosticLogConfiguration(
      quotaBytes: 4_096, segmentBytes: 2_048, maximumRecordBytes: 1_024)
    let logDirectory = base.appending(path: "logs")
    var lastSegment: URL?
    do {
      let store = try StructuredDiagnosticLogStore(
        directory: logDirectory, configuration: configuration)
      let logger = SystemLogger(
        structuredStore: store, unifiedLogger: CapturedUnifiedDiagnosticLogger(),
        auditClock: FixedDiagnosticAuditClock())

      for _ in 0..<200 {
        try logger.log(
          level: .info, category: .app, eventName: .rotationSample,
          correlationID: DiagnosticCorrelationID(),
          fields: [.publicCode: .publicCode(.rotationSample)])
      }

      let snapshot = try store.snapshot()
      XCTAssertLessThanOrEqual(store.retainedBytes, configuration.quotaBytes)
      XCTAssertEqual(snapshot.totalBytes, store.retainedBytes)
      XCTAssertLessThanOrEqual(snapshot.totalBytes, configuration.quotaBytes)
      XCTAssertGreaterThan(
        snapshot.files.first?.name ?? "", "diagnostics-00000000000000000000.jsonl")
      XCTAssertGreaterThan(snapshot.files.count, 0)
      XCTAssertTrue(snapshot.files.allSatisfy { $0.data.last == 0x0A })
      XCTAssertEqual(try DiagnosticsFixtures.redactedLogFiles(snapshot).count, snapshot.files.count)
      lastSegment = logDirectory.appending(path: try XCTUnwrap(snapshot.files.last).name)
      print(
        "TEST-AC-DIAG-001-01 quota=\(configuration.quotaBytes) retained=\(snapshot.totalBytes) segments=\(snapshot.files.count)"
      )
    }

    let handle = try FileHandle(forWritingTo: try XCTUnwrap(lastSegment))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("torn-sensitive-tail".utf8))
    try handle.close()
    let reopened = try StructuredDiagnosticLogStore(
      directory: logDirectory, configuration: configuration)
    let repaired = try reopened.snapshot()
    XCTAssertTrue(repaired.files.allSatisfy { $0.data.last == 0x0A })
    XCTAssertFalse(repaired.files.contains { $0.data.contains(Data("torn-sensitive-tail".utf8)) })
    XCTAssertLessThanOrEqual(repaired.totalBytes, configuration.quotaBytes)
  }

  func testTEST_AC_DIAG_001_02_fiveCategoriesRedactBeforeBothSinks() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-redaction")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try StructuredDiagnosticLogStore(directory: base.appending(path: "logs"))
    let unified = CapturedUnifiedDiagnosticLogger()
    let logger = SystemLogger(
      structuredStore: store, unifiedLogger: unified,
      auditClock: FixedDiagnosticAuditClock())

    for category in SystemLogCategory.allCases {
      try logger.log(
        level: .warning, category: category, eventName: .privacyContract,
        correlationID: DiagnosticCorrelationID(),
        fields: [
          .device: .deviceIdentifier(DiagnosticsFixtures.deviceIdentifier),
          .path: .userPath(DiagnosticsFixtures.userPath),
          .business: .businessString(DiagnosticsFixtures.businessString),
          .publicCode: .publicCode(.diagnosticsTest),
        ])
    }

    let structured = try DiagnosticsFixtures.decodedRecords(store.snapshot())
    XCTAssertEqual(Set(structured.map(\.category)), Set(SystemLogCategory.allCases))
    XCTAssertEqual(Set(unified.records.map(\.category)), Set(SystemLogCategory.allCases))
    XCTAssertEqual(structured, unified.records.map(DecodedDiagnosticRecord.init))
    let structuredBytes = try XCTUnwrap(store.snapshot().files.first).data
    let unifiedBytes = try JSONEncoder().encode(unified.records)
    for sensitive in [
      DiagnosticsFixtures.deviceIdentifier, DiagnosticsFixtures.userPath,
      DiagnosticsFixtures.businessString,
    ] {
      XCTAssertFalse(structuredBytes.contains(Data(sensitive.utf8)))
      XCTAssertFalse(unifiedBytes.contains(Data(sensitive.utf8)))
    }
    XCTAssertTrue(structuredBytes.contains(Data("[REDACTED-DEVICE-ID]".utf8)))
    XCTAssertTrue(structuredBytes.contains(Data("[REDACTED-USER-PATH]".utf8)))
    XCTAssertTrue(structuredBytes.contains(Data("[REDACTED-BUSINESS-STRING]".utf8)))
    XCTAssertEqual(Set(structured.map(\.correlationID)).count, 5)
    for file in try DiagnosticsFixtures.redactedLogFiles(store.snapshot()) {
      XCTAssertTrue(file.data.contains(Data("\"eventName\":\"privacy.contract\"".utf8)))
      XCTAssertTrue(file.data.contains(Data("\"publicCode\":\"diagnostics.test\"".utf8)))
      for correlationID in structured.map(\.correlationID) {
        XCTAssertTrue(file.data.contains(Data(correlationID.utf8)))
      }
    }
  }

  func testTEST_AC_DIAG_001_02_untrustedExportLogIsRejected() throws {
    let malicious = Data(
      """
      {"category":"app","correlationId":"\(DiagnosticsFixtures.deviceIdentifier)","eventName":"\(DiagnosticsFixtures.deviceIdentifier)","fields":{"\(DiagnosticsFixtures.deviceIdentifier)":"\(DiagnosticsFixtures.businessString)","path":"\(DiagnosticsFixtures.userPath)"},"level":"warning","schemaVersion":"1.0.0","timestamp":"2026-07-17T08:00:00Z"}

      """.utf8)
    XCTAssertThrowsError(
      try RedactedDiagnosticLogFile(
        name: "diagnostics-00000000000000000000.jsonl", data: malicious))

    XCTAssertThrowsError(
      try RedactedDiagnosticLogFile(name: "customer-secret.jsonl", data: malicious)
    ) { error in
      guard case .invalidInput = error as? LocalDiagnosticBundleError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    let unknownRootMember = Data(malicious.dropLast())
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: unknownRootMember) as? [String: Any])
    object["untrusted"] = DiagnosticsFixtures.businessString
    var invalidShape = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    invalidShape.append(0x0A)
    XCTAssertThrowsError(
      try RedactedDiagnosticLogFile(
        name: "diagnostics-00000000000000000001.jsonl", data: invalidShape))
  }

  func testTEST_AC_DIAG_001_02_typedFieldCannotMisclassifyDeviceIdentifier() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-public-catalog")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try StructuredDiagnosticLogStore(directory: base.appending(path: "logs"))
    let unified = CapturedUnifiedDiagnosticLogger()
    let logger = SystemLogger(
      structuredStore: store, unifiedLogger: unified,
      auditClock: FixedDiagnosticAuditClock())

    XCTAssertThrowsError(
      try logger.log(
        level: .warning, category: .app, eventName: .privacyContract,
        correlationID: DiagnosticCorrelationID(),
        fields: [.publicCode: .deviceIdentifier(DiagnosticsFixtures.deviceIdentifier)])
    ) { error in
      XCTAssertEqual(error as? SystemLoggerError, .invalidFieldPrivacy)
    }
    XCTAssertTrue(unified.records.isEmpty)
    XCTAssertFalse(
      try store.snapshot().files.contains {
        $0.data.contains(Data(DiagnosticsFixtures.deviceIdentifier.utf8))
      })
  }

  func testTEST_AC_DIAG_002_01_crashAndJobFailureCannotMaterializeExport() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-trigger")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try StructuredDiagnosticLogStore(directory: base.appending(path: "logs"))
    try SystemLogger(
      structuredStore: store, unifiedLogger: CapturedUnifiedDiagnosticLogger(),
      auditClock: FixedDiagnosticAuditClock()
    ).log(
      level: .error, category: .workflow, eventName: .jobFailed,
      correlationID: DiagnosticCorrelationID(),
      fields: [.code: .publicCode(.fixtureFailure)])
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination,
      logs: DiagnosticsFixtures.redactedLogFiles(store.snapshot()), session: session)
    let exporter = try LocalDiagnosticBundleExporter()
    let preview = try exporter.preview(request)

    for trigger in [DiagnosticExportTrigger.appCrash, .jobFailure] {
      XCTAssertThrowsError(
        try exporter.export(request, trigger: trigger, approvedPreview: preview)
      ) { error in
        XCTAssertEqual(error as? LocalDiagnosticBundleError, .explicitUserInitiationRequired)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    let materialized = try exporter.export(
      request, trigger: .userInitiated, approvedPreview: preview)
    XCTAssertEqual(materialized.root, destination)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    let manifest = try Data(contentsOf: destination.appending(path: "bundle.json"))
    XCTAssertTrue(manifest.contains(Data("\"automaticUploadEnabled\":false".utf8)))
  }

  func testTEST_AC_DIAG_002_01_exportUsesThePreparedBytesApprovedForPublication() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-preview-binding")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let sourceManifest = session.materialized.root.appending(path: "manifest.json")
    let originalManifest = try Data(contentsOf: sourceManifest)
    let originalSHA256 = try SessionManifestDocument(data: originalManifest).sha256
    let changedManifest = try SessionStorageFixtures.manifest(
      sessionID: "session-diagnostics", jobID: "job-diagnostics",
      warnings: ["changed-after-approved-bytes-were-prepared"])
    let changedSHA256 = try SessionManifestDocument(data: changedManifest).sha256
    XCTAssertNotEqual(originalSHA256, changedSHA256)

    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let exporter = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterPreparedForExport else { return }
        try changedManifest.write(to: sourceManifest)
      })
    let preview = try exporter.preview(request)
    _ = try exporter.export(request, trigger: .userInitiated, approvedPreview: preview)

    let summary = try Data(
      contentsOf: destination.appending(
        path: "sessions/recent-0000/manifest-summary.json"))
    XCTAssertTrue(summary.contains(Data(originalSHA256.utf8)))
    XCTAssertFalse(summary.contains(Data(changedSHA256.utf8)))
  }

  func testTEST_AC_DIAG_002_01_rejectsMismatchedJournalSummaryIdentity() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-journal-identity")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let variants = [
      (sessionID: "other-session", jobID: "job-diagnostics", executionMode: "simulated"),
      (sessionID: "session-diagnostics", jobID: "other-job", executionMode: "simulated"),
      (sessionID: "session-diagnostics", jobID: "job-diagnostics", executionMode: "execute"),
    ]

    for (index, variant) in variants.enumerated() {
      let journalURL = base.appending(path: "mismatched-journal-\(index).jsonl")
      do {
        let journal = try FileDurableJournal(url: journalURL)
        try journal.appendAndSynchronize(
          JournalEvent.jobCreated(
            eventID: "mismatched-created-\(index)", sequence: 0,
            sessionID: variant.sessionID, jobID: variant.jobID,
            timestamp: SessionStorageFixtures.timestamp,
            executionMode: variant.executionMode))
      }
      let replay = try DurableJournalRecovery.inspect(url: journalURL)
      let destination = base.appending(path: "diagnostic-bundle-\(index)")
      let baseline = try DiagnosticsFixtures.bundleRequest(
        destination: destination, logs: [], session: session)
      let request = LocalDiagnosticBundleRequest(
        destination: destination, metadata: baseline.metadata, tool: baseline.tool, logs: [],
        recentSessions: [
          RecentSessionDiagnosticSource(export: session.materialized, journalReplay: replay)
        ])

      XCTAssertThrowsError(try LocalDiagnosticBundleExporter().preview(request)) { error in
        guard case .invalidInput(let message) = error as? LocalDiagnosticBundleError else {
          return XCTFail("unexpected journal identity error: \(error)")
        }
        XCTAssertTrue(message.contains("identity does not match"))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testTEST_AC_DIAG_002_01_parentReplacementCannotRedirectPublishOrCleanup() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-parent-binding")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let exportParent = base.appending(path: "approved-parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let displacedParent = base.appending(path: "displaced-approved-parent")
    let replacementMarker = Data("replacement-parent-must-survive-cleanup".utf8)
    let replacementMarkerURL = exportParent.appending(path: "marker")
    let destination = exportParent.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let exporter = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterStagingOpened else { return }
        try FileManager.default.moveItem(at: exportParent, to: displacedParent)
        try FileManager.default.createDirectory(
          at: exportParent, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        try replacementMarker.write(to: replacementMarkerURL)
      })
    let preview = try exporter.preview(request)

    XCTAssertThrowsError(
      try exporter.export(request, trigger: .userInitiated, approvedPreview: preview)
    ) { error in
      guard case .invalidInput(let message) = error as? LocalDiagnosticBundleError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("parent changed"))
    }
    XCTAssertEqual(try Data(contentsOf: replacementMarkerURL), replacementMarker)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: displacedParent.appending(path: "diagnostic-bundle").path))
    let displacedEntries = try FileManager.default.contentsOfDirectory(atPath: displacedParent.path)
    XCTAssertFalse(displacedEntries.contains { $0.hasPrefix(".diagnostic-bundle.") })
  }

  func testTEST_AC_DIAG_002_01_previewRejectsParentReplacementBeforeExport() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-preview-parent")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let exportParent = base.appending(path: "approved-parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let displacedParent = base.appending(path: "displaced-approved-parent")
    let destination = exportParent.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let exporter = try LocalDiagnosticBundleExporter()
    let approvedPreview = try exporter.preview(request)

    try FileManager.default.moveItem(at: exportParent, to: displacedParent)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let marker = exportParent.appending(path: "replacement-marker")
    try Data("replacement".utf8).write(to: marker)

    XCTAssertThrowsError(
      try exporter.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    ) { error in
      XCTAssertEqual(error as? LocalDiagnosticBundleError, .previewScopeMismatch)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: displacedParent.appending(path: "diagnostic-bundle").path))
  }

  func testTEST_AC_DIAG_002_01_previewEstimateIncludesManifestAtQuotaBoundary() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-quota-boundary")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let referencePreview = try LocalDiagnosticBundleExporter().preview(request)
    let insufficient = try LocalDiagnosticBundleExporter(
      maximumBundleBytes: referencePreview.estimatedBytes - 1)
    XCTAssertThrowsError(try insufficient.preview(request)) { error in
      XCTAssertEqual(error as? LocalDiagnosticBundleError, .bundleQuotaExceeded)
    }

    let exact = try LocalDiagnosticBundleExporter(
      maximumBundleBytes: referencePreview.estimatedBytes)
    let exactPreview = try exact.preview(request)
    XCTAssertEqual(exactPreview.estimatedBytes, referencePreview.estimatedBytes)
    _ = try exact.export(request, trigger: .userInitiated, approvedPreview: exactPreview)
    XCTAssertEqual(UInt64(try bundleData(destination).count), exactPreview.estimatedBytes)
  }

  func testTEST_AC_DIAG_002_01_postRenameFailureCleansDestinationAndAllowsRetry() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-rename-cleanup")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let failing = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterRenameBeforeCommit else { return }
        throw LocalDiagnosticBundleError.invalidInput("injected post-rename validation failure")
      })
    let approvedPreview = try failing.preview(request)

    XCTAssertThrowsError(
      try failing.export(request, trigger: .userInitiated, approvedPreview: approvedPreview))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    let parentEntries = try FileManager.default.contentsOfDirectory(atPath: base.path)
    XCTAssertFalse(parentEntries.contains { $0.hasPrefix(".diagnostic-bundle.") })

    _ = try LocalDiagnosticBundleExporter().export(
      request, trigger: .userInitiated, approvedPreview: approvedPreview)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testTEST_AC_DIAG_002_01_postRenameMoveAwayReturnsOutcomeUnknown() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-rename-move-away")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let destination = base.appending(path: "diagnostic-bundle")
    let movedDestination = base.appending(path: "moved-diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let failing = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterRenameBeforeCommit else { return }
        try FileManager.default.moveItem(at: destination, to: movedDestination)
        throw LocalDiagnosticBundleError.invalidInput("injected after moving renamed bundle")
      })
    let approvedPreview = try failing.preview(request)

    XCTAssertThrowsError(
      try failing.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    ) { error in
      XCTAssertEqual(error as? LocalDiagnosticBundleError, .exportOutcomeUnknown)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: movedDestination.path))
  }

  func testTEST_AC_DIAG_002_01_fifoReplacementFailsWithoutBlockingAndCleansUp() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-fifo-replacement")
    defer { try? FileManager.default.removeItem(at: base) }
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [], session: session)
    let exporter = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .beforePublish else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        guard
          let stagingName = names.first(where: {
            $0.hasPrefix(".diagnostic-bundle.diagnostics.") && $0.hasSuffix(".tmp")
          })
        else {
          throw LocalDiagnosticBundleError.invalidInput("diagnostic staging fixture was not found")
        }
        let metadata = base.appending(path: stagingName).appending(path: "metadata.json")
        try FileManager.default.removeItem(at: metadata)
        guard mkfifo(metadata.path, 0o600) == 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(path: metadata.path, errno: errno)
        }
      })
    let approvedPreview = try exporter.preview(request)

    XCTAssertThrowsError(
      try exporter.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    ) { error in
      guard case .invalidInput(let message) = error as? LocalDiagnosticBundleError else {
        return XCTFail("unexpected FIFO validation error: \(error)")
      }
      XCTAssertTrue(message.contains("changed before publication"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    let parentEntries = try FileManager.default.contentsOfDirectory(atPath: base.path)
    XCTAssertFalse(parentEntries.contains { $0.hasPrefix(".diagnostic-bundle.diagnostics.") })
  }

  func testTEST_MAC_M1_DIAG_001_rejectsNonOwnerOnlyLogDirectoryAndSegments() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-permissions")
    defer { try? FileManager.default.removeItem(at: base) }
    let permissiveDirectory = base.appending(path: "permissive-directory")
    try FileManager.default.createDirectory(
      at: permissiveDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: permissiveDirectory.path)
    XCTAssertThrowsError(try StructuredDiagnosticLogStore(directory: permissiveDirectory)) {
      XCTAssertEqual($0 as? SystemLoggerError, .unsafeLogDirectory)
    }

    let permissiveSegmentDirectory = base.appending(path: "permissive-segment")
    try FileManager.default.createDirectory(
      at: permissiveSegmentDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let segment = permissiveSegmentDirectory.appending(
      path: "diagnostics-00000000000000000000.jsonl")
    try Data().write(to: segment)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment.path)
    XCTAssertThrowsError(try StructuredDiagnosticLogStore(directory: permissiveSegmentDirectory)) {
      XCTAssertEqual($0 as? SystemLoggerError, .invalidSegment)
    }
  }

  func testTEST_MAC_M1_DIAG_001_writerLockReplacementFailsClosedForBothStores() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-writer-lock")
    defer { try? FileManager.default.removeItem(at: base) }
    let logDirectory = base.appending(path: "logs")
    do {
      let store1 = try StructuredDiagnosticLogStore(directory: logDirectory)
      let logger1 = SystemLogger(
        structuredStore: store1, unifiedLogger: CapturedUnifiedDiagnosticLogger(),
        auditClock: FixedDiagnosticAuditClock())
      try logger1.log(
        level: .info, category: .app, eventName: .privacyContract,
        correlationID: DiagnosticCorrelationID(),
        fields: [.publicCode: .publicCode(.diagnosticsTest)])
      let before = try store1.snapshot().files

      let writerLock = logDirectory.appending(path: ".writer.lock")
      try FileManager.default.removeItem(at: writerLock)
      try Data().write(to: writerLock)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: writerLock.path)

      XCTAssertThrowsError(try StructuredDiagnosticLogStore(directory: logDirectory)) { error in
        XCTAssertEqual(error as? SystemLoggerError, .activeWriterExists)
      }
      XCTAssertThrowsError(
        try logger1.log(
          level: .info, category: .app, eventName: .privacyContract,
          correlationID: DiagnosticCorrelationID(),
          fields: [.publicCode: .publicCode(.diagnosticsTest)])
      ) { error in
        XCTAssertEqual(error as? SystemLoggerError, .unsafeLogDirectory)
      }

      let segmentNames = try FileManager.default.contentsOfDirectory(atPath: logDirectory.path)
        .filter { $0.hasPrefix("diagnostics-") && $0.hasSuffix(".jsonl") }.sorted()
      let after = try segmentNames.map { name in
        StructuredDiagnosticSnapshotFile(
          name: name, data: try Data(contentsOf: logDirectory.appending(path: name)))
      }
      XCTAssertEqual(after, before)
    }
  }

  func testTEST_MAC_M1_DIAG_001_platformLoggingRotationAndRawExclusion() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-platform")
    defer { try? FileManager.default.removeItem(at: base) }
    let configuration = try StructuredDiagnosticLogConfiguration(
      quotaBytes: 8_192, segmentBytes: 4_096, maximumRecordBytes: 2_048)
    let store = try StructuredDiagnosticLogStore(
      directory: base.appending(path: "logs"), configuration: configuration)
    let unified = CapturedUnifiedDiagnosticLogger()
    let logger = SystemLogger(
      structuredStore: store, unifiedLogger: unified,
      auditClock: FixedDiagnosticAuditClock())
    for category in SystemLogCategory.allCases {
      try logger.log(
        level: .notice, category: category, eventName: .platformContract,
        correlationID: DiagnosticCorrelationID(),
        fields: [
          .device: .deviceIdentifier(DiagnosticsFixtures.deviceIdentifier),
          .path: .userPath(DiagnosticsFixtures.userPath),
          .business: .businessString(DiagnosticsFixtures.businessString),
        ])
    }
    let snapshot = try store.snapshot()
    let session = try await DiagnosticsFixtures.makeSessionExport(base: base)
    XCTAssertEqual(session.materialized.plan.excludedDeviceDataRelativePaths.count, 1)
    let destination = base.appending(path: "platform-diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination,
      logs: DiagnosticsFixtures.redactedLogFiles(snapshot), session: session)
    let exporter = try LocalDiagnosticBundleExporter()
    let preview = try exporter.preview(request)
    XCTAssertTrue(preview.deviceRawExcluded)
    XCTAssertTrue(preview.includedEntries.contains("sessions/recent-0000/manifest-summary.json"))
    XCTAssertTrue(preview.includedEntries.contains("sessions/recent-0000/journal-summary.json"))
    _ = try exporter.export(request, trigger: .userInitiated, approvedPreview: preview)

    let bundleBytes = try bundleData(destination)
    let productionUnifiedLogger = UnifiedSystemDiagnosticLogger(
      subsystem: "com.arkdeck.ArkDeck.DiagnosticsContractTests")
    unified.records.forEach(productionUnifiedLogger.log)
    XCTAssertEqual(Set(unified.records.map(\.category)), Set(SystemLogCategory.allCases))
    XCTAssertLessThanOrEqual(snapshot.totalBytes, configuration.quotaBytes)
    XCTAssertFalse(bundleBytes.contains(session.rawBytes))
    XCTAssertFalse(bundleBytes.contains(Data("device-1".utf8)))
    for sensitive in [
      DiagnosticsFixtures.deviceIdentifier, DiagnosticsFixtures.userPath,
      DiagnosticsFixtures.businessString,
    ] {
      XCTAssertFalse(bundleBytes.contains(Data(sensitive.utf8)))
    }
    let paths = try FileManager.default.subpathsOfDirectory(atPath: destination.path).sorted()
    XCTAssertFalse(
      paths.contains(where: { $0.contains("artifacts/raw") || $0.hasSuffix(".trace") }))
    XCTAssertEqual(
      paths,
      [
        "bundle.json", "hdc", "hdc/tool-placeholder.json", "logs",
        "logs/diagnostics-00000000000000000000.jsonl", "metadata.json", "sessions",
        "sessions/recent-0000", "sessions/recent-0000/journal-summary.json",
        "sessions/recent-0000/manifest-summary.json",
      ])
    try assertOwnerOnlyTree(destination)
    print(
      "TEST-MAC-M1-DIAG-001 quota=\(configuration.quotaBytes) logs=\(snapshot.totalBytes) entries=\(paths.count) rawExcluded=true unifiedCategories=\(unified.records.count)"
    )
  }

  private func bundleData(_ root: URL) throws -> Data {
    var combined = Data()
    for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
      let url = root.appending(path: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      combined.append(try Data(contentsOf: url))
    }
    return combined
  }

  private func assertOwnerOnlyTree(_ root: URL) throws {
    for path in [""] + (try FileManager.default.subpathsOfDirectory(atPath: root.path)) {
      let url = path.isEmpty ? root : root.appending(path: path)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
      XCTAssertEqual(permissions & 0o077, 0, "expected owner-only permissions: \(url.path)")
    }
  }
}
