#[cfg(target_os = "macos")]
mod facade;
mod host;

use arkdeck_contract::MAX_REQUEST_BYTES;
use arkdeck_control::Control;
use arkdeck_platform::{LocalEndpoint, LocalListener, default_user_endpoint, read_frame};
use std::io::{self, BufReader, Write};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;

fn serve() -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    if let Some(swift) = facade::swift_executable() {
        return facade::serve(swift);
    }
    if std::env::args_os().len() != 1 {
        return Err("arkdeck-agentd takes no device, command, path or authority arguments; configure the local host environment".into());
    }
    let endpoint = match std::env::var_os("ARKDECK_ENDPOINT") {
        Some(path) => LocalEndpoint::new(path),
        None => default_user_endpoint()?,
    };
    let mut listener = LocalListener::bind(&endpoint)?;
    let control = Arc::new(Control::new(host::Host::from_environment())?);
    let active = Arc::new(AtomicUsize::new(0));
    loop {
        let connection = match listener.accept() {
            Ok(connection) => connection,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::PermissionDenied
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        if active.fetch_add(1, Ordering::AcqRel) >= 16 {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        let control = Arc::clone(&control);
        let active = Arc::clone(&active);
        std::thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _active = Active(active);
            if connection
                .set_read_timeout(Some(Duration::from_secs(20)))
                .is_err()
                || connection
                    .set_write_timeout(Some(Duration::from_secs(20)))
                    .is_err()
            {
                return;
            }
            let mut reader = BufReader::new(connection);
            // Bound a connection's work without rejecting the required health
            // followed by business exchange. A new connection reauthenticates.
            for _ in 0..128 {
                let frame = match read_frame(&mut reader, MAX_REQUEST_BYTES) {
                    Ok(frame) => frame,
                    Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                        let _ = reader.get_mut().write_all(&control.handle_frame(&[]));
                        return;
                    }
                    Err(_) => return,
                };
                let reply = control.handle_frame(&frame);
                if reader.get_mut().write_all(&reply).is_err() || reader.get_mut().flush().is_err()
                {
                    return;
                }
            }
        });
    }
}

fn main() {
    if let Err(error) = serve() {
        eprintln!("arkdeck-agentd: {error}");
        std::process::exit(69);
    }
}
