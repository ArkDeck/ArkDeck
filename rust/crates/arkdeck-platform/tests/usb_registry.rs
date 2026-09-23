//! The host's I/O Registry through the platform census, read-only. The USB
//! device census answers whether or not a DAYU200 is attached (with one, what
//! it lists is still not device evidence), and the census reads numbers,
//! booleans and strings from the host's real USB host controllers.
//!
//! It then measures what repeated censuses leave behind on a thread that has
//! no autorelease pool of its own, as a Runtime owner's thread has none: heap
//! blocks and Mach port names, over `WARM_UP` unmeasured and `MEASURED`
//! measured batches of `CALLS` censuses each. Each census is measured, and so
//! is each kind of property read on its own, so that any growth names the
//! read that causes it. A control that churns the heap from Rust alone is
//! measured the same way and only reported.
//!
//! A census takes the same path over the same registry on every call, so
//! whatever it kept it would keep on every call: at least `CALLS` in every
//! batch. The ownership mutants in the run record kept 2,000 to 8,000 per
//! batch. Hence two rules:
//!
//! - (a) no measured batch keeps `CALLS / 2` or more, which leaves twice the
//!   margin below per-call retention;
//! - (b) the growth stops: some measured batch keeps fewer than `CALLS / 100`.
//!   A leak grows in every batch at its rate, whereas what the system fills
//!   on first use stops growing, and an allocator's own bookkeeping moves both
//!   ways.
//!
//! The per-batch figures go to the job's log on every run, passing or not, so
//! each host's numbers are on record: libtest captures only the print macros.
//! This file holds one test so that no other test allocates while it counts.
#![cfg(target_os = "macos")]

use arkdeck_platform::{RegistryEntry, RegistryValue, registry_census, usb_host_devices};
use std::ffi::CStr;
use std::io::Write;

const CALLS: i64 = 2_000;
const WARM_UP: usize = 3;
const MEASURED: usize = 6;
const CONTROLLERS: &CStr = c"AppleUSBHostController";

/// Heap blocks and bytes in use across every malloc zone.
fn heap_in_use() -> (i64, i64) {
    let mut statistics = libc::malloc_statistics_t {
        blocks_in_use: 0,
        size_in_use: 0,
        max_size_in_use: 0,
        size_allocated: 0,
    };
    // SAFETY: a null zone sums every malloc zone into this live structure.
    unsafe { libc::malloc_zone_statistics(std::ptr::null_mut(), &mut statistics) };
    (
        i64::from(statistics.blocks_in_use),
        statistics.size_in_use as i64,
    )
}

/// How many port names this task holds: a registry reference a census kept
/// would be one more each time.
fn port_names() -> i64 {
    unsafe extern "C" {
        static mach_task_self_: u32;
        fn mach_port_names(
            task: u32,
            names: *mut *mut u32,
            names_count: *mut u32,
            types: *mut *mut u32,
            types_count: *mut u32,
        ) -> i32;
        fn vm_deallocate(task: u32, address: usize, size: usize) -> i32;
    }
    let (mut names, mut names_count) = (std::ptr::null_mut(), 0_u32);
    let (mut types, mut types_count) = (std::ptr::null_mut(), 0_u32);
    // SAFETY: this task's own name space into live outputs; the kernel
    // allocates both arrays out of line, and they are deallocated at their
    // reported sizes before returning.
    unsafe {
        let task = mach_task_self_;
        let status = mach_port_names(
            task,
            &mut names,
            &mut names_count,
            &mut types,
            &mut types_count,
        );
        assert_eq!(status, 0, "mach_port_names");
        vm_deallocate(task, names as usize, names_count as usize * 4);
        vm_deallocate(task, types as usize, types_count as usize * 4);
    }
    i64::from(names_count)
}

/// A census to measure, named for the report.
type Measured = (&'static str, Box<dyn Fn() + Sync>);

/// What one measured batch left behind.
#[derive(Clone, Copy)]
struct Kept {
    blocks: i64,
    bytes: i64,
    ports: i64,
}

/// What each of `MEASURED` consecutive batches of `CALLS` censuses left
/// behind on a fresh thread, counted before that thread exits (its exit would
/// drain an implicit pool), after `WARM_UP` unmeasured batches that absorb
/// what the system caches on first use.
fn batches(census: &(dyn Fn() + Sync)) -> Vec<Kept> {
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let batch = || {
                    for _ in 0..CALLS {
                        census();
                    }
                };
                for _ in 0..WARM_UP {
                    batch();
                }
                let mut kept = Vec::with_capacity(MEASURED);
                let (mut blocks, mut bytes) = heap_in_use();
                let mut ports = port_names();
                for _ in 0..MEASURED {
                    batch();
                    let (now_blocks, now_bytes) = heap_in_use();
                    let now_ports = port_names();
                    kept.push(Kept {
                        blocks: now_blocks - blocks,
                        bytes: now_bytes - bytes,
                        ports: now_ports - ports,
                    });
                    (blocks, bytes, ports) = (now_blocks, now_bytes, now_ports);
                }
                kept
            })
            .join()
            .unwrap()
    })
}

/// A line for the job's log whether or not the test passes: written to the
/// standard error stream itself, which libtest does not capture.
fn report(line: &str) {
    let _ = writeln!(std::io::stderr(), "usb_registry: {line}");
}

/// A census of the host's USB host controllers doing `read` with each entry.
fn controller_census(read: impl Fn(&dyn RegistryEntry)) -> usize {
    registry_census(CONTROLLERS, |entry| {
        read(entry);
        Some(())
    })
    .expect("the USB host controller census answers")
    .len()
}

/// Everything the census reads from each USB host controller: a string, a
/// number and a boolean the controllers carry, a device's serial they do not
/// carry, and the registry entry ID.
fn controller_reads(entry: &dyn RegistryEntry) {
    let _ = (
        entry.property("IOClass"),
        entry.property("locationID"),
        entry.property("kUSBSleepSupported"),
        entry.property("USB Serial Number"),
        entry.registry_entry_id(),
    );
}

#[test]
fn the_host_registry_is_read_without_holding_anything() {
    // The USB device census answers on any host; what it lists is this
    // host's, never a fixture and never acceptance.
    let devices = usb_host_devices().expect("the USB device census answers");
    for device in &devices {
        assert_eq!(
            device
                .topology
                .parse::<u64>()
                .map(|value| value.to_string()),
            Ok(device.topology.clone())
        );
        assert_ne!(device.registry_entry_id, Some(0));
    }
    let boards = devices
        .iter()
        .filter(|device| device.vendor_id == 0x2207 && device.product_id == 0x5000)
        .count();
    if boards == 0 {
        report(&format!(
            "skipped: no DAYU200 (2207:5000) is attached; the census listed {} USB device(s)",
            devices.len()
        ));
    } else {
        report(&format!(
            "{boards} DAYU200 (2207:5000) listed among {} USB device(s): a host-only read, not \
             device evidence",
            devices.len()
        ));
    }

    // Real entries through the same reads: a string, a number and a boolean
    // come back as such, a property an entry lacks as none.
    let controllers = registry_census(CONTROLLERS, |entry| {
        Some((
            entry.property("IOClass"),
            entry.property("locationID"),
            entry.property("kUSBSleepSupported"),
            entry.property("USB Serial Number"),
            entry.registry_entry_id(),
        ))
    })
    .expect("the USB host controller census answers");
    report(&format!(
        "read {} USB host controller(s)",
        controllers.len()
    ));
    for (class, location, sleep, serial, id) in &controllers {
        assert!(
            matches!(class, Some(RegistryValue::Text(name)) if !name.is_empty()),
            "{class:?}"
        );
        assert!(
            matches!(location, None | Some(RegistryValue::Number(_))),
            "{location:?}"
        );
        assert!(
            matches!(sleep, None | Some(RegistryValue::Number(0 | 1))),
            "{sleep:?}"
        );
        assert_eq!(*serial, None, "a controller has no device serial");
        assert!(id.is_some_and(|id| id != 0), "{id:?}");
    }

    // The production census, the controller census, each kind of read on its
    // own, and the control.
    let judged: [Measured; 8] = [
        (
            "usb_host_devices",
            Box::new(|| {
                usb_host_devices().unwrap();
            }),
        ),
        (
            "controllers, every read",
            Box::new(|| {
                controller_census(controller_reads);
            }),
        ),
        (
            "controllers, enumeration only",
            Box::new(|| {
                controller_census(|_| {});
            }),
        ),
        (
            "controllers, string IOClass",
            Box::new(|| {
                controller_census(|entry| {
                    let _ = entry.property("IOClass");
                });
            }),
        ),
        (
            "controllers, number locationID",
            Box::new(|| {
                controller_census(|entry| {
                    let _ = entry.property("locationID");
                });
            }),
        ),
        (
            "controllers, boolean kUSBSleepSupported",
            Box::new(|| {
                controller_census(|entry| {
                    let _ = entry.property("kUSBSleepSupported");
                });
            }),
        ),
        (
            "controllers, absent USB Serial Number",
            Box::new(|| {
                controller_census(|entry| {
                    let _ = entry.property("USB Serial Number");
                });
            }),
        ),
        (
            "controllers, registry entry ID",
            Box::new(|| {
                controller_census(|entry| {
                    let _ = entry.registry_entry_id();
                });
            }),
        ),
    ];
    let describe = |name: &str, kept: &[Kept]| {
        let blocks: Vec<i64> = kept.iter().map(|batch| batch.blocks).collect();
        let bytes: Vec<i64> = kept.iter().map(|batch| batch.bytes).collect();
        let ports: Vec<i64> = kept.iter().map(|batch| batch.ports).collect();
        format!(
            "{name}: per {CALLS} censuses after {WARM_UP} warm-up batches, heap blocks \
             {blocks:?} (bytes {bytes:?}), port names {ports:?}"
        )
    };
    let control = batches(&|| {
        let blocks: Vec<Vec<u8>> = (0..8).map(|size| vec![0_u8; 16 << (size % 4)]).collect();
        std::hint::black_box(blocks);
    });
    report(&describe("control, Rust heap churn only", &control));
    let mut failures = Vec::new();
    for (name, census) in &judged {
        let kept = batches(census.as_ref());
        report(&describe(name, &kept));
        for (counter, counts) in [
            (
                "heap blocks",
                kept.iter().map(|batch| batch.blocks).collect::<Vec<_>>(),
            ),
            (
                "port names",
                kept.iter().map(|batch| batch.ports).collect::<Vec<_>>(),
            ),
        ] {
            // (a) Per-call retention keeps at least CALLS in every batch.
            if counts.iter().any(|count| *count >= CALLS / 2) {
                failures.push(format!(
                    "(a) {name} kept {counts:?} {counter}: a batch reached half of one per \
                     census"
                ));
            }
            // (b) A leak keeps growing in every batch; a first-use fill stops.
            if counts.iter().all(|count| *count >= CALLS / 100) {
                failures.push(format!(
                    "(b) {name} kept {counts:?} {counter}: it grew in every batch, as a \
                     leak does"
                ));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
