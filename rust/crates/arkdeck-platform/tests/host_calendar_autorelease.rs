//! The Gregorian calendar helpers leave nothing behind on the calling
//! thread. Foundation autoreleases a date-components object for each
//! decomposition, and a Rust thread has no autorelease pool of its own: until
//! each call drained its own, every object stayed allocated until the thread
//! exited, which a Runtime owner's thread does not do (TASK-XPA-025 soak).
//! This file holds one test so that no other test allocates while it counts.
#![cfg(target_os = "macos")]

use arkdeck_platform::{host_gregorian_add_days, host_gregorian_seconds, host_gregorian_timestamp};

const CALLS: i64 = 10_000;

fn blocks_in_use() -> i64 {
    let mut statistics = libc::malloc_statistics_t {
        blocks_in_use: 0,
        size_in_use: 0,
        max_size_in_use: 0,
        size_allocated: 0,
    };
    // SAFETY: a null zone sums every malloc zone into this live structure.
    unsafe { libc::malloc_zone_statistics(std::ptr::null_mut(), &mut statistics) };
    i64::from(statistics.blocks_in_use)
}

/// Heap blocks still allocated after `CALLS` calls on a fresh thread, counted
/// before that thread exits, since its exit would drain an implicit pool.
fn retained_blocks(call: impl Fn() + Send) -> i64 {
    std::thread::scope(|scope| {
        scope
            .spawn(move || {
                // The first call fills one-time caches, such as calendar data.
                call();
                let before = blocks_in_use();
                for _ in 0..CALLS {
                    call();
                }
                blocks_in_use() - before
            })
            .join()
            .unwrap()
    })
}

#[test]
fn calendar_calls_drain_what_they_autorelease() {
    let at = host_gregorian_seconds(2026, 7, 17, 8, 0, 0).unwrap();
    for (name, retained) in [
        (
            "host_gregorian_add_days",
            retained_blocks(|| {
                host_gregorian_add_days(at, 30).unwrap();
            }),
        ),
        (
            "host_gregorian_timestamp",
            retained_blocks(|| {
                host_gregorian_timestamp(at).unwrap();
            }),
        ),
        (
            "host_gregorian_seconds",
            retained_blocks(|| {
                host_gregorian_seconds(2026, 7, 17, 8, 0, 0).unwrap();
            }),
        ),
    ] {
        // An undrained call keeps two blocks: 20,000 here. The allowance
        // absorbs only one-time allocations, never one block per call.
        assert!(
            retained < CALLS / 10,
            "{name} kept {retained} heap blocks after {CALLS} calls"
        );
    }
}
