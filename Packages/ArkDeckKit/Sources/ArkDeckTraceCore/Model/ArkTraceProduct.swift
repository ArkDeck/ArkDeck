/// Machine identity retained by the migrated `arktrace` helper.
/// AppDistributionTests bind compatible version/build values to ArkDeck's
/// canonical Xcode project so the App/helper contract cannot drift silently.
package enum ArkTraceProduct {
    public static let name = "ArkTrace"
    public static let commandName = "arktrace"
    public static let version = "0.1.0"
    public static let build = "1"
}
