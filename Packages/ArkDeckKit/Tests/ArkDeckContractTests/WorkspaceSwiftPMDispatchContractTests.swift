import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class WorkspaceSwiftPMDispatchContractTests: XCTestCase {
  func testSwiftPMTestRoleRetainsItsToolchainBundleDuringStartup() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "workspace-swiftpm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.resolvingSymlinksInPath().path
    let candidates = [
      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-package",
      "/Library/Developer/CommandLineTools/usr/bin/swift-package",
    ]
    let path = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
    let role = URL(filePath: path).deletingLastPathComponent().appending(path: "swift-test").path
    let executable = try WorkspaceExecutableIdentity.hashing(path: path)
    let invocation = WorkspaceResolvedInvocation(
      operation: "workspace.run-tests@1", projectRef: "TestProject", projectRoot: directory,
      presetID: "arkdeck-tests", executable: executable, argumentZero: role,
      arguments: ["--help"], timeoutSeconds: 30)
    let dispatcher = DescriptorBoundProcessDispatcher(
      resolver: try FixedExecutableResolver.hashing(path: path, providerID: "workspace"))
    let receipt = try await dispatcher.dispatch(
      TypedProcessPlan(
        action: .workspace(.runTests(invocation)),
        kind: .process(
          executableSHA256: executable.sha256, argumentSummary: invocation.arguments,
          timeoutSeconds: 30), argumentZero: role, workingDirectory: directory))
    XCTAssertEqual(receipt.exitStatus, 0)
    XCTAssertTrue(String(decoding: receipt.stdout, as: UTF8.self).contains("swift test"))
  }
}
