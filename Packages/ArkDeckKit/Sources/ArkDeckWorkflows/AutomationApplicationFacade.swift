// App-facing projection of the existing Harness task plane.
//
// The surface intentionally cannot submit a task, resume a human decision,
// propose a patch, collect a promotion bundle, or administer authority. It
// can observe existing typed tasks and request three lifecycle transitions
// whose meaning remains owned and validated by Harness.

import ArkDeckCore
import Foundation
import os

public enum AutomationAvailability: Sendable, Equatable {
  case available
  case unavailable(String)
}

public struct AutomationTaskPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let type: String
  public let lifecycle: String
  public let stage: String
  public let waitReason: String?
  public let targetID: String
  public let goal: String
  public let activeRound: Int
  public let activeJobID: String?
  public let cancelRequested: Bool
  public let version: Int
  public let createdAtUTC: String
  public let updatedAtUTC: String
  public let allowedOperations: [String]

  public var isTerminal: Bool {
    ["succeeded", "failed", "cancelled"].contains(lifecycle)
  }
}

public struct AutomationPresentation: Sendable, Equatable {
  public let availability: AutomationAvailability
  public let tasks: [AutomationTaskPresentation]

  public init(
    availability: AutomationAvailability,
    tasks: [AutomationTaskPresentation]
  ) {
    self.availability = availability
    self.tasks = tasks
  }

  public static let loading = AutomationPresentation(
    availability: .unavailable("Automation tasks are loading"), tasks: [])
}

public enum AutomationTaskAction: String, Sendable, Equatable {
  case reconcile
  case pause
  case cancel
}

public enum AutomationTaskActionResult: Sendable, Equatable {
  case completed(AutomationTaskPresentation)
  case failed(String)
}

public protocol AutomationApplicationProviding: Sendable {
  func refresh() async -> AutomationPresentation
  func perform(
    _ action: AutomationTaskAction,
    taskID: String
  ) async -> AutomationTaskActionResult
}

public enum AutomationApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any AutomationApplicationProviding {
    if arguments.contains("--ui-test-automation") {
      return AutomationFixtureApplicationProvider()
    }
    return AutomationProductionApplicationProvider()
  }
}

private actor AutomationProductionApplicationProvider: AutomationApplicationProviding {
  func refresh() async -> AutomationPresentation {
    AutomationResponseDecoding.list(
      await AutomationXPCTransport.request(method: "task.list"))
  }

  func perform(
    _ action: AutomationTaskAction,
    taskID: String
  ) async -> AutomationTaskActionResult {
    guard AutomationResponseDecoding.isTaskID(taskID) else {
      return .failed("The selected Harness task ID is invalid")
    }
    let response = await AutomationXPCTransport.request(
      method: "task.\(action.rawValue)",
      params: ["htaskId": .string(taskID)])
    return AutomationResponseDecoding.action(response, action: action, taskID: taskID)
  }
}

enum AutomationTransportResult: Sendable {
  case success(Data)
  case failure(String)
}

private enum AutomationXPCTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> AutomationTransportResult {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
    } catch {
      return .failure("Could not compose an Automation Runtime request")
    }
    return await withCheckedContinuation { continuation in
      let box = XPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: AutomationTransportResult) {
        let alreadyAnswered = answered.withLock { value -> Bool in
          if value { return true }
          value = true
          return false
        }
        guard !alreadyAnswered else { return }
        box.connection.invalidate()
        continuation.resume(returning: result)
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        finish(.failure("ArkDeck Runtime is not reachable: \(error.localizedDescription)"))
      } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure("ArkDeck Runtime is not reachable"))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure("Runtime refused the Automation request: \(refusal)"))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure("Runtime returned no Automation response"))
        }
      }
    }
  }
}

enum AutomationResponseDecoding {
  static func list(_ response: AutomationTransportResult) -> AutomationPresentation {
    do {
      let result = try resultValue(response)
      guard let rows = result as? [[String: Any]] else {
        return unavailable("Runtime returned no Harness task list")
      }
      let tasks = try rows.map(task)
      return AutomationPresentation(
        availability: .available,
        tasks: tasks.sorted { ($0.updatedAtUTC, $0.id) > ($1.updatedAtUTC, $1.id) })
    } catch let failure as AutomationResponseFailure {
      return unavailable(failure.message)
    } catch {
      return unavailable("Runtime returned unreadable Harness task facts")
    }
  }

  static func action(
    _ response: AutomationTransportResult,
    action: AutomationTaskAction,
    taskID: String
  ) -> AutomationTaskActionResult {
    do {
      let value = try resultValue(response)
      guard let object = value as? [String: Any] else {
        return .failed("Runtime returned no updated Harness task")
      }
      let taskObject: [String: Any]
      if action == .reconcile {
        guard let nested = object["task"] as? [String: Any] else {
          return .failed("Runtime reconcile response omitted the updated task")
        }
        taskObject = nested
      } else {
        taskObject = object
      }
      let decoded = try task(taskObject)
      guard decoded.id == taskID else {
        return .failed("Runtime returned a different Harness task")
      }
      return .completed(decoded)
    } catch let failure as AutomationResponseFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Runtime returned unreadable Harness task facts")
    }
  }

  static func isTaskID(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII
          && (CharacterSet.alphanumerics.contains(scalar)
            || "._:@-".unicodeScalars.contains(scalar))
      }
  }

  private static func task(_ row: [String: Any]) throws -> AutomationTaskPresentation {
    guard let id = row["htaskId"] as? String, isTaskID(id),
      let type = row["type"] as? String,
      let lifecycle = row["lifecycle"] as? String,
      let stage = row["stage"] as? String,
      let targetID = row["targetId"] as? String,
      let goal = row["goal"] as? String,
      let activeRound = integer(row["activeRound"]),
      let cancelRequested = row["cancelRequested"] as? Bool,
      let version = integer(row["version"]),
      let createdAtUTC = row["createdAtUtc"] as? String,
      let updatedAtUTC = row["updatedAtUtc"] as? String,
      let allowedOperations = row["allowedOperations"] as? [String]
    else {
      throw AutomationResponseFailure(
        message: "Runtime returned an incomplete Harness task")
    }
    return AutomationTaskPresentation(
      id: id,
      type: type,
      lifecycle: lifecycle,
      stage: stage,
      waitReason: optionalString(row["waitReason"]),
      targetID: targetID,
      goal: goal,
      activeRound: activeRound,
      activeJobID: optionalString(row["activeJobId"]),
      cancelRequested: cancelRequested,
      version: version,
      createdAtUTC: createdAtUTC,
      updatedAtUTC: updatedAtUTC,
      allowedOperations: allowedOperations)
  }

  private static func resultValue(_ response: AutomationTransportResult) throws -> Any {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let message): throw AutomationResponseFailure(message: message)
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw AutomationResponseFailure(message: "Runtime response was unreadable") }
    if let error = envelope["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      throw AutomationResponseFailure(
        message: "Runtime refused the Automation request: \(code) — \(message)")
    }
    guard envelope["ok"] as? Bool == true, let result = envelope["result"] else {
      throw AutomationResponseFailure(message: "Runtime returned no Automation result")
    }
    return result
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private static func optionalString(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? String
  }

  private static func unavailable(_ reason: String) -> AutomationPresentation {
    AutomationPresentation(availability: .unavailable(reason), tasks: [])
  }
}

private struct AutomationResponseFailure: Error {
  let message: String
}

private actor AutomationFixtureApplicationProvider: AutomationApplicationProviding {
  private var task = AutomationTaskPresentation(
    id: "HTASK-UI-FIXTURE",
    type: "debugCrash",
    lifecycle: "running",
    stage: "collecting",
    waitReason: nil,
    targetID: "target-fixture-dayu200",
    goal: "Collect the crash evidence and converge on a verified repair",
    activeRound: 2,
    activeJobID: "job-ui-fixture-automation",
    cancelRequested: false,
    version: 4,
    createdAtUTC: "2026-08-08T08:00:00Z",
    updatedAtUTC: "2026-08-08T08:04:00Z",
    allowedOperations: ["capture.diagnostics@1", "debug.hap@1"])

  func refresh() async -> AutomationPresentation {
    AutomationPresentation(availability: .available, tasks: [task])
  }

  func perform(
    _ action: AutomationTaskAction,
    taskID: String
  ) async -> AutomationTaskActionResult {
    guard taskID == task.id else { return .failed("Unknown fixture Harness task") }
    task = AutomationTaskPresentation(
      id: task.id,
      type: task.type,
      lifecycle: action == .cancel ? "cancelled" : action == .pause ? "waiting" : "running",
      stage: task.stage,
      waitReason: action == .pause ? "USER_SUSPENDED" : nil,
      targetID: task.targetID,
      goal: task.goal,
      activeRound: action == .reconcile ? task.activeRound + 1 : task.activeRound,
      activeJobID: action == .reconcile ? "job-ui-fixture-reconciled" : nil,
      cancelRequested: action == .cancel,
      version: task.version + 1,
      createdAtUTC: task.createdAtUTC,
      updatedAtUTC: "2026-08-08T08:05:00Z",
      allowedOperations: task.allowedOperations)
    return .completed(task)
  }
}
