//! What the serving loop's stop waits for, as Swift's `drainAndStop` does:
//! the frames being answered, each counted from the moment a complete frame
//! has been read until its reply is written or fails to be, and the
//! connections still open, each with a handle that ends it from outside the
//! thread serving it.
//!
//! Swift ends an idle connection with `shutdown(SHUT_RDWR)` alone. That was
//! seen not to wake a read blocked on the socket on the macOS 26 CI runner
//! (#2004's first run), so a connection's thread here waits for the start of
//! its next frame on the socket and on the drain's `closing` latch together,
//! and the drain sets the latch as it shuts the connections down.
use arkdeck_platform::{ConnectionCloser, Latch, LocalConnection};
use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

pub(crate) struct Serving {
    state: Mutex<State>,
    changed: Condvar,
    closing: Latch,
}

#[derive(Default)]
struct State {
    requests: usize,
    next: u64,
    connections: HashMap<u64, ConnectionCloser>,
}

/// One open connection, let go of when its thread drops it.
pub(crate) struct Registered {
    serving: Arc<Serving>,
    id: u64,
}

/// One frame being answered.
pub(crate) struct Request {
    serving: Arc<Serving>,
}

impl Serving {
    pub(crate) fn new() -> io::Result<Self> {
        Ok(Self {
            state: Mutex::default(),
            changed: Condvar::new(),
            closing: Latch::new()?,
        })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Set once the drain ends the open connections.
    pub(crate) fn closing(&self) -> &Latch {
        &self.closing
    }

    /// Swift `register`: the loop registers each connection it accepted
    /// before a thread serves it. A connection no second handle can be made
    /// for is not served.
    pub(crate) fn register(self: &Arc<Self>, connection: &LocalConnection) -> Option<Registered> {
        let closer = connection.closer().ok()?;
        let mut state = self.state();
        let id = state.next;
        state.next += 1;
        state.connections.insert(id, closer);
        Some(Registered {
            serving: Arc::clone(self),
            id,
        })
    }

    /// Swift `beginRequest`, ended by dropping the request (`finishRequest`).
    pub(crate) fn request(self: &Arc<Self>) -> Request {
        self.state().requests += 1;
        Request {
            serving: Arc::clone(self),
        }
    }

    /// Swift `drainAndStop` once its listener is closed: waits until no frame
    /// is being answered, ends every open connection, idle ones included,
    /// and waits until each has been let go — all within one deadline, past
    /// which it returns with whatever is still running.
    pub(crate) fn drain(&self, deadline: Instant) {
        let mut state = self.state();
        while state.requests > 0 {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            state = self
                .changed
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        self.closing.set();
        for closer in state.connections.values() {
            closer.close();
        }
        while !state.connections.is_empty() {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            state = self
                .changed
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl Drop for Registered {
    fn drop(&mut self) {
        self.serving.state().connections.remove(&self.id);
        self.serving.changed.notify_all();
    }
}

impl Drop for Request {
    fn drop(&mut self) {
        self.serving.state().requests -= 1;
        self.serving.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_platform::{LocalEndpoint, LocalListener, Readiness, ServerIdentity, random_bytes};
    use std::io::Read;
    use std::path::PathBuf;
    use std::time::Duration;

    struct Directory(PathBuf);
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A served connection pair: the daemon's end and the client's.
    fn pair() -> (Directory, LocalConnection, LocalConnection) {
        let nonce = u64::from_le_bytes(random_bytes().unwrap());
        let directory = Directory(
            std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("ad-drain-{nonce:016x}")),
        );
        let endpoint = LocalEndpoint::new(directory.0.join("control.sock"));
        let mut listener = LocalListener::bind(&endpoint).unwrap();
        let client = LocalConnection::connect(&endpoint, &ServerIdentity::new("/unused")).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let served = listener.accept().unwrap();
        (directory, served, client)
    }

    #[test]
    fn a_drain_waits_for_the_frame_being_answered_then_ends_idle_connections() {
        let serving = Arc::new(Serving::new().unwrap());
        let (_directory, served, mut client) = pair();
        let registered = serving.register(&served).unwrap();
        let request = serving.request();
        let waiting = Arc::clone(&serving);
        let answering = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            drop(request);
            // The connection's thread then waits for its next frame, as the
            // serving loop does, until the drain ends the connection.
            let readiness = served
                .wait_readable(waiting.closing(), Duration::from_secs(20))
                .unwrap();
            drop(served);
            drop(registered);
            readiness
        });
        let started = Instant::now();
        serving.drain(Instant::now() + Duration::from_secs(20));
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(250), "{waited:?}");
        assert!(waited < Duration::from_secs(10), "{waited:?}");
        assert_eq!(answering.join().unwrap(), Readiness::Latched);
        let mut rest = Vec::new();
        client.read_to_end(&mut rest).unwrap();
        assert!(rest.is_empty());
        assert!(serving.state().connections.is_empty());
    }

    #[test]
    fn a_connection_waits_for_its_next_frame_or_its_end() {
        use std::io::Write;
        let serving = Serving::new().unwrap();
        let (_directory, served, mut client) = pair();
        assert_eq!(
            served
                .wait_readable(serving.closing(), Duration::from_millis(100))
                .unwrap(),
            Readiness::TimedOut
        );
        client.write_all(b"{").unwrap();
        assert_eq!(
            served
                .wait_readable(serving.closing(), Duration::from_secs(10))
                .unwrap(),
            Readiness::Readable
        );
        serving.closing().set();
        assert!(serving.closing().is_set());
        // A set latch is seen first, even beside unread bytes, and stays set.
        for _ in 0..2 {
            assert_eq!(
                served
                    .wait_readable(serving.closing(), Duration::from_secs(10))
                    .unwrap(),
                Readiness::Latched
            );
        }
    }

    #[test]
    fn a_drain_returns_at_its_deadline_with_work_still_running() {
        let serving = Arc::new(Serving::new().unwrap());
        let (_directory, served, _client) = pair();
        let _registered = serving.register(&served).unwrap();
        let _request = serving.request();
        let started = Instant::now();
        serving.drain(Instant::now() + Duration::from_millis(200));
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(200), "{waited:?}");
        assert!(waited < Duration::from_secs(10), "{waited:?}");
        assert_eq!(serving.state().requests, 1);
    }
}
