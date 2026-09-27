use super::*;
use arkdeck_contract::{DeviceObservationsResult, Request, WireError, encode_frame};
use arkdeck_control::HdcStatus;
use arkdeck_platform::{HostDirectory, HostReadLock, Latch, ServerIdentity};
use serde_json::{Map, Value, json};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::sync::{Mutex, mpsc};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_le_bytes(arkdeck_platform::random_bytes().unwrap());
        let path = PathBuf::from(format!("/private/tmp/ad-sock-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn endpoint(&self) -> arkdeck_platform::LocalEndpoint {
        arkdeck_platform::LocalEndpoint::new(self.0.join("control.sock"))
    }
    fn owner_lock(&self) -> io::Result<HostReadLock> {
        HostDirectory::open(&self.0)?.lock_document("owner.lock")
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct Host {
    owner_lock: Option<HostReadLock>,
    dropped: mpsc::Sender<()>,
    entered: mpsc::Sender<()>,
    release: Mutex<mpsc::Receiver<()>>,
}
impl Drop for Host {
    fn drop(&mut self) {
        drop(self.owner_lock.take());
        let _ = self.dropped.send(());
    }
}
impl HostServices for Host {
    fn observed_at(&self) -> String {
        "2026-09-27T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "fixture")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        unreachable!("lifecycle test uses no device API")
    }
    fn job_resource(&self, _: &str, _: &Map<String, Value>) -> Result<Value, WireError> {
        self.entered.send(()).unwrap();
        self.release
            .lock()
            .unwrap()
            .recv_timeout(Duration::from_secs(10))
            .unwrap();
        Err(WireError {
            code: "resourceNotFound".into(),
            message: "fixture".into(),
            details: None,
        })
    }
}
struct Running {
    stop: Arc<Latch>,
    release: mpsc::Sender<()>,
    entered: mpsc::Receiver<()>,
    dropped: mpsc::Receiver<()>,
    accepted: mpsc::Receiver<()>,
    thread: std::thread::JoinHandle<io::Result<DrainOutcome>>,
}
fn start(root: &Root, timeout: Duration, accept_error: Option<mpsc::Receiver<()>>) -> Running {
    let (release, released) = mpsc::channel();
    let (entry, entered) = mpsc::channel();
    let (dropper, dropped) = mpsc::channel();
    let (accepted_tx, accepted) = mpsc::channel();
    let host = Host {
        owner_lock: Some(root.owner_lock().unwrap()),
        dropped: dropper,
        entered: entry,
        release: Mutex::new(released),
    };
    let control = Arc::new(Control::new(host).unwrap());
    let listener = LocalListener::bind_facade(&root.endpoint()).unwrap();
    let stop = Arc::new(Latch::new().unwrap());
    let stop_thread = Arc::clone(&stop);
    let thread = std::thread::spawn(move || {
        let mut did_accept = false;
        serve_control(
            listener,
            control,
            |listener| {
                if did_accept && let Some(trigger) = &accept_error {
                    trigger.recv_timeout(Duration::from_secs(10)).unwrap();
                    return Err(io::Error::other("injected accept failure"));
                }
                let next = listener.accept_until_latch(&stop_thread)?;
                if next.is_some() {
                    did_accept = true;
                    accepted_tx.send(()).unwrap();
                }
                Ok(next)
            },
            Duration::from_secs(5),
            timeout,
        )
    });
    Running {
        stop,
        release,
        entered,
        dropped,
        accepted,
        thread,
    }
}
fn client(root: &Root) -> LocalConnection {
    let client =
        LocalConnection::connect(&root.endpoint(), &ServerIdentity::new("/unused")).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client
}
fn block_request(client: &mut LocalConnection) {
    let request = Request::new(
        "lifecycle",
        "job.status",
        Some(Map::from_iter([("jobId".into(), json!("fixture-job"))])),
    );
    client
        .write_all(&encode_frame(&request, MAX_REQUEST_BYTES).unwrap())
        .unwrap();
}
fn eventually_rebind(root: &Root) -> LocalListener {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match LocalListener::bind_facade(&root.endpoint()) {
            Ok(listener) => return listener,
            Err(error)
                if Instant::now() < deadline && error.kind() == io::ErrorKind::PermissionDenied =>
            {
                std::thread::yield_now();
            }
            Err(error) => panic!("old serving generation did not release its lock: {error}"),
        }
    }
}

#[test]
fn completed_drain_releases_real_host_resources_before_reopen() {
    let root = Root::new();
    let run = start(&root, Duration::from_secs(5), None);
    let mut client = client(&root);
    block_request(&mut client);
    run.entered.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(root.owner_lock().is_err());
    run.stop.set();
    run.release.send(()).unwrap();
    let outcome = run.thread.join().unwrap().unwrap();
    assert!(outcome.complete);
    // No waiting hides the old bug: complete must already imply Host::drop.
    run.dropped
        .try_recv()
        .expect("completed drain retained the old Control/Host");
    drop(
        root.owner_lock()
            .expect("completed drain still holds the actual owner lock"),
    );
    assert!(LocalListener::bind_facade(&root.endpoint()).is_err());
    drop(outcome);
    drop(LocalListener::bind_facade(&root.endpoint()).unwrap());
}

#[test]
fn timeout_keeps_generation_locked_until_the_blocked_handler_releases_its_owner() {
    let root = Root::new();
    let run = start(&root, Duration::ZERO, None);
    let mut client = client(&root);
    block_request(&mut client);
    run.entered.recv_timeout(Duration::from_secs(5)).unwrap();
    run.stop.set();
    let outcome = run.thread.join().unwrap().unwrap();
    assert!(!outcome.complete);
    drop(outcome);
    assert!(root.owner_lock().is_err());
    assert!(LocalListener::bind_facade(&root.endpoint()).is_err());
    assert!(run.dropped.try_recv().is_err());
    run.release.send(()).unwrap();
    drop(client);
    run.dropped.recv_timeout(Duration::from_secs(5)).unwrap();
    drop(root.owner_lock().unwrap());
    drop(eventually_rebind(&root));
}

#[test]
fn accept_error_preserves_the_error_and_keeps_the_live_generation_locked() {
    let root = Root::new();
    let (fail, failure) = mpsc::channel();
    let run = start(&root, Duration::from_secs(5), Some(failure));
    let mut client = client(&root);
    block_request(&mut client);
    run.entered.recv_timeout(Duration::from_secs(5)).unwrap();
    fail.send(()).unwrap();
    let result = run.thread.join().unwrap();
    assert!(matches!(result, Err(ref error) if error.to_string() == "injected accept failure"));
    assert!(root.owner_lock().is_err());
    assert!(LocalListener::bind_facade(&root.endpoint()).is_err());
    run.release.send(()).unwrap();
    drop(client);
    run.dropped.recv_timeout(Duration::from_secs(5)).unwrap();
    drop(eventually_rebind(&root));
}

#[test]
fn idle_and_partial_frames_are_closed_by_the_same_drain() {
    for bytes in [b"".as_slice(), b"{".as_slice()] {
        let root = Root::new();
        let run = start(&root, Duration::from_secs(5), None);
        let mut client = client(&root);
        client.write_all(bytes).unwrap();
        run.accepted.recv_timeout(Duration::from_secs(5)).unwrap();
        run.stop.set();
        let outcome = run.thread.join().unwrap().unwrap();
        assert!(outcome.complete);
        run.dropped
            .try_recv()
            .expect("idle/partial handler retained its owner");
        drop(outcome);
        drop(LocalListener::bind_facade(&root.endpoint()).unwrap());
    }
}
