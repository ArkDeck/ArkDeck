//! macOS transport facade. No handlers, durable owners, retries or response cache.
use arkdeck_contract::{
    ContractError, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, Response, decode_request, encode_frame,
    sha256_hex, strict_json,
};
use arkdeck_platform::{
    LocalConnection, LocalEndpoint, LocalListener, PeerOrigin, ServerIdentity, listen_mach,
    random_bytes, read_frame,
};
use serde::Serialize;
use serde_json::json;
use std::{
    fs,
    io::{self, BufReader, IoSlice, Write},
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

const APP_REQUIREMENT: &str = "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" and identifier \"com.arkdeck.desktop\"";

pub fn swift_executable() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("ARKDECK_SWIFT_DAEMON") {
        return Some(path.into());
    }
    let executable = std::env::current_exe().ok()?;
    (executable.file_name()? == "arkdeck-facade")
        .then(|| executable.with_file_name("arkdeck-agentd"))
}

struct Forwarder {
    endpoint: LocalEndpoint,
    identity: ServerIdentity,
    secret: String,
}
impl Forwarder {
    fn connect(&self) -> io::Result<BufReader<LocalConnection>> {
        let mut socket = LocalConnection::connect(&self.endpoint, &self.identity)?;
        socket.set_write_timeout(Some(Duration::from_secs(20)))?;
        // job.run can legitimately outlive an ordinary control request.
        socket.set_read_timeout(Some(Duration::from_secs(4 * 60 * 60 + 300)))?;
        let pairing = encode_frame(&json!({"arkdeckPairing":1,"secret":self.secret}), 1024)
            .map_err(io::Error::other)?;
        socket.write_all(&pairing)?;
        Ok(BufReader::new(socket))
    }
}

fn failure(id: &str, code: &str, message: &str) -> Vec<u8> {
    encode_frame(
        &Response::failure(id, code, message).value(),
        MAX_RESPONSE_BYTES,
    )
    .expect("bounded transport refusal")
}
fn validate(frame: &[u8]) -> Result<String, Vec<u8>> {
    match decode_request(frame) {
        Ok(request) => Ok(request.id),
        Err(error) => {
            let (code, message) = match error {
                ContractError::UnsupportedVersion => (
                    "unsupportedProtocolVersion",
                    "this Runtime requires exactly 1.0.0",
                ),
                ContractError::ContractMismatch => (
                    "unsupportedProtocolVersion",
                    "client and Runtime must use the same current control contract",
                ),
                ContractError::UnknownMethod => {
                    ("unknownMethod", "method is not published by this Runtime")
                }
                _ => ("malformedFrame", "undecodable current request frame"),
            };
            let value = strict_json(frame).ok();
            let id = if matches!(
                error,
                ContractError::UnsupportedVersion
                    | ContractError::ContractMismatch
                    | ContractError::UnknownMethod
            ) {
                value.as_ref().and_then(|v| v["id"].as_str()).unwrap_or("")
            } else {
                ""
            };
            Err(failure(id, code, message))
        }
    }
}
#[derive(Serialize)]
struct Origin<'a> {
    #[serde(rename = "arkdeckOrigin")]
    version: u8,
    transport: &'a str,
    #[serde(rename = "foregroundConsole")]
    foreground_console: bool,
    #[serde(rename = "peerEUID")]
    peer_euid: u32,
    #[serde(rename = "peerPID")]
    peer_pid: i32,
    #[serde(rename = "frameSHA256")]
    frame_sha256: String,
}

fn exchange(
    reader: &mut BufReader<LocalConnection>,
    frame: &[u8],
    peer: PeerOrigin,
    transport: &str,
) -> io::Result<Vec<u8>> {
    let origin = encode_frame(
        &Origin {
            version: 1,
            transport,
            foreground_console: peer.foreground_console,
            peer_euid: peer.euid,
            peer_pid: peer.pid,
            frame_sha256: sha256_hex(frame),
        },
        1024,
    )
    .map_err(io::Error::other)?;
    // A partial write is already an ambiguous interruption. No error produced
    // below carries details.phase/newDispatchCount, and no request is retried.
    // One vectored write avoids waking Swift for an origin whose frame has
    // not arrived yet. Partial writes advance only over bytes already sent.
    let mut slices = [
        IoSlice::new(&origin),
        IoSlice::new(frame),
        IoSlice::new(b"\n"),
    ];
    let mut remaining = &mut slices[..];
    while !remaining.is_empty() {
        match reader.get_mut().write_vectored(remaining) {
            Ok(0) => return Err(io::Error::from(io::ErrorKind::WriteZero)),
            Ok(count) => IoSlice::advance_slices(&mut remaining, count),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    let mut response = read_frame(reader, MAX_RESPONSE_BYTES)?;
    // Do not parse, normalize, cache or rewrite the authority's response bytes.
    response.push(b'\n');
    Ok(response)
}
fn interrupted(id: &str) -> Vec<u8> {
    failure(
        id,
        "runtimeUnavailable",
        "Runtime transport interrupted; read job.status/job.list before another submission; no request was replayed",
    )
}

pub fn serve(swift: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().len() != 1 {
        return Err("facade accepts no request or device arguments".into());
    }
    if std::env::var_os("ARKDECK_SWIFT_DAEMON").is_none() {
        let expected = std::env::var("ARKDECK_SWIFT_SHA256")
            .map_err(|_| "paired Swift identity missing; run runtime service update")?;
        if sha256_hex(&fs::read(&swift)?) != expected {
            return Err("paired Swift identity changed; run runtime service update".into());
        }
    }
    let public = match std::env::var_os("ARKDECK_ENDPOINT") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME unavailable")?)
            .join("Library/Application Support/ArkDeck/Agentd/agentd.sock"),
    };
    let parent = public.parent().ok_or("public socket parent absent")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let mut listener = LocalListener::bind_facade(&LocalEndpoint::new(public.clone()))?;
    let nonce = random_bytes::<16>()?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let private = PathBuf::from("/private/tmp").join(format!("arkdeck-facade-{nonce}"));
    fs::DirBuilder::new().mode(0o700).create(&private)?;
    struct Directory(PathBuf);
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir(&self.0);
        }
    }
    let _directory = Directory(private.clone());
    let secret = random_bytes::<32>()?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let endpoint = LocalEndpoint::new(private.join("swift.sock"));
    let mut command = Command::new(&swift);
    command
        .env("ARKDECK_PRIVATE_SOCKET", endpoint.as_path())
        .stdin(Stdio::piped());
    // Only local host composition inputs. Never forward client argv or wire fields.
    if std::env::var_os("ARKDECK_ENDPOINT").is_some() {
        command.arg("--state-dir").arg(parent);
    }
    let mut child = command.spawn()?;
    let mut lifetime = child.stdin.take().ok_or("pairing pipe unavailable")?;
    lifetime.write_all(secret.as_bytes())?;
    lifetime.write_all(b"\n")?;
    let forwarder = Arc::new(Forwarder {
        endpoint,
        identity: ServerIdentity::new(&swift),
        secret,
    });
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        if child.try_wait()?.is_some() {
            return Err("Swift authority failed to start".into());
        }
        if forwarder.connect().is_ok() {
            break;
        }
        if Instant::now() >= deadline {
            return Err("Swift private socket startup timed out".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    // Keep the pairing pipe open for exactly the facade lifetime. EOF also
    // handles SIGKILL, which cannot run a Rust destructor or retry a frame.
    std::thread::spawn(move || {
        let _lifetime = lifetime;
        let _ = child.wait();
        std::process::exit(69);
    });
    if std::env::var_os("ARKDECK_ENDPOINT").is_none() {
        let forwarder = Arc::clone(&forwarder);
        listen_mach(
            "com.arkdeck.agentd",
            APP_REQUIREMENT,
            Box::new(move |frame, peer| {
                let id = match validate(frame) {
                    Ok(id) => id,
                    Err(reply) => return reply,
                };
                match forwarder
                    .connect()
                    .and_then(|mut private| exchange(&mut private, frame, peer, "appXPC"))
                {
                    Ok(reply) => reply,
                    Err(_) => interrupted(&id),
                }
            }),
        )?;
    }
    let active = Arc::new(AtomicUsize::new(0));
    loop {
        let socket = match listener.accept() {
            Ok(socket) => socket,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::PermissionDenied | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        if active.fetch_add(1, Ordering::AcqRel) >= 16 {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        let active = Arc::clone(&active);
        let forwarder = Arc::clone(&forwarder);
        std::thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _active = Active(active);
            let _ = socket.set_read_timeout(Some(Duration::from_secs(120)));
            let _ = socket.set_write_timeout(Some(Duration::from_secs(20)));
            let mut client = BufReader::new(socket);
            let mut private = None;
            loop {
                let frame = match read_frame(&mut client, MAX_REQUEST_BYTES) {
                    Ok(frame) => frame,
                    Err(e) if e.kind() == io::ErrorKind::InvalidData => {
                        let _ = client.get_mut().write_all(&failure(
                            "",
                            "malformedFrame",
                            "undecodable current request frame",
                        ));
                        return;
                    }
                    Err(_) => return,
                };
                let id = match validate(&frame) {
                    Ok(id) => id,
                    Err(reply) => {
                        if client.get_mut().write_all(&reply).is_err() {
                            return;
                        }
                        continue;
                    }
                };
                let peer = match client.get_ref().origin() {
                    Ok(peer) => peer,
                    Err(_) => return,
                };
                if private.is_none() {
                    match forwarder.connect() {
                        Ok(connection) => private = Some(connection),
                        Err(_) => {
                            let _ = client.get_mut().write_all(&interrupted(&id));
                            return;
                        }
                    }
                }
                match exchange(
                    private.as_mut().expect("connected"),
                    &frame,
                    peer,
                    "unixSocket",
                ) {
                    Ok(response) => {
                        if client.get_mut().write_all(&response).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = client.get_mut().write_all(&interrupted(&id));
                        return;
                    }
                }
            }
        });
    }
}
