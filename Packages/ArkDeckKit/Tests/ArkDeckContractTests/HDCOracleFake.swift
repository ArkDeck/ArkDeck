// The fake HDC every Swift HDC oracle pins (CHG-2026-074, TASK-XPA-014).

import Darwin
import Foundation

/// One POSIX sh driver at one fixed physical root, shared by every HDC oracle
/// and by the Rust replays of them, so all of them record one executable
/// identity: the HDC tool's SHA-256 is part of a Job's durable evidence, and
/// a SwiftPM-built `ArkDeckFakeHDCFixture` has a new identity on every build.
///
/// The driver never changes. What it answers is the `hdc-answers.sh` fragment
/// an oracle installs beside it and records with its fixture; the fragment
/// reads the mode named in `hdc-mode` (`normal` when there is none) and the
/// call's arguments. Every call first appends its arguments, each followed by
/// U+001F, and then a newline to `hdc-invocations.log`. A child receives none
/// of the test's environment and a script's `$0` is the executor's inode
/// path, so every path the driver uses is fixed and absolute.
enum HDCOracleFake {
  static let root = URL(filePath: "/private/tmp/arkdeck-hdc-oracle", directoryHint: .isDirectory)
  static let lockPath = "/private/tmp/arkdeck-hdc-oracle.lock"
  static let driver = Data(
    #"""
    #!/bin/sh
    # ArkDeck HDC oracle driver. Each call is recorded, then answered by the
    # oracle's hdc-answers.sh in the mode hdc-mode names.
    root=/private/tmp/arkdeck-hdc-oracle
    mode=normal
    if [ -r "$root/hdc-mode" ]; then IFS= read -r mode < "$root/hdc-mode"; fi
    printf '%s\037' "$@" >> "$root/hdc-invocations.log"
    printf '\n' >> "$root/hdc-invocations.log"
    . "$root/hdc-answers.sh"

    """#.utf8)

  /// Serializes every user of the fixed root, Rust replays included.
  static func lock() throws -> Int32 {
    let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    guard flock(lock, LOCK_EX) == 0 else {
      close(lock)
      throw POSIXError(.EBUSY)
    }
    return lock
  }

  /// Recreates the root holding the driver, the oracle's answers and an
  /// empty invocation log, and returns the driver.
  static func install(answers: String) throws -> URL {
    let manager = FileManager.default
    try? manager.removeItem(at: root)
    try manager.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let hdc = root.appending(path: "hdc")
    try driver.write(to: hdc)
    guard chmod(hdc.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    try Data(answers.utf8).write(to: root.appending(path: "hdc-answers.sh"))
    try Data().write(to: root.appending(path: "hdc-invocations.log"))
    return hdc
  }

  /// Names the mode the next calls answer in.
  static func setMode(_ mode: String) throws {
    try Data("\(mode)\n".utf8).write(to: root.appending(path: "hdc-mode"))
  }

  /// Every call recorded since the root was installed.
  static func invocations() throws -> Data {
    try Data(contentsOf: root.appending(path: "hdc-invocations.log"))
  }
}
