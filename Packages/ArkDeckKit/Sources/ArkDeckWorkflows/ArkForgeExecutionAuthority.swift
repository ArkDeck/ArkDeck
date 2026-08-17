import ArkDeckCore
import ArkForgeIPC
import Foundation

/// ArkDeck's half of the split: it decides whether a step may run, and says so
/// by signing a `StepPermit`.
///
/// `arkforged` performs the write and cannot mint a permit — its architecture
/// guard forbids the daemon from referencing the issuing function. This type is
/// the other side of that guard, and the properties below are what make the
/// split worth having rather than just a second process.
///
/// # The snapshot is re-verified, never echoed
///
/// The daemon sends what it read immediately before asking. Signing it back
/// unchanged would prove nothing: the daemon would be asking itself. Every
/// admission is checked against facts this authority holds independently — the
/// plan it approved, the binding it confirmed, and its own clock
/// (design §3.3, ArkForge `architecture.md` 8.3).
///
/// # A refusal is an answer; silence is not
///
/// Declining is reported with a reason, and the daemon acts on it
/// (`CancelledSafe`). Saying nothing lets the snapshot expire and admission run
/// again. The two are different outcomes and this type never confuses them.
///
/// # Retransmission replays bytes
///
/// A permit is stored complete — bytes and tag — before it is returned. Asked
/// again for the same `permitID`, this replays those bytes rather than
/// re-deriving them. Two byte sequences claiming to be "the same permit" is
/// exactly the ambiguity the integrity tag exists to remove (ArkForge
/// `architecture.md` 8.6), and re-deriving is how the second one gets born.
package actor ArkForgeExecutionAuthority {

  /// What this authority approved, held independently of anything the daemon
  /// says. An admission is checked against these, not against itself.
  package struct ApprovedPlan: Sendable, Equatable {
    package let jobID: String
    package let planID: String
    /// 32 raw bytes of the plan digest this authority authorized.
    package let planSHA256: [UInt8]
    /// The device facts digest of the binding this authority confirmed.
    package let admittedDeviceFactsSHA256: [UInt8]
    package let binding: ArkForgeAuthorityBinding
    package let controllerSessionID: String
    /// How long a permit stays valid once signed. Bounded because an
    /// unbounded permit is a standing authorization to write.
    package let permitLifetimeMs: UInt64

    package init(
      jobID: String, planID: String, planSHA256: [UInt8],
      admittedDeviceFactsSHA256: [UInt8], binding: ArkForgeAuthorityBinding,
      controllerSessionID: String, permitLifetimeMs: UInt64 = 60_000
    ) {
      self.jobID = jobID
      self.planID = planID
      self.planSHA256 = planSHA256
      self.admittedDeviceFactsSHA256 = admittedDeviceFactsSHA256
      self.binding = binding
      self.controllerSessionID = controllerSessionID
      self.permitLifetimeMs = permitLifetimeMs
    }
  }

  /// Why an admission was declined.
  ///
  /// Each case is a distinct fact that failed to match, because "refused" on
  /// its own tells an operator nothing about which side moved — the plan, the
  /// device, or the clock.
  package enum Refusal: Sendable, Equatable, CustomStringConvertible {
    case unknownJob(asked: String, approved: String)
    case planMismatch
    case deviceFactsMismatch
    case snapshotExpired(observedAtEpochMs: UInt64, lifetimeMs: UInt64, nowEpochMs: UInt64)
    case snapshotFromTheFuture(observedAtEpochMs: UInt64, nowEpochMs: UInt64)
    case missingStepIdentity

    package var description: String {
      switch self {
      case .unknownJob(let asked, let approved):
        return "admission names job \(asked); this authority approved \(approved)"
      case .planMismatch:
        return "the admission's plan digest is not the plan this authority approved"
      case .deviceFactsMismatch:
        return
          "the admission's device facts are not the binding this authority confirmed; the "
          + "device under the daemon is not the device that was authorized"
      case .snapshotExpired(let observed, let lifetime, let now):
        return
          "the snapshot was read at \(observed) and lives \(lifetime) ms; it is now \(now). "
          + "Signing a stale snapshot authorizes a write against facts that have expired"
      case .snapshotFromTheFuture(let observed, let now):
        return
          "the snapshot claims to have been read at \(observed), which is after this "
          + "authority's own clock reads \(now); freshness cannot be judged"
      case .missingStepIdentity:
        return "the admission carries no step or attempt identity"
      }
    }
  }

  /// What this authority decided.
  package enum Decision: Sendable, Equatable {
    case sign(ArkForgeSignedPermit)
    case refuse(Refusal)
  }

  private let plan: ApprovedPlan
  private let secret: ArkForgePairingSecret
  private let now: @Sendable () -> UInt64
  /// permitID → the exact bytes that were signed, so a retransmission replays
  /// rather than re-derives.
  private var issued: [String: ArkForgeSignedPermit] = [:]
  /// The job identity `arkforged` assigned, adopted once at `startExecution`.
  ///
  /// The daemon names the job. ArkDeck's own job ID is a different namespace —
  /// `job-806a…` against the daemon's `JOB-0000…` — so checking an admission
  /// against it refused every admission that ever arrived, and a refused
  /// admission is a write that never happens.
  ///
  /// Adopting is not trusting the snapshot. This is taken from the
  /// `startExecution` reply, before any admission exists, and it can be set
  /// only once, so no later admission can move the job this authority approved.
  private var daemonJobID: String?

  /// Records the job identity the daemon assigned. Ignored after the first call.
  package func adoptDaemonJob(_ jobID: String) {
    guard daemonJobID == nil, !jobID.isEmpty else { return }
    daemonJobID = jobID
  }

  package init(
    plan: ApprovedPlan, secret: ArkForgePairingSecret,
    now: @escaping @Sendable () -> UInt64 = {
      UInt64(Date().timeIntervalSince1970 * 1000)
    }
  ) {
    self.plan = plan
    self.secret = secret
    self.now = now
  }

  /// Answers one admission.
  ///
  /// Deterministic in its inputs: the same snapshot at the same time yields the
  /// same decision, and the same `permitID` always yields the same bytes.
  package func admit(_ snapshot: ArkForgeStepAdmissionSnapshot) -> Decision {
    let permitID = Self.permitID(for: snapshot)
    // Retransmission first, before any re-verification. The bytes were already
    // authorized; re-deciding could produce a different answer for a permit
    // that has already been handed out, and then two permits would exist for
    // one admission.
    if let already = issued[permitID] {
      return .sign(already)
    }

    guard !snapshot.stepID.isEmpty, !snapshot.attemptID.isEmpty else {
      return .refuse(.missingStepIdentity)
    }
    let approvedJobID = daemonJobID ?? plan.jobID
    guard snapshot.jobID == approvedJobID else {
      return .refuse(.unknownJob(asked: snapshot.jobID, approved: approvedJobID))
    }
    // Compared against what this authority holds, not against the snapshot's
    // own claims. A snapshot cannot vouch for itself.
    guard snapshot.planID == plan.planID, snapshot.planSHA256 == plan.planSHA256 else {
      return .refuse(.planMismatch)
    }
    guard snapshot.admittedDeviceFactsSHA256 == plan.admittedDeviceFactsSHA256 else {
      return .refuse(.deviceFactsMismatch)
    }

    let currentTime = now()
    guard snapshot.observedAtEpochMs <= currentTime else {
      return .refuse(
        .snapshotFromTheFuture(
          observedAtEpochMs: snapshot.observedAtEpochMs, nowEpochMs: currentTime))
    }
    guard currentTime - snapshot.observedAtEpochMs <= snapshot.snapshotLifetimeMs else {
      return .refuse(
        .snapshotExpired(
          observedAtEpochMs: snapshot.observedAtEpochMs,
          lifetimeMs: snapshot.snapshotLifetimeMs, nowEpochMs: currentTime))
    }

    let permit = ArkForgeStepPermit(
      permitID: permitID,
      authorityNamespace: plan.binding.authorityNamespace,
      controllerSessionID: plan.controllerSessionID,
      // The daemon's name for the job, not ArkDeck's. The permit is verified on
      // the daemon's side against the job it created, so the id it is bound to
      // has to be the one the daemon assigned.
      jobID: approvedJobID,
      planID: plan.planID,
      planDigest: plan.planSHA256,
      stepID: snapshot.stepID,
      attemptID: snapshot.attemptID,
      // These three come from the snapshot by design: they describe what the
      // daemon is about to do, and this authority's job is to authorize *that*
      // rather than to invent its own version of it. What is checked above is
      // that the plan and the device are the ones it approved; within that,
      // the step's own digests are the daemon's to state and the permit's to
      // bind, so a substituted action fails at the daemon's own check.
      publicStepDigest: snapshot.publicStepSHA256,
      privateActionDigest: snapshot.privateActionSHA256,
      effectSetDigest: snapshot.effectSetSHA256,
      authorityBinding: plan.binding,
      admittedDeviceFactsDigest: plan.admittedDeviceFactsSHA256,
      issuedAtEpochMs: currentTime,
      expiresAtEpochMs: currentTime + plan.permitLifetimeMs,
      // Never configurable. A permit that could be spent twice is not a
      // permit; ArkForge refuses a non-single-use one outright.
      singleUse: true)

    let signed = ArkForgeSignedPermit(permit: permit, secret: secret)
    // Stored before it is returned. A permit handed out but not recorded is one
    // this authority could sign a second, different version of.
    issued[permitID] = signed
    return .sign(signed)
  }

  /// The permit identity for an admission.
  ///
  /// Derived from the step and attempt rather than generated, so a
  /// retransmitted admission maps to the permit that was already issued. A
  /// random id would make every retransmission a new authorization.
  package static func permitID(for snapshot: ArkForgeStepAdmissionSnapshot) -> String {
    "PERMIT-\(snapshot.jobID)-\(snapshot.stepID)-\(snapshot.attemptID)"
  }

  /// How many distinct permits this authority has issued. One per admission,
  /// never one per request.
  package var issuedCount: Int { issued.count }

  /// The bytes issued for a permit, if any. Read-only: nothing can replace a
  /// permit that was already handed out.
  package func issuedPermit(_ permitID: String) -> ArkForgeSignedPermit? {
    issued[permitID]
  }
}
