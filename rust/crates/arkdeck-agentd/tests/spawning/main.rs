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
//!
//! On Windows three things run here:
//! - the Flash host facts replay (TASK-XPA-010);
//! - a Flash Job planned, admitted, run and reconciled through the Host and
//!   Control over the Swift Flash run oracle's fake lane, with the fake HDC
//!   given through the test seam (`flash_execution_control.rs`, TASK-XPA-010),
//!   and the same Flash driven by the real CLI over the control pipe of a
//!   signed copy of this binary (`flash_socket_control.rs`);
//! - the signed test daemon (`signed_daemon.rs`, TASK-XPA-009), which this
//!   binary serves on a development root's pipe for the real CLI.
//!
//! Both use the shared fake's answers ported in process (`oracle_fake.rs`),
//! given to the Host through its test-only seam (`Host::with_test_hdc`). No
//! production Windows daemon composes an HDC until its tuple is registered.
#![cfg(any(target_os = "macos", windows))]

use std::sync::{Mutex, MutexGuard, PoisonError};

/// One test at a time; see the binary's documentation.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The daemon's unit tests beside a module compiled here run in its own test
/// build only (`src/main.rs`): here the block is nothing.
#[allow(unused_macros)]
macro_rules! daemon_unit_tests {
    ($($item:item)*) => {};
}

// The daemon's modules, from its sources. The tests drive part of each.
#[cfg(target_os = "macos")]
#[allow(dead_code)]
#[path = "../../src/app_ingress.rs"]
mod app_ingress;
#[allow(dead_code)]
#[path = "../../src/bootstrap_readers.rs"]
mod bootstrap_readers;
#[allow(dead_code)]
#[path = "../../src/host.rs"]
mod host;
#[allow(dead_code)]
#[path = "../../src/managed_hdc.rs"]
mod managed_hdc;
/// The shared fake HDC's answers in process (Windows cannot run its driver),
/// as the hoststore replays' support compiles them.
#[cfg(windows)]
use support::oracle_fake;
#[cfg(target_os = "macos")]
#[allow(dead_code)]
#[path = "../../src/tool_selection_startup.rs"]
mod tool_selection_startup;
// The Windows development root's lifecycle and composition, which the
// signed test daemon serves through (`signed_daemon.rs`), with every module
// it names.
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/arkforge_execution.rs"]
mod arkforge_execution;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/arkforge_lane.rs"]
mod arkforge_lane;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/code_sign_helper.rs"]
mod code_sign_helper;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/development_usb.rs"]
mod development_usb;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/hilog_summary_analyzer.rs"]
mod hilog_summary_analyzer;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/windows_hdc_gate.rs"]
mod windows_hdc_gate;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../src/windows_lifecycle.rs"]
mod windows_lifecycle;

#[cfg(target_os = "macos")]
mod app_ingress_fake_hdc;
#[cfg(target_os = "macos")]
mod debug_read_control;
#[cfg(target_os = "macos")]
mod flash_broker_control;
mod flash_execution_control;
mod flash_host_facts_control;
mod flash_socket_control;
#[cfg(windows)]
mod gj1_device_leaves;
#[cfg(windows)]
mod gj23_replay;
#[cfg(target_os = "macos")]
mod managed_hdc_server;
#[cfg(windows)]
mod signed_daemon;
/// The hoststore replays' support for the Swift oracles over the shared fake
/// HDC (rebuilding the oracle's root, its labels and what a replay compares),
/// which the GJ-2/3 replay through the signed test daemon shares.
#[cfg(windows)]
#[allow(unused_imports)]
#[path = "../../../arkdeck-hoststore/tests/support/mod.rs"]
mod support;
#[cfg(target_os = "macos")]
mod target_observation_control;
#[cfg(target_os = "macos")]
mod trace_probe_control;

/// A module compiled here from the daemon's sources keeps no test beside it:
/// one would run in this binary as well, outside [`turn`], besides the
/// daemon's own unit tests. A module keeps its unit tests beside it only
/// inside `daemon_unit_tests!`, which this binary expands to nothing; that
/// block is its last item.
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
        ("host", include_str!("../../src/host.rs")),
        ("managed_hdc", include_str!("../../src/managed_hdc.rs")),
        (
            "managed_hdc_lifecycle",
            include_str!("../../src/managed_hdc_lifecycle.rs"),
        ),
        (
            "arkforge_execution",
            include_str!("../../src/arkforge_execution.rs"),
        ),
        ("arkforge_lane", include_str!("../../src/arkforge_lane.rs")),
        (
            "code_sign_helper",
            include_str!("../../src/code_sign_helper.rs"),
        ),
        (
            "development_usb",
            include_str!("../../src/development_usb.rs"),
        ),
        (
            "hilog_summary_analyzer",
            include_str!("../../src/hilog_summary_analyzer.rs"),
        ),
        (
            "windows_hdc_gate",
            include_str!("../../src/windows_hdc_gate.rs"),
        ),
        (
            "windows_lifecycle",
            include_str!("../../src/windows_lifecycle.rs"),
        ),
    ] {
        let source = match source.find("\ndaemon_unit_tests! {\n") {
            Some(start) => {
                let block = &source[start..];
                let mut depth = 0_i32;
                let end = block
                    .char_indices()
                    .find(|&(_, c)| {
                        depth += match c {
                            '{' => 1,
                            '}' => -1,
                            _ => 0,
                        };
                        c == '}' && depth == 0
                    })
                    .map(|(end, _)| end)
                    .unwrap_or_else(|| panic!("{module}'s daemon_unit_tests! block is unclosed"));
                assert!(
                    block[end + 1..].trim().is_empty(),
                    "{module}'s daemon_unit_tests! block is its last item"
                );
                &source[..start]
            }
            None => source,
        };
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
