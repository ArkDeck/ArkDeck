// HDC device authorization workflow, channel protection and security presentation.
//
// Pure move out of HDCProduction.swift (CHG-2026-047 T06): bytes are
// unchanged apart from this header and the shared import block. The
// dispatch-security core (semantic bindings, prepared commands, dispatch
// permits, lifecycle executor) deliberately stays in HDCProduction.swift:
// its private/fileprivate web is a load-bearing anti-forgery boundary.

import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

// MARK: - Authorization and channel protection

enum HDCAuthorizationProbeState: Sendable, Equatable {
  case ready
  case unauthorized
  case denied(reason: String)
  case keyAccessDenied(reason: String)
  case offline
  case unknown(reason: String)
}

public enum HDCAuthorizationState: Sendable, Equatable {
  case unauthorizedWaitingForTrust
  case ready
  case denied(reason: String)
  case timedOut
  case cancelled
  case keyAccessDenied(reason: String)
  case unavailable(reason: String)

  package var hasNonDestructiveRetry: Bool {
    switch self {
    case .ready: false
    case .unauthorizedWaitingForTrust, .denied, .timedOut, .cancelled, .keyAccessDenied,
      .unavailable:
      true
    }
  }
}

struct HDCAuthorizationPollingPolicy: Sendable, Equatable {
  let maximumAttempts: Int
  let perProbeTimeout: Duration
  let overallTimeout: Duration
  let pollingInterval: Duration

  init(
    maximumAttempts: Int,
    perProbeTimeout: Duration = .seconds(5),
    overallTimeout: Duration = .seconds(30),
    pollingInterval: Duration = .milliseconds(250)
  ) {
    precondition(maximumAttempts > 0, "authorization polling must be bounded")
    precondition(perProbeTimeout > .zero, "each authorization probe must have a deadline")
    precondition(overallTimeout > .zero, "authorization polling must have an overall deadline")
    precondition(pollingInterval >= .zero, "authorization polling interval cannot be negative")
    self.maximumAttempts = maximumAttempts
    self.perProbeTimeout = perProbeTimeout
    self.overallTimeout = overallTimeout
    self.pollingInterval = pollingInterval
  }
}

private enum HDCAuthorizationProbeRaceResult: Sendable {
  case probe(HDCAuthorizationProbeState)
  case deadlineExceeded
  case cancelled
}

private actor HDCAuthorizationProbeRace {
  private var result: HDCAuthorizationProbeRaceResult?
  private var continuation: CheckedContinuation<HDCAuthorizationProbeRaceResult, Never>?

  func wait() async -> HDCAuthorizationProbeRaceResult {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }

  func resolve(_ result: HDCAuthorizationProbeRaceResult) {
    guard self.result == nil else { return }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: result)
  }
}

/// Bounded polling has no lifecycle executor and therefore cannot restart a
/// shared server to force an authorization prompt.
struct HDCAuthorizationWorkflow: Sendable {
  func poll(
    policy: HDCAuthorizationPollingPolicy,
    probe: @escaping @Sendable (Int) async -> HDCAuthorizationProbeState
  ) async -> HDCAuthorizationState {
    let clock = ContinuousClock()
    let overallDeadline = clock.now.advanced(by: policy.overallTimeout)
    for attempt in 1...policy.maximumAttempts {
      if Task.isCancelled { return .cancelled }
      guard clock.now < overallDeadline else { return .timedOut }
      let remaining = clock.now.duration(to: overallDeadline)
      let probeResult = await runProbe(
        attempt: attempt,
        timeout: min(policy.perProbeTimeout, remaining),
        probe: probe)
      if Task.isCancelled { return .cancelled }
      let probeState: HDCAuthorizationProbeState
      switch probeResult {
      case .probe(let state):
        probeState = state
      case .deadlineExceeded:
        return .timedOut
      case .cancelled:
        return .cancelled
      }
      switch probeState {
      case .ready:
        return .ready
      case .denied(let reason):
        return .denied(reason: reason)
      case .keyAccessDenied(let reason):
        return .keyAccessDenied(reason: reason)
      case .offline:
        return .unavailable(reason: "HDC reported the target offline")
      case .unknown(let reason):
        return .unavailable(reason: reason)
      case .unauthorized:
        break
      }

      if (attempt < policy.maximumAttempts) && (policy.pollingInterval > .zero) {
        guard clock.now < overallDeadline else { return .timedOut }
        let delay = min(policy.pollingInterval, clock.now.duration(to: overallDeadline))
        do {
          try await clock.sleep(for: delay)
        } catch {
          return .cancelled
        }
      }
    }
    return .timedOut
  }

  /// The probe runs in an unstructured task so leaving this function never
  /// waits for a non-cooperative implementation. Cancellation is requested on
  /// every losing branch, and the single-assignment race rejects late values.
  private func runProbe(
    attempt: Int,
    timeout: Duration,
    probe: @escaping @Sendable (Int) async -> HDCAuthorizationProbeState
  ) async -> HDCAuthorizationProbeRaceResult {
    let race = HDCAuthorizationProbeRace()
    let probeTask = Task {
      let state = await probe(attempt)
      await race.resolve(.probe(state))
    }
    let deadlineTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await race.resolve(.deadlineExceeded)
    }
    let result = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      Task { await race.resolve(.cancelled) }
    }
    probeTask.cancel()
    deadlineTask.cancel()
    return result
  }
}

public struct HDCChannelProtectionEvidence: Sendable, Equatable {
  public let evidenceVersion: String
  public let source: String
  public let detail: String

  public init(evidenceVersion: String, source: String, detail: String) {
    precondition(!evidenceVersion.isEmpty && !source.isEmpty && !detail.isEmpty)
    self.evidenceVersion = evidenceVersion
    self.source = source
    self.detail = detail
  }
}

public enum HDCChannelProtectionState: Sendable, Equatable {
  case encryptedVerified(HDCChannelProtectionEvidence)
  case unverifiedAssumeUnprotected
}

public enum HDCSubserverCapability: Sendable, Equatable {
  case supportedReadOnly
  case unsupported
  case unknown(reason: String)
}

package struct HDCSecurityPresentation: Sendable, Equatable {
  public let authorization: HDCAuthorizationState
  public let protection: HDCChannelProtectionState
  public let tcpWarning: String?

  public init(
    authorization: HDCAuthorizationState,
    protection: HDCChannelProtectionState,
    transportIsTCP: Bool
  ) {
    self.authorization = authorization
    self.protection = protection
    tcpWarning =
      transportIsTCP && protection == .unverifiedAssumeUnprotected
      ? "Channel protection is unverified. Use this TCP target only on a trusted, isolated network."
      : nil
  }
}

/// The recovery state exposed to the UI is deliberately narrower than an
/// executor.  A presentation can request and confirm an impact snapshot, but
/// it contains neither an argv nor a dispatch capability.
public enum HDCLifecycleRecoveryPresentation: Sendable, Equatable {
  case unavailable(reason: String)
  case preview(HDCServerLifecycleImpactPreview)
  case confirmed(HDCServerLifecycleConfirmation)
  case blocked(reason: String)

  var impactPreview: HDCServerImpactSnapshot? {
    switch self {
    case .preview(let preview): return preview.snapshot
    case .confirmed: return nil
    case .unavailable, .blocked: return nil
    }
  }
}

/// App-facing diagnostics use case.  It intentionally has no lifecycle
/// executor parameter, so UI actions can create a durable preview and user
/// confirmation but can never manufacture a `kill` or `kill -r` dispatch.
package protocol HDCDiagnosticsStateProviding: Sendable {
  func refresh() async -> HDCDiagnosticsPresentation
  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
}

/// App-owned configuration for the read-only discovery phase. User-selected
/// executables persist as security-scoped bookmarks; explicit launch/support
/// overrides remain absolute-path-only. Discovery validates every path and
/// never searches PATH. Session composition replaces this read-only provider
/// once a durable supervisor is available.
