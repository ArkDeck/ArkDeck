//! SPK-2 listener: a Rust process checks in to launchd as the Mach service
//! `com.arkdeck.agentd` through the libxpc C API, admits peers by euid and a
//! code-signing requirement, and answers one request frame per message.
//!
//! Wire shape (what XPA-003's façade and the App's `xpc_connection` client
//! would agree on): a message dictionary with
//!   `frame` : data   — one LF-free JSON request frame, ≤ 4 MiB
//!   `pad`   : uint64 — optional; ask for a reply frame padded to this size
//! and a reply dictionary with
//!   `frame` : data   — the response frame (`SPK2_REPLY_MODE=echo` echoes the
//!                      request bytes instead)
//!   `error` : string — a structured transport refusal, no `frame`
//!
//! Every accepted peer, message, refusal and error is written to stderr as one
//! JSON line so launchd's StandardErrorPath is the run's log.

#![allow(non_camel_case_types, non_upper_case_globals)]

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

type xpc_object_t = *mut c_void;
type xpc_connection_t = *mut c_void;
type xpc_type_t = *const c_void;

const XPC_CONNECTION_MACH_SERVICE_LISTENER: u64 = 1 << 0;
const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

extern "C" {
    static _NSConcreteStackBlock: c_void;
    static _xpc_type_connection: c_void;
    static _xpc_type_dictionary: c_void;
    static _xpc_type_error: c_void;
    static _xpc_error_connection_invalid: c_void;
    static _xpc_error_connection_interrupted: c_void;
    static _xpc_error_termination_imminent: c_void;
    static _xpc_error_peer_code_signing_requirement: c_void;

    fn xpc_connection_create_mach_service(
        name: *const c_char,
        targetq: *mut c_void,
        flags: u64,
    ) -> xpc_connection_t;
    fn xpc_connection_set_event_handler(connection: xpc_connection_t, handler: *const c_void);
    fn xpc_connection_activate(connection: xpc_connection_t);
    fn xpc_connection_cancel(connection: xpc_connection_t);
    fn xpc_connection_get_pid(connection: xpc_connection_t) -> i32;
    fn xpc_connection_get_euid(connection: xpc_connection_t) -> u32;
    fn xpc_connection_get_egid(connection: xpc_connection_t) -> u32;
    fn xpc_connection_get_asid(connection: xpc_connection_t) -> u32;
    fn xpc_connection_set_peer_code_signing_requirement(
        connection: xpc_connection_t,
        requirement: *const c_char,
    ) -> i32;
    fn xpc_connection_send_message(connection: xpc_connection_t, message: xpc_object_t);
    fn xpc_get_type(object: xpc_object_t) -> xpc_type_t;
    fn xpc_dictionary_create_reply(original: xpc_object_t) -> xpc_object_t;
    fn xpc_dictionary_get_data(
        dictionary: xpc_object_t,
        key: *const c_char,
        length: *mut usize,
    ) -> *const c_void;
    fn xpc_dictionary_get_uint64(dictionary: xpc_object_t, key: *const c_char) -> u64;
    fn xpc_dictionary_get_string(dictionary: xpc_object_t, key: *const c_char) -> *const c_char;
    fn xpc_dictionary_get_count(dictionary: xpc_object_t) -> usize;
    fn xpc_dictionary_set_data(
        dictionary: xpc_object_t,
        key: *const c_char,
        bytes: *const c_void,
        length: usize,
    );
    fn xpc_dictionary_set_string(dictionary: xpc_object_t, key: *const c_char, value: *const c_char);
    fn xpc_dictionary_set_uint64(dictionary: xpc_object_t, key: *const c_char, value: u64);
    fn xpc_copy_description(object: xpc_object_t) -> *mut c_char;
    fn xpc_release(object: xpc_object_t);
    fn dispatch_main() -> !;
    fn geteuid() -> u32;
    fn getpid() -> i32;
    fn free(pointer: *mut c_void);
}

// ---------------------------------------------------------------------------
// Blocks, by hand. libxpc takes `void (^)(xpc_object_t)`; a block is a pointer
// to this layout, and libxpc `Block_copy`s it, which for a stack block means
// malloc + memcpy of `descriptor.size` bytes. With a plain-data capture and no
// copy/dispose helper that is the whole contract.
// ---------------------------------------------------------------------------

#[repr(C)]
struct BlockDescriptor {
    reserved: usize,
    size: usize,
}

#[repr(C)]
struct Block<T> {
    isa: *const c_void,
    flags: i32,
    reserved: i32,
    invoke: unsafe extern "C" fn(*mut Block<T>, xpc_object_t),
    descriptor: *const BlockDescriptor,
    captured: T,
}

static LISTENER_DESCRIPTOR: BlockDescriptor = BlockDescriptor {
    reserved: 0,
    size: std::mem::size_of::<Block<()>>(),
};
static PEER_DESCRIPTOR: BlockDescriptor = BlockDescriptor {
    reserved: 0,
    size: std::mem::size_of::<Block<Peer>>(),
};

/// Plain data captured by each peer's event handler. `xpc_object_t` events
/// only hand back the connection for messages, not for errors, so the peer
/// carries it (and the facts logged at accept time) itself.
#[derive(Clone, Copy)]
struct Peer {
    connection: xpc_connection_t,
    serial: u64,
    pid: i32,
}

// ---------------------------------------------------------------------------
// Logging: one JSON object per line on stderr.
// ---------------------------------------------------------------------------

static STARTED: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
static PEERS: AtomicU64 = AtomicU64::new(0);
static MESSAGES: AtomicU64 = AtomicU64::new(0);
static REFUSALS: AtomicU64 = AtomicU64::new(0);

fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn log(event: &str, fields: &[(&str, String)]) {
    let started = STARTED.get_or_init(Instant::now);
    let mut line = format!(
        "{{\"t_ms\":{:.3},\"event\":\"{}\"",
        started.elapsed().as_secs_f64() * 1000.0,
        json_escape(event)
    );
    for (key, value) in fields {
        line.push_str(&format!(",\"{}\":{}", json_escape(key), value));
    }
    line.push_str("}\n");
    let stderr = std::io::stderr();
    let mut handle = stderr.lock();
    let _ = handle.write_all(line.as_bytes());
    let _ = handle.flush();
}

fn s(text: &str) -> String {
    format!("\"{}\"", json_escape(text))
}

fn cstr(text: &str) -> CString {
    CString::new(text).expect("no interior NUL")
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// The request id, pulled out of the frame without a JSON parser: the spike
/// answers frames, it does not interpret them (XPA-003's façade validates the
/// single-v1 shape with a real decoder; that is its job, not this spike's).
fn request_id(frame: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(frame).ok()?;
    let start = text.find("\"id\":\"")? + 6;
    let end = text[start..].find('"')? + start;
    Some(text[start..end].to_string())
}

fn response_frame(frame: &[u8], pad: u64) -> Vec<u8> {
    let id = request_id(frame).unwrap_or_default();
    let mut body = format!(
        "{{\"id\":\"{}\",\"ok\":true,\"result\":{{\"listener\":\"spk2-rust-libxpc\",\"echoBytes\":{}",
        json_escape(&id),
        frame.len()
    );
    if pad > 0 {
        body.push_str(",\"padding\":\"");
        let head = body.len() + "\"}}".len();
        let target = pad as usize;
        if target > head {
            body.extend(std::iter::repeat('x').take(target - head));
        }
        body.push('"');
    }
    body.push_str("}}");
    body.into_bytes()
}

// ---------------------------------------------------------------------------
// Peer connections
// ---------------------------------------------------------------------------

unsafe fn error_name(event: xpc_object_t) -> &'static str {
    let e = event as *const c_void;
    if e == &_xpc_error_connection_invalid as *const c_void {
        "XPC_ERROR_CONNECTION_INVALID"
    } else if e == &_xpc_error_connection_interrupted as *const c_void {
        "XPC_ERROR_CONNECTION_INTERRUPTED"
    } else if e == &_xpc_error_termination_imminent as *const c_void {
        "XPC_ERROR_TERMINATION_IMMINENT"
    } else if e == &_xpc_error_peer_code_signing_requirement as *const c_void {
        "XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT"
    } else {
        "XPC_ERROR_OTHER"
    }
}

unsafe fn error_description(event: xpc_object_t) -> String {
    let key = cstr("XPCErrorDescription");
    let text = xpc_dictionary_get_string(event, key.as_ptr());
    if text.is_null() {
        String::new()
    } else {
        CStr::from_ptr(text).to_string_lossy().into_owned()
    }
}

unsafe fn description_excerpt(object: xpc_object_t, limit: usize) -> String {
    let raw = xpc_copy_description(object);
    if raw.is_null() {
        return String::new();
    }
    let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
    free(raw as *mut c_void);
    let mut excerpt: String = text.chars().take(limit).collect();
    if text.chars().count() > limit {
        excerpt.push_str("…");
    }
    excerpt
}

unsafe extern "C" fn peer_event(block: *mut Block<Peer>, event: xpc_object_t) {
    let peer = (*block).captured;
    let kind = xpc_get_type(event);
    if kind == &_xpc_type_error as *const c_void {
        let name = error_name(event);
        log(
            "peer.error",
            &[
                ("peer", peer.serial.to_string()),
                ("pid", peer.pid.to_string()),
                ("error", s(name)),
                ("description", s(&error_description(event))),
            ],
        );
        if name == "XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT" {
            REFUSALS.fetch_add(1, Ordering::Relaxed);
        }
        return;
    }
    if kind != &_xpc_type_dictionary as *const c_void {
        log(
            "peer.unexpected",
            &[
                ("peer", peer.serial.to_string()),
                ("pid", peer.pid.to_string()),
                ("description", s(&description_excerpt(event, 400))),
            ],
        );
        return;
    }

    let frame_key = cstr("frame");
    let mut length: usize = 0;
    let bytes = xpc_dictionary_get_data(event, frame_key.as_ptr(), &mut length);
    let reply = xpc_dictionary_create_reply(event);
    if bytes.is_null() {
        // Not this spike's wire shape. The interesting case is the production
        // App's NSXPCConnection reaching a raw listener: record what NSXPC
        // sends so XPA-003 knows what the raw listener will see from an
        // un-migrated App.
        log(
            "peer.foreignMessage",
            &[
                ("peer", peer.serial.to_string()),
                ("pid", peer.pid.to_string()),
                ("keys", xpc_dictionary_get_count(event).to_string()),
                ("description", s(&description_excerpt(event, 3000))),
            ],
        );
        if !reply.is_null() {
            let key = cstr("error");
            let value = cstr("malformedFrame");
            xpc_dictionary_set_string(reply, key.as_ptr(), value.as_ptr());
            xpc_connection_send_message(peer.connection, reply);
            xpc_release(reply);
        }
        return;
    }
    let frame = std::slice::from_raw_parts(bytes as *const u8, length);
    let serial = MESSAGES.fetch_add(1, Ordering::Relaxed) + 1;
    let mode = env_or("SPK2_REPLY_MODE", "respond");
    let refusal = if length == 0 || length > MAX_FRAME_BYTES {
        Some("frameSizeOutOfRange")
    } else if frame[0] != b'{' || frame.last() != Some(&b'}') {
        Some("malformedFrame")
    } else {
        None
    };
    if serial <= 3 || serial % 500 == 0 {
        log(
            "peer.message",
            &[
                ("peer", peer.serial.to_string()),
                ("pid", peer.pid.to_string()),
                ("message", serial.to_string()),
                ("bytes", length.to_string()),
                ("mode", s(&mode)),
                ("refusal", refusal.map(s).unwrap_or_else(|| "null".into())),
            ],
        );
    }
    if reply.is_null() {
        return;
    }
    if let Some(reason) = refusal {
        let key = cstr("error");
        let value = cstr(reason);
        xpc_dictionary_set_string(reply, key.as_ptr(), value.as_ptr());
    } else {
        let pad_key = cstr("pad");
        let pad = xpc_dictionary_get_uint64(event, pad_key.as_ptr());
        let body: Vec<u8> = if mode == "echo" {
            frame.to_vec()
        } else {
            response_frame(frame, pad)
        };
        xpc_dictionary_set_data(
            reply,
            frame_key.as_ptr(),
            body.as_ptr() as *const c_void,
            body.len(),
        );
        let serial_key = cstr("serial");
        xpc_dictionary_set_uint64(reply, serial_key.as_ptr(), serial);
    }
    xpc_connection_send_message(peer.connection, reply);
    xpc_release(reply);
}

unsafe fn accept(connection: xpc_connection_t, requirement: &str) {
    let serial = PEERS.fetch_add(1, Ordering::Relaxed) + 1;
    let pid = xpc_connection_get_pid(connection);
    let euid = xpc_connection_get_euid(connection);
    let egid = xpc_connection_get_egid(connection);
    let asid = xpc_connection_get_asid(connection);
    let own_euid = geteuid();

    // Layer 1 (design §F.2): the peer's euid must be the daemon's own.
    if euid != own_euid {
        log(
            "peer.refusedEUID",
            &[
                ("peer", serial.to_string()),
                ("pid", pid.to_string()),
                ("euid", euid.to_string()),
                ("ownEUID", own_euid.to_string()),
            ],
        );
        REFUSALS.fetch_add(1, Ordering::Relaxed);
        xpc_connection_cancel(connection);
        return;
    }

    // Layer 2: the code-signing requirement, checked by libxpc on every
    // message; must be set before the peer connection is activated and at
    // most once per connection. `SPK2_PEER_REQUIREMENT=none` leaves it out so
    // the per-connection cost of the check can be measured by difference.
    let (rc, set_micros) = if requirement == "none" {
        (0, 0u128)
    } else {
        let requirement_c = cstr(requirement);
        let started = Instant::now();
        let rc = xpc_connection_set_peer_code_signing_requirement(connection, requirement_c.as_ptr());
        (rc, started.elapsed().as_micros())
    };
    log(
        "peer.accepted",
        &[
            ("peer", serial.to_string()),
            ("pid", pid.to_string()),
            ("euid", euid.to_string()),
            ("egid", egid.to_string()),
            ("asid", asid.to_string()),
            ("requirement", s(if requirement == "none" { "none" } else { "set" })),
            ("requirementSet", rc.to_string()),
            ("requirementSetMicros", set_micros.to_string()),
        ],
    );
    if rc != 0 {
        log(
            "peer.requirementRejected",
            &[("peer", serial.to_string()), ("rc", rc.to_string())],
        );
        xpc_connection_cancel(connection);
        return;
    }

    let block = Block::<Peer> {
        isa: &_NSConcreteStackBlock as *const c_void,
        flags: 0,
        reserved: 0,
        invoke: peer_event,
        descriptor: &PEER_DESCRIPTOR,
        captured: Peer {
            connection,
            serial,
            pid,
        },
    };
    xpc_connection_set_event_handler(connection, &block as *const Block<Peer> as *const c_void);
    xpc_connection_activate(connection);
}

unsafe extern "C" fn listener_event(_block: *mut Block<()>, event: xpc_object_t) {
    let kind = xpc_get_type(event);
    if kind == &_xpc_type_connection as *const c_void {
        let requirement = env_or(
            "SPK2_PEER_REQUIREMENT",
            "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" \
             and identifier \"com.arkdeck.spk2-client\"",
        );
        accept(event, &requirement);
    } else if kind == &_xpc_type_error as *const c_void {
        log(
            "listener.error",
            &[
                ("error", s(error_name(event))),
                ("description", s(&error_description(event))),
            ],
        );
    } else {
        log(
            "listener.unexpected",
            &[("description", s(&description_excerpt(event, 400)))],
        );
    }
}

fn main() {
    STARTED.get_or_init(Instant::now);
    let service = env_or("SPK2_MACH_SERVICE", "com.arkdeck.agentd");
    let requirement = env_or("SPK2_PEER_REQUIREMENT", "(default)");
    log(
        "listener.starting",
        &[
            ("pid", unsafe { getpid() }.to_string()),
            ("euid", unsafe { geteuid() }.to_string()),
            ("service", s(&service)),
            ("requirement", s(&requirement)),
            ("replyMode", s(&env_or("SPK2_REPLY_MODE", "respond"))),
            (
                "launchdVended",
                std::env::var("XPC_SERVICE_NAME").map(|v| s(&v)).unwrap_or_else(|_| "null".into()),
            ),
        ],
    );
    unsafe {
        let name = cstr(&service);
        let listener = xpc_connection_create_mach_service(
            name.as_ptr(),
            std::ptr::null_mut(),
            XPC_CONNECTION_MACH_SERVICE_LISTENER,
        );
        if listener.is_null() {
            log("listener.createFailed", &[]);
            std::process::exit(2);
        }
        let block = Block::<()> {
            isa: &_NSConcreteStackBlock as *const c_void,
            flags: 0,
            reserved: 0,
            invoke: listener_event,
            descriptor: &LISTENER_DESCRIPTOR,
            captured: (),
        };
        xpc_connection_set_event_handler(listener, &block as *const Block<()> as *const c_void);
        xpc_connection_activate(listener);
        log("listener.activated", &[("service", s(&service))]);
        dispatch_main();
    }
}
