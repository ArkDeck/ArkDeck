//! The daemon's in-process tests whose paths start child processes, in a
//! binary of their own, one test at a time.
//!
//! macOS has no `SOCK_CLOEXEC`: Rust's std makes a socket with `socket()` and
//! only then marks it close-on-exec, so a child that another thread spawns in
//! between without closing every descriptor on exec — as
//! `std::process::Command` spawns, unlike `arkdeck-platform` — keeps that
//! socket, bound and listening once its maker binds it, for as long as the
//! child lives; and any child shares every descriptor of this process until
//! its exec. A listener one test dropped, such as the loopback port it
//! released for its managed HDC server or the daemon's installed socket,
//! could then still answer from another test's compiler or fake `hdc`, and a
//! lock it let go of could read as held. So the daemon's unit tests
//! (`src/main.rs`), which listen and take kernel locks in parallel, start no
//! child; every test that does — a compiler, a fake `hdc` run directly or
//! through the daemon's HDC dispatch — is here instead, and each takes
//! [`turn`] first, so that no two of them overlap.
//!
//! The daemon is a binary, so the modules these tests drive are compiled into
//! this one from its own sources (`#[path]`), as the daemon compiles them,
//! with every module they name; their unit tests are declared by
//! `src/main.rs` alone. Host tests only: every HDC here is a fake, and
//! nothing installed is read or written.
#![cfg(target_os = "macos")]

use std::sync::{Mutex, MutexGuard, PoisonError};

/// One test at a time; see the binary's documentation.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

// The daemon's modules, from its sources. The tests drive part of each.
#[allow(dead_code)]
#[path = "../../src/app_ingress.rs"]
mod app_ingress;
#[allow(dead_code)]
#[path = "../../src/bootstrap_readers.rs"]
mod bootstrap_readers;
#[allow(dead_code)]
#[path = "../../src/facade.rs"]
mod facade;
#[allow(dead_code)]
#[path = "../../src/facade_owners.rs"]
mod facade_owners;
#[allow(dead_code)]
#[path = "../../src/host.rs"]
mod host;
#[allow(dead_code)]
#[path = "../../src/managed_hdc.rs"]
mod managed_hdc;

mod app_ingress_fake_hdc;
mod debug_read_control;
mod flash_host_facts_control;
mod managed_hdc_server;
mod target_observation_control;
mod trace_probe_control;

/// A module compiled here from the daemon's sources keeps no test beside it:
/// one would run in this binary as well, outside [`turn`], besides the
/// daemon's own unit tests.
#[test]
fn the_daemon_modules_compiled_here_keep_no_tests_beside_them() {
    let _turn = turn();
    for (module, source) in [
        ("app_ingress", include_str!("../../src/app_ingress.rs")),
        (
            "app_ingress/imports",
            include_str!("../../src/app_ingress/imports.rs"),
        ),
        (
            "app_ingress/jobs",
            include_str!("../../src/app_ingress/jobs.rs"),
        ),
        (
            "bootstrap_readers",
            include_str!("../../src/bootstrap_readers.rs"),
        ),
        ("facade", include_str!("../../src/facade.rs")),
        ("facade_owners", include_str!("../../src/facade_owners.rs")),
        ("host", include_str!("../../src/host.rs")),
        ("managed_hdc", include_str!("../../src/managed_hdc.rs")),
        (
            "managed_hdc_lifecycle",
            include_str!("../../src/managed_hdc_lifecycle.rs"),
        ),
    ] {
        let lines: Vec<&str> = source.lines().map(str::trim).collect();
        for (index, line) in lines.iter().enumerate() {
            assert!(!line.starts_with("#[test]"), "{module} declares a test");
            let test_only = line.starts_with("#[cfg(test)]") || line.starts_with("#[cfg(all(test");
            let module_follows = lines[index + 1..]
                .iter()
                .find(|next| !next.starts_with("#["))
                .is_some_and(|next| next.starts_with("mod ") || next.contains(" mod "));
            assert!(
                !(test_only && module_follows),
                "{module} declares a test module"
            );
        }
    }
}
