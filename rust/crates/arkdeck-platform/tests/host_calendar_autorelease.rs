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

/// Heap blocks left allocated by each of two consecutive batches of `CALLS`
/// calls on a fresh thread, counted before that thread exits (its exit would
/// drain an implicit pool). One batch runs first, unmeasured: it absorbs the
/// caches the system fills on first use, such as calendar and time-zone data.
/// Those do not recur, while anything a call keeps grows with every batch.
fn blocks_per_batch(call: impl Fn() + Send) -> [i64; 2] {
    std::thread::scope(|scope| {
        scope
            .spawn(move || {
                let batch = || {
                    for _ in 0..CALLS {
                        call();
                    }
                };
                batch();
                let start = blocks_in_use();
                batch();
                let middle = blocks_in_use();
                batch();
                [middle - start, blocks_in_use() - middle]
            })
            .join()
            .unwrap()
    })
}

#[test]
fn calendar_calls_drain_what_they_autorelease() {
    let at = host_gregorian_seconds(2026, 7, 17, 8, 0, 0).unwrap();
    for (name, [first, second]) in [
        (
            "host_gregorian_add_days",
            blocks_per_batch(|| {
                host_gregorian_add_days(at, 30).unwrap();
            }),
        ),
        (
            "host_gregorian_timestamp",
            blocks_per_batch(|| {
                host_gregorian_timestamp(at).unwrap();
            }),
        ),
        (
            "host_gregorian_seconds",
            blocks_per_batch(|| {
                host_gregorian_seconds(2026, 7, 17, 8, 0, 0).unwrap();
            }),
        ),
    ] {
        eprintln!("{name}: {first} then {second} heap blocks per {CALLS} calls");
        // An undrained call keeps two blocks, 20,000 per batch, in every
        // batch. The bound admits less than one block per hundred calls in
        // the later batch, after the warm-up and the first measured batch.
        assert!(
            second < CALLS / 100,
            "{name} kept {first} and then {second} heap blocks per {CALLS} calls"
        );
    }
}
