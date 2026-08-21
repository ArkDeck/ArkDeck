import Foundation

@testable import ArkDeckCore
@testable import ArkForgeClient

struct ArkForgeBundleFixture {
  let root: URL
  let daemon: URL
  let profile: URL
  let daemonSHA256: String
  let manifestSHA256: String

  var environment: [String: String] {
    ["ARKDECK_ARKFORGE_BUNDLE_PATH": root.path]
  }
}

@discardableResult
func makeArkForgeBundle(
  at root: URL, daemonBytes: String = "arkforged-test-build"
) throws -> ArkForgeBundleFixture {
  let executableDirectory = root.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
  let profileDirectory = root.appending(
    path: "Contents/Resources/profiles", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: executableDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: profileDirectory, withIntermediateDirectories: true)
  let cli = executableDirectory.appending(path: "arkforge")
  let daemon = executableDirectory.appending(path: "arkforged")
  let profile = profileDirectory.appending(path: "dayu200.yaml")
  try Data("arkforge-test-cli".utf8).write(to: cli)
  try Data(daemonBytes.utf8).write(to: daemon)
  try Data(
    """
    schemaVersion: arkforge.device-profile/v1

    profile:
      id: org.openharmony.dayu200
      version: 1.0.0
    """.utf8
  ).write(to: profile)
  try ArkForgeBundleManifestWriter.write(
    bundleURL: root, version: "0.1.0-test",
    declarations: [
      .init(path: "Contents/MacOS/arkforge", role: .cli),
      .init(path: "Contents/MacOS/arkforged", role: .daemon),
      .init(
        path: "Contents/Resources/profiles/dayu200.yaml", role: .profile,
        profileID: "org.openharmony.dayu200"),
    ])
  let loaded = try ArkForgeReleaseBundleReader.load(bundleURL: root)
  let daemonSHA256 = SHA256Hex.string(of: try Data(contentsOf: daemon))
  return ArkForgeBundleFixture(
    root: loaded.rootURL, daemon: loaded.daemonURL, profile: profile,
    daemonSHA256: daemonSHA256, manifestSHA256: loaded.manifestSHA256)
}
