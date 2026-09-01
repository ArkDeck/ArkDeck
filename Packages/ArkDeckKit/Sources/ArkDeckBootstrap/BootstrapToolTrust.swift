import ArkDeckCore
import Darwin
import Foundation
import Security

/// Read-only macOS code identity assessment. This does not run a version
/// command, clear quarantine, obtain execution permission, or trust an HDC
/// candidate merely because it has any developer's valid signature.
package struct BootstrapToolTrust: Codable, Equatable {
  package let signature: String
  package let identifier: String?
  package let teamIdentifier: String?
  package let codeDirectorySHA256: String?

  package static func inspect(_ url: URL) throws -> BootstrapToolTrust {
    try inspect(url, validationFlags: SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures))
  }

  /// Validates the signed native code and its publisher while deliberately
  /// leaving mutable bundle resources to a separate, allowlisted resource
  /// envelope check. DevEco's SDK manager may replace SDK payloads after the
  /// app was signed, so validating every unrelated bundle resource would make
  /// a still publisher-bound toolchain impossible to register. This flag does
  /// not skip executable page hashes or CMS/publisher validation.
  package static func inspectCodeOnly(_ url: URL) throws -> BootstrapToolTrust {
    try inspect(url, validationFlags: SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        | kSecCSDoNotValidateResources))
  }

  private static func inspect(
    _ url: URL, validationFlags: SecCSFlags
  ) throws -> BootstrapToolTrust {
    var code: SecStaticCode?
    let opened = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
    guard opened == errSecSuccess, let code else {
      throw BootstrapBundleFiles.failure("admissionDenied", "host tool has no readable native code identity (status \(opened))")
    }
    let status = SecStaticCodeCheckValidity(code, validationFlags, nil)
    if status == errSecCSUnsigned {
      return Self(signature: "unsigned", identifier: nil, teamIdentifier: nil, codeDirectorySHA256: nil)
    }
    guard status == errSecSuccess else {
      throw BootstrapBundleFiles.failure("admissionDenied", "host tool signature failed validation (status \(status))")
    }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
      let fields = raw as? [String: Any], let flags = fields[kSecCodeInfoFlags as String] as? NSNumber else {
      throw BootstrapBundleFiles.failure("admissionDenied", "host tool signing information cannot be read")
    }
    let identifier = fields[kSecCodeInfoIdentifier as String] as? String
    let team = fields[kSecCodeInfoTeamIdentifier as String] as? String
    guard [identifier, team].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
      throw BootstrapBundleFiles.failure("admissionDenied", "host tool signing metadata is outside its bounded schema")
    }
    // CS_ADHOC. A valid ad-hoc signature is integrity information, not an
    // identified developer or a Gatekeeper authorization.
    let state = flags.uint32Value & 0x2 != 0 ? "adHoc" : "verified"
    let directory = fields[kSecCodeInfoUnique as String] as? Data
    return Self(signature: state, identifier: identifier, teamIdentifier: team,
      codeDirectorySHA256: directory.map { SHA256Hex.string(of: $0) })
  }

  package func projection(identity match: BootstrapToolRegistry.PublishedIdentity? = nil) -> JSONValue {
    return .object([
      "policy": .string("arkdeck.host-tool-inspection/1"), "signature": .string(signature),
      "signingIdentifier": identifier.map(JSONValue.string) ?? .null,
      "teamIdentifier": teamIdentifier.map(JSONValue.string) ?? .null,
      "codeDirectoryIdentitySHA256": codeDirectorySHA256.map(JSONValue.string) ?? .null,
      "platformTrust": .string("unverified"), "executionAssessment": .string("notPerformed"),
      "registeredIdentity": .bool(match != nil),
      "profileReferences": .array((match?.profileReferences ?? []).map(JSONValue.string)),
      "toolVersion": match.map { .string($0.version) } ?? .null,
      "versionSource": match == nil ? .null : .string("publishedProfileDigestMatch"),
    ])
  }

  package var isWellFormed: Bool {
    guard ["unsigned", "adHoc", "verified"].contains(signature),
      [identifier, teamIdentifier].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else { return false }
    if signature == "unsigned" { return identifier == nil && teamIdentifier == nil && codeDirectorySHA256 == nil }
    return codeDirectorySHA256.map(Self.digest) ?? true
  }
  package static func digest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
