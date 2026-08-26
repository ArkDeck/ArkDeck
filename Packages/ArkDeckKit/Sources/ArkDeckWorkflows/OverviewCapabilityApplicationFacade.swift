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

/// One adopted target the capability matrix could describe.
public struct OverviewCapabilityTarget: Identifiable, Sendable, Equatable {
  public let id: String
  public let bindingRevision: Int

  public init(id: String, bindingRevision: Int) {
    self.id = id
    self.bindingRevision = bindingRevision
  }
}

public struct OverviewCapabilityMatrixPresentation: Sendable, Equatable {
  public let targetID: String?
  public let bindingRevision: Int?
  public let items: [OverviewCapabilityItemPresentation]
  public let failure: String?
  /// Every adopted target Runtime reported. The page offers these as a choice;
  /// it must never present one device's capabilities as if the reader had
  /// picked it.
  public let adoptedTargets: [OverviewCapabilityTarget]

  public init(
    targetID: String?,
    bindingRevision: Int?,
    items: [OverviewCapabilityItemPresentation],
    failure: String? = nil,
    adoptedTargets: [OverviewCapabilityTarget] = []
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.items = items
    self.failure = failure
    self.adoptedTargets = adoptedTargets
  }

  public static let loading = OverviewCapabilityMatrixPresentation(
    targetID: nil, bindingRevision: nil, items: [], failure: nil)
}

/// Restricts Overview's device scope to the App's shared, current device
/// observation. `target.list` is durable history; it can contain an adopted
/// target long after that device has gone offline. Such a target remains
/// addressable in History, but it is not a device the live Overview can offer.
public enum OverviewOnlineTargetProjection {
  public static func targets(
    from devices: DeviceListPresentation
  ) -> [OverviewCapabilityTarget] {
    var seen: Set<String> = []
    return devices.candidates.compactMap { candidate in
      guard candidate.isAuthorized,
        let targetID = candidate.adoptedTargetID,
        let bindingRevision = candidate.bindingRevision,
        seen.insert(targetID).inserted
      else { return nil }
      return OverviewCapabilityTarget(id: targetID, bindingRevision: bindingRevision)
    }
  }

  /// The preferred target is the reader's explicit choice. When it is no
  /// longer online, one remaining online target may become the scope; with
  /// zero or several remaining targets the page truthfully has no selection.
  public static func presentation(
    from capabilities: OverviewCapabilityMatrixPresentation,
    devices: DeviceListPresentation,
    preferredTargetID: String?
  ) -> OverviewCapabilityMatrixPresentation {
    let onlineTargets = targets(from: devices)
    let selected: OverviewCapabilityTarget?
    if let preferredTargetID,
      let preferred = onlineTargets.first(where: { $0.id == preferredTargetID })
    {
      selected = preferred
    } else if onlineTargets.count == 1 {
      selected = onlineTargets[0]
    } else {
      selected = nil
    }

    // Target-probed rows cannot be carried from a device that is now offline
    // to another target. The canonical Flash row is Catalog-owned and remains
    // truthful without a selected device.
    let describesSelectedTarget = capabilities.targetID == selected?.id
    let items = describesSelectedTarget
      ? capabilities.items
      : capabilities.items.filter { $0.id == "rockusb-flash" }
    return OverviewCapabilityMatrixPresentation(
      targetID: selected?.id,
      bindingRevision: selected?.bindingRevision,
      items: items,
      failure: capabilities.failure,
      adoptedTargets: onlineTargets)
  }
}

public protocol OverviewCapabilityApplicationProviding: Sendable {
  /// Probes one named target's capabilities.
  ///
  /// `targetID` is the target the reader chose. Passing nil asks the provider
  /// to resolve one only when there is nothing to choose between — exactly one
  /// adopted target. With several, it refuses and reports them, because a
  /// matrix that silently described whichever target came back first is a
  /// matrix about a device nobody selected and the page cannot name.
  func refresh(targetID: String?) async -> OverviewCapabilityMatrixPresentation
}

public enum OverviewCapabilityApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any OverviewCapabilityApplicationProviding {
    if arguments.contains("--ui-test-hdc-diagnostics") {
      return OverviewCapabilityFixtureProvider(arguments: arguments)
    }
    return OverviewCapabilityProductionProvider()
  }
}

private actor OverviewCapabilityProductionProvider: OverviewCapabilityApplicationProviding {
  func refresh(targetID requested: String?) async -> OverviewCapabilityMatrixPresentation {
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


    let adopted: [OverviewCapabilityTarget] = targets.compactMap { entry in
      guard let id = entry["targetId"] as? String,
        let revision = entry["bindingRevision"] as? Int
      else { return nil }
      return OverviewCapabilityTarget(id: id, bindingRevision: revision)
    }

    func unresolved(_ reason: String) -> OverviewCapabilityMatrixPresentation {
      // The Flash row is a Catalog fact about the published operation, not a
      // device probe, so it survives having no target to describe.
      OverviewCapabilityMatrixPresentation(
        targetID: nil, bindingRevision: nil,
        items: [Self.flashCapability(from: operations)],
        failure: reason,
        adoptedTargets: adopted)
    }

    let resolved: OverviewCapabilityTarget
    if let requested {
      guard let match = adopted.first(where: { $0.id == requested }) else {
        return unresolved(
          "The selected target is no longer adopted: \(requested)")
      }
      resolved = match
    } else if adopted.count == 1, let only = adopted.first {
      resolved = only
    } else if adopted.isEmpty {
      return unresolved("No adopted target is available for device capability probing")
    } else {
      // Refusing here is the point. Probing the first entry would answer a
      // question nobody asked, about a device the page could not truthfully
      // name as the reader's choice.
      return unresolved(
        "\(adopted.count) adopted targets are available; choose which one to describe")
    }
    let targetID = resolved.id
    let bindingRevision = resolved.bindingRevision

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
      targetID: targetID, bindingRevision: bindingRevision, items: items,
      adoptedTargets: adopted)
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
    guard let row = operations.first(where: {
      $0["reference"] as? String == ArkForgeFlashOperation.canonicalReference
    }),
      let availability = row["availability"] as? String,
      let reasons = row["reasons"] as? [String]
    else {
      return OverviewCapabilityItemPresentation(
        id: "rockusb-flash", name: "RockUSB Flash", state: .unknown,
        evidence: "Runtime omitted canonical ArkForge Flash availability")
    }
    return OverviewCapabilityItemPresentation(
      id: "rockusb-flash", name: "RockUSB Flash",
      state: availability == "available" ? .available : .unavailable,
      evidence: availability == "available"
        ? "canonical ArkForge Flash provider and lowering are available"
        : (reasons.isEmpty ? "Runtime reported unavailable" : reasons.joined(separator: " · ")))
  }
}

private actor OverviewCapabilityFixtureProvider: OverviewCapabilityApplicationProviding {
  private let includesOfflineTarget: Bool

  init(arguments: [String]) {
    includesOfflineTarget = arguments.contains("--ui-test-overview-offline-target")
  }

  func refresh(targetID requested: String?) async -> OverviewCapabilityMatrixPresentation {
    let onlineTarget = OverviewCapabilityTarget(
      id: "target-fixture-dayu200", bindingRevision: 3)
    let adopted = [onlineTarget]
      + (includesOfflineTarget
        ? [OverviewCapabilityTarget(id: "target-fixture-offline", bindingRevision: 2)] : [])
    guard requested == nil || requested == onlineTarget.id else {
      return OverviewCapabilityMatrixPresentation(
        targetID: nil, bindingRevision: nil, items: [],
        failure: "The selected target is no longer adopted: \(requested ?? "")",
        adoptedTargets: adopted)
    }
    return OverviewCapabilityMatrixPresentation(
      targetID: onlineTarget.id, bindingRevision: onlineTarget.bindingRevision,
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
          evidence: "UI fixture · canonical ArkForge Flash available"),
      ],
      adoptedTargets: adopted)
  }
}
