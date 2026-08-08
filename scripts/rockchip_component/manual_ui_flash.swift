#!/usr/bin/env swift

// Manual, real-device GJ-4 driver. This file is intentionally outside every
// XCTest/UI-test target because a flash attempt can take several minutes.
//
// The driver exercises ArkDeck's real Accessibility surface, verifies the
// exact plan and userdata impact shown by the UI, and presses the App's
// one-click typed Runtime submit control. Runtime creates/consumes the
// capability; this driver has no authority or capability administration
// surface.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

enum DriverFailure: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let message): message
    }
  }
}

@objc private protocol ManualFlashXPCProtocol {
  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// Manual-only adapter for a daemon that is already running from a shell and
/// therefore cannot itself check in to launchd's Mach service. It forwards
/// the same closed App allowlist to that daemon's private Unix socket.
/// This keeps the UI attached to the real Runtime state without stopping an
/// existing job or copying a target record into a fixture store.
private final class ManualFlashXPCBridge: NSObject, NSXPCListenerDelegate,
  ManualFlashXPCProtocol, @unchecked Sendable
{
  private enum Admission {
    case direct
    case flashSubmit(requestID: String)
    case flashRun(jobID: String)
  }

  private static let directMethods: Set<String> = [
    "artifact.importFlashBundle.abort", "artifact.importFlashBundle.append",
    "artifact.importFlashBundle.begin", "artifact.importFlashBundle.commit",
    "artifact.inspect", "artifact.list", "job.evidence", "job.list",
    "job.list-page", "job.status", "operation.list", "target.list",
  ]

  private let socketPath: String
  private let listener = NSXPCListener(machServiceName: "com.arkdeck.agentd")
  private let jobLock = NSLock()
  private var runnableJobIDs: Set<String> = []

  init(socketPath: String) {
    self.socketPath = socketPath
    super.init()
    listener.delegate = self
  }

  func run() -> Never {
    listener.resume()
    dispatchMain()
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ManualFlashXPCProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    guard let admission = Self.admission(of: frame) else {
      reply(nil, "malformedFrame")
      return
    }
    if case .flashRun(let jobID) = admission, !consume(jobID: jobID) {
      reply(nil, "methodNotAllowlisted")
      return
    }
    let socketPath = self.socketPath
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try forward(frame: frame, socketPath: socketPath)
        if case .flashSubmit(let requestID) = admission,
          let jobID = Self.successfulSubmittedJobID(in: response, requestID: requestID)
        {
          self.record(jobID: jobID)
        }
        reply(response, nil)
      } catch {
        reply(nil, "appBridgeFailure: \(error)")
      }
    }
  }

  private static func admission(of frame: Data) -> Admission? {
    guard
      let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      request["protocolVersion"] as? String == "1.0.0",
      let requestID = request["id"] as? String,
      let method = request["method"] as? String
    else { return nil }
    if directMethods.contains(method) { return .direct }

    guard let params = request["params"] as? [String: Any], params.count == 1 else {
      return nil
    }
    switch method {
    case "job.submit":
      guard
        let requestJSON = params["requestJson"] as? String,
        let data = requestJSON.data(using: .utf8),
        let typed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        typed["documentType"] as? String == "runtime-operation-request",
        typed["schemaVersion"] as? String == "2.0.0",
        typed["authorization"] == nil,
        typed["campaignReservation"] == nil,
        let operation = typed["operation"] as? [String: Any],
        operation["id"] as? String == "flash.dayu200",
        operation["version"] as? Int == 1,
        let context = typed["clientContext"] as? [String: Any],
        context["clientName"] as? String == "ArkDeckApp.FlashWorkspace"
      else { return nil }
      return .flashSubmit(requestID: requestID)
    case "job.run":
      guard let jobID = params["jobId"] as? String,
        !jobID.isEmpty, jobID.count <= 128
      else { return nil }
      return .flashRun(jobID: jobID)
    default:
      return nil
    }
  }

  private static func successfulSubmittedJobID(in response: Data, requestID: String) -> String? {
    guard
      let wire = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
      wire["id"] as? String == requestID,
      wire["ok"] as? Bool == true,
      let result = wire["result"] as? [String: Any],
      let jobID = result["jobId"] as? String,
      !jobID.isEmpty, jobID.count <= 128
    else { return nil }
    return jobID
  }

  private func record(jobID: String) {
    jobLock.lock()
    runnableJobIDs.insert(jobID)
    jobLock.unlock()
  }

  private func consume(jobID: String) -> Bool {
    jobLock.lock()
    let removed = runnableJobIDs.remove(jobID) != nil
    jobLock.unlock()
    return removed
  }
}

private func forward(frame: Data, socketPath: String) throws -> Data {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw DriverFailure.message("could not create Unix socket") }
  defer { close(descriptor) }

  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw DriverFailure.message("Runtime socket path is too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    socketPath.utf8CString.withUnsafeBytes { source in
      destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count)))
    }
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else {
    throw DriverFailure.message("could not connect to Runtime socket: errno \(errno)")
  }

  var request = frame
  request.append(0x0A)
  try request.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard count > 0 else {
        throw DriverFailure.message("could not write Runtime request: errno \(errno)")
      }
      offset += count
    }
  }

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while response.count <= 8 * 1024 * 1024 {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count >= 0 else {
      throw DriverFailure.message("could not read Runtime response: errno \(errno)")
    }
    if count == 0 { break }
    response.append(contentsOf: buffer.prefix(count))
    if response.last == 0x0A { break }
  }
  guard !response.isEmpty, response.count <= 8 * 1024 * 1024 else {
    throw DriverFailure.message("Runtime response is empty or oversized")
  }
  if response.last == 0x0A { response.removeLast() }
  return response
}

struct Options {
  let appURL: URL
  let archiveURL: URL
  let expectedPlanDigest: String
  let expectedArchiveDigest: String
  let expectedStepSetDigest: String
  let expectedTargetID: String
  let expectedBindingRevision: Int
  let timeoutSeconds: TimeInterval
  let stopBeforeSubmit: Bool

  static func parse(_ arguments: [String]) throws -> Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--stop-before-submit" {
        flags.insert(argument)
        index += 1
        continue
      }
      guard argument.hasPrefix("--"), index + 1 < arguments.count else {
        throw DriverFailure.message("invalid or missing value for argument: \(argument)")
      }
      values[argument] = arguments[index + 1]
      index += 2
    }

    func required(_ name: String) throws -> String {
      guard let value = values[name], !value.isEmpty else {
        throw DriverFailure.message("missing required argument \(name)")
      }
      return value
    }
    func digest(_ name: String) throws -> String {
      let value = try required(name).lowercased()
      guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw DriverFailure.message("\(name) must be a lowercase SHA-256 digest")
      }
      return value
    }
    func existingFile(_ name: String) throws -> URL {
      let url = URL(fileURLWithPath: try required(name)).standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw DriverFailure.message("\(name) is not a readable file: \(url.path)")
      }
      return url
    }

    let appURL = URL(fileURLWithPath: try required("--app")).standardizedFileURL
    guard appURL.pathExtension == "app",
      FileManager.default.fileExists(atPath: appURL.path)
    else {
      throw DriverFailure.message("--app must name an existing .app bundle")
    }
    let revisionText = try required("--expected-binding-revision")
    guard let revision = Int(revisionText), revision > 0 else {
      throw DriverFailure.message("--expected-binding-revision must be a positive integer")
    }

    let timeoutSeconds = values["--timeout-seconds"].flatMap(TimeInterval.init) ?? 7_200
    guard timeoutSeconds >= 60, timeoutSeconds <= 14_400 else {
      throw DriverFailure.message("--timeout-seconds must be between 60 and 14400")
    }

    return Options(
      appURL: appURL,
      archiveURL: try existingFile("--archive"),
      expectedPlanDigest: try digest("--expected-plan-digest-sha256"),
      expectedArchiveDigest: try digest("--expected-archive-digest-sha256"),
      expectedStepSetDigest: try digest("--expected-step-set-digest-sha256"),
      expectedTargetID: try required("--expected-target"),
      expectedBindingRevision: revision,
      timeoutSeconds: timeoutSeconds,
      stopBeforeSubmit: flags.contains("--stop-before-submit"))
  }
}

final class AccessibilityDriver {
  private let application: AXUIElement

  init(processIdentifier: pid_t) throws {
    guard AXIsProcessTrusted() else {
      throw DriverFailure.message(
        "Accessibility access is required for the executable running this script")
    }
    application = AXUIElementCreateApplication(processIdentifier)
  }

  func press(_ identifier: String, timeout: TimeInterval = 20) throws {
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
      throw DriverFailure.message("could not press \(identifier): AX error \(result.rawValue)")
    }
  }

  /// Clicks the visual centre of an accessibility element.
  ///
  /// SwiftUI controls can report a successful AXPress without delivering the
  /// operator gesture. A real pointer click matches the interaction exercised
  /// by this manual, real-device driver.
  func click(
    _ identifier: String, fallbackStrings: [String] = [], timeout: TimeInterval = 20
  ) throws {
    let element = try waitForElement(
      identifier: identifier, fallbackStrings: fallbackStrings, timeout: timeout)
    try click(element, identifier: identifier)
  }

  /// Scrolls the element's containing area to the bottom before clicking it.
  func revealAndClick(_ identifier: String, timeout: TimeInterval = 20) throws {
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    scrollToBottom(containing: element)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try click(element, identifier: identifier)
  }

  /// Delivers the submit gesture exactly once. SwiftUI on macOS can expose a
  /// Button whose AX frame does not hit its visual action. In that case the
  /// same, now-visible AXButton receives AXPress, but only after proving the
  /// pointer path did not synchronously disable the control.
  func submit(_ identifier: String, timeout: TimeInterval = 20) throws {
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    scrollToBottom(containing: element)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try click(element, identifier: identifier)
    if observesSubmitStarted(identifier: identifier, timeout: 2) { return }

    let current = try waitForElement(identifier: identifier, timeout: 2)
    let pressed = AXUIElementPerformAction(current, kAXPressAction as CFString)
    guard pressed == .success,
      observesSubmitStarted(identifier: identifier, timeout: 10)
    else {
      let role = stringAttribute(current, kAXRoleAttribute as CFString) ?? "unknown"
      var rawActions: CFArray?
      AXUIElementCopyActionNames(current, &rawActions)
      let actions = (rawActions as? [String]) ?? []
      throw DriverFailure.message(
        "UI submit action was not delivered; role=\(role) frame=\(String(describing: frame(of: current))) "
          + "actions=\(actions) AXPress=\(pressed.rawValue)")
    }
  }

  private func observesSubmitStarted(identifier: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "flash.execute.failure") != nil
        || element(identifier: "flash.execute.terminal") != nil
      {
        return true
      }
      guard let element = element(identifier: identifier) else { return true }
      if attribute(element, kAXEnabledAttribute as CFString) as? Bool == false { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
  }

  private func click(_ element: AXUIElement, identifier: String) throws {
    if let frame = frame(of: element), frame.width > 0, frame.height > 0 {
      let point = CGPoint(x: frame.midX, y: frame.midY)
      guard
        let down = CGEvent(
          mouseEventSource: nil, mouseType: .leftMouseDown,
          mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(
          mouseEventSource: nil, mouseType: .leftMouseUp,
          mouseCursorPosition: point, mouseButton: .left)
      else {
        throw DriverFailure.message("could not create pointer events for \(identifier)")
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      return
    }

    // macOS 26 can flatten a SwiftUI NavigationSplitView label into an AXRow
    // whose visual frame is omitted even though it remains actionable. Keep
    // the native action/settable-selection fallback bounded to the exact
    // element found by identifier or localized visible text.
    let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if pressed == .success { return }
    let selected = AXUIElementSetAttributeValue(
      element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    if selected == .success { return }

    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
    throw DriverFailure.message(
      "UI element has no clickable frame or native selection action: \(identifier) "
        + "role=\(role) AXPress=\(pressed.rawValue) AXSelected=\(selected.rawValue)")
  }

  func setValue(_ value: String, identifier: String, timeout: TimeInterval = 20) throws {
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    let result = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, value as CFTypeRef)
    guard result == .success else {
      throw DriverFailure.message("could not set \(identifier): AX error \(result.rawValue)")
    }
  }

  func selectPickerValue(_ value: String, identifier: String) throws {
    let element = try waitForElement(identifier: identifier, timeout: 20)
    let direct = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, value as CFTypeRef)
    if direct == .success { return }
    let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard pressed == .success else {
      throw DriverFailure.message("could not open picker \(identifier)")
    }
    type(value)
    key(virtualCode: CGKeyCode(kVK_Return))
  }

  func waitForFacts(_ facts: [String], timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    var missing = facts
    repeat {
      let visible = allStrings()
      missing = facts.filter { fact in !visible.contains(where: { $0.contains(fact) }) }
      if missing.isEmpty { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message(
      "UI did not expose expected facts before timeout: \(missing.joined(separator: ", "))")
  }

  func waitForPresence(_ identifier: String, timeout: TimeInterval) throws {
    _ = try waitForElement(identifier: identifier, timeout: timeout)
  }

  func waitForAbsence(_ identifier: String, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: identifier) == nil { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI element remained present: \(identifier)")
  }

  func waitForEnabled(_ identifier: String, timeout: TimeInterval) throws {
    try waitForEnabledState(true, identifier: identifier, timeout: timeout)
  }

  func waitForDisabled(_ identifier: String, timeout: TimeInterval) throws {
    try waitForEnabledState(false, identifier: identifier, timeout: timeout)
  }

  private func waitForEnabledState(
    _ expected: Bool, identifier: String, timeout: TimeInterval
  ) throws {
    if observesEnabledState(expected, identifier: identifier, timeout: timeout) { return }
    throw DriverFailure.message(
      "UI element \(identifier) did not become \(expected ? "enabled" : "disabled")")
  }

  private func observesEnabledState(
    _ expected: Bool, identifier: String, timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier),
        attribute(element, kAXEnabledAttribute as CFString) as? Bool == expected
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    return false
  }

  func openGoToFolder(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "PathTextField") != nil { return }
      key(virtualCode: CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } while Date() < deadline
    throw DriverFailure.message("file picker did not open the Go to Folder path field")
  }

  func commitGoToFolder(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "PathTextField") == nil { return }
      key(virtualCode: CGKeyCode(kVK_Return))
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } while Date() < deadline
    throw DriverFailure.message("file picker did not accept the Go to Folder path")
  }

  /// Waits only on the post-submit presentation owned by the current review.
  /// Historical Runtime cards deliberately do not participate in this check.
  func waitForFlashSubmission(timeout: TimeInterval) throws -> (jobID: String, state: String) {
    let deadline = Date().addingTimeInterval(timeout)
    let terminalStates = ["succeeded", "failed", "waitingForRecovery", "cancelled"]
    repeat {
      if let failure = element(identifier: "flash.execute.failure") {
        let detail = strings(near: failure)
          .filter { !$0.isEmpty && $0 != "flash.execute.failure" }
          .joined(separator: " | ")
        throw DriverFailure.message(
          "Runtime Flash submission failed before returning a Job: \(detail)")
      }
      if let job = element(identifier: "flash.execute.jobId"),
        let terminal = element(identifier: "flash.execute.terminal")
      {
        let jobID = strings(near: job).first { $0.hasPrefix("job-") }
        let terminalStrings = strings(near: terminal)
        let state = terminalStates.first { state in
          terminalStrings.contains(where: { $0 == state || $0.contains(state) })
        }
        if let jobID, let state { return (jobID, state) }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw DriverFailure.message(
      "current UI submission did not return a terminal Runtime Flash result before timeout")
  }

  func assertNoFlashSubmission() throws {
    let forbidden = [
      "flash.execute.failure", "flash.execute.jobId", "flash.execute.terminal",
    ]
    if let exposed = forbidden.first(where: { element(identifier: $0) != nil }) {
      throw DriverFailure.message(
        "Flash UI exposed \(exposed) before the one-click submit action")
    }
  }

  func chooseFile(_ url: URL) throws {
    try press("flash.image.choose")
    try waitForPresence("open-panel", timeout: 20)
    try openGoToFolder(timeout: 10)
    try setValue(url.path, identifier: "PathTextField")
    try commitGoToFolder(timeout: 10)
    try waitForEnabled("OKButton", timeout: 20)
    try press("OKButton")
    try waitForAbsence("open-panel", timeout: 20)
    try waitForFacts([url.lastPathComponent], timeout: 60)
  }

  private func waitForElement(
    identifier: String, fallbackStrings: [String] = [], timeout: TimeInterval
  ) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier) { return element }
      if let element = element(displayingAny: fallbackStrings) { return element }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI element not found: \(identifier)")
  }

  private func element(identifier: String) -> AXUIElement? {
    descendants(of: application).first {
      stringAttribute($0, kAXIdentifierAttribute as CFString) == identifier
    }
  }

  private func element(displayingAny strings: [String]) -> AXUIElement? {
    guard !strings.isEmpty else { return nil }
    let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
      .map { $0 as CFString }
    return descendants(of: application).first { element in
      attributes.contains { attribute in
        guard let value = stringAttribute(element, attribute) else { return false }
        return strings.contains(value)
      }
    }
  }

  private func descendants(of root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = [root]
    var visited: Set<CFHashCode> = [CFHash(root)]
    var cursor = 0
    while cursor < result.count, result.count < 10_000 {
      if let children = attribute(result[cursor], kAXChildrenAttribute as CFString)
        as? [AXUIElement]
      {
        for child in children where visited.insert(CFHash(child)).inserted {
          result.append(child)
        }
      }
      cursor += 1
    }
    return result
  }

  private func allStrings() -> [String] {
    let attributes = [
      kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
      kAXValueAttribute, kAXHelpAttribute,
    ].map { $0 as CFString }
    return descendants(of: application).flatMap { element in
      attributes.compactMap { stringAttribute(element, $0) }
    }
  }

  private func strings(near element: AXUIElement) -> [String] {
    let attributes = [
      kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
      kAXValueAttribute, kAXHelpAttribute,
    ].map { $0 as CFString }
    return descendants(of: element).flatMap { descendant in
      attributes.compactMap { stringAttribute(descendant, $0) }
    }
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    guard
      let positionValue = attribute(element, kAXPositionAttribute as CFString),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      let sizeValue = attribute(element, kAXSizeAttribute as CFString),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
  }

  private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    let value = attribute(element, name)
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private func key(virtualCode: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
  }

  private func scrollDown() {
    CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
      wheel1: -6, wheel2: 0, wheel3: 0
    )?.post(tap: .cghidEventTap)
  }

  private func scrollToBottom(containing element: AXUIElement) {
    var current: AXUIElement? = element
    for _ in 0..<30 {
      guard let scope = current else { break }
      if stringAttribute(scope, kAXRoleAttribute as CFString) == (kAXScrollAreaRole as String),
        let rawScrollBar = attribute(scope, kAXVerticalScrollBarAttribute as CFString),
        CFGetTypeID(rawScrollBar) == AXUIElementGetTypeID()
      {
        let scrollBar = rawScrollBar as! AXUIElement
        if AXUIElementSetAttributeValue(
          scrollBar, kAXValueAttribute as CFString, NSNumber(value: 1)) == .success
        {
          return
        }
      }
      if let parent = attribute(scope, kAXParentAttribute as CFString),
        CFGetTypeID(parent) == AXUIElementGetTypeID()
      {
        current = (parent as! AXUIElement)
      } else {
        current = nil
      }
    }
    scrollDown()
  }

  private func type(_ text: String) {
    let units = Array(text.utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    units.withUnsafeBufferPointer { buffer in
      event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    }
    event?.post(tap: .cghidEventTap)
  }
}

private func isSameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
  let lhs = lhs.standardizedFileURL.resolvingSymlinksInPath()
  let rhs = rhs.standardizedFileURL.resolvingSymlinksInPath()
  if lhs == rhs { return true }

  let key = URLResourceKey.fileResourceIdentifierKey
  let lhsIdentifier = try? lhs.resourceValues(forKeys: [key]).fileResourceIdentifier
  let rhsIdentifier = try? rhs.resourceValues(forKeys: [key]).fileResourceIdentifier
  guard let lhsIdentifier, let rhsIdentifier else { return false }
  return lhsIdentifier.isEqual(rhsIdentifier)
}

func launch(_ appURL: URL) throws -> pid_t {
  if let running = NSWorkspace.shared.runningApplications.first(where: {
    guard let bundleURL = $0.bundleURL else { return false }
    return isSameApplication(bundleURL, appURL)
  }) {
    running.activate(options: [.activateAllWindows])
    return running.processIdentifier
  }

  let semaphore = DispatchSemaphore(value: 0)
  var launched: NSRunningApplication?
  var launchError: Error?
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = true
  NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    launched = app
    launchError = error
    semaphore.signal()
  }
  semaphore.wait()
  if let launchError { throw launchError }
  guard let launched else { throw DriverFailure.message("ArkDeck did not launch") }
  guard let launchedURL = launched.bundleURL,
    isSameApplication(launchedURL, appURL)
  else {
    throw DriverFailure.message(
      "Launch Services opened a different ArkDeck instance; close duplicate bundle IDs and retry")
  }
  return launched.processIdentifier
}

func run() throws {
  let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
  let pid = try launch(options.appURL)
  let driver = try AccessibilityDriver(processIdentifier: pid)

  // macOS 26 can flatten SwiftUI List labels into an AXRow and omit the
  // identifier. The bounded visible-text fallback covers ArkDeck's supported
  // English and Simplified Chinese localizations without hard-coded coordinates.
  try driver.click("app.navigation.flash", fallbackStrings: ["Flash", "刷机"])
  try driver.waitForPresence("flash.mode", timeout: 20)
  try driver.click("flash.mode.execute")
  try driver.chooseFile(options.archiveURL)
  try driver.selectPickerValue(options.expectedTargetID, identifier: "flash.target")
  try driver.waitForEnabled("flash.plan.prepare", timeout: 30)
  try driver.press("flash.plan.prepare", timeout: 30)
  try driver.waitForFacts(
    [
      options.archiveURL.lastPathComponent,
      options.expectedPlanDigest,
      options.expectedArchiveDigest,
      options.expectedStepSetDigest,
      options.expectedTargetID,
      String(options.expectedBindingRevision),
    ],
    timeout: 180)

  try driver.waitForFacts(
    [
      options.expectedPlanDigest,
      options.expectedArchiveDigest,
      options.expectedStepSetDigest,
      options.expectedTargetID,
      "ERASE-USERDATA",
    ],
    timeout: 30)
  try driver.waitForAbsence("flash.confirm.sheet", timeout: 1)
  try driver.waitForPresence("flash.execute.submit", timeout: 30)
  try driver.waitForEnabled("flash.execute.submit", timeout: 30)
  try driver.assertNoFlashSubmission()
  if options.stopBeforeSubmit {
    print(
      "UI_REVIEW_PASS: exact typed Flash request is ready for one-click submit; "
        + "no Runtime Job is exposed before the button is pressed")
    return
  }
  print("UI_REVIEW_PASS: submitting the exact typed Flash request with one ArkDeck UI click")
  try driver.submit("flash.execute.submit")
  let submission = try driver.waitForFlashSubmission(timeout: options.timeoutSeconds)
  guard submission.state == "succeeded" else {
    throw DriverFailure.message(
      "Runtime Flash Job \(submission.jobID) stopped in \(submission.state)")
  }
  print("REAL_DEVICE_PASS: ArkDeck UI Flash Runtime Job \(submission.jobID) succeeded")
}

func runFlashBridge(_ arguments: [String]) throws -> Never {
  guard arguments.count == 2, arguments[0] == "--socket" else {
    throw DriverFailure.message(
      "usage: manual_ui_flash --xpc-flash-bridge --socket <existing-agentd.sock>")
  }
  let socketPath = arguments[1]
  guard socketPath.hasPrefix("/"), FileManager.default.fileExists(atPath: socketPath) else {
    throw DriverFailure.message("Flash bridge requires an existing absolute Runtime socket")
  }
  print("manual_ui_flash: bounded App XPC bridge -> \(socketPath)")
  return ManualFlashXPCBridge(socketPath: socketPath).run()
}

func requestAccessibilityPermission() -> Never {
  let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
  let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
  if trusted {
    print("manual_ui_flash: Accessibility access is already enabled")
    exit(0)
  }
  fputs(
    "manual_ui_flash: enable Manual UI Flash Driver in System Settings > "
      + "Privacy & Security > Accessibility, then run the driver again\n",
    stderr)
  exit(3)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--request-accessibility"] {
    requestAccessibilityPermission()
  } else if arguments.first == "--xpc-flash-bridge" {
    try runFlashBridge(Array(arguments.dropFirst()))
  } else {
    try run()
  }
} catch {
  fputs("manual_ui_flash: \(error)\n", stderr)
  exit(2)
}
