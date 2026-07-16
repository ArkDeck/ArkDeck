import Foundation

public enum SystemSleepWakeNotification: Equatable, Sendable {
  case sleep
  case wake
}

public protocol SleepWakeNotificationSource: AnyObject, Sendable {
  func start(handler: @escaping @Sendable (SystemSleepWakeNotification) -> Void) throws
  func stop()
}

/// Production `PORT-SLEEP-WAKE-001` notification source.
public final class NSWorkspaceSleepWakeNotificationSource: SleepWakeNotificationSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var tokens: [NSObjectProtocol] = []
  private var notificationCenter: NotificationCenter?

  public init() {}

  deinit {
    stop()
  }

  public func start(
    handler: @escaping @Sendable (SystemSleepWakeNotification) -> Void
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard tokens.isEmpty else { return }
    guard let center = Self.workspaceNotificationCenter() else {
      throw SleepWakeNotificationSourceError.workspaceUnavailable
    }
    tokens = [
      center.addObserver(
        forName: Notification.Name("NSWorkspaceWillSleepNotification"),
        object: nil,
        queue: nil
      ) { _ in handler(.sleep) },
      center.addObserver(
        forName: Notification.Name("NSWorkspaceDidWakeNotification"),
        object: nil,
        queue: nil
      ) { _ in handler(.wake) },
    ]
    notificationCenter = center
  }

  public func stop() {
    lock.lock()
    let tokensToRemove = tokens
    let center = notificationCenter
    tokens = []
    notificationCenter = nil
    lock.unlock()
    if let center {
      for token in tokensToRemove {
        center.removeObserver(token)
      }
    }
  }

  /// Keeps AppKit types out of the Runtime module surface while still using
  /// the production NSWorkspace notification center selected by the profile.
  private static func workspaceNotificationCenter() -> NotificationCenter? {
    _ = Bundle(path: "/System/Library/Frameworks/AppKit.framework")?.load()
    guard let workspaceType = NSClassFromString("NSWorkspace") as? NSObject.Type,
      let workspace = workspaceType.perform(
        NSSelectorFromString("sharedWorkspace")
      )?.takeUnretainedValue() as? NSObject
    else {
      return nil
    }
    let notificationCenterSelector = NSSelectorFromString("notificationCenter")
    guard workspace.responds(to: notificationCenterSelector) else { return nil }
    return workspace.perform(notificationCenterSelector)?.takeUnretainedValue()
      as? NotificationCenter
  }
}

public enum SleepWakeNotificationSourceError: Error, Equatable, Sendable {
  case workspaceUnavailable
}

public enum RuntimeSleepWakeJournalEventKind: String, Codable, Equatable, Sendable {
  case sleep
  case wake
}

/// Typed fields required by the locked `journal-event-1.0.0` sleep/wake
/// payloads. Session/job/sequence envelope fields are supplied by Storage.
public struct RuntimeSleepWakeJournalEvent: Equatable, Sendable {
  public let eventID: String
  public let kind: RuntimeSleepWakeJournalEventKind
  public let sleepEventID: String?
  public let elapsedDurationNanoseconds: Int64
  public let activeDurationNanoseconds: Int64
  public let throughputSegmentReset: Bool?

  public init(
    eventID: String,
    kind: RuntimeSleepWakeJournalEventKind,
    sleepEventID: String?,
    elapsedDurationNanoseconds: Int64,
    activeDurationNanoseconds: Int64,
    throughputSegmentReset: Bool?
  ) {
    self.eventID = eventID
    self.kind = kind
    self.sleepEventID = sleepEventID
    self.elapsedDurationNanoseconds = elapsedDurationNanoseconds
    self.activeDurationNanoseconds = activeDurationNanoseconds
    self.throughputSegmentReset = throughputSegmentReset
  }
}

public protocol RuntimeLifecycleSink: AnyObject, Sendable {
  func record(_ event: RuntimeSleepWakeJournalEvent)
  func resetThroughputSegment()
  func evaluateReconnect()
  func requestReconcile()
}

/// Debounces duplicate/out-of-order notifications and emits exactly one set of
/// journal/reset/reconnect/reconcile triggers for each valid sleep/wake pair.
public final class RuntimeSleepWakeObserver: @unchecked Sendable {
  public typealias EventIDGenerator = @Sendable () -> String
  public typealias ErrorHandler = @Sendable (Error) -> Void

  private enum State {
    case stopped
    case awake
    case sleeping(sleepEventID: String)
  }

  private let executor = DispatchQueue(label: "dev.arkdeck.runtime.sleep-wake-observer")
  private let executorKey = DispatchSpecificKey<UInt8>()
  private let source: any SleepWakeNotificationSource
  private let clocks: RuntimeClockPair
  private let sink: any RuntimeLifecycleSink
  private let eventIDGenerator: EventIDGenerator
  private let errorHandler: ErrorHandler
  private var state: State = .stopped
  private var pendingNotifications: [SystemSleepWakeNotification] = []
  private var isProcessingNotifications = false

  public init(
    source: any SleepWakeNotificationSource = NSWorkspaceSleepWakeNotificationSource(),
    clocks: RuntimeClockPair = RuntimeClockPair(),
    sink: any RuntimeLifecycleSink,
    eventIDGenerator: @escaping EventIDGenerator = { UUID().uuidString },
    errorHandler: @escaping ErrorHandler = { _ in }
  ) {
    self.source = source
    self.clocks = clocks
    self.sink = sink
    self.eventIDGenerator = eventIDGenerator
    self.errorHandler = errorHandler
    executor.setSpecific(key: executorKey, value: 1)
  }

  deinit {
    stop()
  }

  public func start() throws {
    try executeSynchronously {
      guard case .stopped = state else { return }
      do {
        try source.start { [weak self] notification in
          self?.enqueue(notification)
        }
        // Source callbacks are enqueued onto this same executor, so none can
        // observe the transient registration-before-awake interval.
        state = .awake
      } catch {
        // A source that partially registered before throwing is also returned
        // to the stopped state within the same serialized lifecycle operation.
        source.stop()
        state = .stopped
        throw error
      }
    }
  }

  public func stop() {
    executeSynchronously {
      guard !isStopped else { return }
      // This is the stop linearization point. Callbacks emitted while the
      // source is being removed queue behind this operation and are ignored.
      state = .stopped
      pendingNotifications.removeAll()
      source.stop()
    }
  }

  public func handle(_ notification: SystemSleepWakeNotification) {
    executeSynchronously {
      accept(notification)
    }
  }

  private func enqueue(_ notification: SystemSleepWakeNotification) {
    executor.async { [weak self] in
      self?.accept(notification)
    }
  }

  private func accept(_ notification: SystemSleepWakeNotification) {
    guard !isStopped else { return }
    pendingNotifications.append(notification)
    guard !isProcessingNotifications else { return }
    isProcessingNotifications = true
    defer { isProcessingNotifications = false }

    while !pendingNotifications.isEmpty {
      guard !isStopped else {
        pendingNotifications.removeAll()
        return
      }
      process(pendingNotifications.removeFirst())
    }
  }

  private func process(_ notification: SystemSleepWakeNotification) {
    let sample: RuntimeDurationSample
    do {
      sample = try clocks.sample()
    } catch {
      errorHandler(error)
      return
    }

    let event: RuntimeSleepWakeJournalEvent
    switch (state, notification) {
    case (.awake, .sleep):
      let eventID = eventIDGenerator()
      guard !eventID.isEmpty else { return }
      event = RuntimeSleepWakeJournalEvent(
        eventID: eventID,
        kind: .sleep,
        sleepEventID: nil,
        elapsedDurationNanoseconds: sample.elapsedDurationNanoseconds,
        activeDurationNanoseconds: sample.activeDurationNanoseconds,
        throughputSegmentReset: nil
      )
      state = .sleeping(sleepEventID: eventID)
    case (.sleeping(let sleepEventID), .wake):
      let eventID = eventIDGenerator()
      guard !eventID.isEmpty else { return }
      event = RuntimeSleepWakeJournalEvent(
        eventID: eventID,
        kind: .wake,
        sleepEventID: sleepEventID,
        elapsedDurationNanoseconds: sample.elapsedDurationNanoseconds,
        activeDurationNanoseconds: sample.activeDurationNanoseconds,
        throughputSegmentReset: true
      )
      state = .awake
    case (.stopped, _), (.awake, .wake), (.sleeping, .sleep):
      return
    }

    sink.record(event)
    if event.kind == .wake {
      sink.resetThroughputSegment()
      sink.evaluateReconnect()
      sink.requestReconcile()
    }
  }

  private var isStopped: Bool {
    if case .stopped = state { return true }
    return false
  }

  private func executeSynchronously<T>(
    _ operation: @Sendable () throws -> T
  ) rethrows -> T {
    if DispatchQueue.getSpecific(key: executorKey) != nil {
      return try operation()
    }
    return try executor.sync(execute: operation)
  }
}
