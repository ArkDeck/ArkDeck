#!/usr/bin/env swift

// Manual, real-device GJ-4 driver. This file is intentionally outside every
// XCTest/UI-test target because a flash attempt can take several minutes.
//
// The driver exercises ArkDeck's real Accessibility surface, verifies the
// exact plan shown by the UI, acknowledges userdata loss, and presses the
// App's typed Runtime submit control. Runtime creates/consumes the capability;
// this driver has no authority or capability administration surface.

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

  static func parse(_ arguments: [String]) throws -> Options {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
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
      timeoutSeconds: timeoutSeconds)
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
    repeat {
      let visible = allStrings()
      if facts.allSatisfy({ fact in visible.contains(where: { $0.contains(fact) }) }) {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI did not expose every expected exact-plan fact before timeout")
  }

  func waitForPresence(_ identifier: String, timeout: TimeInterval) throws {
    _ = try waitForElement(identifier: identifier, timeout: timeout)
  }

  func waitForFlashTerminal(timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let visible = allStrings()
      for state in ["succeeded", "failed", "waitingForRecovery", "cancelled"]
      where visible.contains(where: { $0.contains(state) }) {
        return state
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw DriverFailure.message("Runtime Flash did not reach a terminal state before timeout")
  }

  func chooseFile(_ url: URL) throws {
    try press("flash.image.choose")
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    key(virtualCode: CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    type(url.path)
    key(virtualCode: CGKeyCode(kVK_Return))
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    key(virtualCode: CGKeyCode(kVK_Return))
  }

  private func waitForElement(identifier: String, timeout: TimeInterval) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier) { return element }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI element not found: \(identifier)")
  }

  private func element(identifier: String) -> AXUIElement? {
    descendants(of: application).first {
      stringAttribute($0, kAXIdentifierAttribute as CFString) == identifier
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

  private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
  }

  private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    attribute(element, name) as? String
  }

  private func key(virtualCode: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
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

func launch(_ appURL: URL) throws -> pid_t {
  if let running = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleURL?.standardizedFileURL == appURL
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
  return launched.processIdentifier
}

func run() throws {
  let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
  let pid = try launch(options.appURL)
  let driver = try AccessibilityDriver(processIdentifier: pid)

  try driver.press("app.navigation.flash")
  try driver.press("flash.mode.execute")
  try driver.chooseFile(options.archiveURL)
  try driver.selectPickerValue(options.expectedTargetID, identifier: "flash.target")
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

  try driver.press("flash.execute.review")
  let destructivePhrase = "FLASH \(options.expectedPlanDigest.prefix(12))"
  try driver.waitForFacts(
    [
      destructivePhrase,
      options.expectedPlanDigest,
      options.expectedArchiveDigest,
      options.expectedStepSetDigest,
      options.expectedTargetID,
      "ERASE-USERDATA",
    ],
    timeout: 30)
  try driver.setValue(destructivePhrase, identifier: "flash.confirm.destructivePhrase")
  try driver.setValue("ERASE-USERDATA", identifier: "flash.confirm.userdataPhrase")
  try driver.press("flash.confirm.accept")
  try driver.waitForFacts(
    [
      options.expectedPlanDigest,
      options.expectedArchiveDigest,
      options.expectedTargetID,
    ],
    timeout: 30)
  // SwiftUI may merge the receipt Label into its decorated container, while
  // the submit control remains a stable, named post-review element.
  try driver.waitForPresence("flash.execute.submit", timeout: 30)
  print("UI_REVIEW_PASS: submitting the reviewed typed Flash request through ArkDeck UI")
  try driver.press("flash.execute.submit")
  let terminal = try driver.waitForFlashTerminal(timeout: options.timeoutSeconds)
  guard terminal == "succeeded" else {
    throw DriverFailure.message("Runtime Flash stopped in \(terminal)")
  }
  print("REAL_DEVICE_PASS: ArkDeck UI Flash Runtime Job succeeded")
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

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--xpc-flash-bridge" {
    try runFlashBridge(Array(arguments.dropFirst()))
  } else {
    try run()
  }
} catch {
  fputs("manual_ui_flash: \(error)\n", stderr)
  exit(2)
}
