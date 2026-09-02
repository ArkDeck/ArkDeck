import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeWorkspaceProjectStoreContractTests: XCTestCase {
  private final class ToolchainPins: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Set<String>] = [:]
    var failNextRelease = false

    func owner() -> RuntimeWorkspaceToolchainPinning {
      RuntimeWorkspaceToolchainPinning(
        acquire: { [self] reference, generation, presetRef in
          guard generation == 1 else {
            throw RuntimeWorkspaceProjectFailure(
              "resourceConflict", "fixture toolchain generation changed")
          }
          _ = lock.withLock { values[reference, default: []].insert(presetRef) }
        },
        release: { [self] reference, presetRef in
          try lock.withLock {
            if failNextRelease {
              failNextRelease = false
              throw RuntimeWorkspaceProjectFailure(
                "ioFailure", "fixture release interruption")
            }
            values[reference]?.remove(presetRef)
          }
        })
    }

    func contains(_ reference: String, _ presetRef: String) -> Bool {
      lock.withLock { values[reference]?.contains(presetRef) == true }
    }
  }

  private final class CredentialPins: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Set<String>] = [:]
    var failNextRelease = false

    func owner() -> RuntimeWorkspaceCredentialPinning {
      RuntimeWorkspaceCredentialPinning(
        acquire: { [self] reference, presetRef in
          _ = lock.withLock { values[reference, default: []].insert(presetRef) }
        },
        release: { [self] reference, presetRef in
          try lock.withLock {
            if failNextRelease {
              failNextRelease = false
              throw RuntimeWorkspaceProjectFailure(
                "ioFailure", "fixture credential release interruption")
            }
            values[reference]?.remove(presetRef)
          }
        })
    }

    func contains(_ reference: String, _ presetRef: String) -> Bool {
      lock.withLock { values[reference]?.contains(presetRef) == true }
    }
  }

  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory.appending(
      path: "workspace-project-store-\(UUID())", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: stateDirectory)
  }

  func testRegistrationIsDurableIdempotentAndKeepsTheRootPrivate() throws {
    let root = try makeRoot("first-project")
    let store = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, nowUTC: { "2026-09-01T12:00:00.000Z" })

    let registered = try store.register(
      requestID: "registration-1", kind: "arkdeck", rootPath: root.path)
    XCTAssertEqual(registered.generation, 1)
    XCTAssertEqual(registered.configurationStatus, "runtimeRestartRequired")
    let ownerDirectory = stateDirectory.appending(
      path: "workspace-projects", directoryHint: .isDirectory)
    let document = ownerDirectory.appending(path: "projects.json")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: ownerDirectory.path)[.posixPermissions]
        as? NSNumber)?.intValue ?? -1,
      0o700)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: document.path)[.posixPermissions]
        as? NSNumber)?.intValue ?? -1,
      0o600)
    XCTAssertEqual(
      try store.register(
        requestID: "registration-1", kind: "arkdeck", rootPath: root.path),
      registered)

    XCTAssertThrowsError(
      try store.register(
        requestID: "registration-1", kind: "openharmony", rootPath: root.path)
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "idempotencyConflict")
    }

    let reopened = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    XCTAssertEqual(try reopened.list().map(\.projectRef), [registered.projectRef])
    let privateRecord = try XCTUnwrap(try reopened.compositionRecords().first)
    XCTAssertEqual(privateRecord.rootPath, root.path)

    let rendered = String(
      data: try JSONEncoder().encode(registered.projection), encoding: .utf8) ?? ""
    XCTAssertTrue(rendered.contains(registered.projectRef))
    XCTAssertFalse(rendered.contains(root.path))
    XCTAssertFalse(rendered.contains("root"))
  }

  func testGenerationCASAndUseTokenCloseUpdateAndRemoveRaces() throws {
    let firstRoot = try makeRoot("first-project")
    let secondRoot = try makeRoot("second-project")
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    let registered = try store.register(
      requestID: "registration-2", kind: "arkdeck", rootPath: firstRoot.path)
    store.markApplied([registered.projectRef: registered.generation])

    let use = try store.acquireUse(projectRef: registered.projectRef)
    for mutation in [
      {
        _ = try store.update(
          projectRef: registered.projectRef, expectedGeneration: 1,
          kind: "arkdeck", rootPath: secondRoot.path,
          requireNoActiveReference: { _ in })
      },
      {
        _ = try store.remove(
          projectRef: registered.projectRef, expectedGeneration: 1,
          requireNoActiveReference: { _ in })
      },
    ] {
      XCTAssertThrowsError(try mutation()) { error in
        XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
      }
    }
    store.endUse(use)

    let updated = try store.update(
      projectRef: registered.projectRef, expectedGeneration: 1,
      kind: "arkdeck", rootPath: secondRoot.path,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(updated.generation, 2)
    XCTAssertEqual(updated.configurationStatus, "runtimeRestartRequired")
    XCTAssertThrowsError(
      try store.update(
        projectRef: registered.projectRef, expectedGeneration: 1,
        kind: "arkdeck", rootPath: firstRoot.path,
        requireNoActiveReference: { _ in })
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }

    let removed = try store.remove(
      projectRef: registered.projectRef, expectedGeneration: 2,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(removed.configurationStatus, "removed")
    XCTAssertTrue(try store.list().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondRoot.path))
  }

  func testActiveDurableReferenceCheckRunsInsideTheMutationOwner() throws {
    let root = try makeRoot("first-project")
    let replacement = try makeRoot("replacement-project")
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    let registered = try store.register(
      requestID: "registration-3", kind: "arkdeck", rootPath: root.path)
    var checkedProjectRef: String?

    XCTAssertThrowsError(
      try store.update(
        projectRef: registered.projectRef, expectedGeneration: 1,
        kind: "arkdeck", rootPath: replacement.path,
        requireNoActiveReference: { projectRef in
          checkedProjectRef = projectRef
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "fixture active Job reference")
        })
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(checkedProjectRef, registered.projectRef)
    XCTAssertEqual(try store.inspect(registered.projectRef).generation, 1)
  }

  func testSymlinkAndChangedRootIdentityFailClosed() throws {
    let root = try makeRoot("first-project")
    let symlink = stateDirectory.appending(path: "root-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)

    XCTAssertThrowsError(
      try store.register(
        requestID: "registration-link", kind: "arkdeck", rootPath: symlink.path)
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "invalidInput")
    }

    let registered = try store.register(
      requestID: "registration-4", kind: "arkdeck", rootPath: root.path)
    store.markApplied([registered.projectRef: 1])
    let moved = stateDirectory.appending(path: "moved-project", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    let startup = try XCTUnwrap(try store.startupRecords().first)
    XCTAssertNil(startup.composition)
    XCTAssertEqual(startup.failure?.code, "factsDrifted")
    XCTAssertThrowsError(try store.acquireUse(projectRef: registered.projectRef)) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "factsDrifted")
    }
  }

  func testPresetLifecycleIsTypedIdempotentAndSharesTheProjectUseOwner() throws {
    let root = try makeRoot("preset-project")
    let pins = ToolchainPins()
    let store = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: pins.owner(),
      nowUTC: { "2026-09-01T12:00:00.000Z" })
    let project = try store.register(
      requestID: "preset-project-registration", kind: "openharmony", rootPath: root.path)
    let firstToolchain = "toolchain:sha256:" + String(repeating: "a", count: 64)
    let secondToolchain = "toolchain:sha256:" + String(repeating: "b", count: 64)
    let constraints = RuntimeWorkspacePresetConstraints(
      module: "entry", product: "default", buildMode: "debug")

    let preset = try store.registerPreset(
      requestID: "preset-registration", projectRef: project.projectRef,
      kind: "build", templateRef: "openharmony.hvigor-build@1",
      toolchainRef: firstToolchain, toolchainGeneration: 1,
      credentialRef: nil, timeoutSeconds: 1_800, constraints: constraints)
    XCTAssertEqual(preset.generation, 1)
    XCTAssertEqual(preset.configurationStatus, "runtimeRestartRequired")
    XCTAssertTrue(pins.contains(firstToolchain, preset.presetRef))
    XCTAssertEqual(
      try store.registerPreset(
        requestID: "preset-registration", projectRef: project.projectRef,
        kind: "build", templateRef: "openharmony.hvigor-build@1",
        toolchainRef: firstToolchain, toolchainGeneration: 1,
        credentialRef: nil, timeoutSeconds: 1_800, constraints: constraints),
      preset)

    let rendered = String(
      data: try JSONEncoder().encode(preset.projection), encoding: .utf8) ?? ""
    XCTAssertTrue(rendered.contains(firstToolchain))
    XCTAssertFalse(rendered.contains(root.path))
    XCTAssertFalse(rendered.contains("argv"))
    XCTAssertFalse(rendered.contains("executable"))

    store.markApplied(
      projects: [project.projectRef: 1], presets: [preset.presetRef: 1])
    let use = try store.acquireUse(
      projectRef: project.projectRef, presetRefs: [preset.presetRef])
    XCTAssertThrowsError(
      try store.updatePreset(
        requestID: "preset-update", projectRef: project.projectRef,
        presetRef: preset.presetRef, expectedGeneration: 1,
        kind: "build", templateRef: "openharmony.hvigor-build@1",
        toolchainRef: secondToolchain, toolchainGeneration: 1,
        credentialRef: nil, timeoutSeconds: 1_200, constraints: constraints,
        requireNoActiveReference: { _ in })) { error in
          XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
        }
    store.endUse(use)

    let updated = try store.updatePreset(
      requestID: "preset-update", projectRef: project.projectRef,
      presetRef: preset.presetRef, expectedGeneration: 1,
      kind: "build", templateRef: "openharmony.hvigor-build@1",
      toolchainRef: secondToolchain, toolchainGeneration: 1,
      credentialRef: nil, timeoutSeconds: 1_200, constraints: constraints,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(updated.generation, 2)
    XCTAssertFalse(pins.contains(firstToolchain, preset.presetRef))
    XCTAssertTrue(pins.contains(secondToolchain, preset.presetRef))
    XCTAssertEqual(
      try store.updatePreset(
        requestID: "preset-update", projectRef: project.projectRef,
        presetRef: preset.presetRef, expectedGeneration: 1,
        kind: "build", templateRef: "openharmony.hvigor-build@1",
        toolchainRef: secondToolchain, toolchainGeneration: 1,
        credentialRef: nil, timeoutSeconds: 1_200, constraints: constraints,
        requireNoActiveReference: { _ in }),
      updated)

    XCTAssertThrowsError(
      try store.remove(
        projectRef: project.projectRef, expectedGeneration: 1,
        requireNoActiveReference: { _ in })) { error in
          XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
        }
    let removed = try store.removePreset(
      requestID: "preset-remove", projectRef: project.projectRef,
      presetRef: preset.presetRef, expectedGeneration: 2,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(removed.configurationStatus, "removed")
    XCTAssertFalse(pins.contains(secondToolchain, preset.presetRef))
    XCTAssertTrue(try store.listPresets(projectRef: project.projectRef).isEmpty)
    XCTAssertEqual(
      try store.removePreset(
        requestID: "preset-remove", projectRef: project.projectRef,
        presetRef: preset.presetRef, expectedGeneration: 2,
        requireNoActiveReference: { _ in }),
      removed)
  }

  func testPresetReleaseTransactionRecoversBeforeTheStoreServesReads() throws {
    let root = try makeRoot("recovery-project")
    let pins = ToolchainPins()
    let toolchain = "toolchain:sha256:" + String(repeating: "c", count: 64)
    var store: RuntimeWorkspaceProjectStore? = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: pins.owner())
    let project = try XCTUnwrap(store).register(
      requestID: "recovery-project-registration", kind: "openharmony", rootPath: root.path)
    let preset = try XCTUnwrap(store).registerPreset(
      requestID: "recovery-preset-registration", projectRef: project.projectRef,
      kind: "test", templateRef: "openharmony.hvigor-test@1",
      toolchainRef: toolchain, toolchainGeneration: 1, credentialRef: nil,
      timeoutSeconds: 600,
      constraints: RuntimeWorkspacePresetConstraints(
        module: "entry", product: "default", buildMode: "debug"))
    pins.failNextRelease = true
    XCTAssertThrowsError(
      try XCTUnwrap(store).removePreset(
        requestID: "recovery-remove", projectRef: project.projectRef,
        presetRef: preset.presetRef, expectedGeneration: 1,
        requireNoActiveReference: { _ in })) { error in
          XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "ioFailure")
        }
    XCTAssertTrue(pins.contains(toolchain, preset.presetRef))

    // Reproduce the exact interrupted transaction shape written by the /2
    // owner: its optional credential fields did not exist yet. The /3 reader
    // must decode it, finish the idempotent release, and durably upgrade on
    // that recovery write.
    let documentURL = stateDirectory
      .appending(path: "workspace-projects", directoryHint: .isDirectory)
      .appending(path: "projects.json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
        as? [String: Any])
    document["schemaVersion"] = "arkdeck.workspace-project-store/2"
    var pending = try XCTUnwrap(document["pendingToolchainMutation"] as? [String: Any])
    pending.removeValue(forKey: "credentialRef")
    pending.removeValue(forKey: "releaseAfterAcquireCredentialRef")
    document["pendingToolchainMutation"] = pending
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(
      to: documentURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: documentURL.path)

    store = nil
    let reopened = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: pins.owner())
    XCTAssertFalse(pins.contains(toolchain, preset.presetRef))
    XCTAssertTrue(try reopened.listPresets(projectRef: project.projectRef).isEmpty)
    let recoveredDocument = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
        as? [String: Any])
    XCTAssertEqual(
      recoveredDocument["schemaVersion"] as? String,
      "arkdeck.workspace-project-store/3")
    let replayed = try reopened.removePreset(
      requestID: "recovery-remove", projectRef: project.projectRef,
      presetRef: preset.presetRef, expectedGeneration: 1,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(replayed.configurationStatus, "removed")
  }

  func testSigningPresetPinsCredentialAndToolchainAsOneDurableDependencySet() throws {
    let root = try makeRoot("signing-project")
    let toolchains = ToolchainPins()
    let credentials = CredentialPins()
    let toolchain = "toolchain:sha256:" + String(repeating: "d", count: 64)
    let firstCredential = "credential:sha256-" + String(repeating: "e", count: 64)
    let secondCredential = "credential:sha256-" + String(repeating: "f", count: 64)
    let store = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: toolchains.owner(),
      credentialPinning: credentials.owner())
    let project = try store.register(
      requestID: "signing-project-registration", kind: "openharmony",
      rootPath: root.path)
    let preset = try store.registerPreset(
      requestID: "signing-preset-registration", projectRef: project.projectRef,
      kind: "signing", templateRef: "openharmony.local-sign@1",
      toolchainRef: toolchain, toolchainGeneration: 1,
      credentialRef: firstCredential, timeoutSeconds: 600,
      constraints: RuntimeWorkspacePresetConstraints())
    XCTAssertTrue(toolchains.contains(toolchain, preset.presetRef))
    XCTAssertTrue(credentials.contains(firstCredential, preset.presetRef))

    let updated = try store.updatePreset(
      requestID: "signing-preset-update", projectRef: project.projectRef,
      presetRef: preset.presetRef, expectedGeneration: 1,
      kind: "signing", templateRef: "openharmony.local-sign@1",
      toolchainRef: toolchain, toolchainGeneration: 1,
      credentialRef: secondCredential, timeoutSeconds: 600,
      constraints: RuntimeWorkspacePresetConstraints(),
      requireNoActiveReference: { _ in })
    XCTAssertEqual(updated.credentialRef, secondCredential)
    XCTAssertTrue(toolchains.contains(toolchain, preset.presetRef))
    XCTAssertFalse(credentials.contains(firstCredential, preset.presetRef))
    XCTAssertTrue(credentials.contains(secondCredential, preset.presetRef))

    let removed = try store.removePreset(
      requestID: "signing-preset-remove", projectRef: project.projectRef,
      presetRef: preset.presetRef, expectedGeneration: 2,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(removed.configurationStatus, "removed")
    XCTAssertFalse(toolchains.contains(toolchain, preset.presetRef))
    XCTAssertFalse(credentials.contains(secondCredential, preset.presetRef))
  }

  func testSigningPresetCredentialReleaseRecoversAfterToolchainRelease() throws {
    let root = try makeRoot("signing-recovery-project")
    let toolchains = ToolchainPins()
    let credentials = CredentialPins()
    let toolchain = "toolchain:sha256:" + String(repeating: "1", count: 64)
    let credential = "credential:sha256-" + String(repeating: "2", count: 64)
    var store: RuntimeWorkspaceProjectStore? = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: toolchains.owner(),
      credentialPinning: credentials.owner())
    let project = try XCTUnwrap(store).register(
      requestID: "signing-recovery-project-registration", kind: "openharmony",
      rootPath: root.path)
    let preset = try XCTUnwrap(store).registerPreset(
      requestID: "signing-recovery-preset-registration", projectRef: project.projectRef,
      kind: "signing", templateRef: "openharmony.local-sign@1",
      toolchainRef: toolchain, toolchainGeneration: 1,
      credentialRef: credential, timeoutSeconds: 600,
      constraints: RuntimeWorkspacePresetConstraints())
    credentials.failNextRelease = true
    XCTAssertThrowsError(
      try XCTUnwrap(store).removePreset(
        requestID: "signing-recovery-remove", projectRef: project.projectRef,
        presetRef: preset.presetRef, expectedGeneration: 1,
        requireNoActiveReference: { _ in })) { error in
          XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "ioFailure")
        }
    XCTAssertFalse(toolchains.contains(toolchain, preset.presetRef))
    XCTAssertTrue(credentials.contains(credential, preset.presetRef))

    store = nil
    let reopened = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, toolchainPinning: toolchains.owner(),
      credentialPinning: credentials.owner())
    XCTAssertFalse(toolchains.contains(toolchain, preset.presetRef))
    XCTAssertFalse(credentials.contains(credential, preset.presetRef))
    XCTAssertTrue(try reopened.listPresets(projectRef: project.projectRef).isEmpty)
  }

  private func makeRoot(_ name: String) throws -> URL {
    let root = stateDirectory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard let canonical = realpath(root.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(canonical) }
    return URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
  }
}
