import ArkDeckCore
import Foundation

public enum OverviewCapabilityState: String, Sendable, Equatable {
  case available
  case limited
  case unavailable
  case unknown
}

public struct OverviewCapabilityItemPresentation: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let state: OverviewCapabilityState
  public let evidence: String

  public init(id: String, name: String, state: OverviewCapabilityState, evidence: String) {
    self.id = id
    self.name = name
    self.state = state
    self.evidence = evidence
  }
}

public struct OverviewCapabilityMatrixPresentation: Sendable, Equatable {
  public let targetID: String?
  public let bindingRevision: Int?
  public let items: [OverviewCapabilityItemPresentation]
  public let failure: String?

  public init(
    targetID: String?,
    bindingRevision: Int?,
    items: [OverviewCapabilityItemPresentation],
    failure: String? = nil
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.items = items
    self.failure = failure
  }

  public static let loading = OverviewCapabilityMatrixPresentation(
    targetID: nil, bindingRevision: nil, items: [], failure: nil)
}

public protocol OverviewCapabilityApplicationProviding: Sendable {
  func refresh() async -> OverviewCapabilityMatrixPresentation
}

public enum OverviewCapabilityApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any OverviewCapabilityApplicationProviding {
    if arguments.contains("--ui-test-hdc-diagnostics") {
      return OverviewCapabilityFixtureProvider()
    }
    return OverviewCapabilityProductionProvider()
  }
}

private actor OverviewCapabilityProductionProvider: OverviewCapabilityApplicationProviding {
  func refresh() async -> OverviewCapabilityMatrixPresentation {
    async let operationResponse = DebugXPCReadTransport.request(method: "operation.list")
    async let targetResponse = DebugXPCReadTransport.request(method: "target.list")
    let operations: [[String: Any]]
    let targets: [[String: Any]]
    do {
      operations = try Self.resultArray(await operationResponse)
      targets = try Self.resultArray(await targetResponse)
    } catch {
      return OverviewCapabilityMatrixPresentation(
        targetID: nil, bindingRevision: nil, items: [],
        failure: String(describing: error))
    }

    guard let target = targets.first,
      let targetID = target["targetId"] as? String,
      let bindingRevision = target["bindingRevision"] as? Int
    else {
      return OverviewCapabilityMatrixPresentation(
        targetID: nil, bindingRevision: nil,
        items: [Self.flashCapability(from: operations)],
        failure: "No adopted target is available for device capability probing")
    }

    async let traceResponse = DebugXPCReadTransport.request(
      method: "trace.probe", params: ["targetId": .string(targetID)])
    async let hidumperResponse = DebugXPCReadTransport.request(
      method: "debug.template.run",
      params: [
        "targetId": .string(targetID),
        "templateId": .string(DebugRuntimeCommandTemplate.windowInventory.rawValue),
      ])

    var items: [OverviewCapabilityItemPresentation] = []
    switch await traceResponse {
    case .failure(let failure):
      items += Self.unknownTraceItems(reason: failure.message)
    case .success(let data):
      do {
        items += try Self.traceCapabilities(from: data, targetID: targetID, revision: bindingRevision)
      } catch {
        items += Self.unknownTraceItems(reason: String(describing: error))
      }
    }
    items.insert(
      Self.hidumperCapability(
        from: await hidumperResponse, targetID: targetID, revision: bindingRevision),
      at: 0)
    items.append(Self.flashCapability(from: operations))
    return OverviewCapabilityMatrixPresentation(
      targetID: targetID, bindingRevision: bindingRevision, items: items)
  }

  private static func resultArray(
    _ response: Result<Data, DebugXPCReadFailure>
  ) throws -> [[String: Any]] {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure): throw failure
    }
    let envelope = try resultEnvelope(data)
    guard let result = envelope["result"] as? [[String: Any]] else {
      throw DebugXPCReadFailure.transport("Runtime returned no result list")
    }
    return result
  }

  private static func resultEnvelope(_ data: Data) throws -> [String: Any] {
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw DebugXPCReadFailure.transport("Runtime returned an unreadable response") }
    if let error = envelope["error"] as? [String: Any] {
      throw DebugXPCReadFailure.transport(
        "Runtime refused the request: " + (error["message"] as? String ?? "no message"))
    }
    guard envelope["ok"] as? Bool == true else {
      throw DebugXPCReadFailure.transport("Runtime returned an unsuccessful response")
    }
    return envelope
  }

  private static func traceCapabilities(
    from data: Data,
    targetID: String,
    revision: Int
  ) throws -> [OverviewCapabilityItemPresentation] {
    let envelope = try resultEnvelope(data)
    guard let result = envelope["result"] as? [String: Any],
      result["targetId"] as? String == targetID,
      result["bindingRevision"] as? Int == revision,
      let rows = result["tools"] as? [[String: Any]],
      let tags = result["supportedTags"] as? [String]
    else { throw DebugXPCReadFailure.transport("Runtime returned mismatched Trace facts") }
    return ["hitrace", "bytrace"].map { tool in
      guard let row = rows.first(where: { $0["tool"] as? String == tool }),
        let raw = row["disposition"] as? String,
        let disposition = TraceRuntimeToolDisposition(rawValue: raw)
      else {
        return OverviewCapabilityItemPresentation(
          id: tool, name: tool, state: .unknown,
          evidence: "Required probe result was omitted")
      }
      let digest = row["rawHelpSha256"] as? String
      let family = row["family"] as? String
      let state: OverviewCapabilityState
      let evidence: String
      switch disposition {
      case .captureEligible:
        state = .available
        evidence = [
          family,
          tool == "hitrace" ? "tags × \(tags.count)" : nil,
          digest.map { "help sha256 \($0.prefix(12))…" },
        ]
          .compactMap { $0 }.joined(separator: " · ")
      case .probeOnly:
        state = .limited
        evidence = [family, "probe-only", digest.map { "help sha256 \($0.prefix(12))…" }]
          .compactMap { $0 }.joined(separator: " · ")
      case .unrecognized:
        state = .unknown
        evidence = digest.map { "Unregistered help family · sha256 \($0.prefix(12))…" }
          ?? "Help family could not be recognized"
      case .probeFailed:
        state = .unknown
        evidence = row["detail"] as? String ?? "Read-only probe failed"
      }
      return OverviewCapabilityItemPresentation(
        id: tool, name: tool, state: state, evidence: evidence)
    }
  }

  private static func unknownTraceItems(reason: String) -> [OverviewCapabilityItemPresentation] {
    ["hitrace", "bytrace"].map {
      OverviewCapabilityItemPresentation(
        id: $0, name: $0, state: .unknown, evidence: reason)
    }
  }

  private static func hidumperCapability(
    from response: Result<Data, DebugXPCReadFailure>,
    targetID: String,
    revision: Int
  ) -> OverviewCapabilityItemPresentation {
    do {
      let data: Data
      switch response {
      case .success(let value): data = value
      case .failure(let failure): throw failure
      }
      let envelope = try resultEnvelope(data)
      guard let result = envelope["result"] as? [String: Any],
        result["targetId"] as? String == targetID,
        result["bindingRevision"] as? Int == revision,
        result["templateId"] as? String == DebugRuntimeCommandTemplate.windowInventory.rawValue,
        let truncated = result["outputTruncated"] as? Bool,
        let lowering = result["loweringSha256"] as? String
      else { throw DebugXPCReadFailure.transport("Runtime returned mismatched hidumper facts") }
      let exitCode = result["exitCode"] as? Int
      guard exitCode == 0, !truncated else {
        return OverviewCapabilityItemPresentation(
          id: "hidumper", name: "hidumper", state: .unknown,
          evidence: "Probe did not complete cleanly")
      }
      return OverviewCapabilityItemPresentation(
        id: "hidumper", name: "hidumper", state: .available,
        evidence: "WindowManagerService read verified · lowering sha256 \(lowering.prefix(12))…")
    } catch {
      return OverviewCapabilityItemPresentation(
        id: "hidumper", name: "hidumper", state: .unknown,
        evidence: String(describing: error))
    }
  }

  private static func flashCapability(
    from operations: [[String: Any]]
  ) -> OverviewCapabilityItemPresentation {
    guard let row = operations.first(where: { $0["reference"] as? String == "flash.dayu200" }),
      let availability = row["availability"] as? String,
      let reasons = row["reasons"] as? [String]
    else {
      return OverviewCapabilityItemPresentation(
        id: "rockusb-flash", name: "RockUSB Flash", state: .unknown,
        evidence: "Runtime omitted flash.dayu200 availability")
    }
    return OverviewCapabilityItemPresentation(
      id: "rockusb-flash", name: "RockUSB Flash",
      state: availability == "available" ? .available : .unavailable,
      evidence: availability == "available"
        ? "flash.dayu200 provider and lowering are available"
        : (reasons.isEmpty ? "Runtime reported unavailable" : reasons.joined(separator: " · ")))
  }
}

private actor OverviewCapabilityFixtureProvider: OverviewCapabilityApplicationProviding {
  func refresh() async -> OverviewCapabilityMatrixPresentation {
    OverviewCapabilityMatrixPresentation(
      targetID: "ui-fixture-target", bindingRevision: 7,
      items: [
        OverviewCapabilityItemPresentation(
          id: "hidumper", name: "hidumper", state: .available,
          evidence: "UI fixture · WindowManagerService read verified"),
        OverviewCapabilityItemPresentation(
          id: "hitrace", name: "hitrace", state: .available,
          evidence: "UI fixture · registered family · tags × 11"),
        OverviewCapabilityItemPresentation(
          id: "bytrace", name: "bytrace", state: .unknown,
          evidence: "UI fixture · unrecognized help family"),
        OverviewCapabilityItemPresentation(
          id: "rockusb-flash", name: "RockUSB Flash", state: .available,
          evidence: "UI fixture · flash.dayu200 available"),
      ])
  }
}
