//! A child that another thread spawns shares every open file description of
//! this process until its exec closes the close-on-exec descriptors, so a
//! host-store lock this process has just released can still be held by that
//! child for the window. These tests spawn children, so they have this test
//! binary to themselves: every other test's locks would be shared too.
#![cfg(target_os = "macos")]
use arkdeck_platform::{HostDirectory, random_bytes};
use std::fs::{self, File, TryLockError};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const NAME: &str = "owner.lock";

/// Each child shares every descriptor of this process, another test's locks
/// included; one test at a time keeps each test's timing its own.
static SERIAL: Mutex<()> = Mutex::new(());

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-lock-spawn-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }
    /// One non-blocking attempt from a new open file description, as a
    /// second owner would make it.
    fn refuses_one_attempt(&self) -> bool {
        let file = File::options()
            .read(true)
            .write(true)
            .open(self.0.join(NAME))
            .unwrap();
        matches!(file.try_lock(), Err(TryLockError::WouldBlock))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn pipe() -> (OwnedFd, OwnedFd) {
    let mut descriptors = [-1; 2];
    // SAFETY: two writable descriptor slots.
    assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
    for descriptor in descriptors {
        // SAFETY: a live descriptor; only its close-on-exec flag changes.
        assert_eq!(
            unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    // SAFETY: pipe returned two new descriptors, each owned once here.
    unsafe {
        (
            OwnedFd::from_raw_fd(descriptors[0]),
            OwnedFd::from_raw_fd(descriptors[1]),
        )
    }
}

/// A child that has forked, and so shares every descriptor of this process,
/// but does not exec until it is released (by drop, at the latest).
struct HeldChild {
    release: Option<OwnedFd>,
    spawner: Option<JoinHandle<()>>,
}
impl HeldChild {
    fn start() -> Self {
        let (forked, forked_signal) = pipe();
        let (release_wait, release) = pipe();
        let (signal, wait) = (forked_signal.as_raw_fd(), release_wait.as_raw_fd());
        let spawner = thread::spawn(move || {
            let mut command = Command::new("/usr/bin/true");
            // SAFETY: runs in the forked child before exec and calls only the
            // async-signal-safe write and read on descriptors it inherited.
            unsafe {
                command.pre_exec(move || {
                    let mut byte = 0_u8;
                    libc::write(signal, (&raw const byte).cast(), 1);
                    while libc::read(wait, (&raw mut byte).cast(), 1) < 0 {}
                    Ok(())
                });
            }
            assert!(command.status().unwrap().success());
            // Both ends stay open until the child has exec'd.
            drop((forked_signal, release_wait));
        });
        let mut byte = 0_u8;
        // SAFETY: one byte into a live local from a live descriptor.
        let read = unsafe { libc::read(forked.as_raw_fd(), (&raw mut byte).cast(), 1) };
        assert_eq!(read, 1, "the child must have forked");
        Self {
            release: Some(release),
            spawner: Some(spawner),
        }
    }
}
impl Drop for HeldChild {
    /// Lets the child exec and waits until it has exited.
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            let byte = 0_u8;
            // SAFETY: one byte from a live local to a live descriptor.
            unsafe { libc::write(release.as_raw_fd(), (&raw const byte).cast(), 1) };
        }
        if let Some(spawner) = self.spawner.take() {
            let _ = spawner.join();
        }
    }
}

/// Every entry point that takes an existing owner lock; `None` is its
/// refusal.
fn reacquire(root: &HostDirectory, entry: usize) -> Option<arkdeck_platform::HostReadLock> {
    match entry {
        0 => match root.lock_document(NAME) {
            Ok(lock) => Some(lock),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => None,
            Err(error) => panic!("lock_document: {error}"),
        },
        1 => root.try_lock_existing(NAME).unwrap(),
        _ => root.try_lock_existing_strict(NAME).unwrap(),
    }
}

#[test]
fn a_released_lock_a_forked_child_still_shares_is_reacquired_once_the_child_execs() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    for entry in 0..3 {
        let held = root.lock_document(NAME).unwrap();
        let child = HeldChild::start();
        drop(held);
        // Released here, the lock is still held through the child's copy
        // of the descriptor: one non-blocking attempt is refused.
        assert!(fixture.refuses_one_attempt(), "entry {entry}");
        let releaser = thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            drop(child);
        });
        let started = Instant::now();
        let reacquired = reacquire(&root, entry);
        let waited = started.elapsed();
        releaser.join().unwrap();
        assert!(
            reacquired.is_some(),
            "entry {entry} refused after {waited:?}"
        );
        assert!(
            waited >= Duration::from_millis(90),
            "entry {entry} acquired before the child exec'd: {waited:?}"
        );
    }
}

#[test]
fn a_live_second_owner_is_still_refused_once_the_wait_has_passed() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    let held = root.lock_document(NAME).unwrap();
    let started = Instant::now();
    let refused = root
        .lock_document(NAME)
        .err()
        .expect("a live owner holds it");
    assert_eq!(
        (refused.kind(), refused.raw_os_error()),
        (io::ErrorKind::WouldBlock, Some(libc::EWOULDBLOCK))
    );
    assert!(started.elapsed() >= HostDirectory::LOCK_WAIT);
    for entry in 1..3 {
        let started = Instant::now();
        assert!(reacquire(&root, entry).is_none(), "entry {entry}");
        assert!(
            started.elapsed() >= HostDirectory::LOCK_WAIT,
            "entry {entry}"
        );
    }
    drop(held);
    assert!(reacquire(&root, 0).is_some());
}

#[test]
fn drop_and_reopen_survive_children_another_thread_spawns_in_a_loop() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    drop(root.lock_document(NAME).unwrap());
    let stop = Arc::new(AtomicBool::new(false));
    let spawner = {
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            let mut spawned = 0_u32;
            while !stop.load(Ordering::Relaxed) {
                let mut command = Command::new("/usr/bin/true");
                // SAFETY: poll is async-signal-safe; the forked child only
                // delays its exec by 2 ms, as a loaded host would.
                unsafe {
                    command.pre_exec(|| {
                        libc::poll(std::ptr::null_mut(), 0, 2);
                        Ok(())
                    });
                }
                assert!(command.status().unwrap().success());
                spawned += 1;
            }
            spawned
        })
    };
    let mut refused = 0;
    for iteration in 0..20_000 {
        if reacquire(&root, iteration % 3).is_none() {
            refused += 1;
        }
    }
    stop.store(true, Ordering::Relaxed);
    let spawned = spawner.join().unwrap();
    assert!(spawned > 0);
    assert_eq!(
        refused, 0,
        "{refused} of 20000 reacquisitions refused while {spawned} children were spawned"
    );
}
