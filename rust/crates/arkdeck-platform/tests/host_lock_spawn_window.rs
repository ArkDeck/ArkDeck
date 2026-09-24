//! A child that another thread spawns shares every open file description of
//! this process until its exec closes the close-on-exec descriptors, so a
//! lock released only by closing its descriptor stays held through that
//! child for the window. `HostReadLock` unlocks before it closes, which
//! releases the lock for every reference at once, and so does the facade's
//! lock on its transport directory, its refusals included. These tests spawn
//! children, so they have this test binary to themselves: every other test's
//! locks would be shared too.
#![cfg(target_os = "macos")]
use arkdeck_platform::{HostDirectory, HostReadLock, LocalEndpoint, LocalListener, random_bytes};
use std::fs::{self, File, TryLockError};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};

const NAME: &str = "owner.lock";

/// Each child shares every descriptor of this process, another test's locks
/// included; one test at a time keeps each test's children its own.
static SERIAL: Mutex<()> = Mutex::new(());

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        Self::at(std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-lock-spawn-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        )))
    }
    /// A root short enough for a socket's name to fit `sun_path`.
    fn transport() -> Self {
        Self::at(PathBuf::from(format!(
            "/private/tmp/adfl-{:016x}",
            u64::from_le_bytes(random_bytes().unwrap())
        )))
    }
    fn at(root: PathBuf) -> Self {
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }
    /// The lock file through a new open file description, as a second owner
    /// opens it.
    fn open(&self) -> File {
        File::options()
            .read(true)
            .write(true)
            .open(self.0.join(NAME))
            .unwrap()
    }
    /// One non-blocking attempt from a new open file description.
    fn refuses_one_attempt(&self) -> bool {
        matches!(self.open().try_lock(), Err(TryLockError::WouldBlock))
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
/// but does not exec until it is dropped.
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

/// Another thread spawning children one after another until the flag is
/// set, each delaying its exec by 2 ms as a loaded host would; how many it
/// spawned.
fn spawn_in_a_loop() -> (Arc<AtomicBool>, JoinHandle<u32>) {
    let stop = Arc::new(AtomicBool::new(false));
    let spawner = {
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            let mut spawned = 0_u32;
            while !stop.load(Ordering::Relaxed) {
                let mut command = Command::new("/usr/bin/true");
                // SAFETY: poll is async-signal-safe; the forked child only
                // delays its exec by 2 ms.
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
    (stop, spawner)
}

/// Every entry point that takes an existing owner lock; `None` is its
/// refusal.
fn reacquire(root: &HostDirectory, entry: usize) -> Option<HostReadLock> {
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
fn a_lock_released_while_a_forked_child_shares_it_is_free_at_once() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    drop(root.lock_document(NAME).unwrap());
    // Control: a lock released only by closing stays held through the child.
    let closed_only = fixture.open();
    closed_only.try_lock().unwrap();
    let child = HeldChild::start();
    drop(closed_only);
    assert!(
        fixture.refuses_one_attempt(),
        "closing alone must leave the lock with the child"
    );
    drop(child);
    assert!(
        !fixture.refuses_one_attempt(),
        "the child's exec releases it"
    );
    for entry in 0..3 {
        let held = reacquire(&root, entry).expect("the lock is free");
        let child = HeldChild::start();
        drop(held);
        assert!(
            !fixture.refuses_one_attempt(),
            "entry {entry}: a released owner lock stayed held by a forked child"
        );
        assert!(reacquire(&root, entry).is_some(), "entry {entry}");
        drop(child);
    }
}

#[test]
fn a_live_owner_keeps_its_lock_while_children_come_and_go() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    let held = root.lock_document(NAME).unwrap();
    // A child that shared the descriptor and then exec'd leaves the owner's
    // lock in place: only the owner's own release unlocks it.
    drop(HeldChild::start());
    let refused = root
        .lock_document(NAME)
        .err()
        .expect("a live owner holds it");
    assert_eq!(
        (refused.kind(), refused.raw_os_error()),
        (io::ErrorKind::WouldBlock, Some(libc::EWOULDBLOCK))
    );
    assert!(root.try_lock_existing(NAME).unwrap().is_none());
    assert!(root.try_lock_existing_strict(NAME).unwrap().is_none());
    assert!(fixture.refuses_one_attempt());
    drop(held);
    assert!(reacquire(&root, 0).is_some());
}

#[test]
fn drop_and_reopen_survive_children_another_thread_spawns_in_a_loop() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::new();
    let root = HostDirectory::open(&fixture.0).unwrap();
    drop(root.lock_document(NAME).unwrap());
    let (stop, spawner) = spawn_in_a_loop();
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

/// The facade refuses a live transport after taking its directory's lock,
/// and lets go of that lock with the refusal even while a child another
/// thread spawns shares the descriptor: the next facade, or the next claim
/// of the daemon's own transport, is never refused because of it.
#[test]
fn a_refused_facade_bind_lets_go_of_its_transport_directory_while_children_are_spawned() {
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let fixture = Fixture::transport();
    let endpoint = LocalEndpoint::new(fixture.0.join("agentd.sock"));
    // A live listener at the transport's name, which every bind refuses.
    let live = UnixListener::bind(endpoint.as_path()).unwrap();
    fs::set_permissions(endpoint.as_path(), fs::Permissions::from_mode(0o600)).unwrap();
    live.set_nonblocking(true).unwrap();
    let (stop, spawner) = spawn_in_a_loop();
    let mut held = 0;
    for _ in 0..20_000 {
        let refusal = LocalListener::bind_facade(&endpoint)
            .err()
            .expect("the transport is live");
        if refusal.to_string() == "another facade owns the public transport directory" {
            held += 1;
        } else {
            assert_eq!(
                refusal.to_string(),
                "public transport endpoint is already occupied"
            );
        }
        // Each refusal's probe waits in the accept queue; none may fill it.
        while live.accept().is_ok() {}
        let probe = File::open(&fixture.0).unwrap();
        match probe.try_lock() {
            // The probe lets go the same way, or it would hold the lock itself.
            Ok(()) => probe.unlock().unwrap(),
            Err(TryLockError::WouldBlock) => held += 1,
            Err(error) => panic!("{error:?}"),
        }
    }
    stop.store(true, Ordering::Relaxed);
    let spawned = spawner.join().unwrap();
    assert!(spawned > 0);
    assert_eq!(
        held, 0,
        "the transport directory stayed locked {held} times after 20000 refusals while \
         {spawned} children were spawned"
    );
}
