//! Shared local control transport. The production binary and isolated soak
//! use this exact serving/drain implementation; no Host or device composition
//! is exported by this library.
#[cfg(unix)]
mod drain;
use arkdeck_contract::MAX_REQUEST_BYTES;
use arkdeck_control::{Control, HostServices};
#[cfg(unix)]
use arkdeck_platform::ListenerLock;
use arkdeck_platform::{LocalConnection, LocalListener, read_frame};
use std::io::{self, BufReader, Write};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;

/// The listener lock remains owned after drain so the composition decides
/// when a successor may bind. A fixture must refuse to reopen if incomplete.
pub struct DrainOutcome {
    #[cfg(unix)]
    pub listener_lock: Arc<ListenerLock>,
    pub complete: bool,
}

/// Serve the existing authenticated control protocol until the caller's stop
/// source ends acceptance. Production supplies StopSignal; an isolated owner
/// cycle supplies its private Latch. Neither path changes framing or dispatch.
pub fn serve_control<H: HostServices + 'static>(
    mut listener: LocalListener,
    control: Arc<Control<H>>,
    mut accept: impl FnMut(&mut LocalListener) -> io::Result<Option<LocalConnection>>,
    connection_idle: Duration,
    _drain_timeout: Duration,
) -> io::Result<DrainOutcome> {
    let active = Arc::new(AtomicUsize::new(0));
    #[cfg(unix)]
    let serving = Arc::new(drain::Serving::new()?);
    loop {
        let accepted = accept(&mut listener);
        let connection = match accepted {
            Ok(Some(connection)) => connection,
            // A stop was requested: nothing more is accepted.
            Ok(None) => break,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::PermissionDenied
                ) =>
            {
                continue;
            }
            Err(error) => {
                // Preserve the original accept error, but keep the generation
                // locked while any already accepted handler still owns state.
                #[cfg(unix)]
                serving.retain_listener_lock(Arc::new(listener.stop_listening()));
                return Err(error);
            }
        };
        if active.fetch_add(1, Ordering::AcqRel) >= 16 {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        #[cfg(unix)]
        let Some(registered) = serving.register(&connection) else {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        };
        let control = Arc::clone(&control);
        let active = Arc::clone(&active);
        #[cfg(unix)]
        let serving = Arc::clone(&serving);
        std::thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _active = Active(active);
            #[cfg(unix)]
            let _registered = registered;
            serve_connection(
                connection,
                control,
                #[cfg(unix)]
                serving,
                connection_idle,
            );
        });
    }
    #[cfg(unix)]
    {
        let listener_lock = Arc::new(listener.stop_listening());
        serving.retain_listener_lock(Arc::clone(&listener_lock));
        let complete = serving.drain(Instant::now() + _drain_timeout);
        Ok(DrainOutcome {
            listener_lock,
            complete,
        })
    }
    #[cfg(not(unix))]
    unreachable!("only a stop request ends accepting")
}

// Consuming these arguments here ensures all handler-owned Control/Host and
// connection resources are released before the outer registration reports done.
fn serve_connection<H: HostServices>(
    connection: LocalConnection,
    control: Arc<Control<H>>,
    #[cfg(unix)] serving: Arc<drain::Serving>,
    connection_idle: Duration,
) {
    if connection.set_read_timeout(Some(connection_idle)).is_err()
        || connection.set_write_timeout(Some(connection_idle)).is_err()
    {
        return;
    }
    let mut reader = BufReader::new(connection);
    // Bound a connection's work without rejecting the required health
    // followed by business exchange. A new connection reauthenticates.
    for _ in 0..128 {
        // The start of the next frame, or the drain ending this
        // connection (see `drain`), or the idle timeout.
        #[cfg(unix)]
        if reader.buffer().is_empty()
            && !matches!(
                reader
                    .get_ref()
                    .wait_readable(serving.closing(), connection_idle),
                Ok(arkdeck_platform::Readiness::Readable)
            )
        {
            return;
        }
        let frame = match read_frame(&mut reader, MAX_REQUEST_BYTES) {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                #[cfg(unix)]
                let _request = serving.request();
                let _ = reader.get_mut().write_all(&control.handle_frame(&[]));
                return;
            }
            Err(_) => return,
        };
        #[cfg(unix)]
        let _request = serving.request();
        #[cfg(target_os = "macos")]
        let foreground_console = reader
            .get_ref()
            .origin()
            .is_ok_and(|peer| peer.foreground_console);
        #[cfg(not(target_os = "macos"))]
        let foreground_console = false;
        let reply = control.handle_frame_with_console(&frame, foreground_console);
        if reader.get_mut().write_all(&reply).is_err() || reader.get_mut().flush().is_err() {
            return;
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod server_lifecycle_tests;
