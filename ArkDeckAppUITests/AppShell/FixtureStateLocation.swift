import Foundation

/// Where UI tests put the fixture state they hand to the App.
///
/// Tests pass the file's path at launch and the App reads it from inside its
/// sandbox, through the read-only "/" exception Xcode adds to test builds. It
/// must not sit inside another app's container: macOS then asks whether
/// ArkDeck may access data from other apps, and the App's startup reads wait
/// for an answer, so a run nobody watches stalls at its first device row. The
/// runner's own temporary directory is such a place, because Xcode signs every
/// macOS UI-test runner sandboxed.
///
/// This directory is outside every container. The runner may write it only
/// through the exception in ArkDeckHDCUITests.entitlements, which names this
/// exact home-relative path; change both or neither.
enum FixtureStateLocation {
  static let homeRelativeDirectory = "Library/Caches/com.arkdeck.ui-test-fixture-state"

  /// A file in that directory, which is created on first use.
  static func file(named name: String) -> URL {
    let directory = accountHome.appending(
      path: homeRelativeDirectory, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: name)
  }

  /// The account's home, not the runner's: getpwuid_r ignores both HOME and
  /// the App Sandbox's container home, which is what NSHomeDirectory() gives a
  /// sandboxed runner.
  private static var accountHome: URL {
    var record = passwd(), resolved: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    let code = getpwuid_r(geteuid(), &record, &buffer, buffer.count, &resolved)
    guard code == 0, resolved != nil, let home = record.pw_dir,
      let path = String(validatingCString: home), path.hasPrefix("/")
    else {
      preconditionFailure("the account's home directory is unavailable")
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }
}
