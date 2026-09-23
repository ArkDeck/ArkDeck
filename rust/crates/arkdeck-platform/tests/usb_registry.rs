//! The host's I/O Registry through the platform census, read-only. The USB
//! device census answers whether or not a DAYU200 is attached (with one, what
//! it lists is still not device evidence); the census reads numbers, booleans
//! and strings from the host's real USB host controllers; and repeated
//! censuses leave neither heap blocks nor Mach port names behind on a thread
//! that has no autorelease pool of its own, which a Runtime owner's does not.
//! This file holds one test so that no other test allocates while it counts.
#![cfg(target_os = "macos")]

use arkdeck_platform::{RegistryValue, registry_census, usb_host_devices};

const CALLS: i64 = 2_000;

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

/// Heap blocks and port names left by each of two consecutive batches of
/// `CALLS` censuses on a fresh thread, counted before that thread exits (its
/// exit would drain an implicit pool). One batch runs first, unmeasured, to
/// absorb what the system caches on first use; anything a census keeps grows
/// with every batch.
fn growth_per_batch(census: impl Fn() + Send) -> [(i64, i64); 2] {
    std::thread::scope(|scope| {
        scope
            .spawn(move || {
                let batch = || {
                    for _ in 0..CALLS {
                        census();
                    }
                };
                batch();
                let start = (blocks_in_use(), port_names());
                batch();
                let middle = (blocks_in_use(), port_names());
                batch();
                let end = (blocks_in_use(), port_names());
                [
                    (middle.0 - start.0, middle.1 - start.1),
                    (end.0 - middle.0, end.1 - middle.1),
                ]
            })
            .join()
            .unwrap()
    })
}

/// Everything the census reads from each USB host controller: a string, a
/// number and a boolean the controllers carry, the USB keys they do not
/// (a device's), and the registry entry ID.
type ControllerRead = (
    Option<RegistryValue>,
    Option<RegistryValue>,
    Option<RegistryValue>,
    Option<RegistryValue>,
    Option<u64>,
);

fn controller_census() -> Vec<ControllerRead> {
    registry_census(c"AppleUSBHostController", |entry| {
        Some((
            entry.property("IOClass"),
            entry.property("locationID"),
            entry.property("kUSBSleepSupported"),
            entry.property("USB Serial Number"),
            entry.registry_entry_id(),
        ))
    })
    .expect("the USB host controller census answers")
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
        eprintln!(
            "skipped: no DAYU200 (2207:5000) is attached; the census listed {} USB device(s)",
            devices.len()
        );
    } else {
        eprintln!(
            "{boards} DAYU200 (2207:5000) listed among {} USB device(s): a host-only read, not \
             device evidence",
            devices.len()
        );
    }

    // Real entries through the same reads: a string, a number and a boolean
    // come back as such, a property an entry lacks as none.
    let controllers = controller_census();
    if controllers.is_empty() {
        eprintln!("skipped: this host lists no USB host controller");
    } else {
        eprintln!("read {} USB host controller(s)", controllers.len());
    }
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

    for (name, [first, second]) in [
        (
            "usb_host_devices",
            growth_per_batch(|| {
                usb_host_devices().unwrap();
            }),
        ),
        (
            "the USB host controller census",
            growth_per_batch(|| {
                controller_census();
            }),
        ),
    ] {
        eprintln!(
            "{name}: {} then {} heap blocks, {} then {} port names per {CALLS} censuses",
            first.0, second.0, first.1, second.1
        );
        // A census that kept its iterator, an entry, a key or a value would
        // keep at least one of them per call: CALLS per batch, in every batch.
        assert!(
            second.0 < CALLS / 100,
            "{name} kept {} and then {} heap blocks per {CALLS} censuses",
            first.0,
            second.0
        );
        assert!(
            second.1 < CALLS / 100,
            "{name} kept {} and then {} port names per {CALLS} censuses",
            first.1,
            second.1
        );
    }
}
