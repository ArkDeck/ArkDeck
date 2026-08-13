import Foundation

/// Production identities shared by the Xcode-built CLI and LaunchAgent
/// wrappers. Data Protection Keychain access is granted by the provisioning
/// profile and these signed entitlements, never by a caller-supplied value.
package enum ArkDeckHelperIdentity {
  package static let teamIdentifier = "8AQTYW5FKR"
  package static let keychainAccessGroup = "8AQTYW5FKR.com.arkdeck.shared"
  package static let cliBundleIdentifier = "com.arkdeck.cli"
  package static let daemonBundleIdentifier = "com.arkdeck.agentd"
  package static let daemonBundleName = "ArkDeckAgent.app"
  package static let daemonExecutableName = "arkdeck-agentd"

  package static func applicationIdentifier(bundleIdentifier: String) -> String {
    teamIdentifier + "." + bundleIdentifier
  }

  package static let daemonCodeRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \""
    + teamIdentifier + "\" and identifier \"" + daemonBundleIdentifier + "\""
}
