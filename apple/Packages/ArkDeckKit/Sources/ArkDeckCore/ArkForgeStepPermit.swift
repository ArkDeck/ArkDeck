import CryptoKit
import Foundation

/// The authority's reference to its own target binding, as ArkForge reads it.
///
/// `stableIdentityDigest` is what lets ArkForge notice that "the same binding"
/// now points at a different device without ArkForge knowing how ArkDeck
/// computes identity.
package struct ArkForgeAuthorityBinding: Sendable, Equatable {
  package let authorityNamespace: String
  package let bindingID: String
  package let bindingRevision: UInt64
  /// 32 raw bytes, not hex. The wire form is a CBOR byte string.
  package let stableIdentityDigest: [UInt8]

  package init(
    authorityNamespace: String,
    bindingID: String,
    bindingRevision: UInt64,
    stableIdentityDigest: [UInt8]
  ) {
    self.authorityNamespace = authorityNamespace
    self.bindingID = bindingID
    self.bindingRevision = bindingRevision
    self.stableIdentityDigest = stableIdentityDigest
  }

  var cbor: CanonicalCBOR.Value {
    .map([
      ("authorityNamespace", .text(authorityNamespace)),
      ("bindingId", .text(bindingID)),
      ("bindingRevision", .unsigned(bindingRevision)),
      ("stableIdentityDigest", .bytes(stableIdentityDigest)),
    ])
  }
}

/// One authorization for one step of one plan, as ArkForge defines it.
///
/// The field names and CBOR shape are ArkForge's, not ArkDeck's: the canonical
/// definition is `crates/arkforge-authority-api/src/lib.rs`, and this type
/// exists to reproduce it byte for byte. Renaming a field here without renaming
/// it there produces a permit that decodes as malformed, which is the good
/// failure; changing a *type* here (a digest to hex text, say) produces one
/// that decodes fine and verifies against the wrong bytes, which is not.
///
/// The integrity tag is deliberately not part of this value. It covers the
/// body, and a body that contained its own tag would be signing a claim about
/// itself — see `signingBody`.
package struct ArkForgeStepPermit: Sendable, Equatable {
  package let permitID: String
  package let authorityNamespace: String
  package let controllerSessionID: String
  package let jobID: String
  package let planID: String
  package let planDigest: [UInt8]
  package let stepID: String
  package let attemptID: String
  package let publicStepDigest: [UInt8]
  package let privateActionDigest: [UInt8]
  package let effectSetDigest: [UInt8]
  package let authorityBinding: ArkForgeAuthorityBinding
  package let admittedDeviceFactsDigest: [UInt8]
  package let issuedAtEpochMs: UInt64
  package let expiresAtEpochMs: UInt64
  package let singleUse: Bool

  package init(
    permitID: String,
    authorityNamespace: String,
    controllerSessionID: String,
    jobID: String,
    planID: String,
    planDigest: [UInt8],
    stepID: String,
    attemptID: String,
    publicStepDigest: [UInt8],
    privateActionDigest: [UInt8],
    effectSetDigest: [UInt8],
    authorityBinding: ArkForgeAuthorityBinding,
    admittedDeviceFactsDigest: [UInt8],
    issuedAtEpochMs: UInt64,
    expiresAtEpochMs: UInt64,
    singleUse: Bool
  ) {
    self.permitID = permitID
    self.authorityNamespace = authorityNamespace
    self.controllerSessionID = controllerSessionID
    self.jobID = jobID
    self.planID = planID
    self.planDigest = planDigest
    self.stepID = stepID
    self.attemptID = attemptID
    self.publicStepDigest = publicStepDigest
    self.privateActionDigest = privateActionDigest
    self.effectSetDigest = effectSetDigest
    self.authorityBinding = authorityBinding
    self.admittedDeviceFactsDigest = admittedDeviceFactsDigest
    self.issuedAtEpochMs = issuedAtEpochMs
    self.expiresAtEpochMs = expiresAtEpochMs
    self.singleUse = singleUse
  }

  /// The CBOR value the tag covers — every field except the tag.
  ///
  /// Mirrors `permit_body` in `arkforge-authority-api`. The listing order is
  /// that function's order so the two can be read side by side; the encoder
  /// sorts by encoded key regardless, so order here carries no meaning.
  var body: CanonicalCBOR.Value {
    .map([
      ("permitId", .text(permitID)),
      ("authorityNamespace", .text(authorityNamespace)),
      ("controllerSessionId", .text(controllerSessionID)),
      ("jobId", .text(jobID)),
      ("planId", .text(planID)),
      ("planDigest", .bytes(planDigest)),
      ("stepId", .text(stepID)),
      ("attemptId", .text(attemptID)),
      ("publicStepDigest", .bytes(publicStepDigest)),
      ("privateActionDigest", .bytes(privateActionDigest)),
      ("effectSetDigest", .bytes(effectSetDigest)),
      ("authorityBinding", authorityBinding.cbor),
      ("admittedDeviceFactsDigest", .bytes(admittedDeviceFactsDigest)),
      ("issuedAtEpochMs", .unsigned(issuedAtEpochMs)),
      ("expiresAtEpochMs", .unsigned(expiresAtEpochMs)),
      ("singleUse", .bool(singleUse)),
    ])
  }

  /// The exact bytes the integrity tag is computed over, and the exact bytes
  /// that travel to the daemon.
  ///
  /// ArkForge re-encodes what it decodes and refuses a permit whose encoding
  /// differs from these bytes, so "close enough" fails closed rather than
  /// executing under a permit nobody signed.
  package var signingBody: Data {
    CanonicalCBOR.encodedData(body)
  }
}

/// Identifies which pairing secret minted a tag. Rotates whenever either
/// process restarts, so an unconsumed permit from an older epoch is void
/// rather than merely old (ArkForge `architecture.md` 8.6).
package struct ArkForgePairingEpoch: Sendable, Equatable, Hashable {
  package let value: UInt64
  package init(_ value: UInt64) { self.value = value }
}

/// The shared secret ArkDeck writes to the daemon's stdin at startup.
///
/// Held in memory only and never written to disk in the clear. It is a
/// `struct` holding bytes rather than a `String` so it does not end up in a
/// description, a log line, or a JSON encoding by accident — `debugDescription`
/// is overridden for the same reason.
package struct ArkForgePairingSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  private let secret: [UInt8]
  package let epoch: ArkForgePairingEpoch

  package init(secret: [UInt8], epoch: ArkForgePairingEpoch) {
    self.secret = secret
    self.epoch = epoch
  }

  package var description: String { "ArkForgePairingSecret(epoch: \(epoch.value))" }
  package var debugDescription: String { description }

  /// Mints the integrity tag for a permit body.
  ///
  /// This is the one function in ArkDeck that makes a write authorizable, and
  /// it is the reason the split works: ArkForge's architecture guard forbids
  /// its daemon from referencing the minting side at all, so a permit can only
  /// come from here.
  package func integrityTag(over signingBody: Data) -> [UInt8] {
    let key = SymmetricKey(data: Data(secret))
    return Array(HMAC<SHA256>.authenticationCode(for: signingBody, using: key))
  }
}

/// A permit plus the tag that authorizes it, ready to hand to the daemon.
///
/// The bytes are carried, not the permit: a retransmission must replay the
/// exact bytes that were signed rather than re-deriving them. Two byte
/// sequences claiming to be "the same permit" is the ambiguity the integrity
/// tag exists to remove (ArkForge `architecture.md` 8.6), and re-deriving is
/// how a second, differently-encoded permit gets created by accident.
package struct ArkForgeSignedPermit: Sendable, Equatable {
  package let permitID: String
  package let signingBody: Data
  package let integrityTag: [UInt8]
  package let pairingEpoch: ArkForgePairingEpoch

  package init(permit: ArkForgeStepPermit, secret: ArkForgePairingSecret) {
    let body = permit.signingBody
    self.permitID = permit.permitID
    self.signingBody = body
    self.integrityTag = secret.integrityTag(over: body)
    self.pairingEpoch = secret.epoch
  }
}
