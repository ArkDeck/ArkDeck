import Foundation

public enum NativeLibraryDirectorySource {
  public enum Failure: LocalizedError {
    case invalidDirectory, tooManyEntries, tooManyLibraries
    public var errorDescription: String? {
      switch self {
      case .invalidDirectory: "Choose 1–4 readable directories. Symbolic links are not followed."
      case .tooManyEntries: "The selected directories contain more than 500 entries. Choose a narrower build directory."
      case .tooManyLibraries: "More than 100 libraries were found. Choose a narrower build directory."
      }
    }
  }

  /// Uses the user's file-picker grant, including a Finder-mounted SMB share.
  /// No network mount, credentials, shell or writes are involved.
  @concurrent
  public static func libraries(in directories: [URL]) async throws -> [NativeLibraryDeploymentSource] {
    guard (1...4).contains(directories.count) else { throw Failure.invalidDirectory }
    var libraries: [NativeLibraryDeploymentSource] = []
    var visited = 0
    for directory in directories {
      let gainedScope = directory.startAccessingSecurityScopedResource()
      defer { if gainedScope { directory.stopAccessingSecurityScopedResource() } }
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      let values = try directory.resourceValues(forKeys: keys)
      guard directory.isFileURL, values.isDirectory == true, values.isSymbolicLink != true,
        directory.resolvingSymlinksInPath().path != "/" else {
        throw Failure.invalidDirectory
      }
      var pending = [directory]
      while let parent = pending.popLast() {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
          at: parent, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        visited += children.count
        guard visited <= 500 else { throw Failure.tooManyEntries }
        for child in children {
          let values = try child.resourceValues(forKeys: keys)
          guard values.isSymbolicLink != true, contains(child, in: directory) else { continue }
          if values.isDirectory == true {
            pending.append(child)
          } else if values.isRegularFile == true,
            DebugTypedValueValidator.isValidNativeLibraryLogicalName(child.lastPathComponent) {
            libraries.append(.file(child, directory: directory))
            guard libraries.count <= 100 else { throw Failure.tooManyLibraries }
          }
        }
      }
    }
    var seen: Set<String> = []
    return libraries.filter { seen.insert($0.id).inserted }.sorted {
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.id < $1.id
    }
  }

  package static func contains(_ file: URL, in directory: URL) -> Bool {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let path = file.resolvingSymlinksInPath().standardizedFileURL.path
    let originalRoot = directory.standardizedFileURL.path + "/"
    let originalPath = file.standardizedFileURL.path
    guard root != "/", originalPath.hasPrefix(originalRoot),
      (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    else { return false }
    let relativePath = originalPath.dropFirst(originalRoot.count)
    return path == root + "/" + relativePath
  }
}
