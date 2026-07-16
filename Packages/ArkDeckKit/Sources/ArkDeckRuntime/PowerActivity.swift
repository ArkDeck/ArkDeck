import Foundation

public protocol PowerActivityBackend: AnyObject, Sendable {
  func beginIdleSleepPrevention(reason: String) throws -> AnyObject
  func endIdleSleepPrevention(_ activity: AnyObject)
}

/// `PORT-POWER-001` production backend. It prevents idle system sleep only;
/// lid closure and explicit user sleep remain outside its guarantee.
public final class ProcessInfoPowerActivityBackend: PowerActivityBackend, @unchecked Sendable {
  public init() {}

  public func beginIdleSleepPrevention(reason: String) throws -> AnyObject {
    ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled],
      reason: reason
    ) as AnyObject
  }

  public func endIdleSleepPrevention(_ activity: AnyObject) {
    guard let activity = activity as? NSObjectProtocol else { return }
    ProcessInfo.processInfo.endActivity(activity)
  }
}

/// Reference-counts one underlying activity and balances it across explicit
/// release, lease deinit, operation errors/cancellation, and controller deinit.
public final class PowerActivityController: @unchecked Sendable {
  private let lock = NSLock()
  private let backend: any PowerActivityBackend
  private var activeLeaseIDs: Set<UUID> = []
  private var activity: AnyObject?

  public init(backend: any PowerActivityBackend = ProcessInfoPowerActivityBackend()) {
    self.backend = backend
  }

  deinit {
    lock.lock()
    let activityToEnd = activity
    activeLeaseIDs.removeAll()
    activity = nil
    lock.unlock()
    if let activityToEnd {
      backend.endIdleSleepPrevention(activityToEnd)
    }
  }

  public func acquire(reason: String) throws -> PowerActivityLease {
    let leaseID = UUID()
    lock.lock()
    do {
      if activeLeaseIDs.isEmpty {
        activity = try backend.beginIdleSleepPrevention(reason: reason)
      }
      activeLeaseIDs.insert(leaseID)
      lock.unlock()
    } catch {
      activity = nil
      lock.unlock()
      throw error
    }

    return PowerActivityLease { [weak self] in
      self?.releaseLease(leaseID)
    }
  }

  public func withActivity<T>(reason: String, operation: () throws -> T) throws -> T {
    let lease = try acquire(reason: reason)
    defer { lease.end() }
    return try operation()
  }

  public func withActivity<T>(
    reason: String,
    operation: () async throws -> T
  ) async throws -> T {
    let lease = try acquire(reason: reason)
    defer { lease.end() }
    return try await operation()
  }

  public var activeLeaseCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeLeaseIDs.count
  }

  private func releaseLease(_ leaseID: UUID) {
    lock.lock()
    guard activeLeaseIDs.remove(leaseID) != nil else {
      lock.unlock()
      return
    }
    if activeLeaseIDs.isEmpty, let activity {
      // Serialize the last end with the next begin. Releasing this lock first
      // would permit two underlying activities to overlap during the handoff.
      backend.endIdleSleepPrevention(activity)
      self.activity = nil
    }
    lock.unlock()
  }
}

public final class PowerActivityLease: @unchecked Sendable {
  private let lock = NSLock()
  private var release: (@Sendable () -> Void)?

  fileprivate init(release: @escaping @Sendable () -> Void) {
    self.release = release
  }

  deinit {
    end()
  }

  public func end() {
    lock.lock()
    let action = release
    release = nil
    lock.unlock()
    action?()
  }
}
