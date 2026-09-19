// Loopback ports for host tests that start listeners in other processes,
// included by each test that needs them (`mod loopback_ports { include!(..) }`).
//
// A port taken from `bind(0)` and released comes from the kernel's ephemeral
// range, and the macOS 26 CI runners hand a port just released straight back
// to the next `bind(0)` — this binary's own, or any process on the host — so a
// test could find its port listened on by a neighbour, or a neighbour's probe
// could hold it for a moment. These ports are chosen below the ephemeral range
// instead, where no `bind(0)` on the host ever lands: at random, checked free
// by binding them, and recorded so that no other test of the binary is handed
// the same one.

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::sync::{Mutex, OnceLock};

/// Every port a test of this binary was handed, released or held.
static ISSUED: Mutex<BTreeSet<u16>> = Mutex::new(BTreeSet::new());

/// The first port of the kernel's ephemeral range.
fn ephemeral_first() -> u16 {
    static FIRST: OnceLock<u16> = OnceLock::new();
    *FIRST.get_or_init(|| {
        #[cfg(target_os = "macos")]
        let first = std::process::Command::new("/usr/sbin/sysctl")
            .args(["-n", "net.inet.ip.portrange.first"])
            .output()
            .ok()
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .and_then(|text| text.trim().parse().ok())
            .unwrap_or(49_152);
        #[cfg(target_os = "linux")]
        let first = std::fs::read_to_string("/proc/sys/net/ipv4/ip_local_port_range")
            .ok()
            .and_then(|text| text.split_whitespace().next()?.parse().ok())
            .unwrap_or(32_768);
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let first = 49_152;
        first
    })
}

/// A port in the lower half below the ephemeral range, at random.
fn candidate() -> u16 {
    let first = ephemeral_first().max(2_048);
    let low = first / 2;
    let random = u16::from_le_bytes(arkdeck_platform::random_bytes::<2>().unwrap());
    low + random % (first - low)
}

/// A listener the test keeps, on a loopback port no other test was handed.
// Each including test uses some of these.
#[allow(dead_code)]
pub fn issued_listener() -> TcpListener {
    loop {
        let port = candidate();
        // Recorded before it is tried: a port something else on the host
        // holds is never tried again.
        if !ISSUED.lock().unwrap().insert(port) {
            continue;
        }
        if let Ok(listener) = TcpListener::bind((Ipv4Addr::LOCALHOST, port)) {
            return listener;
        }
    }
}

/// A free loopback endpoint no other test was handed, released for the
/// process that will listen on it.
// Each including test uses some of these.
#[allow(dead_code)]
pub fn free_endpoint() -> SocketAddrV4 {
    let port = issued_listener().local_addr().unwrap().port();
    SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
}

// Each including test uses some of these.
#[allow(dead_code)]
pub fn free_port() -> u16 {
    free_endpoint().port()
}
