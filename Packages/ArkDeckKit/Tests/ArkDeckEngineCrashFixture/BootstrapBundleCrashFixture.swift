import ArkDeckCore
import ArkDeckLaunchAgent
import Darwin
import Foundation

func runBootstrapBundleCrashFixture(window: String, directory: URL) throws {
  let source = directory.appending(path: "Fixture.app")
  try FileManager.default.createDirectory(at: source.appending(path: "Contents"), withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-1"], format: .xml, options: 0)
    .write(to: source.appending(path: "Contents/Info.plist"))
  try Data("never executed fixture bytes".utf8).write(to: source.appending(path: "Contents/payload"))
  let registry = BootstrapBundleRegistry(root: directory.appending(path: "registry"),
    validateBundle: { _ in /* synthetic host fixture; no production trust or device claim */ }, fault: { point in
      guard window == "bootstrap-bundle-" + point else { return }
      try Data(point.utf8).write(to: directory.appending(path: "ready"))
      raise(SIGSTOP)
      while true { pause() }
    }, nowUTC: { "2026-09-01T00:00:00Z" })
  _ = try registry.register(file: source)
}
