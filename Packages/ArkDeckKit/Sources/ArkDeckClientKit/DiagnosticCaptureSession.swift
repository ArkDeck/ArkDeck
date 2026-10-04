import Foundation
import Observation

/// App state never proves recording. Only a validated Runtime snapshot can
/// enable Mark; the Runtime deadline survives navigation or transport loss.
@MainActor @Observable
public final class DiagnosticCaptureSession {
  public enum Phase: String, Sendable { case idle, checking, submitting, active, finished, unavailable, uncertain }
  public private(set) var phase: Phase = .idle
  public private(set) var target: DeviceTargetPresentation?
  public private(set) var jobID: String?
  public private(set) var snapshot: DiagnosticCaptureSnapshot?
  public private(set) var failure: String?
  public private(set) var isControlling = false
  public private(set) var completedContext: RuntimeHistoryWorkspaceContext?
  @ObservationIgnored private let provider: any DiagnosticCaptureProviding
  @ObservationIgnored private let pause: @Sendable () async throws -> Void
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var monitoringTicket: UUID?
  private var loadingHistory = false

  public convenience init(provider: any DiagnosticCaptureProviding) {
    self.init(provider: provider, pause: { try await Task.sleep(for: .seconds(1)) })
  }

  package init(provider: any DiagnosticCaptureProviding, pause: @escaping @Sendable () async throws -> Void) {
    self.provider = provider
    self.pause = pause
  }

  public var canStart: Bool { [.idle, .finished, .unavailable].contains(phase) && !isControlling && !loadingHistory }
  public var canMark: Bool {
    phase == .active && !isControlling && snapshot?.state == "recording"
      && snapshot?.controlAvailable == true && snapshot?.stopRequested == false
      && (snapshot?.markers.count ?? 0) < (snapshot?.maximumMarkers ?? 0)
  }
  public var canStop: Bool {
    phase == .active && !isControlling && snapshot?.controlAvailable == true
      && snapshot?.stopRequested == false && ["preparing", "recording"].contains(snapshot?.state ?? "")
  }
  public var canCancelPreparation: Bool {
    phase == .active && !isControlling && snapshot?.state == "preparing"
      && snapshot?.controlAvailable == false
  }

  /// A changed selection invalidates an unsubmitted preflight. Once a Job
  /// was submitted, its controls keep the exact original target and revision.
  public func selectionChanged(to selection: DeviceTargetPresentation?) {
    guard phase == .checking, selection?.id != target?.id || selection?.bindingRevision != target?.bindingRevision else { return }
    generation = UUID()
    phase = .idle
    target = nil
  }

  public func start(target: DeviceTargetPresentation, durationSeconds: Int) async {
    guard canStart else { return }
    let ticket = UUID()
    generation = ticket
    phase = .checking
    self.target = target
    jobID = nil
    snapshot = nil
    failure = nil
    completedContext = nil
    do {
      try await provider.preflight(target: target)
      guard generation == ticket else { return }
      phase = .submitting
      let accepted = try await provider.submit(target: target, durationSeconds: durationSeconds)
      jobID = accepted
      phase = .active
      Task { [weak self, provider] in
        do { try await provider.run(jobID: accepted) }
        catch { self?.recordRunFailure(error, ticket: ticket) }
        await self?.refresh()
      }
      await monitor(ticket: ticket)
    } catch {
      guard generation == ticket else { return }
      failure = Self.message(error)
      // A transport loss after submit may already have created a Job. No
      // automatic retry or second submission follows an uncertain reply.
      if phase == .submitting, (error as? DiagnosticCaptureFailure)?.uncertain != false {
        phase = .uncertain
      } else { phase = .unavailable }
    }
  }

  public func mark() async {
    guard canMark, let jobID, let target else { return }
    await control {
      try await self.provider.mark(jobID: jobID, markerID: UUID().uuidString.lowercased(), target: target)
    }
  }

  public func stop() async {
    guard canStop, let jobID, let target else { return }
    await control { try await self.provider.stop(jobID: jobID, target: target) }
  }

  public func cancelPreparation() async {
    guard canCancelPreparation, let jobID else { return }
    isControlling = true
    revision += 1
    do { try await provider.cancelPreparation(jobID: jobID) }
    catch { failure = Self.message(error); phase = .uncertain }
    isControlling = false
    await refresh()
  }

  public func refresh() async {
    guard let jobID, let target, !isControlling else { return }
    let ticket = generation
    let readRevision = revision
    do {
      let fresh = try await provider.status(jobID: jobID, target: target)
      guard generation == ticket, revision == readRevision, !isControlling else { return }
      await publish(fresh)
    } catch {
      guard generation == ticket, revision == readRevision else { return }
      phase = .uncertain
      failure = Self.message(error)
    }
  }

  private func control(_ action: () async throws -> DiagnosticCaptureSnapshot) async {
    isControlling = true
    revision += 1
    do { await publish(try await action()) }
    catch {
      failure = Self.message(error)
      phase = .uncertain
    }
    isControlling = false
    // Read back the outcome; never resend a marker or stop on a lost reply.
    if phase == .uncertain { await refresh() }
  }

  private func publish(_ fresh: DiagnosticCaptureSnapshot) async {
    guard let jobID, let target else { return }
    do { try fresh.validate(jobID: jobID, target: target) }
    catch { failure = Self.message(error); phase = .uncertain; return }
    snapshot = fresh
    failure = nil
    if fresh.outcomeUnknown || fresh.state == "interrupted" {
      phase = .uncertain
    } else if fresh.isTerminal {
      phase = .finished
    } else { phase = .active }
    if fresh.isTerminal && completedContext == nil && !loadingHistory {
      loadingHistory = true
      let ticket = generation
      do {
        let context = try await provider.history(jobID: jobID, target: target)
        guard context.jobID == jobID, context.targetID == target.id,
          context.operationReference == DiagnosticCaptureFacade.operationReference else {
          throw DiagnosticCaptureFailure("Session result does not match the accepted Job")
        }
        if generation == ticket { completedContext = context }
      } catch { if generation == ticket { failure = Self.message(error) } }
      loadingHistory = false
    }
  }

  private func monitor(ticket: UUID) async {
    guard monitoringTicket != ticket else { return }
    monitoringTicket = ticket
    defer { if monitoringTicket == ticket { monitoringTicket = nil } }
    // Bounded App reads, separate from the Runtime's monotonic recording
    // deadline. A queued Job may outlast these reads; Refresh stays explicit.
    for _ in 0..<600 {
      guard generation == ticket else { return }
      await refresh()
      if snapshot?.isTerminal == true { return }
      do { try await pause() } catch { return }
    }
    if generation == ticket {
      phase = .uncertain
      failure = "Automatic status reads ended. Refresh this Job or open History; the Runtime owns its deadline."
    }
  }

  private func recordRunFailure(_ error: Error, ticket: UUID) {
    guard generation == ticket, snapshot?.isTerminal != true else { return }
    failure = Self.message(error)
    phase = .uncertain
  }

  private static func message(_ error: Error) -> String {
    (error as? DiagnosticCaptureFailure)?.message ?? String(describing: error)
  }
}
