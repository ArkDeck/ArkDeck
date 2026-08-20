import Foundation

/// The path of `url` inside `root`, compared by path component rather than by
/// trimming a string prefix.
///
/// The three packaged-resource tests each computed it as
/// `url.path.replacingOccurrences(of: root.path + "/", with: "")`, which is
/// only correct while both sides spell the same directory the same way. They
/// do not: `Bundle.module.url(forResource:)` hands back the path as the bundle
/// records it, and `FileManager`'s enumerator resolves symlinks in what it
/// yields. On a checkout under `/tmp` — a symlink to `/private/tmp` on macOS —
/// the root is `/tmp/…/Golden` while its own children come back as
/// `/private/tmp/…/Golden/1.0.0/…`, so removing the root substring leaves
/// `/private` glued to the front and every packaged file reads as
/// `/private1.0.0/registry.json`.
///
/// The test then fails on a resource set that is perfectly correct, which is
/// worse than a real failure: it fails only for developers whose checkout
/// happens to sit there, and the message accuses the fixtures.
///
/// Comparing components removes the arithmetic that made this possible.
/// Resolving both sides first makes the comparison answer the question asked —
/// "is this file inside that directory" — rather than "do these two strings
/// start the same way". A file that is not inside `root` returns nil instead
/// of a mangled string, so a caller cannot mistake one for the other.
func relativePathInsideBundleResource(_ url: URL, root: URL) -> String? {
  let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
  let urlComponents = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
  guard urlComponents.count > rootComponents.count,
    Array(urlComponents.prefix(rootComponents.count)) == rootComponents
  else { return nil }
  return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
}
