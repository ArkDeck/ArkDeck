import Darwin
import Foundation

/// Read-only projection of campaign ledgers written before Runtime-owned Flash
/// admission replaced the Evolution campaign lane. This surface deliberately
/// has no encoder, constructor, reservation or append API: old records remain
/// inspectable, but no current process can mint or advance one.
package struct HistoricalEvolutionCampaignArchive: Sendable {
  package static let maximumBytes = 16 * 1_024 * 1_024

  private let root: URL

  package init(root: URL) throws {
    guard root.isFileURL, root.path.hasPrefix("/") else {
      throw HistoricalEvolutionCampaignArchiveError.invalidRoot
    }
    self.root = root.standardizedFileURL
  }

  package static func production() throws -> Self {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false)
    return try Self(
      root: applicationSupport
        .appending(path: "ArkDeck", directoryHint: .isDirectory)
        .appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
        .appending(path: "evolution-campaigns", directoryHint: .isDirectory))
  }

  package func load(_ campaignID: String) throws -> HistoricalEvolutionCampaignDocument {
    guard Self.isCampaignID(campaignID) else {
      throw HistoricalEvolutionCampaignArchiveError.campaignNotFound(campaignID)
    }
    let rootDescriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      if errno == ENOENT {
        throw HistoricalEvolutionCampaignArchiveError.campaignNotFound(campaignID)
      }
      throw HistoricalEvolutionCampaignArchiveError.unreadable("openRoot")
    }
    defer { Darwin.close(rootDescriptor) }

    var rootMetadata = stat()
    guard fstat(rootDescriptor, &rootMetadata) == 0,
      (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
      rootMetadata.st_uid == geteuid(), rootMetadata.st_mode & 0o077 == 0
    else { throw HistoricalEvolutionCampaignArchiveError.unreadable("rootBinding") }

    let descriptor = Darwin.openat(
      rootDescriptor, "\(campaignID).json",
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT {
        throw HistoricalEvolutionCampaignArchiveError.campaignNotFound(campaignID)
      }
      throw HistoricalEvolutionCampaignArchiveError.unreadable("openDocument")
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0, metadata.st_size <= Self.maximumBytes
    else { throw HistoricalEvolutionCampaignArchiveError.unreadable("documentMetadata") }

    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset, off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw HistoricalEvolutionCampaignArchiveError.unreadable("readDocument")
      }
      offset += count
    }

    do {
      let document = try JSONDecoder().decode(
        HistoricalEvolutionCampaignDocument.self, from: data)
      guard document.campaignID == campaignID else {
        throw HistoricalEvolutionCampaignArchiveError.unreadable("documentIdentity")
      }
      return document
    } catch let error as HistoricalEvolutionCampaignArchiveError {
      throw error
    } catch {
      throw HistoricalEvolutionCampaignArchiveError.unreadable("decodeDocument")
    }
  }

  private static func isCampaignID(_ value: String) -> Bool {
    value.range(of: #"^ECAMP-[A-F0-9]{24}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }
}

package enum HistoricalEvolutionCampaignArchiveError: Error, Equatable, LocalizedError {
  case invalidRoot
  case campaignNotFound(String)
  case unreadable(String)

  package var errorDescription: String? {
    switch self {
    case .invalidRoot:
      "historical campaign archive root is invalid"
    case .campaignNotFound(let campaignID):
      "historical campaign not found: \(campaignID)"
    case .unreadable(let reason):
      "historical campaign archive is unreadable: \(reason)"
    }
  }
}

package struct HistoricalEvolutionCampaignDocument: Decodable, Sendable {
  private static let documentType = "rockchip-evolution-campaign-ledger"
  private static let schemaVersion = "1.0.0"

  package let campaignID: String
  package let assertion: HistoricalEvolutionCampaignAssertion
  package let events: [HistoricalEvolutionCampaignEvent]

  private enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case campaignID
    case assertion
    case events
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let documentType = try container.decode(String.self, forKey: .documentType)
    let schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    campaignID = try container.decode(String.self, forKey: .campaignID)
    assertion = try container.decode(
      HistoricalEvolutionCampaignAssertion.self, forKey: .assertion)
    events = try container.decode([HistoricalEvolutionCampaignEvent].self, forKey: .events)
    guard documentType == Self.documentType, schemaVersion == Self.schemaVersion,
      campaignID == assertion.campaignID,
      events.enumerated().allSatisfy({ $0.element.sequence == $0.offset + 1 })
    else {
      throw HistoricalEvolutionCampaignArchiveError.unreadable("documentIdentity")
    }
  }

  package var isTerminal: Bool {
    if events.contains(where: { $0.kind == .campaignStopped }) { return true }
    return events.contains {
      $0.kind == .attemptTerminal && $0.disposition != .safeToReflash
    }
  }

  package var reservedAttemptCount: Int {
    events.filter { $0.kind == .attemptReserved }.count
  }
}

package struct HistoricalEvolutionCampaignAssertion: Decodable, Sendable {
  package let confirmationDigestSHA256: String
  package let maxAttempts: Int

  private enum CodingKeys: String, CodingKey {
    case confirmationDigestSHA256
    case maxAttempts
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    confirmationDigestSHA256 = try container.decode(
      String.self, forKey: .confirmationDigestSHA256)
    maxAttempts = try container.decode(Int.self, forKey: .maxAttempts)
    guard confirmationDigestSHA256.range(
      of: #"^[a-f0-9]{64}$"#, options: .regularExpression)
      == confirmationDigestSHA256.startIndex..<confirmationDigestSHA256.endIndex,
      (1...16).contains(maxAttempts)
    else {
      throw HistoricalEvolutionCampaignArchiveError.unreadable("assertionIdentity")
    }
  }

  package var campaignID: String {
    "ECAMP-\(confirmationDigestSHA256.prefix(24).uppercased())"
  }
}

package enum HistoricalEvolutionAttemptDisposition: String, Decodable, Sendable {
  case succeeded
  case safeToReflash
  case unsafePartial
  case outcomeUnknown
}

package enum HistoricalEvolutionCampaignEventKind: String, Decodable, Sendable {
  case candidatePrepared
  case attemptReserved
  case attemptTerminal
  case campaignStopped
}

package struct HistoricalEvolutionCampaignEvent: Decodable, Sendable {
  package let sequence: Int
  package let kind: HistoricalEvolutionCampaignEventKind
  package let at: String
  package let candidate: HistoricalEvolutionCandidateReference?
  package let review: HistoricalEvolutionReviewReference?
  package let ordinal: Int?
  package let jobID: String?
  package let sessionID: String?
  package let disposition: HistoricalEvolutionAttemptDisposition?
  package let reasonCode: String?
  package let detail: String?
}

package struct HistoricalEvolutionCandidateReference: Decodable, Sendable {
  package let candidateID: String
}

package struct HistoricalEvolutionReviewReference: Decodable, Sendable {
  package let reviewID: String
}
