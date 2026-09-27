//! An internal composition stop gets a separate process-wide signal fixture.
#![cfg(unix)]
use arkdeck_platform::{LocalEndpoint, LocalListener, StopSignal, random_bytes};

#[test]
fn composition_stop_wakes_accept_and_remains_latched() {
    assert!(StopSignal::request_current().is_err());
    let stop = StopSignal::install().unwrap();
    assert!(!stop.requested());
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "internal-stop-{:016x}",
        u64::from_ne_bytes(random_bytes().unwrap())
    ));
    let endpoint = LocalEndpoint::new(root.join("control.sock"));
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    StopSignal::request_current().unwrap();
    for _ in 0..3 {
        assert!(stop.requested());
        assert!(listener.accept_until(&stop).unwrap().is_none());
    }
    drop(listener);
    std::fs::remove_dir_all(root).unwrap();
}
