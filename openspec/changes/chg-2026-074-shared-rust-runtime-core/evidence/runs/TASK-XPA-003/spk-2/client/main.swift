// SPK-2 client: a sandboxed process reaches the Mach service through the raw
// libxpc C API (`xpc_connection_*`), the transport XPA-003 moves the App to.
//
// Modes
//   roundtrips  N request/reply round trips on one connection
//   fresh       N round trips, a new connection per request (the App's
//               NSXPCConnection-per-request pattern today)
//   sizes       round trips at several reply sizes, plus the 4 MiB request cap
//   probe       one request with a bounded wait; reports reply / error / timeout
//   nsxpc       the same round trips over NSXPCConnection against whatever
//               daemon vends the service (the production Swift daemon before
//               the swap), for a same-host comparison
//
// Output: one JSON object on stdout. Self-reported identity comes from the
// Security framework, so the record pairs with the listener's pid log.

import Darwin
import Foundation
import Security
import XPC

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.isEmpty ? "roundtrips" : arguments.removeFirst()
func option(_ name: String, default value: String) -> String {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
    return value
  }
  return arguments[index + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }

let service = option("--service", default: "com.arkdeck.agentd")
let count = Int(option("--count", default: "1000")) ?? 1000
let warmup = Int(option("--warmup", default: "100")) ?? 100
let pad = UInt64(option("--pad", default: "0")) ?? 0
let timeoutSeconds = Double(option("--timeout", default: "5")) ?? 5
let method = option("--method", default: "runtime.storage.status")
let protocolVersion = option("--protocol", default: "1.0.0")
let pinServer: String? = arguments.contains("--pin-server") ? option("--pin-server", default: "") : nil

// MARK: - Clocks and statistics (nearest rank, as SPK-1)

@inline(__always) func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func percentile(_ sorted: [Double], _ p: Double) -> Double {
  guard !sorted.isEmpty else { return .nan }
  let rank = Int((p / 100.0 * Double(sorted.count)).rounded(.up))
  return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

func summary(_ samplesNs: [UInt64]) -> [String: Any] {
  let ms = samplesNs.map { Double($0) / 1_000_000.0 }.sorted()
  guard !ms.isEmpty else { return ["n": 0] }
  return [
    "n": ms.count,
    "unit": "milliseconds",
    "min": ms.first!,
    "p50": percentile(ms, 50),
    "p95": percentile(ms, 95),
    "p99": percentile(ms, 99),
    "max": ms.last!,
    "mean": ms.reduce(0, +) / Double(ms.count),
  ]
}

// MARK: - Frames (the daemon's single-v1 request envelope, canonical key order)

func requestFrame(method: String, id: String = UUID().uuidString) -> Data {
  Data("{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":null,\"protocolVersion\":\"\(protocolVersion)\"}".utf8)
}

func sample(_ data: Data?) -> Any {
  guard let data, let text = String(data: data, encoding: .utf8) else { return NSNull() }
  return String(text.prefix(240))
}

func frameID(_ frame: Data) -> String? {
  guard let text = String(data: frame, encoding: .utf8),
    let range = text.range(of: "\"id\":\"")
  else { return nil }
  let rest = text[range.upperBound...]
  guard let end = rest.firstIndex(of: "\"") else { return nil }
  return String(rest[..<end])
}

// MARK: - Self identity

func selfIdentity() -> [String: Any] {
  var record: [String: Any] = [
    "pid": Int(getpid()),
    "euid": Int(geteuid()),
    "executable": CommandLine.arguments[0],
    "bundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(),
    "sandboxContainer": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? NSNull(),
  ]
  var code: SecCode?
  guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
    record["signing"] = "SecCodeCopySelf failed"
    return record
  }
  var staticCode: SecStaticCode?
  guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
    record["signing"] = "SecCodeCopyStaticCode failed"
    return record
  }
  var information: CFDictionary?
  let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
  guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
    let info = information as? [String: Any]
  else {
    record["signing"] = "SecCodeCopySigningInformation failed"
    return record
  }
  var signing: [String: Any] = [:]
  signing["identifier"] = info[kSecCodeInfoIdentifier as String] ?? NSNull()
  signing["teamIdentifier"] = info[kSecCodeInfoTeamIdentifier as String] ?? NSNull()
  signing["flags"] = info[kSecCodeInfoFlags as String] ?? NSNull()
  if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
    signing["entitlementKeys"] = entitlements.keys.sorted()
    signing["machLookupGlobalNames"] =
      entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] ?? NSNull()
    signing["appSandbox"] = entitlements["com.apple.security.app-sandbox"] ?? NSNull()
  } else {
    signing["entitlementKeys"] = []
  }
  if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
    signing["certificateChain"] = certificates.map {
      (SecCertificateCopySubjectSummary($0) as String?) ?? "?"
    }
  } else {
    signing["certificateChain"] = []
  }
  record["signing"] = signing
  return record
}

// MARK: - Raw libxpc client

final class RawClient {
  let connection: xpc_connection_t
  let events = NSLock()
  var connectionEvents: [[String: Any]] = []
  var pinResult: Int32?

  init(service: String, pin: String?) {
    connection = xpc_connection_create_mach_service(service, nil, 0)
    if let pin, !pin.isEmpty {
      pinResult = xpc_connection_set_peer_code_signing_requirement(connection, pin)
    }
    xpc_connection_set_event_handler(connection) { [self] event in
      let record = describe(event)
      events.lock()
      connectionEvents.append(record)
      events.unlock()
    }
    xpc_connection_activate(connection)
  }

  func describe(_ object: xpc_object_t) -> [String: Any] {
    if xpc_get_type(object) == XPC_TYPE_ERROR {
      var name = "XPC_ERROR_OTHER"
      if xpc_equal(object, XPC_ERROR_CONNECTION_INVALID) {
        name = "XPC_ERROR_CONNECTION_INVALID"
      } else if xpc_equal(object, XPC_ERROR_CONNECTION_INTERRUPTED) {
        name = "XPC_ERROR_CONNECTION_INTERRUPTED"
      } else if xpc_equal(object, XPC_ERROR_TERMINATION_IMMINENT) {
        name = "XPC_ERROR_TERMINATION_IMMINENT"
      }
      let description = xpc_dictionary_get_string(object, "XPCErrorDescription").map {
        String(cString: $0)
      }
      if description?.lowercased().contains("code signing") == true {
        name = "XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT"
      }
      return ["error": name, "description": description ?? NSNull(), "tMs": Double(now()) / 1e6]
    }
    return ["type": String(cString: xpc_copy_description(object)).prefix(200).description]
  }

  func message(frame: Data, pad: UInt64) -> xpc_object_t {
    let message = xpc_dictionary_create(nil, nil, 0)
    frame.withUnsafeBytes { buffer in
      xpc_dictionary_set_data(message, "frame", buffer.baseAddress!, buffer.count)
    }
    if pad > 0 { xpc_dictionary_set_uint64(message, "pad", pad) }
    return message
  }

  /// One synchronous round trip. Returns the reply frame or an error record.
  func roundTrip(frame: Data, pad: UInt64) -> (Data?, [String: Any]?, UInt64) {
    let message = self.message(frame: frame, pad: pad)
    let start = now()
    let reply = xpc_connection_send_message_with_reply_sync(connection, message)
    let elapsed = now() - start
    if xpc_get_type(reply) == XPC_TYPE_ERROR {
      return (nil, describe(reply), elapsed)
    }
    if let refusal = xpc_dictionary_get_string(reply, "error") {
      return (nil, ["transportRefusal": String(cString: refusal)], elapsed)
    }
    var length = 0
    guard let bytes = xpc_dictionary_get_data(reply, "frame", &length) else {
      return (nil, ["error": "replyWithoutFrame"], elapsed)
    }
    return (Data(bytes: bytes, count: length), nil, elapsed)
  }

  /// One asynchronous round trip with a bounded wait.
  func probe(frame: Data, timeout: Double) -> [String: Any] {
    let message = self.message(frame: frame, pad: 0)
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var outcome: [String: Any] = [:]
    let start = now()
    xpc_connection_send_message_with_reply(connection, message, nil) { [self] reply in
      lock.lock()
      if xpc_get_type(reply) == XPC_TYPE_ERROR {
        outcome = ["outcome": "error", "detail": describe(reply)]
      } else {
        var length = 0
        let bytes = xpc_dictionary_get_data(reply, "frame", &length)
        let replyData = bytes.map { Data(bytes: $0, count: length) }
        outcome = [
          "outcome": bytes == nil ? "replyWithoutFrame" : "reply",
          "replyBytes": length,
          "replyID": replyData.flatMap(frameID) ?? NSNull(),
          "replySample": sample(replyData),
        ]
      }
      lock.unlock()
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      return ["outcome": "timeout", "waitedSeconds": timeout]
    }
    lock.lock()
    defer { lock.unlock() }
    outcome["elapsedMs"] = Double(now() - start) / 1e6
    return outcome
  }

  func cancel() { xpc_connection_cancel(connection) }

  func drainEvents() -> [[String: Any]] {
    events.lock()
    defer { events.unlock() }
    return connectionEvents
  }
}

// MARK: - NSXPC comparison client

@objc protocol SPK2AgentXPCProtocol {
  func sendRequestFrame(_ frame: Data, with reply: @escaping (Data?, String?) -> Void)
}

func nsxpcRoundTrip(connection: NSXPCConnection, frame: Data) -> (Data?, String?, UInt64) {
  let semaphore = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var result: (Data?, String?) = (nil, nil)
  let start = now()
  let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    lock.lock()
    result = (nil, "proxyError: \(error.localizedDescription)")
    lock.unlock()
    semaphore.signal()
  } as! SPK2AgentXPCProtocol
  proxy.sendRequestFrame(frame) { data, refusal in
    lock.lock()
    result = (data, refusal)
    lock.unlock()
    semaphore.signal()
  }
  if semaphore.wait(timeout: .now() + 30) == .timedOut {
    return (nil, "timeout", now() - start)
  }
  let elapsed = now() - start
  lock.lock()
  defer { lock.unlock() }
  return (result.0, result.1, elapsed)
}

// MARK: - Modes

var output: [String: Any] = [
  "mode": mode,
  "service": service,
  "protocolVersion": protocolVersion,
  "client": selfIdentity(),
  "host": [
    "kernel": ProcessInfo.processInfo.operatingSystemVersionString,
    "cpuCount": ProcessInfo.processInfo.processorCount,
  ],
]
if let pinServer { output["pinServer"] = pinServer }

func emit(_ extra: [String: Any]) -> Never {
  for (key, value) in extra { output[key] = value }
  let data = try! JSONSerialization.data(
    withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(0)
}

switch mode {
case "roundtrips":
  let client = RawClient(service: service, pin: pinServer)
  if let rc = client.pinResult { output["pinServerResult"] = Int(rc) }
  var samples: [UInt64] = []
  var errors: [[String: Any]] = []
  var replyBytes = 0
  var mismatches = 0
  var replySample: Any = NSNull()
  for index in 0..<(warmup + count) {
    let frame = requestFrame(method: method)
    let (reply, error, elapsed) = client.roundTrip(frame: frame, pad: pad)
    if let error {
      errors.append(error)
      if errors.count >= 3 { break }
      continue
    }
    if index >= warmup { samples.append(elapsed) }
    if let reply {
      replyBytes = reply.count
      if index == 0 { replySample = sample(reply) }
      if frameID(reply) != frameID(frame) { mismatches += 1 }
    }
  }
  client.cancel()
  emit([
    "warmup": warmup, "count": count, "method": method, "pad": pad,
    "requestBytes": requestFrame(method: method).count,
    "replyBytes": replyBytes,
    "replySample": replySample,
    "idMismatches": mismatches,
    "latency": summary(samples),
    "errors": errors,
    "connectionEvents": client.drainEvents(),
  ])

case "fresh":
  var samples: [UInt64] = []
  var errors: [[String: Any]] = []
  for index in 0..<(warmup + count) {
    let client = RawClient(service: service, pin: pinServer)
    let frame = requestFrame(method: method)
    let start = now()
    let (_, error, _) = client.roundTrip(frame: frame, pad: pad)
    let elapsed = now() - start
    client.cancel()
    if let error {
      errors.append(error)
      if errors.count >= 3 { break }
      continue
    }
    if index >= warmup { samples.append(elapsed) }
  }
  emit([
    "warmup": warmup, "count": count, "method": method,
    "latency": summary(samples), "errors": errors,
  ])

case "sizes":
  let client = RawClient(service: service, pin: pinServer)
  var rows: [[String: Any]] = []
  for replyTarget: UInt64 in [0, 4_096, 65_536, 1_048_576, 4_194_304] {
    var samples: [UInt64] = []
    var replyBytes = 0
    var errors = 0
    for index in 0..<(20 + count) {
      let (reply, error, elapsed) = client.roundTrip(frame: requestFrame(method: method), pad: replyTarget)
      if error != nil { errors += 1; continue }
      if index >= 20 { samples.append(elapsed) }
      replyBytes = reply?.count ?? 0
    }
    rows.append([
      "replyTarget": replyTarget, "replyBytes": replyBytes, "errors": errors,
      "latency": summary(samples),
    ])
  }
  // Request-size edge: exactly 4 MiB is a frame, one byte over is refused.
  var requestRows: [[String: Any]] = []
  for requestBytes in [4 * 1024 * 1024, 4 * 1024 * 1024 + 1] {
    let id = UUID().uuidString
    let head = "{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":{\"blob\":\""
    let tail = "\"},\"protocolVersion\":\"1.0.0\"}"
    let fill = requestBytes - head.utf8.count - tail.utf8.count
    let frame = Data((head + String(repeating: "y", count: fill) + tail).utf8)
    precondition(frame.count == requestBytes)
    let (reply, error, elapsed) = client.roundTrip(frame: frame, pad: 0)
    requestRows.append([
      "requestBytes": requestBytes,
      "outcome": error ?? ["reply": true, "replyBytes": reply?.count ?? 0, "idEcho": frameID(reply ?? Data()) == id],
      "elapsedMs": Double(elapsed) / 1e6,
    ])
  }
  client.cancel()
  emit(["count": count, "replies": rows, "requests": requestRows, "connectionEvents": client.drainEvents()])

case "probe":
  let client = RawClient(service: service, pin: pinServer)
  if let rc = client.pinResult { output["pinServerResult"] = Int(rc) }
  let frame = requestFrame(method: method)
  let probe = client.probe(frame: frame, timeout: timeoutSeconds)
  // Give a refusal delivered on the connection itself a moment to arrive.
  Thread.sleep(forTimeInterval: 0.3)
  client.cancel()
  Thread.sleep(forTimeInterval: 0.1)
  emit(["requestID": frameID(frame) ?? "", "probe": probe, "connectionEvents": client.drainEvents()])

case "nsxpc":
  let persistent = NSXPCConnection(machServiceName: service, options: [])
  persistent.remoteObjectInterface = NSXPCInterface(with: SPK2AgentXPCProtocol.self)
  persistent.resume()
  var samples: [UInt64] = []
  var errors: [String] = []
  var replyBytes = 0
  var refusals: [String] = []
  var replySample: Any = NSNull()
  for index in 0..<(warmup + count) {
    let (data, refusal, elapsed) = nsxpcRoundTrip(connection: persistent, frame: requestFrame(method: method))
    if let refusal {
      if refusal.hasPrefix("proxyError") || refusal == "timeout" { errors.append(refusal) } else { refusals.append(refusal) }
      if errors.count >= 3 { break }
      continue
    }
    replyBytes = data?.count ?? 0
    if index == 0 { replySample = sample(data) }
    if index >= warmup { samples.append(elapsed) }
  }
  persistent.invalidate()
  var freshSamples: [UInt64] = []
  let freshCount = min(count, 200)
  for index in 0..<(10 + freshCount) {
    let connection = NSXPCConnection(machServiceName: service, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SPK2AgentXPCProtocol.self)
    let start = now()
    connection.resume()
    let (_, refusal, _) = nsxpcRoundTrip(connection: connection, frame: requestFrame(method: method))
    let elapsed = now() - start
    connection.invalidate()
    if refusal == nil, index >= 10 { freshSamples.append(elapsed) }
  }
  emit([
    "warmup": warmup, "count": count, "method": method, "replyBytes": replyBytes,
    "replySample": replySample,
    "persistentConnection": summary(samples),
    "connectionPerRequest": ["count": freshCount, "latency": summary(freshSamples)],
    "errors": errors, "refusals": Array(Set(refusals)),
  ])

default:
  FileHandle.standardError.write(Data("unknown mode \(mode)\n".utf8))
  exit(2)
}
