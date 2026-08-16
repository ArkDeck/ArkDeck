import Foundation

/// Which `rkdeveloptool` this authority tells `arkforged` to bind, and why
/// that choice is not a detail.
///
/// The toolchain digest is part of the maturity combination (ArkForge
/// `architecture.md` 12.3), so "which build" decides *which combination gets
/// published*. A real-hardware pass earned with one build does not carry over
/// to another; swapping later costs a full re-run.
///
/// # The three builds, measured (ArkForge AD-023, 2026-08-16)
///
/// | digest | source | shippable |
/// |---|---|---|
/// | `bbd7bdc0…` | homebrew, ArkDeck's `pinnedReadOnlyDiscovery` | no — quarantine hangs it in dyld (AD-011/AD-015) |
/// | `038a8a0e…` | local build, ArkDeck's `pinnedProduction`, the one the 2026-08-15 rehearsal ran | no — links `/opt/homebrew/…/libusb-1.0.0.dylib`, a path only that machine has |
/// | `231a05ef…` | this repository's `rockchip-component-build@1.0.0`, bundled in the App | **yes** — seven system libraries, libusb statically linked, Developer ID, Hardened Runtime, empty entitlement dictionary |
///
/// Only the third can ship, so it is the one pinned here.
///
/// # Signed, not unsigned
///
/// `openspec/integrations/rockchip/bundled-component/1.0.0/package.json`
/// records `be753c69…` with `"unsigned": true` — the digest of the bytes that
/// were *ingested*, before Code Sign On Copy. `arkforged` hashes the file it is
/// about to execute, which is the signed one. Pinning the unsigned digest
/// makes the daemon refuse to start with "hashes to X, pin says Y", and the
/// two digests being one letter apart in a document is exactly how that
/// happens.
///
/// # This is data with provenance, not a constant
///
/// Re-signing the component changes these bytes. The value below belongs to
/// one signed build and must be re-read from that build's package receipt
/// whenever the component is rebuilt — it is not a property of "rkdeveloptool
/// 1.32".
public enum ArkForgeToolchainPin: Sendable {
  /// The identifier `arkforged` reports back on the handshake as
  /// `toolchain_id`.
  public static let toolchainID = "rkdeveloptool"

  /// SHA-256 of the **signed** component inside the ArkDeck app bundle, which
  /// is what `--rkdeveloptool-sha256` must be given.
  public static let signedSHA256 =
    "231a05ef9aae17f9c8b8d3801b3ec2f4a4653291782021fe65517610aa11c79e"

  /// SHA-256 of the unsigned ingest, as recorded in the component package.
  /// Kept beside the signed one so the difference is visible rather than
  /// discovered.
  public static let unsignedSHA256 =
    "be753c696b8e37016cd072167acaac426e561ab070a8ee8a8e5fb29816b36fb7"

  /// Where the component sits inside the app bundle.
  public static let bundleRelativePath = "Contents/MacOS/rkdeveloptool"

  /// The only dynamic libraries a shippable component may pull in.
  ///
  /// This is the list AD-023 turns on: the rejected build linked Homebrew's
  /// libusb, which is not here and never can be. Kept as data so a future
  /// component that grows a dependency fails a check rather than a customer's
  /// machine.
  public static let permittedDependencies: Set<String> = [
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
    "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
    "/System/Library/Frameworks/Security.framework/Versions/A/Security",
    "/usr/lib/libSystem.B.dylib",
    "/usr/lib/libc++.1.dylib",
    "/usr/lib/libiconv.2.dylib",
    "/usr/lib/libobjc.A.dylib",
  ]

  /// Whether a digest the daemon reported is the one this authority pinned.
  ///
  /// Compared case-insensitively on purpose: the daemon prints lowercase hex
  /// and so does this file, but a mismatch caused by letter case would be an
  /// exceptionally unhelpful way to refuse a flash.
  public static func matchesPin(reportedSHA256: String) -> Bool {
    reportedSHA256.lowercased() == signedSHA256
  }

  /// Why a handshake's toolchain does not match, in a sentence worth reading.
  ///
  /// Named cases rather than a generic mismatch, because these three have
  /// different fixes and the operator cannot tell them apart from the digest
  /// alone.
  public static func mismatchExplanation(reportedSHA256: String) -> String? {
    let reported = reportedSHA256.lowercased()
    if reported == signedSHA256 { return nil }
    if reported.isEmpty {
      return "the daemon has no tool bound; start it with --rkdeveloptool and "
        + "--rkdeveloptool-sha256 \(signedSHA256)"
    }
    if reported == unsignedSHA256 {
      return "the daemon was pinned to the unsigned ingest (\(unsignedSHA256)); it must be "
        + "pinned to the signed component in the app bundle (\(signedSHA256))"
    }
    if reported == "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611" {
      return "the daemon bound the local build that links Homebrew's libusb; it cannot ship "
        + "(ArkForge AD-023). Bind the bundled component (\(signedSHA256))"
    }
    if reported == "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923" {
      return "the daemon bound the homebrew build, which hangs in dyld under quarantine "
        + "(ArkForge AD-011/AD-015). Bind the bundled component (\(signedSHA256))"
    }
    return "the daemon bound \(reported), and this authority publishes plans for "
      + "\(signedSHA256); the toolchain digest is part of the maturity combination, so this "
      + "pairing was never published"
  }
}
