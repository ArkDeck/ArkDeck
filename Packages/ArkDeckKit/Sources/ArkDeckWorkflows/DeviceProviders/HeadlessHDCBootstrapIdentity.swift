import ArkDeckOpenHarmony

/// Static diagnostic lookup for pre-daemon CLI composition. No process is
/// launched and no tool selection, trust or operation authority is created.
package enum HeadlessHDCBootstrapIdentity {
  package static func lookup(sha256: String) -> (version: String, profileReferences: [String])? {
    HDCRegisteredToolIdentity.match(sha256: sha256).map { ($0.version, $0.profileReferences) }
  }
}
