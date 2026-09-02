import Darwin
import Foundation

enum ManualUIFlashFixtureError: Error, CustomStringConvertible {
  case moduleCacheNotOwnerPrivate(String)

  var description: String {
    switch self {
    case .moduleCacheNotOwnerPrivate(let path):
      return "manual UI module cache is not an owner-private real directory: \(path)"
    }
  }
}

/// Shared support for the contract tests that interpret
/// `scripts/manual_ui_flash/manual_ui_flash.swift` through `xcrun swift`.
enum ManualUIFlashFixtures {
  /// The one Clang module cache every interpreting test process shares.
  ///
  /// `swift test --parallel` runs each test method in its own `xctest`
  /// process, so a per-process cache (the previous `static let` seeded with a
  /// fresh UUID) never reused a module: every method paid the cold AppKit and
  /// Foundation module build again, about nine seconds against two warm, and
  /// left its cache behind in `$TMPDIR`, roughly seventy megabytes per process
  /// per run, with nothing removing them. Clang keys cache entries by compiler
  /// configuration and locks each module build, so one directory is safe to
  /// share between parallel processes and across runs, and a toolchain update
  /// only adds a new hashed subdirectory. One fixed directory bounds the
  /// residue to a single cache that macOS purges with the rest of the
  /// per-user temporary directory.
  static func sharedModuleCache() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-manual-ui-test-modules", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // The cache feeds compiled modules into the interpreting process, so it
    // has to be a real directory only this user can write, the same rule the
    // driver applies to its own AOT cache. The permissions above apply only
    // when the directory is created; a pre-existing wrong one fails here.
    var status = stat()
    guard directory.path.withCString({ lstat($0, &status) }) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & (S_IRWXG | S_IRWXO) == 0
    else {
      throw ManualUIFlashFixtureError.moduleCacheNotOwnerPrivate(directory.path)
    }
    return directory
  }
}
