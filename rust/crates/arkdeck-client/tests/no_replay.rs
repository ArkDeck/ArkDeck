use arkdeck_client::{Client, ClientError, read_frame};
use arkdeck_contract::*;
use serde_json::{Value, json};
use std::io::{self, Cursor, Read, Write};
use std::sync::{Arc, Mutex};

struct Stream {
    input: Cursor<Vec<u8>>,
    sent: Arc<Mutex<Vec<u8>>>,
}
impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.input.read(buf)
    }
}
impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.sent.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn health() -> Value {
    json!({"id":"health","ok":true,"result":{"status":"ok","protocolVersion":PROTOCOL_VERSION,
    "contractIdentity":CONTRACT_IDENTITY,"catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}})
}
fn client(frames: &[Value]) -> (Client<Stream>, Arc<Mutex<Vec<u8>>>) {
    let sent = Arc::new(Mutex::new(Vec::new()));
    let input = frames
        .iter()
        .flat_map(|v| encode_frame(v, MAX_RESPONSE_BYTES).unwrap())
        .collect();
    (
        Client::new(Stream {
            input: Cursor::new(input),
            sent: Arc::clone(&sent),
        }),
        sent,
    )
}
fn methods(sent: &Arc<Mutex<Vec<u8>>>) -> Vec<String> {
    String::from_utf8(sent.lock().unwrap().clone())
        .unwrap()
        .lines()
        .map(|line| {
            serde_json::from_str::<Value>(line).unwrap()["method"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect()
}

#[test]
fn business_frame_follows_valid_health_on_the_same_connection() {
    let (mut client, sent) = client(&[
        health(),
        json!({"id":"one","ok":true,"result":[]}),
        json!({"id":"two","ok":true,"result":[]}),
    ]);
    assert_eq!(
        client.request("one", "operation.list", None).unwrap(),
        json!([])
    );
    client.request("two", "operation.list", None).unwrap();
    assert_eq!(
        methods(&sent),
        ["health", "operation.list", "operation.list"]
    );
}

#[test]
fn every_health_mismatch_sends_zero_business_frames_and_poisoned_connection_cannot_retry() {
    for (field, value) in [
        ("contractIdentity", json!("wrong")),
        ("protocolVersion", json!("2.0.0")),
        ("publishedMethods", json!(["health"])),
        ("catalogDigest", json!("invalid")),
        ("status", json!("starting")),
        ("providers", json!([""])),
    ] {
        let mut response = health();
        response["result"][field] = value;
        let (mut client, sent) = client(&[response]);
        assert!(matches!(
            client.request("one", "operation.list", None),
            Err(ClientError::Contract(_))
        ));
        assert!(matches!(
            client.request("two", "operation.list", None),
            Err(ClientError::ConnectionUnusable)
        ));
        assert_eq!(methods(&sent), ["health"]);
    }
}

#[test]
fn lost_reply_is_never_replayed_or_reconnected() {
    let (mut client, sent) = client(&[health()]);
    assert!(matches!(
        client.request("one", "operation.list", None),
        Err(ClientError::Transport(_))
    ));
    assert!(matches!(
        client.request("one", "operation.list", None),
        Err(ClientError::ConnectionUnusable)
    ));
    assert_eq!(methods(&sent), ["health", "operation.list"]);
}

#[test]
fn reconnect_requires_a_new_health_exchange() {
    for _ in 0..2 {
        let (mut client, sent) = client(&[health(), json!({"id":"one","ok":true,"result":[]})]);
        client.request("one", "operation.list", None).unwrap();
        assert_eq!(methods(&sent), ["health", "operation.list"]);
    }
}

#[test]
fn invalid_local_input_and_reply_identity_fail_without_new_business_dispatch() {
    let (mut client, sent) = client(&[health(), json!({"id":"wrong","ok":true,"result":[]})]);
    assert!(client.request("bad\nid", "operation.list", None).is_err());
    assert!(methods(&sent).is_empty());
    assert!(matches!(
        client.request("one", "operation.list", None),
        Err(ClientError::Contract(_))
    ));
    assert_eq!(methods(&sent), ["health", "operation.list"]);
}

#[test]
fn bounded_reader_requires_lf_and_preserves_the_next_frame() {
    let mut reader = io::BufReader::new(Cursor::new(b"{}\n[]\n"));
    assert_eq!(read_frame(&mut reader, 3).unwrap(), b"{}");
    assert_eq!(read_frame(&mut reader, 3).unwrap(), b"[]");
    for bytes in [b"{}".as_slice(), b"{} \n", b"xxxxxxx"] {
        assert!(read_frame(&mut Cursor::new(bytes), 3).is_err());
    }
}
