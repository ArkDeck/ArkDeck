import ArkDeckBootstrap
import ArkDeckLaunchAgent
import Darwin
import Foundation

func runBootstrapToolCrashFixture(window: String, directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let source = directory.appending(path: "source-hdc")
  let fixture = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "ArkDeckFakeHDCFixture")
  try FileManager.default.copyItem(at: fixture, to: source)
  let registry = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: directory.appending(path: "registry")), fault: { point in
    guard window == "bootstrap-tool-" + point else { return }
    try Data(point.utf8).write(to: directory.appending(path: "ready"))
    raise(SIGSTOP)
    while true { pause() }
  })
  // Reads/copies native fixture bytes using the production static signature
  // inspector. It never executes FakeHDC or connects to any device/server.
  _ = try registry.register(file: source)
}
