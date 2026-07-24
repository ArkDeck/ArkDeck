import Foundation
import Security

public enum UpdateArtifactSecurityError: Error, Equatable, Sendable {
  case runningApplicationUnsigned
  case invalidRunningApplicationTeam
  case staticCodeUnavailable
  case unsignedOrInvalidArtifact
  case differentTeam
  case artifactReplaced
  case consentRequired
  case handoffFailed
}

public struct ValidatedUpdateArtifact: Equatable, Sendable {
  public let downloaded: DownloadedUpdateArtifact
  public let teamIdentifier: String

  public init(downloaded: DownloadedUpdateArtifact, teamIdentifier: String) {
    self.downloaded = downloaded
    self.teamIdentifier = teamIdentifier
  }
}

public protocol UpdateArtifactValidating: Sendable {
  func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact
}

public protocol UpdateArtifactRevealing: Sendable {
  @MainActor func revealInFinder(_ url: URL) throws
}

/// Uses the running product's signature as the trust anchor. No Team identifier is hard-coded.
public struct SystemUpdateArtifactValidator: UpdateArtifactValidating, Sendable {
  public init() {}

  public func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact {
    let before = try UpdateArtifactStore.verifyFile(
      at: artifact.url,
      expectedLength: artifact.byteLength,
      expectedSHA256: artifact.sha256)
    guard before == artifact.identity else {
      throw UpdateArtifactSecurityError.artifactReplaced
    }
    let teamIdentifier = try Self.runningApplicationTeamIdentifier()
    let requirement = try Self.sameTeamRequirement(teamIdentifier)
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(artifact.url as CFURL, SecCSFlags(), &staticCode)
        == errSecSuccess,
      let staticCode
    else { throw UpdateArtifactSecurityError.staticCodeUnavailable }

    let flags = SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
    guard status == errSecSuccess else {
      if status == errSecCSReqFailed {
        throw UpdateArtifactSecurityError.differentTeam
      }
      throw UpdateArtifactSecurityError.unsignedOrInvalidArtifact
    }
    guard let artifactTeam = try Self.teamIdentifier(for: staticCode),
      artifactTeam == teamIdentifier
    else { throw UpdateArtifactSecurityError.differentTeam }

    let after = try UpdateArtifactStore.verifyFile(
      at: artifact.url,
      expectedLength: artifact.byteLength,
      expectedSHA256: artifact.sha256)
    guard after == before else { throw UpdateArtifactSecurityError.artifactReplaced }
    return ValidatedUpdateArtifact(downloaded: artifact, teamIdentifier: artifactTeam)
  }

  private static func runningApplicationTeamIdentifier() throws -> String {
    var runningCode: SecCode?
    var runningStaticCode: SecStaticCode?
    guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess, let runningCode,
      SecCodeCheckValidity(runningCode, SecCSFlags(), nil) == errSecSuccess,
      SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode) == errSecSuccess,
      let runningStaticCode,
      let team = try teamIdentifier(for: runningStaticCode)
    else { throw UpdateArtifactSecurityError.runningApplicationUnsigned }
    guard isValidTeamIdentifier(team) else {
      throw UpdateArtifactSecurityError.invalidRunningApplicationTeam
    }
    return team
  }

  private static func teamIdentifier(for code: SecStaticCode) throws -> String? {
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
    else { throw UpdateArtifactSecurityError.unsignedOrInvalidArtifact }
    let dictionary = information as? [String: Any]
    return dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
  }

  private static func sameTeamRequirement(_ teamIdentifier: String) throws -> SecRequirement {
    guard isValidTeamIdentifier(teamIdentifier) else {
      throw UpdateArtifactSecurityError.invalidRunningApplicationTeam
    }
    let source =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
      as CFString
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(source, SecCSFlags(), &requirement) == errSecSuccess,
      let requirement
    else { throw UpdateArtifactSecurityError.invalidRunningApplicationTeam }
    return requirement
  }

  private static func isValidTeamIdentifier(_ value: String) -> Bool {
    value.count == 10
      && value.allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase) }
  }
}
