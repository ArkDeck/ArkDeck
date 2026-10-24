import Foundation

/// The App sandbox container is the one filesystem namespace both product processes can use
/// without adding an application-group or home-path entitlement.
///
/// Inside the App, Foundation already resolves Application Support and Caches into this container.
/// The non-sandboxed CLI resolves the same physical directories from the current user's home and
/// the pinned App bundle identifier. Keeping that decision here prevents the three update stores
/// from accidentally splitting into App and CLI copies again.
enum AutoUpdateFilesystemLayout {
  static let appBundleIdentifier = "com.arkdeck.desktop"

  static func applicationSupportDirectory(
    fileManager: FileManager = .default,
    processBundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) throws -> URL {
    let processDirectory = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return sharedDirectory(
      kind: "Application Support",
      processBundleIdentifier: processBundleIdentifier,
      processDirectory: processDirectory,
      processHomeDirectory: fileManager.homeDirectoryForCurrentUser)
  }

  static func cachesDirectory(
    fileManager: FileManager = .default,
    processBundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) throws -> URL {
    let processDirectory = try fileManager.url(
      for: .cachesDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return sharedDirectory(
      kind: "Caches",
      processBundleIdentifier: processBundleIdentifier,
      processDirectory: processDirectory,
      processHomeDirectory: fileManager.homeDirectoryForCurrentUser)
  }

  package static func sharedDirectory(
    kind: String,
    processBundleIdentifier: String?,
    processDirectory: URL,
    processHomeDirectory: URL
  ) -> URL {
    if processBundleIdentifier == appBundleIdentifier {
      return processDirectory.standardizedFileURL
    }
    return processHomeDirectory
      .appending(path: "Library/Containers", directoryHint: .isDirectory)
      .appending(path: appBundleIdentifier, directoryHint: .isDirectory)
      .appending(path: "Data/Library", directoryHint: .isDirectory)
      .appending(path: kind, directoryHint: .isDirectory)
      .standardizedFileURL
  }
}
