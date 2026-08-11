import Foundation

public protocol AuditClock: Sendable {
  var nowUTC: Date { get }
}

package protocol MonotonicRuntimeClock: Sendable {
  var nowNanoseconds: Int64 { get }
}

public struct SystemAuditClock: AuditClock {
  public init() {}

  public var nowUTC: Date { Date() }
}

/// `PORT-CLOCK-ELAPSED-001`: continues across system sleep.
package final class ContinuousElapsedClock: MonotonicRuntimeClock, @unchecked Sendable {
  private let clock = ContinuousClock()
  private let origin: ContinuousClock.Instant

  public init() {
    origin = clock.now
  }

  package var nowNanoseconds: Int64 {
    durationNanoseconds(origin.duration(to: clock.now))
  }
}

/// `PORT-CLOCK-ACTIVE-001`: suspends while the system is asleep.
package final class SuspendingActiveClock: MonotonicRuntimeClock, @unchecked Sendable {
  private let clock = SuspendingClock()
  private let origin: SuspendingClock.Instant

  public init() {
    origin = clock.now
  }

  package var nowNanoseconds: Int64 {
    durationNanoseconds(origin.duration(to: clock.now))
  }
}

package struct RuntimeDurationSample: Equatable, Sendable {
  package let auditUTC: Date
  package let elapsedDurationNanoseconds: Int64
  package let activeDurationNanoseconds: Int64

  public init(
    auditUTC: Date,
    elapsedDurationNanoseconds: Int64,
    activeDurationNanoseconds: Int64
  ) {
    self.auditUTC = auditUTC
    self.elapsedDurationNanoseconds = elapsedDurationNanoseconds
    self.activeDurationNanoseconds = activeDurationNanoseconds
  }
}

/// Captures process-local origins and exposes only accumulated durations. The
/// origins are intentionally not Codable and cannot enter restart snapshots.
package final class RuntimeClockPair: @unchecked Sendable {
  private let lock = NSLock()
  private let auditClock: any AuditClock
  private let elapsedClock: any MonotonicRuntimeClock
  private let activeClock: any MonotonicRuntimeClock
  private let elapsedOrigin: Int64
  private let activeOrigin: Int64
  private let accumulatedElapsed: Int64
  private let accumulatedActive: Int64

  public init(
    auditClock: any AuditClock = SystemAuditClock(),
    elapsedClock: any MonotonicRuntimeClock = ContinuousElapsedClock(),
    activeClock: any MonotonicRuntimeClock = SuspendingActiveClock(),
    accumulatedElapsedDurationNanoseconds: Int64 = 0,
    accumulatedActiveDurationNanoseconds: Int64 = 0
  ) {
    self.auditClock = auditClock
    self.elapsedClock = elapsedClock
    self.activeClock = activeClock
    elapsedOrigin = elapsedClock.nowNanoseconds
    activeOrigin = activeClock.nowNanoseconds
    accumulatedElapsed = max(0, accumulatedElapsedDurationNanoseconds)
    accumulatedActive = max(0, accumulatedActiveDurationNanoseconds)
  }

  package func sample() throws -> RuntimeDurationSample {
    lock.lock()
    defer { lock.unlock() }
    let elapsedNow = elapsedClock.nowNanoseconds
    let activeNow = activeClock.nowNanoseconds
    guard elapsedNow >= elapsedOrigin, activeNow >= activeOrigin else {
      throw RuntimeClockError.monotonicClockRegressed
    }
    return RuntimeDurationSample(
      auditUTC: auditClock.nowUTC,
      elapsedDurationNanoseconds: addingWithoutOverflow(
        accumulatedElapsed,
        elapsedNow - elapsedOrigin
      ),
      activeDurationNanoseconds: addingWithoutOverflow(
        accumulatedActive,
        activeNow - activeOrigin
      )
    )
  }
}

public enum RuntimeClockError: Error, Equatable, Sendable {
  case monotonicClockRegressed
}

package struct ElapsedDeadline: Equatable, Sendable {
  package let startElapsedDurationNanoseconds: Int64
  package let timeoutNanoseconds: Int64

  public init(startElapsedDurationNanoseconds: Int64, timeoutNanoseconds: Int64) throws {
    guard startElapsedDurationNanoseconds >= 0, timeoutNanoseconds > 0 else {
      throw RuntimeTimingError.invalidDuration
    }
    self.startElapsedDurationNanoseconds = startElapsedDurationNanoseconds
    self.timeoutNanoseconds = timeoutNanoseconds
  }

  package func isExpired(atElapsedDurationNanoseconds elapsed: Int64) -> Bool {
    remainingNanoseconds(atElapsedDurationNanoseconds: elapsed) == 0
  }

  package func remainingNanoseconds(atElapsedDurationNanoseconds elapsed: Int64) -> Int64 {
    guard elapsed >= startElapsedDurationNanoseconds else { return 0 }
    let consumed = elapsed - startElapsedDurationNanoseconds
    return consumed >= timeoutNanoseconds ? 0 : timeoutNanoseconds - consumed
  }
}

/// The only timing form permitted to cross a process boundary. There is no
/// field for a monotonic instant, tick, boot time, or clock origin.
package struct RestartSafeTimingSnapshot: Equatable, Sendable {
  package let accumulatedElapsedDurationNanoseconds: Int64
  package let accumulatedActiveDurationNanoseconds: Int64
  package let configuredOverallTimeoutNanoseconds: Int64?
  package let configuredDeadlineUTC: Date?
  package let snapshotUTC: Date

  public init(
    accumulatedElapsedDurationNanoseconds: Int64,
    accumulatedActiveDurationNanoseconds: Int64,
    configuredOverallTimeoutNanoseconds: Int64?,
    configuredDeadlineUTC: Date?,
    snapshotUTC: Date
  ) throws {
    guard accumulatedElapsedDurationNanoseconds >= 0,
      accumulatedActiveDurationNanoseconds >= 0,
      configuredOverallTimeoutNanoseconds.map({ $0 > 0 }) ?? true,
      configuredOverallTimeoutNanoseconds != nil || configuredDeadlineUTC != nil,
      snapshotUTC.timeIntervalSince1970.isFinite,
      configuredDeadlineUTC.map({ $0.timeIntervalSince1970.isFinite }) ?? true
    else {
      throw RuntimeTimingError.invalidDuration
    }
    self.accumulatedElapsedDurationNanoseconds = accumulatedElapsedDurationNanoseconds
    self.accumulatedActiveDurationNanoseconds = accumulatedActiveDurationNanoseconds
    self.configuredOverallTimeoutNanoseconds = configuredOverallTimeoutNanoseconds
    self.configuredDeadlineUTC = configuredDeadlineUTC
    self.snapshotUTC = snapshotUTC
  }
}

public enum RuntimeTimingError: Error, Equatable, Sendable {
  case invalidDuration
}

package enum RestartDeadlineFailure: String, Equatable, Sendable {
  case invalidOrMissingEvidence
  case wallClockRollback
  case deadlineReached
}

package enum RestartDeadlineEvaluation: Equatable, Sendable {
  case notExpired(remainingNanoseconds: Int64)
  case expired(RestartDeadlineFailure)
}

package enum RestartDeadlineEvaluator {
  public static func evaluate(
    snapshot: RestartSafeTimingSnapshot?,
    currentUTC: Date
  ) -> RestartDeadlineEvaluation {
    guard let snapshot,
      snapshot.accumulatedElapsedDurationNanoseconds >= 0,
      snapshot.accumulatedActiveDurationNanoseconds >= 0,
      snapshot.configuredOverallTimeoutNanoseconds != nil || snapshot.configuredDeadlineUTC != nil,
      currentUTC.timeIntervalSince1970.isFinite
    else {
      return .expired(.invalidOrMissingEvidence)
    }
    guard currentUTC >= snapshot.snapshotUTC else {
      return .expired(.wallClockRollback)
    }

    var remainingCandidates: [Int64] = []
    if let timeout = snapshot.configuredOverallTimeoutNanoseconds {
      guard timeout > 0,
        let wallDelta = nanosecondsBetween(snapshot.snapshotUTC, currentUTC)
      else {
        return .expired(.invalidOrMissingEvidence)
      }
      let projectedElapsed = addingWithoutOverflow(
        snapshot.accumulatedElapsedDurationNanoseconds,
        wallDelta
      )
      remainingCandidates.append(
        projectedElapsed >= timeout ? 0 : timeout - projectedElapsed
      )
    }
    if let deadline = snapshot.configuredDeadlineUTC {
      guard let remaining = nanosecondsBetween(currentUTC, deadline) else {
        return .expired(.invalidOrMissingEvidence)
      }
      remainingCandidates.append(remaining)
    }

    guard let remaining = remainingCandidates.min(), remaining > 0 else {
      return .expired(.deadlineReached)
    }
    return .notExpired(remainingNanoseconds: remaining)
  }
}

private func durationNanoseconds(_ duration: Duration) -> Int64 {
  let components = duration.components
  guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
  let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
  guard !seconds.overflow else { return Int64.max }
  return addingWithoutOverflow(seconds.partialValue, components.attoseconds / 1_000_000_000)
}

private func nanosecondsBetween(_ start: Date, _ end: Date) -> Int64? {
  let seconds = end.timeIntervalSince(start)
  guard seconds.isFinite, seconds >= 0,
    seconds <= Double(Int64.max) / 1_000_000_000
  else {
    return seconds < 0 ? 0 : nil
  }
  return Int64((seconds * 1_000_000_000).rounded(.down))
}

private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  let result = lhs.addingReportingOverflow(rhs)
  return result.overflow ? Int64.max : result.partialValue
}
