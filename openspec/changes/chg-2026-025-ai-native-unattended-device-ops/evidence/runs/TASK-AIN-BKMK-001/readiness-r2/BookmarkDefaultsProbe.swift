import Foundation

enum ProbeError: Error {
  case usage
  case bookmarkRoundTrip
  case missingBookmark
  case persistedBytesMismatch
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  throw ProbeError.usage
}

let operation = arguments[1]
let key = arguments[2]
let defaults = UserDefaults.standard

func canonicalURL(_ path: String) -> URL {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
}

switch operation {
case "install":
  guard arguments.count == 4 else {
    throw ProbeError.usage
  }
  let target = canonicalURL(arguments[3])
  let bookmark = try target.bookmarkData(
    options: [],
    includingResourceValuesForKeys: nil,
    relativeTo: nil)
  var stale = false
  let resolved = try URL(
    resolvingBookmarkData: bookmark,
    options: [.withoutUI],
    relativeTo: nil,
    bookmarkDataIsStale: &stale)
  guard !stale, canonicalURL(resolved.path) == target else {
    throw ProbeError.bookmarkRoundTrip
  }
  defaults.set(bookmark, forKey: key)
  _ = defaults.synchronize()
  guard defaults.data(forKey: key) == bookmark else {
    throw ProbeError.persistedBytesMismatch
  }
  print("operation=install")
  print("process=\(ProcessInfo.processInfo.processName)")
  print("bookmark_bytes=\(bookmark.count)")
  print("stale=\(stale)")
  print("target_match=true")

case "resolve":
  guard arguments.count == 4 else {
    throw ProbeError.usage
  }
  guard let bookmark = defaults.data(forKey: key) else {
    throw ProbeError.missingBookmark
  }
  let target = canonicalURL(arguments[3])
  var stale = false
  let resolved = try URL(
    resolvingBookmarkData: bookmark,
    options: [.withoutUI],
    relativeTo: nil,
    bookmarkDataIsStale: &stale)
  guard !stale, canonicalURL(resolved.path) == target else {
    throw ProbeError.bookmarkRoundTrip
  }
  print("operation=resolve")
  print("process=\(ProcessInfo.processInfo.processName)")
  print("bookmark_bytes=\(bookmark.count)")
  print("stale=\(stale)")
  print("target_match=true")

case "remove":
  guard arguments.count == 3 else {
    throw ProbeError.usage
  }
  defaults.removeObject(forKey: key)
  _ = defaults.synchronize()
  print("operation=remove")
  print("process=\(ProcessInfo.processInfo.processName)")
  print("present=\(defaults.object(forKey: key) != nil)")

case "status":
  guard arguments.count == 3 else {
    throw ProbeError.usage
  }
  print("operation=status")
  print("process=\(ProcessInfo.processInfo.processName)")
  print("present=\(defaults.object(forKey: key) != nil)")

default:
  throw ProbeError.usage
}
