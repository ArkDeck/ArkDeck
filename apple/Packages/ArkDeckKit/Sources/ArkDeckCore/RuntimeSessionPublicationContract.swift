// The closed wire contract for one Job's Session publication fact.
//
// Package-only on purpose: Workflows produces the object, the CLI and the
// Agent client validate it, and the App read boundary converts it. None of
// them may invent a state, a reason or a receipt, so all four keys and both
// vocabularies live here once rather than being spelled out per consumer.
//
// A publication receipt is a storage fact. It is never a device-success
// claim, never a retention promise, and never authority to replay anything.

import Foundation

/// What the Runtime can currently say about this Job's Session.
///
/// `unavailable` is the honest answer for a Job that carries no publication
/// ownership marker at all — every Job admitted before the production writer
/// existed, and every Job whose terminal path never reached the writer. It is
/// deliberately distinct from `failed`: nothing was attempted, so nothing
/// failed.
package enum RuntimeSessionPublicationState: String, Sendable, Equatable, CaseIterable {
  case pending
  case published
  case failed
  case outcomeUnknown
  case unavailable
}

/// Why a non-`published` publication is where it is. Closed: a reason the
/// producer cannot establish is `publicationUncertain`, never a guess.
package enum RuntimeSessionPublicationReason: String, Sendable, Equatable, CaseIterable {
  /// The Job has not reached a terminal state, so there is nothing to seal.
  case jobNotTerminal
  /// The configured Session owner could not admit this Job's claim yet.
  case waitingForStorage
  /// A known failure is still explicitly continuable; its Session is sealed
  /// only once that finalization concludes.
  case finalizationPending
  /// The configured Session root, its volume or its catalog is unusable.
  case storageUnavailable
  /// The Job's own durable facts cannot render the current Manifest contract.
  case sourceIntegrityFailed
  /// The root, volume or Session identity moved between two observations.
  case identityChanged
  /// A document this producer built was refused by the current contract.
  case contractViolation
  /// A write crossed the seal boundary and its outcome cannot be proven.
  case publicationUncertain
  /// No ownership marker exists for this Job.
  case noCurrentPublicationRecord

  /// Whether this reason may accompany a `failed` state. `publicationUncertain`
  /// may not: an unprovable outcome is `outcomeUnknown`, and calling it failed
  /// would assert a non-execution nobody established.
  package var isConfirmedFailure: Bool {
    switch self {
    case .storageUnavailable, .sourceIntegrityFailed, .identityChanged, .contractViolation:
      true
    case .jobNotTerminal, .waitingForStorage, .finalizationPending, .publicationUncertain,
      .noCurrentPublicationRecord:
      false
    }
  }
}

/// The exact four-key object every Job read surface publishes.
///
/// Nullable values are explicit `null` — never omitted — so a consumer cannot
/// read an absent key as "no publication" when the producer meant "published
/// with no failure".
package struct RuntimeSessionPublicationFact: Sendable, Equatable {
  package static let keys: Set<String> = [
    "state", "manifestSha256", "catalogGeneration", "reasonCode",
  ]

  package let state: RuntimeSessionPublicationState
  package let manifestSHA256: String?
  /// Canonical decimal string. The catalog generation is a `UInt64` on disk
  /// and JSON's number domain cannot carry it losslessly.
  package let catalogGeneration: String?
  package let reasonCode: RuntimeSessionPublicationReason?

  private init(
    state: RuntimeSessionPublicationState,
    manifestSHA256: String?,
    catalogGeneration: String?,
    reasonCode: RuntimeSessionPublicationReason?
  ) {
    self.state = state
    self.manifestSHA256 = manifestSHA256
    self.catalogGeneration = catalogGeneration
    self.reasonCode = reasonCode
  }

  /// A confirmed receipt. Both facts are required: a receipt without its exact
  /// catalog entry is not a publication.
  package static func published(
    manifestSHA256: String, catalogGeneration: String
  ) throws -> Self {
    guard SHA256Hex.isLowercaseSHA256(manifestSHA256),
      isCanonicalDecimal(catalogGeneration)
    else { throw invalid("published Session publication needs an exact manifest and generation") }
    return Self(
      state: .published, manifestSHA256: manifestSHA256,
      catalogGeneration: catalogGeneration, reasonCode: nil)
  }

  package static func pending(_ reason: RuntimeSessionPublicationReason) throws -> Self {
    guard [.jobNotTerminal, .waitingForStorage, .finalizationPending].contains(reason) else {
      throw invalid("\(reason.rawValue) is not a pending Session publication reason")
    }
    return Self(state: .pending, manifestSHA256: nil, catalogGeneration: nil, reasonCode: reason)
  }

  package static func failed(_ reason: RuntimeSessionPublicationReason) throws -> Self {
    guard reason.isConfirmedFailure else {
      throw invalid("\(reason.rawValue) cannot report a confirmed publication failure")
    }
    return Self(state: .failed, manifestSHA256: nil, catalogGeneration: nil, reasonCode: reason)
  }

  package static let outcomeUnknown = Self(
    state: .outcomeUnknown, manifestSHA256: nil, catalogGeneration: nil,
    reasonCode: .publicationUncertain)

  package static let unavailable = Self(
    state: .unavailable, manifestSHA256: nil, catalogGeneration: nil,
    reasonCode: .noCurrentPublicationRecord)

  package var json: JSONValue {
    .object([
      "state": .string(state.rawValue),
      "manifestSha256": manifestSHA256.map(JSONValue.string) ?? .null,
      "catalogGeneration": catalogGeneration.map(JSONValue.string) ?? .null,
      "reasonCode": reasonCode.map { .string($0.rawValue) } ?? .null,
    ])
  }

  /// Strict decode. Every consumer that reads this fact off the wire uses this
  /// one validator, so a missing, extra, duplicated or wrongly-typed key, and
  /// every state/reason/hash/decimal combination the producer cannot emit, is
  /// refused identically by the CLI, the Agent client and the App boundary.
  package static func validated(_ value: JSONValue) throws -> Self {
    guard case .object(let fields) = value, Set(fields.keys) == keys,
      case .string(let rawState)? = fields["state"],
      let state = RuntimeSessionPublicationState(rawValue: rawState)
    else { throw invalid("Session publication does not match its closed read schema") }
    let reason: RuntimeSessionPublicationReason?
    switch fields["reasonCode"] {
    case .string(let raw)?:
      guard let decoded = RuntimeSessionPublicationReason(rawValue: raw) else {
        throw invalid("Session publication carries an unpublished reason")
      }
      reason = decoded
    case .null?: reason = nil
    default: throw invalid("Session publication reason is unreadable")
    }
    switch state {
    case .published:
      guard case .string(let digest)? = fields["manifestSha256"],
        case .string(let generation)? = fields["catalogGeneration"], reason == nil
      else { throw invalid("published Session publication must carry its exact receipt") }
      return try published(manifestSHA256: digest, catalogGeneration: generation)
    case .pending, .failed, .outcomeUnknown, .unavailable:
      guard fields["manifestSha256"] == .null, fields["catalogGeneration"] == .null,
        let reason
      else { throw invalid("unpublished Session publication must name its reason and no receipt") }
      switch state {
      case .pending: return try pending(reason)
      case .failed: return try failed(reason)
      case .outcomeUnknown:
        guard reason == .publicationUncertain else {
          throw invalid("an uncertain publication reports publicationUncertain")
        }
        return outcomeUnknown
      case .unavailable:
        guard reason == .noCurrentPublicationRecord else {
          throw invalid("an absent publication reports noCurrentPublicationRecord")
        }
        return unavailable
      case .published: throw invalid("unreachable")
      }
    }
  }

  /// A `UInt64` rendered without padding, sign or separators.
  package static func isCanonicalDecimal(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 20,
      value.utf8.allSatisfy({ (48...57).contains($0) }),
      value == "0" || value.first != "0", UInt64(value) != nil
    else { return false }
    return true
  }

  private static func invalid(_ text: String) -> AgentExecutionControlFailure {
    .init("recordUnreadable", text)
  }
}

extension RuntimeSessionPublicationFact: Codable {
  /// One shape on the wire and one validator for it. Decoding routes through
  /// `validated` so a value that crossed a process boundary is held to the
  /// same rules as one the producer just built — a synthesized memberwise
  /// decoder would let a receipt through that no producer could mint.
  package init(from decoder: any Decoder) throws {
    self = try Self.validated(try JSONValue(from: decoder))
  }

  package func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}
