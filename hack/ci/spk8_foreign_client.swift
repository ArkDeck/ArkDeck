// SPK-8 negative (a) client: a bare, ad-hoc signed tool that is NOT the ArkDeck
// team's App. `installed_spk8_negatives.py` compiles and signs it, then asks it
// to send one read-only `health` frame to the fixed `com.arkdeck.agentd` Mach
// service. It prints one JSON record and never retries or sends anything else.
//
//   spk8-foreign-client probe <health-frame-json> <server-requirement>
//   spk8-foreign-client self-test <health-frame-json> <app-requirement>
//
// `self-test` touches no Mach name, launchd or Runtime: it stands up anonymous
// in-process listeners shaped like the Rust daemon's `arkdeck_mach_listen`
// (euid check and code requirement installed on each peer before activation,
// a handler that counts entries) and runs the same round trip against them.
import Darwin
import Foundation
import XPC

let service = "com.arkdeck.agentd"
let arguments = CommandLine.arguments
guard arguments.count == 4, ["probe", "self-test"].contains(arguments[1]) else { exit(64) }
let frame = Data(arguments[2].utf8)
let requirement = arguments[3]
let queue = DispatchQueue(label: "com.arkdeck.spk8.foreign-client")

func errorName(_ object: xpc_object_t) -> String {
  if xpc_equal(object, XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT) { return "peerCodeSigningRequirement" }
  if xpc_equal(object, XPC_ERROR_CONNECTION_INTERRUPTED) { return "connectionInterrupted" }
  if xpc_equal(object, XPC_ERROR_CONNECTION_INVALID) { return "connectionInvalid" }
  return "other"
}

/// One request, one bounded wait. Classifies only what libxpc handed back.
func roundTrip(_ connection: xpc_connection_t) -> [String: Any] {
  var events = [String]()
  xpc_connection_set_event_handler(connection) { event in
    if xpc_get_type(event) == XPC_TYPE_ERROR { events.append(errorName(event)) }
  }
  xpc_connection_activate(connection)
  let message = xpc_dictionary_create(nil, nil, 0)
  frame.withUnsafeBytes { xpc_dictionary_set_data(message, "frame", $0.baseAddress, $0.count) }
  let done = DispatchSemaphore(value: 0)
  var outcome = "noAnswer"
  var replyError: String?
  let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  var elapsed = 0.0
  xpc_connection_send_message_with_reply(connection, message, queue) { reply in
    elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6
    if xpc_get_type(reply) == XPC_TYPE_ERROR {
      let name = errorName(reply)
      replyError = name
      switch name {
      case "peerCodeSigningRequirement": outcome = "serverRequirementUnmet"
      case "connectionInterrupted", "connectionInvalid": outcome = "refused"
      default: outcome = "otherError"
      }
    } else {
      var length = 0
      let answered = xpc_get_type(reply) == XPC_TYPE_DICTIONARY
        && xpc_dictionary_get_count(reply) == 1
        && xpc_dictionary_get_data(reply, "frame", &length) != nil
      // Any reply at all means the peer handler ran for this client.
      outcome = answered ? "answered" : "answeredMalformed"
    }
    done.signal()
  }
  let finished = done.wait(timeout: .now() + 5) == .success
  // Let a trailing connection event land before reporting; never resend.
  Thread.sleep(forTimeInterval: 0.2)
  xpc_connection_cancel(connection)
  return queue.sync {
    var record: [String: Any] = ["outcome": outcome, "connectionEvents": events]
    record["replyError"] = replyError ?? NSNull()
    record["elapsedMs"] = finished ? elapsed : NSNull()
    return record
  }
}

func emit(_ record: [String: Any]) -> Never {
  var output = record
  output["schemaVersion"] = "arkdeck.spk8-foreign-client/1"
  output["mode"] = arguments[1]
  guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { exit(70) }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
  exit(0)
}

if arguments[1] == "probe" {
  let connection = xpc_connection_create_mach_service(service, queue, 0)
  // Pin the answering service to the inspected daemon, so a refusal can only
  // come from it and an impostor shows up as `serverRequirementUnmet`.
  guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else { exit(65) }
  emit(["service": service, "probe": roundTrip(connection)])
}

/// Anonymous stand-in shaped like `arkdeck_mach_listen`.
final class Listener {
  let connection: xpc_connection_t
  var entries = 0
  init(requirement: String?) {
    connection = xpc_connection_create(nil, queue)
    xpc_connection_set_event_handler(connection) { [unowned self] peer in
      guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
      if xpc_connection_get_euid(peer) != geteuid()
        || (requirement.map { xpc_connection_set_peer_code_signing_requirement(peer, $0) != 0 } ?? false)
      {
        xpc_connection_cancel(peer)
        return
      }
      xpc_connection_set_event_handler(peer) { [unowned self] event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(event) else { return }
        self.entries += 1
        xpc_dictionary_set_data(reply, "frame", "{}", 2)
        xpc_connection_send_message(peer, reply)
      }
      xpc_connection_activate(peer)
    }
    xpc_connection_activate(connection)
  }
  func client() -> xpc_connection_t {
    let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(connection))
    xpc_connection_set_target_queue(client, queue)
    return client
  }
}

// The refusing listener carries the App requirement this tool cannot meet; the
// control listener has none, proving the round trip does detect a dispatch.
let refusing = Listener(requirement: requirement)
let refusal = roundTrip(refusing.client())
let control = Listener(requirement: nil)
let accepted = roundTrip(control.client())
emit([
  "refusing": refusal.merging(["handlerEntries": queue.sync { refusing.entries }]) { a, _ in a },
  "control": accepted.merging(["handlerEntries": queue.sync { control.entries }]) { a, _ in a },
])
