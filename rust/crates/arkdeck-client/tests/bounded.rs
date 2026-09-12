#![cfg(unix)]

use arkdeck_client::{Client, ClientError};
use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS,
    PROTOCOL_VERSION, encode_frame, validate_method_value,
};
use arkdeck_platform::{LocalEndpoint, LocalListener, ServerIdentity, read_frame};
use serde_json::{Value, json};
use std::io::{self, BufReader, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::time::{Duration, Instant};

// The fixtures decide their outcomes by whole seconds of margin, not by the
// scheduler. Each `Delay::Pair` response waits RESPONSE_DELAY, and the client
// budget sits between one and two of them: one response fits, two do not. The
// earlier 250 ms / 400 ms pairing left a 150 ms window that the hosted macOS
// runner lost twice in one day (a per-IO read timing out, and a health reply
// exhausting the shared budget before the status request was sent).
const RESPONSE_DELAY: Duration = Duration::from_secs(2);
const CLIENT_BUDGET: Duration = Duration::from_secs(3);
// Eight chunks at this interval outlast the budget, so a partial read that
// renewed the deadline would let the chunked reply complete.
const CHUNK_INTERVAL: Duration = Duration::from_millis(500);
// Only bounds a hung fixture; it must outlast every client-side wait below.
const SERVER_READ_TIMEOUT: Duration = Duration::from_secs(15);

fn health() -> Value {
    json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
        "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,
        "providers":[],"publishedMethods":METHODS}})
}

#[derive(Clone, Copy)]
enum Delay {
    Pair,
    HealthChunks,
    StatusChunks,
    None,
}

fn exercise(delay: Delay, bounded: bool) {
    // Initialize the contract cache before timing transport delays. Otherwise
    // cold schema parsing can exhaust the health budget before the pair fixture
    // reaches the business request it is meant to test.
    validate_method_value("health", "result", &health()["result"]).unwrap();
    let suffix = arkdeck_platform::random_bytes::<8>().unwrap();
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "deadline-{}",
        suffix
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    ));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    let endpoint = LocalEndpoint::new(root.join("socket"));
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = BufReader::new(listener.accept().unwrap());
        stream
            .get_ref()
            .set_read_timeout(Some(SERVER_READ_TIMEOUT))
            .unwrap();
        let mut methods = Vec::new();
        for (index, response) in [
            health(),
            json!({"id":"one","ok":false,"error":{"code":"notFound","message":"no such Job"}}),
        ]
        .into_iter()
        .enumerate()
        {
            let Ok(frame) = read_frame(&mut stream, MAX_REQUEST_BYTES) else {
                break;
            };
            methods.push(serde_json::from_slice::<Value>(&frame).unwrap()["method"].clone());
            let bytes = encode_frame(&response, MAX_RESPONSE_BYTES).unwrap();
            if matches!(delay, Delay::Pair) {
                std::thread::sleep(RESPONSE_DELAY);
            }
            let chunked = matches!(
                (delay, index),
                (Delay::HealthChunks, 0) | (Delay::StatusChunks, 1)
            );
            if chunked {
                for chunk in bytes.chunks(bytes.len().div_ceil(8)) {
                    std::thread::sleep(CHUNK_INTERVAL);
                    if stream.get_mut().write_all(chunk).is_err() {
                        break;
                    }
                }
            } else {
                let _ = stream.get_mut().write_all(&bytes);
            }
        }
        // Closing a timed-out client with unread response bytes may yield
        // ConnectionReset on Linux rather than EOF. Neither permits another
        // health/business frame on the authenticated connection.
        let mut extra = Vec::new();
        if let Err(error) = stream.read_to_end(&mut extra) {
            assert_eq!(error.kind(), io::ErrorKind::ConnectionReset);
        }
        assert!(extra.is_empty(), "an expired request was replayed");
        methods
    });
    let start = Instant::now();
    let request = || Some(serde_json::from_value(json!({"jobId":"JOB-missing"})).unwrap());
    let identity = ServerIdentity::new("unused-on-unix");
    if bounded {
        let mut client = Client::connect_bounded(&endpoint, &identity, CLIENT_BUDGET).unwrap();
        let result = client.request("one", "job.status", request());
        if matches!(delay, Delay::None) {
            assert!(matches!(result, Err(ClientError::Remote(_))));
            // A completed response does not renew the original client's budget.
            std::thread::sleep(CLIENT_BUDGET + Duration::from_secs(1));
            assert!(matches!(client.request("two", "job.status", request()),
                Err(ClientError::Transport(ref e)) if e.kind() == io::ErrorKind::TimedOut));
        } else {
            assert!(
                matches!(result, Err(ClientError::Transport(ref e))
                if matches!(e.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)),
                "{result:?}"
            );
            // A deadline restarted by the status request would expire only
            // after RESPONSE_DELAY + CLIENT_BUDGET.
            assert!(
                start.elapsed() < RESPONSE_DELAY + CLIENT_BUDGET,
                "deadline was renewed"
            );
        }
        assert!(matches!(
            client.request("one", "job.status", request()),
            Err(ClientError::ConnectionUnusable)
        ));
        drop(client);
    } else {
        // Existing callers retain a fresh per-IO timeout, including health.
        let mut client = Client::connect(&endpoint, &identity, CLIENT_BUDGET).unwrap();
        assert!(matches!(
            client.request("one", "job.status", request()),
            Err(ClientError::Remote(_))
        ));
        assert!(start.elapsed() >= 2 * RESPONSE_DELAY);
        drop(client);
    }
    let methods = server.join().unwrap();
    assert_eq!(
        methods,
        if matches!(delay, Delay::HealthChunks) {
            vec![json!("health")]
        } else {
            vec![json!("health"), json!("job.status")]
        }
    );
    std::fs::remove_dir(&root).unwrap();
}

#[test]
fn health_and_status_share_one_budget_and_timeout_prevents_replay() {
    exercise(Delay::Pair, true);
}

#[test]
fn partial_reads_cannot_renew_health_or_status_deadline() {
    exercise(Delay::HealthChunks, true);
    exercise(Delay::StatusChunks, true);
}

#[test]
fn completed_request_does_not_renew_bounded_connection() {
    exercise(Delay::None, true);
}

#[test]
fn legacy_connect_keeps_its_original_per_io_behavior() {
    exercise(Delay::Pair, false);
}
