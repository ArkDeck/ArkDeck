//! The Windows daemon's stop request. It is process-wide, so it keeps a test
//! binary of its own, with one test.
#![cfg(windows)]
use arkdeck_platform::{LocalEndpoint, LocalListener, StateRoot, StopSignal, random_bytes};

#[test]
fn a_named_stop_request_wakes_accept_and_remains_latched() {
    assert!(StopSignal::request_current().is_err());
    let root = std::env::temp_dir().join(format!(
        "ad-winstop-{:016x}",
        u64::from_ne_bytes(random_bytes().unwrap())
    ));
    std::fs::create_dir(&root).unwrap();
    let state = StateRoot::development(&root).unwrap();
    let scope = state.scope().unwrap();
    // No daemon of this scope has this process's id yet.
    assert!(scope.request_stop(std::process::id()).is_err());
    let stop = StopSignal::install(Some(&scope)).unwrap();
    assert!(!stop.requested());
    assert!(StopSignal::install(None).is_err());
    let endpoint = LocalEndpoint::new(format!(
        r"\\.\pipe\arkdeck-stop-test-{:032x}",
        u128::from_le_bytes(random_bytes().unwrap())
    ));
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    // As another process of this user would: by the scope's name and this pid.
    let requester = std::thread::spawn(move || {
        // Not a synchronisation: asked before or during the wait, the answer
        // is the same; the pause makes the blocked wait the likely one.
        std::thread::sleep(std::time::Duration::from_millis(100));
        scope.request_stop(std::process::id()).unwrap();
    });
    assert!(listener.accept_until(&stop).unwrap().is_none());
    requester.join().unwrap();
    for _ in 0..3 {
        assert!(stop.requested());
        assert!(listener.accept_until(&stop).unwrap().is_none());
    }
    StopSignal::request_current().unwrap();
    assert!(stop.requested());
    drop(listener);
    drop(state);
    std::fs::remove_dir_all(root).unwrap();
}
