// Xcode's `xcode-select` tool shims (TASK-XPA-015): `/usr/bin/git` is one
// file under clang's, make's and seventy-five other names, and started from
// its inode it runs whichever of them the kernel last recorded for it. The
// Runtime tells a shim by its signing identifier, pins the tool xcrun
// resolves for it instead, and never launches a shim. What the pinned git
// runs is `XcodeToolShimOracleContractTests`. The Rust port holds the same
// cases (`tool_shim.rs`, `workspace_profile.rs`).

import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class XcodeToolShimContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-tool-shim", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testACodeDirectoryNamesTheImage() {
    let shim = Self.signed("com.apple.dt.xcode_select.tool-shim-public")
    XCTAssertEqual(
      XcodeToolShim.signingIdentifiers(of: shim), ["com.apple.dt.xcode_select.tool-shim-public"])
    XCTAssertTrue(XcodeToolShim.isToolShim(bytes: shim))
    let git = Self.signed("com.apple.git")
    XCTAssertFalse(XcodeToolShim.isToolShim(bytes: git))
    XCTAssertEqual(XcodeToolShim.signingIdentifiers(of: Self.signed(nil)), [nil])
    XCTAssertFalse(XcodeToolShim.isToolShim(bytes: Self.signed(nil)))
    // One shim architecture makes the whole file a shim.
    let mixed = Self.universal([git, shim])
    XCTAssertEqual(XcodeToolShim.signingIdentifiers(of: mixed)?.count, 2)
    XCTAssertTrue(XcodeToolShim.isToolShim(bytes: mixed))
    XCTAssertFalse(XcodeToolShim.isToolShim(bytes: Self.universal([git, git])))
  }

  func testWhatIsNotAWellFormedMachOFileIsNothing() {
    XCTAssertNil(XcodeToolShim.signingIdentifiers(of: Data("#!/bin/sh\nexec git \"$@\"\n".utf8)))
    XCTAssertNil(XcodeToolShim.signingIdentifiers(of: Data()))
    let shim = Self.signed("com.apple.dt.xcode_select.tool-shim-public")
    for cut in [4, 20, 40, 70, shim.count - 1] {
      XCTAssertNil(XcodeToolShim.signingIdentifiers(of: shim.prefix(cut)), "\(cut)")
    }
    var wrong = shim
    wrong[64] ^= 0xff
    XCTAssertNil(XcodeToolShim.signingIdentifiers(of: wrong))
    XCTAssertFalse(XcodeToolShim.isToolShim(bytes: wrong))
  }

  func testTheHostToolsAreToldByTheirSignatureNotTheirLinks() throws {
    func identifiers(_ path: String) throws -> [String?] {
      try XCTUnwrap(XcodeToolShim.signingIdentifiers(of: Data(contentsOf: URL(filePath: path))))
    }
    // One file under 78 names, and no tool at all.
    XCTAssertGreaterThan(try Self.links("/usr/bin/git"), 1)
    XCTAssertTrue(XcodeToolShim.isToolShim(try identifiers("/usr/bin/git")))
    let descriptor = open("/usr/bin/git", O_RDONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    XCTAssertTrue(XcodeToolShim.isToolShim(fileDescriptor: descriptor))
    // Linked three times, and a tool of its own.
    XCTAssertGreaterThan(try Self.links("/usr/bin/grep"), 1)
    XCTAssertFalse(XcodeToolShim.isToolShim(try identifiers("/usr/bin/grep")))
    for tool in ["/usr/bin/sed", "/usr/bin/patch", "/usr/bin/bsdtar"] {
      XCTAssertFalse(XcodeToolShim.isToolShim(try identifiers(tool)), tool)
    }
    XCTAssertTrue(try identifiers("/usr/bin/xcrun").allSatisfy { $0 == "com.apple.xcrun" })
  }

  func testAShimResolvesToTheToolItNames() throws {
    let git = try XcodeToolShim.resolve(tool: "git")
    XCTAssertTrue(git.hasPrefix("/"))
    XCTAssertEqual(URL(filePath: git).resolvingSymlinksInPath().path, git)
    let identifiers = try XCTUnwrap(
      XcodeToolShim.signingIdentifiers(of: Data(contentsOf: URL(filePath: git))))
    XCTAssertFalse(XcodeToolShim.isToolShim(identifiers))
    XCTAssertTrue(identifiers.allSatisfy { $0 == "com.apple.git" })
    for refused in ["", "-v", "a/b", "git\0"] {
      XCTAssertThrowsError(try XcodeToolShim.resolve(tool: refused), refused)
    }
    XCTAssertThrowsError(try XcodeToolShim.resolve(tool: "arkdeck-no-such-developer-tool"))
  }

  func testAShimIsNeverOpenedForALaunch() throws {
    XCTAssertThrowsError(
      try VerifiedExecutableDescriptor.open(
        path: URL(filePath: "/usr/bin/git"), expectedSHA256: try Self.digest("/usr/bin/git"))
    ) { error in
      XCTAssertEqual(error as? ProcessExecutionError, .executableIsToolShim)
    }
    let tool = try XcodeToolShim.resolve(tool: "git")
    let opened = try VerifiedExecutableDescriptor.open(
      path: URL(filePath: tool), expectedSHA256: try Self.digest(tool))
    opened.close()
  }

  /// What a profile pins for `/usr/bin/git` is the tool xcrun resolves,
  /// never the shim; a tool of its own measures as itself.
  func testAPinnedToolShimStandsForTheToolXcrunResolves() throws {
    let tool = try XcodeToolShim.resolve(tool: "git")
    let git = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/git")
    XCTAssertEqual(git.path, tool)
    XCTAssertEqual(git.sha256, try Self.digest(tool))
    XCTAssertFalse(try WorkspaceExecutableIdentity.measuring(path: git.path).isToolShim)
    let shim = try WorkspaceExecutableIdentity.measuring(path: "/usr/bin/git")
    XCTAssertTrue(shim.isToolShim)
    XCTAssertEqual(shim.identity.path, "/usr/bin/git")
    XCTAssertEqual(
      try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/sed").path, "/usr/bin/sed")
  }

  /// A profile left pinning a shim — one xcrun resolved to nothing — offers
  /// nothing, and its dispatcher resolves no executable.
  func testAProfileThatPinnedAShimOffersNothing() throws {
    let shim = try WorkspaceExecutableIdentity.measuring(path: "/usr/bin/git").identity
    let profile = try WorkspaceProjectProfile(
      profileID: "test-workspace@1", projectRef: "TestProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: try WorkspaceCommandPreset(
        presetID: "inspect",
        executable: try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep"),
        fixedArguments: [], timeoutSeconds: 10),
      sourceControlPreset: try WorkspaceCommandPreset(
        presetID: "git", executable: shim, fixedArguments: [], timeoutSeconds: 120),
      patchPreset: try WorkspaceCommandPreset(
        presetID: "patch",
        executable: try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch"),
        fixedArguments: [], timeoutSeconds: 10),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let provider = WorkspaceOperationsProvider(
      profile: profile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: root.appending(path: "attempts", directoryHint: .isDirectory)),
      nowUTC: { "2026-09-26T00:00:00Z" })
    for reference in [
      "workspace.create-checkpoint@1", "workspace.inspect-git-status@1",
      "workspace.inspect-source@1",
    ] {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      XCTAssertEqual(
        provider.runtimeAvailability(for: descriptor),
        .unavailable(code: .providerToolUnavailable, reason: "workspace.toolchainUnavailable"),
        reference)
    }
    XCTAssertThrowsError(
      try WorkspaceActionExecutableResolver(profile: profile)
        .resolveExecutable(providerID: "workspace"))
  }

  // MARK: - Helpers

  private static func links(_ path: String) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.referenceCount] as? Int)
  }

  private static func digest(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(filePath: path)))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// A thin 64-bit little-endian image whose only load command names a code
  /// signature holding a code directory for `identifier`.
  private static func signed(_ identifier: String?) -> Data {
    var image = Data()
    func little(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { image.append(contentsOf: $0) }
    }
    func big(_ value: UInt32, into data: inout Data) {
      withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
    little(0xfeed_facf)
    image.append(contentsOf: [UInt8](repeating: 0, count: 12))
    little(1)
    little(16)
    image.append(contentsOf: [UInt8](repeating: 0, count: 8))
    var blob = Data()
    if let identifier {
      var directory = Data()
      big(0xfade_0c02, into: &directory)
      big(UInt32(48 + identifier.utf8.count + 1), into: &directory)
      directory.append(contentsOf: [UInt8](repeating: 0, count: 12))
      big(48, into: &directory)
      directory.append(contentsOf: [UInt8](repeating: 0, count: 24))
      directory.append(contentsOf: Array(identifier.utf8) + [0])
      big(0xfade_0cc0, into: &blob)
      big(UInt32(20 + directory.count), into: &blob)
      big(1, into: &blob)
      big(0, into: &blob)
      big(20, into: &blob)
      blob.append(directory)
    } else {
      big(0xfade_0cc0, into: &blob)
      big(12, into: &blob)
      big(0, into: &blob)
    }
    little(0x1d)
    little(16)
    little(64)
    little(UInt32(blob.count))
    image.append(contentsOf: [UInt8](repeating: 0, count: 64 - image.count))
    image.append(blob)
    return image
  }

  private static func universal(_ images: [Data]) -> Data {
    var file = Data()
    func big(_ value: UInt32) {
      withUnsafeBytes(of: value.bigEndian) { file.append(contentsOf: $0) }
    }
    big(0xcafe_babe)
    big(UInt32(images.count))
    var offset: UInt32 = 4_096
    for image in images {
      file.append(contentsOf: [UInt8](repeating: 0, count: 8))
      big(offset)
      big(UInt32(image.count))
      big(12)
      offset += (UInt32(image.count) + 4_095) / 4_096 * 4_096
    }
    for image in images {
      file.append(contentsOf: [UInt8](repeating: 0, count: (4_096 - file.count % 4_096) % 4_096))
      file.append(image)
    }
    return file
  }
}
