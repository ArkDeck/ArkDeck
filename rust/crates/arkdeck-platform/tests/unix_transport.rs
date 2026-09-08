#![cfg(unix)]

use arkdeck_platform::{
    LocalConnection, LocalEndpoint, LocalListener, ServerIdentity, random_bytes,
};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::PathBuf;
use std::time::Duration;

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let nonce = u64::from_le_bytes(random_bytes().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-{nonce:016x}"));
        Self(path)
    }
    fn endpoint(&self) -> LocalEndpoint {
        LocalEndpoint::new(self.0.join("control.sock"))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn private_socket_authenticates_both_ends_and_streams_frames() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    assert_eq!(fs::metadata(&directory.0).unwrap().mode() & 0o777, 0o700);
    assert_eq!(
        fs::metadata(endpoint.as_path()).unwrap().mode() & 0o777,
        0o600
    );
    let task = std::thread::spawn(move || {
        let mut accepted = listener.accept().unwrap();
        let mut bytes = [0; 6];
        accepted.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"first\n");
        accepted.write_all(b"reply\n").unwrap();
    });
    let mut client =
        LocalConnection::connect(&endpoint, &ServerIdentity::new("/unused/on/unix")).unwrap();
    client.write_all(b"first\n").unwrap();
    let mut reply = [0; 6];
    client.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"reply\n");
    task.join().unwrap();
    assert!(!endpoint.as_path().exists());
}

#[test]
fn existing_endpoint_is_never_unlinked_or_adopted() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let listener = LocalListener::bind(&endpoint).unwrap();
    let before = fs::metadata(endpoint.as_path()).unwrap().ino();
    assert!(LocalListener::bind(&endpoint).is_err());
    assert_eq!(fs::metadata(endpoint.as_path()).unwrap().ino(), before);
    drop(listener);
}

#[test]
fn unsafe_existing_parent_is_refused_without_chmod() {
    let directory = Directory::new();
    fs::create_dir(&directory.0).unwrap();
    fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(LocalListener::bind(&directory.endpoint()).is_err());
    assert_eq!(fs::metadata(&directory.0).unwrap().mode() & 0o777, 0o755);
}

#[test]
fn symlink_parent_and_relaxed_socket_permissions_are_refused() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let listener = LocalListener::bind(&endpoint).unwrap();
    let link = Directory::new();
    symlink(&directory.0, &link.0).unwrap();
    assert!(LocalConnection::connect(&link.endpoint(), &ServerIdentity::new("/unused")).is_err());
    fs::remove_file(&link.0).unwrap();
    fs::set_permissions(endpoint.as_path(), fs::Permissions::from_mode(0o660)).unwrap();
    assert!(LocalConnection::connect(&endpoint, &ServerIdentity::new("/unused")).is_err());
    drop(listener);
}

#[test]
fn listener_drop_does_not_remove_a_replacement_inode() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let listener = LocalListener::bind(&endpoint).unwrap();
    fs::remove_file(endpoint.as_path()).unwrap();
    fs::write(endpoint.as_path(), b"replacement").unwrap();
    drop(listener);
    assert_eq!(fs::read(endpoint.as_path()).unwrap(), b"replacement");
}

#[test]
fn socket_read_is_bounded_by_the_client_deadline() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let task = std::thread::spawn(move || {
        let _connection = listener.accept().unwrap();
        std::thread::sleep(Duration::from_millis(150));
    });
    let mut client = LocalConnection::connect(&endpoint, &ServerIdentity::new("/unused")).unwrap();
    client
        .set_read_timeout(Some(Duration::from_millis(20)))
        .unwrap();
    let error = client.read(&mut [0; 1]).unwrap_err();
    assert!(matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    ));
    task.join().unwrap();
}
