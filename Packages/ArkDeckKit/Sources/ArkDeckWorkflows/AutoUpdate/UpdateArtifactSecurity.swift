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

protocol UpdateCodeSigningChecking: Sendable {
  func runningApplicationTeamIdentifier() throws -> String
  func validateRunningApplication(requirementSource: String) throws
  func validateArtifact(at url: URL, requirementSource: String) throws -> String?
}

/// Uses the running product's Developer ID Application signature as the trust anchor. No Team
/// identifier is hard-coded.
public struct SystemUpdateArtifactValidator: UpdateArtifactValidating, Sendable {
  private let codeSigning: any UpdateCodeSigningChecking

  public init() {
    codeSigning = SystemUpdateCodeSigningChecker()
  }

  init(codeSigning: any UpdateCodeSigningChecking) {
    self.codeSigning = codeSigning
  }

  public func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact {
    let before = try UpdateArtifactStore.verifyFile(
      at: artifact.url,
      expectedLength: artifact.byteLength,
      expectedSHA256: artifact.sha256)
    guard before == artifact.identity else {
      throw UpdateArtifactSecurityError.artifactReplaced
    }
    let teamIdentifier = try codeSigning.runningApplicationTeamIdentifier()
    let requirementSource = try Self.developerIDApplicationRequirementSource(
      teamIdentifier: teamIdentifier)
    try codeSigning.validateRunningApplication(requirementSource: requirementSource)
    guard
      let artifactTeam = try codeSigning.validateArtifact(
        at: artifact.url, requirementSource: requirementSource),
      artifactTeam == teamIdentifier
    else { throw UpdateArtifactSecurityError.differentTeam }

    let after = try UpdateArtifactStore.verifyFile(
      at: artifact.url,
      expectedLength: artifact.byteLength,
      expectedSHA256: artifact.sha256)
    guard after == before else { throw UpdateArtifactSecurityError.artifactReplaced }
    return ValidatedUpdateArtifact(downloaded: artifact, teamIdentifier: artifactTeam)
  }

  static func developerIDApplicationRequirementSource(
    teamIdentifier: String
  ) throws -> String {
    guard isValidTeamIdentifier(teamIdentifier) else {
      throw UpdateArtifactSecurityError.invalidRunningApplicationTeam
    }
    return
      "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }

  private static func isValidTeamIdentifier(_ value: String) -> Bool {
    value.count == 10
      && value.allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase) }
  }
}

private struct SystemUpdateCodeSigningChecker: UpdateCodeSigningChecking {
  func runningApplicationTeamIdentifier() throws -> String {
    var runningCode: SecCode?
    var runningStaticCode: SecStaticCode?
    guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess, let runningCode,
      SecCodeCheckValidity(runningCode, SecCSFlags(), nil) == errSecSuccess,
      SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode) == errSecSuccess,
      let runningStaticCode,
      let team = try Self.teamIdentifier(for: runningStaticCode)
    else { throw UpdateArtifactSecurityError.runningApplicationUnsigned }
    guard
      (try? SystemUpdateArtifactValidator.developerIDApplicationRequirementSource(
        teamIdentifier: team)) != nil
    else {
      throw UpdateArtifactSecurityError.invalidRunningApplicationTeam
    }
    return team
  }

  func validateRunningApplication(requirementSource: String) throws {
    let requirement = try Self.requirement(source: requirementSource)
    var runningCode: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess, let runningCode else {
      throw UpdateArtifactSecurityError.runningApplicationUnsigned
    }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
    guard SecCodeCheckValidity(runningCode, flags, requirement) == errSecSuccess else {
      throw UpdateArtifactSecurityError.runningApplicationUnsigned
    }
  }

  func validateArtifact(at url: URL, requirementSource: String) throws -> String? {
    let requirement = try Self.requirement(source: requirementSource)
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
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
    return try Self.teamIdentifier(for: staticCode)
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

  private static func requirement(source: String) throws -> SecRequirement {
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(source as CFString, SecCSFlags(), &requirement)
        == errSecSuccess,
      let requirement
    else { throw UpdateArtifactSecurityError.invalidRunningApplicationTeam }
    return requirement
  }
}
