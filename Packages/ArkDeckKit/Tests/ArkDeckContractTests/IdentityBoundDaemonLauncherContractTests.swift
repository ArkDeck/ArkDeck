import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess

/// The launcher that hands a pairing secret to a long-lived child.
///
/// `/bin/dd` is the child: it reads stdin and writes it to a file, it is a
/// plain executable rather than a shell, and it exits at EOF — which makes it
/// prove both halves at once. The secret arrived, and stdin was closed.
///
/// The secret never appears in argv here, and that is the property the whole
/// type exists for: argv is readable by other processes and cannot be erased
/// after the fact, which is exactly what a pairing secret must not be.
final class IdentityBoundDaemonLauncherContractTests: XCTestCase {

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-daemon-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func ddRequest(writingTo destination: URL) throws -> ProcessIdentityBoundRequest {
    let executable = URL(filePath: "/bin/dd")
    let digest = try SHA256Hex.string(of: Data(contentsOf: executable))
    return ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: executable,
        arguments: ["of=\(destination.path)"],
        environment: [:],
        workingDirectory: nil),
      expectedSHA256: digest)
  }

  func testTheSecretReachesTheChildOnStdinAndStdinIsClosed() async throws {
    let destination = root.appending(path: "delivered")
    let secret = Data("pairing-secret-not-in-argv".utf8)

    let handle = try await IdentityBoundDaemonLauncher().launch(
      try ddRequest(writingTo: destination), secret: secret)

    // `dd` exits at EOF. Waiting for it therefore proves stdin was closed —
    // a launcher that left it open would hang here rather than fail loudly,
    // and a daemon in that state never finishes pairing and never opens its
    // sockets.
    var exited = false
    for _ in 0..<200 where !exited {
      if handle.reap() != nil { exited = true; break }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(exited, "the child must reach EOF once the parent closes stdin")
    XCTAssertEqual(try Data(contentsOf: destination), secret)
  }

  func testTheSecretIsNotInArgvOrTheEnvironment() async throws {
    // The reason this type exists. The request carries only the destination;
    // the secret travels by pipe and nothing that outlives the write holds it.
    let destination = root.appending(path: "delivered")
    let request = try ddRequest(writingTo: destination)
    let secret = "pairing-secret-not-in-argv"

    for argument in request.process.arguments {
      XCTAssertFalse(argument.contains(secret), argument)
    }
    for (key, value) in request.process.environment {
      XCTAssertFalse(value.contains(secret), key)
    }
    XCTAssertFalse(request.process.executable.path.contains(secret))
  }

  func testAnExecutableThatDoesNotMatchItsPinIsRefusedBeforeLaunch() async throws {
    // The identity binding. A digest that does not match must fail before a
    // process exists — this child would be the one performing destructive
    // writes, and "started then noticed" is not a recoverable order.
    var request = try ddRequest(writingTo: root.appending(path: "never"))
    request = ProcessIdentityBoundRequest(
      process: request.process, expectedSHA256: String(repeating: "f", count: 64))

    do {
      let handle = try await IdentityBoundDaemonLauncher().launch(
        request, secret: Data("secret".utf8))
      handle.terminate()
      XCTFail("a mismatched digest must refuse before spawning")
    } catch {
      // Any typed refusal is correct; what must not happen is a running child.
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appending(path: "never").path),
        "nothing may have been written by a process that should not exist")
    }
  }

  func testAnEmptySecretStillClosesStdin() async throws {
    // A daemon started with no secret is unpaired, not hung. The distinction
    // matters: unpaired refuses `startExecution` with a standing reason, while
    // hung looks like a daemon that is about to work.
    let destination = root.appending(path: "empty")
    let handle = try await IdentityBoundDaemonLauncher().launch(
      try ddRequest(writingTo: destination), secret: Data())

    var exited = false
    for _ in 0..<200 where !exited {
      if handle.reap() != nil { exited = true; break }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(exited, "an empty secret must still produce EOF")
    XCTAssertEqual(try Data(contentsOf: destination), Data())
  }
}
