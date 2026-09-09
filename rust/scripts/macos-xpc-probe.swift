// Host-only read probe for the signed raw-libxpc matrix. No device operations.
import Foundation
import XPC
import Darwin
let arguments = CommandLine.arguments
let count = arguments.count > 1 ? Int(arguments[1]) ?? 1 : 1
let version = arguments.count > 2 ? arguments[2] : "0.1.0"
let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" and (identifier \"com.arkdeck.agentd\" or identifier \"com.arkdeck.agentd.facade\") and info[CFBundleShortVersionString] = \"\(version)\" and info[CFBundleVersion] = \"1\""
let queue = DispatchQueue(label: "xpa-probe")
let connection = xpc_connection_create_mach_service("com.arkdeck.agentd", queue, 0)
guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else { exit(65) }
xpc_connection_set_event_handler(connection) { _ in }
xpc_connection_activate(connection)
var samples = [Double]()
var errors = [String]()
for i in 0..<(count + 10) {
  let done = DispatchSemaphore(value: 0)
  let frame = Data("{\"protocolVersion\":\"1.0.0\",\"contractIdentity\":\"8a662759721a2081e974306399997801246de4022047365c050107de5dce2912\",\"id\":\"probe-\(i)\",\"method\":\"health\"}".utf8)
  let message = xpc_dictionary_create(nil, nil, 0)
  frame.withUnsafeBytes { xpc_dictionary_set_data(message, "frame", $0.baseAddress, $0.count) }
  let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  xpc_connection_send_message_with_reply(connection, message, queue) { reply in
    if xpc_get_type(reply) == XPC_TYPE_ERROR {
      errors.append(xpc_dictionary_get_string(reply, "XPCErrorDescription").map(String.init(cString:)) ?? "transportError")
    } else {
      var length = 0
      if let bytes = xpc_dictionary_get_data(reply, "frame", &length),
        let object = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length)) as? [String: Any],
        object["ok"] as? Bool == true, object["id"] as? String == "probe-\(i)" {
        if i >= 10 { samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6) }
      } else { errors.append("invalidFrame") }
    }
    done.signal()
  }
  if done.wait(timeout: .now() + 5) != .success { errors.append("timeout"); break }
  if !errors.isEmpty { break }
}
xpc_connection_cancel(connection)
samples.sort()
let output: [String: Any] = ["samples": samples.count, "errors": errors,
  "p95ms": samples.isEmpty ? NSNull() : samples[min(samples.count - 1, Int(ceil(Double(samples.count) * 0.95)) - 1)] as Any]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
exit(errors.isEmpty ? 0 : 69)
