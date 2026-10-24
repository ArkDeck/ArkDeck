import ArkDeckClientKit
import Darwin
import Foundation
import Testing

struct DiagnosticsContractTests {
  @Test func TEST_AC_DIAG_001_01_boundedRotationAndCleanup() throws {
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
      #expect(store.retainedBytes <= configuration.quotaBytes)
      #expect(snapshot.totalBytes == store.retainedBytes)
      #expect(snapshot.totalBytes <= configuration.quotaBytes)
      #expect(
        (snapshot.files.first?.name ?? "") > "diagnostics-00000000000000000000.jsonl")
      #expect(snapshot.files.count > 0)
      #expect(snapshot.files.allSatisfy { $0.data.last == 0x0A })
      #expect(try DiagnosticsFixtures.redactedLogFiles(snapshot).count == snapshot.files.count)
      lastSegment = logDirectory.appending(path: try #require(snapshot.files.last).name)
      print(
        "TEST-AC-DIAG-001-01 quota=\(configuration.quotaBytes) retained=\(snapshot.totalBytes) segments=\(snapshot.files.count)"
      )
    }

    let handle = try FileHandle(forWritingTo: try #require(lastSegment))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("torn-sensitive-tail".utf8))
    try handle.close()
    let reopened = try StructuredDiagnosticLogStore(
      directory: logDirectory, configuration: configuration)
    let repaired = try reopened.snapshot()
    #expect(repaired.files.allSatisfy { $0.data.last == 0x0A })
    #expect(!repaired.files.contains { $0.data.contains(Data("torn-sensitive-tail".utf8)) })
    #expect(repaired.totalBytes <= configuration.quotaBytes)
  }

  @Test func TEST_AC_DIAG_001_02_fiveCategoriesRedactBeforeBothSinks() throws {
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
    #expect(Set(structured.map(\.category)) == Set(SystemLogCategory.allCases))
    #expect(Set(unified.records.map(\.category)) == Set(SystemLogCategory.allCases))
    #expect(structured == unified.records.map(DecodedDiagnosticRecord.init))
    let structuredBytes = try #require(store.snapshot().files.first).data
    let unifiedBytes = try JSONEncoder().encode(unified.records)
    for sensitive in [
      DiagnosticsFixtures.deviceIdentifier, DiagnosticsFixtures.userPath,
      DiagnosticsFixtures.businessString,
    ] {
      #expect(!structuredBytes.contains(Data(sensitive.utf8)))
      #expect(!unifiedBytes.contains(Data(sensitive.utf8)))
    }
    #expect(structuredBytes.contains(Data("[REDACTED-DEVICE-ID]".utf8)))
    #expect(structuredBytes.contains(Data("[REDACTED-USER-PATH]".utf8)))
    #expect(structuredBytes.contains(Data("[REDACTED-BUSINESS-STRING]".utf8)))
    #expect(Set(structured.map(\.correlationID)).count == 5)
    for file in try DiagnosticsFixtures.redactedLogFiles(store.snapshot()) {
      #expect(file.data.contains(Data("\"eventName\":\"privacy.contract\"".utf8)))
      #expect(file.data.contains(Data("\"publicCode\":\"diagnostics.test\"".utf8)))
      for correlationID in structured.map(\.correlationID) {
        #expect(file.data.contains(Data(correlationID.utf8)))
      }
    }
  }

  @Test func TEST_AC_DIAG_001_02_untrustedExportLogIsRejected() throws {
    let malicious = Data(
      """
      {"category":"app","correlationId":"\(DiagnosticsFixtures.deviceIdentifier)","eventName":"\(DiagnosticsFixtures.deviceIdentifier)","fields":{"\(DiagnosticsFixtures.deviceIdentifier)":"\(DiagnosticsFixtures.businessString)","path":"\(DiagnosticsFixtures.userPath)"},"level":"warning","schemaVersion":"1.0.0","timestamp":"2026-07-17T08:00:00Z"}

      """.utf8)
    #expect(throws: (any Error).self) {
      try RedactedDiagnosticLogFile(
        name: "diagnostics-00000000000000000000.jsonl", data: malicious)
    }

    let customerSecretError = #expect(throws: LocalDiagnosticBundleError.self) {
      try RedactedDiagnosticLogFile(name: "customer-secret.jsonl", data: malicious)
    }
    if case .invalidInput = customerSecretError {} else {
      Issue.record("unexpected error: \(String(describing: customerSecretError))")
    }
    let unknownRootMember = Data(malicious.dropLast())
    var object = try #require(
      try JSONSerialization.jsonObject(with: unknownRootMember) as? [String: Any])
    object["untrusted"] = DiagnosticsFixtures.businessString
    var invalidShape = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    invalidShape.append(0x0A)
    #expect(throws: (any Error).self) {
      try RedactedDiagnosticLogFile(
        name: "diagnostics-00000000000000000001.jsonl", data: invalidShape)
    }
  }

  @Test func TEST_AC_DIAG_001_02_typedFieldCannotMisclassifyDeviceIdentifier() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-public-catalog")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try StructuredDiagnosticLogStore(directory: base.appending(path: "logs"))
    let unified = CapturedUnifiedDiagnosticLogger()
    let logger = SystemLogger(
      structuredStore: store, unifiedLogger: unified,
      auditClock: FixedDiagnosticAuditClock())

    #expect(throws: SystemLoggerError.invalidFieldPrivacy) {
      try logger.log(
        level: .warning, category: .app, eventName: .privacyContract,
        correlationID: DiagnosticCorrelationID(),
        fields: [.publicCode: .deviceIdentifier(DiagnosticsFixtures.deviceIdentifier)])
    }
    #expect(unified.records.isEmpty)
    #expect(
      try !store.snapshot().files.contains {
        $0.data.contains(Data(DiagnosticsFixtures.deviceIdentifier.utf8))
      })
  }

  @Test func TEST_AC_DIAG_002_01_crashAndJobFailureCannotMaterializeExport() async throws {
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
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination,
      logs: DiagnosticsFixtures.redactedLogFiles(store.snapshot()))
    let exporter = try LocalDiagnosticBundleExporter()
    let preview = try exporter.preview(request)

    for trigger in [DiagnosticExportTrigger.appCrash, .jobFailure] {
      #expect(throws: LocalDiagnosticBundleError.explicitUserInitiationRequired) {
        try exporter.export(request, trigger: trigger, approvedPreview: preview)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    let materialized = try exporter.export(
      request, trigger: .userInitiated, approvedPreview: preview)
    #expect(materialized.root == destination)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let manifest = try Data(contentsOf: destination.appending(path: "bundle.json"))
    #expect(manifest.contains(Data("\"automaticUploadEnabled\":false".utf8)))
  }

  @Test func TEST_AC_DIAG_002_01_parentReplacementCannotRedirectPublishOrCleanup() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-parent-binding")
    defer { try? FileManager.default.removeItem(at: base) }
    let exportParent = base.appending(path: "approved-parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let displacedParent = base.appending(path: "displaced-approved-parent")
    let replacementMarker = Data("replacement-parent-must-survive-cleanup".utf8)
    let replacementMarkerURL = exportParent.appending(path: "marker")
    let destination = exportParent.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
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

    let error = #expect(throws: LocalDiagnosticBundleError.self) {
      try exporter.export(request, trigger: .userInitiated, approvedPreview: preview)
    }
    if case .invalidInput(let message) = error {
      #expect(message.contains("parent changed"))
    } else {
      Issue.record("unexpected error: \(String(describing: error))")
    }
    #expect(try Data(contentsOf: replacementMarkerURL) == replacementMarker)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: displacedParent.appending(path: "diagnostic-bundle").path))
    let displacedEntries = try FileManager.default.contentsOfDirectory(atPath: displacedParent.path)
    #expect(!displacedEntries.contains { $0.hasPrefix(".diagnostic-bundle.") })
  }

  @Test func TEST_AC_DIAG_002_01_previewRejectsParentReplacementBeforeExport() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-preview-parent")
    defer { try? FileManager.default.removeItem(at: base) }
    let exportParent = base.appending(path: "approved-parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let displacedParent = base.appending(path: "displaced-approved-parent")
    let destination = exportParent.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
    let exporter = try LocalDiagnosticBundleExporter()
    let approvedPreview = try exporter.preview(request)

    try FileManager.default.moveItem(at: exportParent, to: displacedParent)
    try FileManager.default.createDirectory(
      at: exportParent, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let marker = exportParent.appending(path: "replacement-marker")
    try Data("replacement".utf8).write(to: marker)

    #expect(throws: LocalDiagnosticBundleError.previewScopeMismatch) {
      try exporter.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: displacedParent.appending(path: "diagnostic-bundle").path))
  }

  @Test func TEST_AC_DIAG_002_01_previewEstimateIncludesManifestAtQuotaBoundary() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-quota-boundary")
    defer { try? FileManager.default.removeItem(at: base) }
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
    let referencePreview = try LocalDiagnosticBundleExporter().preview(request)
    let insufficient = try LocalDiagnosticBundleExporter(
      maximumBundleBytes: referencePreview.estimatedBytes - 1)
    #expect(throws: LocalDiagnosticBundleError.bundleQuotaExceeded) {
      try insufficient.preview(request)
    }

    let exact = try LocalDiagnosticBundleExporter(
      maximumBundleBytes: referencePreview.estimatedBytes)
    let exactPreview = try exact.preview(request)
    #expect(exactPreview.estimatedBytes == referencePreview.estimatedBytes)
    _ = try exact.export(request, trigger: .userInitiated, approvedPreview: exactPreview)
    #expect(UInt64(try bundleData(destination).count) == exactPreview.estimatedBytes)
  }

  @Test func TEST_AC_DIAG_002_01_postRenameFailureCleansDestinationAndAllowsRetry() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-rename-cleanup")
    defer { try? FileManager.default.removeItem(at: base) }
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
    let failing = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterRenameBeforeCommit else { return }
        throw LocalDiagnosticBundleError.invalidInput("injected post-rename validation failure")
      })
    let approvedPreview = try failing.preview(request)

    #expect(throws: (any Error).self) {
      try failing.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let parentEntries = try FileManager.default.contentsOfDirectory(atPath: base.path)
    #expect(!parentEntries.contains { $0.hasPrefix(".diagnostic-bundle.") })

    _ = try LocalDiagnosticBundleExporter().export(
      request, trigger: .userInitiated, approvedPreview: approvedPreview)
    #expect(FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func TEST_AC_DIAG_002_01_postRenameMoveAwayReturnsOutcomeUnknown() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-rename-move-away")
    defer { try? FileManager.default.removeItem(at: base) }
    let destination = base.appending(path: "diagnostic-bundle")
    let movedDestination = base.appending(path: "moved-diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
    let failing = try LocalDiagnosticBundleExporter(
      faultInjector: LocalDiagnosticBundleFaultInjector { point in
        guard point == .afterRenameBeforeCommit else { return }
        try FileManager.default.moveItem(at: destination, to: movedDestination)
        throw LocalDiagnosticBundleError.invalidInput("injected after moving renamed bundle")
      })
    let approvedPreview = try failing.preview(request)

    #expect(throws: LocalDiagnosticBundleError.exportOutcomeUnknown) {
      try failing.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(FileManager.default.fileExists(atPath: movedDestination.path))
  }

  @Test func TEST_AC_DIAG_002_01_fifoReplacementFailsWithoutBlockingAndCleansUp() async throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-fifo-replacement")
    defer { try? FileManager.default.removeItem(at: base) }
    let destination = base.appending(path: "diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: [])
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

    let error = #expect(throws: LocalDiagnosticBundleError.self) {
      try exporter.export(request, trigger: .userInitiated, approvedPreview: approvedPreview)
    }
    if case .invalidInput(let message) = error {
      #expect(message.contains("changed before publication"))
    } else {
      Issue.record("unexpected FIFO validation error: \(String(describing: error))")
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let parentEntries = try FileManager.default.contentsOfDirectory(atPath: base.path)
    #expect(!parentEntries.contains { $0.hasPrefix(".diagnostic-bundle.diagnostics.") })
  }

  @Test func TEST_MAC_M1_DIAG_001_rejectsNonOwnerOnlyLogDirectoryAndSegments() throws {
    let base = try DiagnosticsFixtures.temporaryDirectory(prefix: "diagnostics-permissions")
    defer { try? FileManager.default.removeItem(at: base) }
    let permissiveDirectory = base.appending(path: "permissive-directory")
    try FileManager.default.createDirectory(
      at: permissiveDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: permissiveDirectory.path)
    #expect(throws: SystemLoggerError.unsafeLogDirectory) {
      try StructuredDiagnosticLogStore(directory: permissiveDirectory)
    }

    let permissiveSegmentDirectory = base.appending(path: "permissive-segment")
    try FileManager.default.createDirectory(
      at: permissiveSegmentDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let segment = permissiveSegmentDirectory.appending(
      path: "diagnostics-00000000000000000000.jsonl")
    try Data().write(to: segment)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: segment.path)
    #expect(throws: SystemLoggerError.invalidSegment) {
      try StructuredDiagnosticLogStore(directory: permissiveSegmentDirectory)
    }
  }

  @Test func TEST_MAC_M1_DIAG_001_writerLockReplacementFailsClosedForBothStores() throws {
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

      #expect(throws: SystemLoggerError.activeWriterExists) {
        try StructuredDiagnosticLogStore(directory: logDirectory)
      }
      #expect(throws: SystemLoggerError.unsafeLogDirectory) {
        try logger1.log(
          level: .info, category: .app, eventName: .privacyContract,
          correlationID: DiagnosticCorrelationID(),
          fields: [.publicCode: .publicCode(.diagnosticsTest)])
      }

      let segmentNames = try FileManager.default.contentsOfDirectory(atPath: logDirectory.path)
        .filter { $0.hasPrefix("diagnostics-") && $0.hasSuffix(".jsonl") }.sorted()
      let after = try segmentNames.map { name in
        StructuredDiagnosticSnapshotFile(
          name: name, data: try Data(contentsOf: logDirectory.appending(path: name)))
      }
      #expect(after == before)
    }
  }

  @Test func TEST_MAC_M1_DIAG_001_platformLoggingRotationAndRawExclusion() async throws {
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
    let destination = base.appending(path: "platform-diagnostic-bundle")
    let request = try DiagnosticsFixtures.bundleRequest(
      destination: destination, logs: DiagnosticsFixtures.redactedLogFiles(snapshot))
    let exporter = try LocalDiagnosticBundleExporter()
    let preview = try exporter.preview(request)
    #expect(preview.deviceRawExcluded)
    // Device data has no way in: a request carries App values and App log
    // snapshots only, and the preview names exactly those entries.
    #expect(
      preview.includedEntries
        == [
          "bundle.json", "hdc/tool-placeholder.json",
          "logs/diagnostics-00000000000000000000.jsonl", "metadata.json",
        ])
    _ = try exporter.export(request, trigger: .userInitiated, approvedPreview: preview)

    let bundleBytes = try bundleData(destination)
    let productionUnifiedLogger = UnifiedSystemDiagnosticLogger(
      subsystem: "com.arkdeck.ArkDeck.DiagnosticsContractTests")
    unified.records.forEach(productionUnifiedLogger.log)
    #expect(Set(unified.records.map(\.category)) == Set(SystemLogCategory.allCases))
    #expect(snapshot.totalBytes <= configuration.quotaBytes)
    for sensitive in [
      DiagnosticsFixtures.deviceIdentifier, DiagnosticsFixtures.userPath,
      DiagnosticsFixtures.businessString,
    ] {
      #expect(!bundleBytes.contains(Data(sensitive.utf8)))
    }
    let paths = try FileManager.default.subpathsOfDirectory(atPath: destination.path).sorted()
    #expect(
      !paths.contains(where: { $0.contains("artifacts/raw") || $0.hasSuffix(".trace") }))
    #expect(
      paths
        == [
          "bundle.json", "hdc", "hdc/tool-placeholder.json", "logs",
          "logs/diagnostics-00000000000000000000.jsonl", "metadata.json",
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
      let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
      #expect(permissions & 0o077 == 0, "expected owner-only permissions: \(url.path)")
    }
  }
}
