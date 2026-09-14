//! The HDC lifecycle executor's process part (SPK-6, TASK-XPA-016): the exact
//! restart and stop commands, the executable identity a launch-window audit
//! records, one launch per preparation, and the post-dispatch re-observation
//! that alone decides the outcome, judged as Swift's
//! `HDCProcessLifecycleExecutor` judges it. The tool is a fake `hdc` compiled
//! here from C: its `-m` server polls a marker file and ends when it appears;
//! its `kill -r` client writes the marker, waits for the port to free, and
//! starts a new server of the same executable in its own session; its
//! behaviour on `kill` is fixed at compile time. No real HDC is launched.
//! Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{LoopbackServerLease, ToolTermination, VerifiedTool};
use arkdeck_provider_hdc::{
    LifecycleAction, LifecycleBudget, LifecycleCommand, LifecycleOutcome, PostDispatchObservation,
    PreparedLifecycle, generation,
};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::ErrorKind;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// `KILL_MODE`: 0 acts, 1 exits 23, 2 writes stderr, 3 does nothing.
const FAKE_HDC: &str = r#"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef KILL_MODE
#define KILL_MODE 0
#endif
static int endpoint_port(const char *endpoint) {
    const char *colon = strrchr(endpoint, ':');
    return colon == NULL ? -1 : atoi(colon + 1);
}
static int listener_reachable(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    int connected = connect(fd, (struct sockaddr *)&address, sizeof address) == 0;
    close(fd);
    return connected;
}
static int serve(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 65;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 4) != 0) return 67;
    for (;;) {
        struct pollfd waiting = { fd, POLLIN, 0 };
        if (poll(&waiting, 1, 50) > 0) {
            int client = accept(fd, NULL, NULL);
            if (client >= 0) close(client);
        }
        if (access(MARKER_DIR "/stop", F_OK) == 0) return 0;
    }
}
int main(int argc, char **argv) {
    const char *endpoint = NULL;
    int foreground = 0, kill_command = 0, restart = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) endpoint = argv[++i];
        else if (strcmp(argv[i], "-m") == 0) foreground = 1;
        else if (strcmp(argv[i], "kill") == 0) kill_command = 1;
        else if (strcmp(argv[i], "-r") == 0) restart = 1;
    }
    if (endpoint == NULL) { fprintf(stderr, "unregistered fixture output\n"); return 23; }
    int port = endpoint_port(endpoint);
    if (port <= 0) return 64;
    if (foreground) return serve(port);
    if (!kill_command) { fprintf(stderr, "unregistered fixture output\n"); return 23; }
    if (KILL_MODE == 1) return 23;
    if (KILL_MODE == 2) { fprintf(stderr, "kill: unexpected condition\n"); return 0; }
    if (KILL_MODE == 3) return 0;
    int marker = open(MARKER_DIR "/stop", O_WRONLY | O_CREAT, 0600);
    if (marker < 0) return 66;
    close(marker);
    for (int i = 0; i < 200 && listener_reachable(port); i++) usleep(20000);
    if (!restart) return 0;
    unlink(MARKER_DIR "/stop");
    pid_t child = fork();
    if (child < 0) return 68;
    if (child == 0) {
        setsid();
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) { dup2(null, 0); dup2(null, 1); dup2(null, 2); if (null > 2) close(null); }
        char *server_argv[] = { (char *)SELF_PATH, "-s", (char *)endpoint, "-m", NULL };
        execv(SELF_PATH, server_argv);
        _exit(69);
    }
    return 0;
}
"#;

/// One compiled variant of the fake under its own canonical directory, with
/// its marker directory beside it.
struct FakeHdc {
    directory: PathBuf,
    binary: PathBuf,
    tool: VerifiedTool,
}

impl FakeHdc {
    fn compile(name: &str, kill_mode: u8) -> Self {
        let directory =
            std::env::temp_dir().join(format!("arkdeck-lifecycle-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let directory = directory.canonicalize().unwrap();
        let source = directory.join("fake-hdc.c");
        fs::write(&source, FAKE_HDC).unwrap();
        let binary = directory.join("hdc");
        let output = Command::new("cc")
            .arg("-O0")
            .arg("-o")
            .arg(&binary)
            .arg(&source)
            .arg(format!("-DKILL_MODE={kill_mode}"))
            .arg(format!("-DMARKER_DIR=\"{}\"", directory.display()))
            .arg(format!("-DSELF_PATH=\"{}\"", binary.display()))
            .output()
            .expect("cc from the developer tools compiles the fake");
        assert!(
            output.status.success(),
            "fake hdc did not compile: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&binary).unwrap()));
        let tool = VerifiedTool::open(&binary, &digest).unwrap();
        Self {
            directory,
            binary,
            tool,
        }
    }

    /// A server of the fake at the endpoint, started by the test as the
    /// daemon would have started it, and its confirmed generation.
    fn server(&self, endpoint: SocketAddrV4) -> (Server, u64) {
        let child = Command::new(&self.binary)
            .args(["-s", &endpoint.to_string(), "-m"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !reachable(endpoint) {
            assert!(Instant::now() < deadline, "the fake server never listened");
            std::thread::sleep(Duration::from_millis(20));
        }
        let lease = LoopbackServerLease::acquire(&self.tool, endpoint).unwrap();
        let expected = generation(lease.identity()).unwrap();
        (Server(child), expected)
    }
}

impl Drop for FakeHdc {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The server a restart started is nobody's child; it is ended by the PID
/// the lease proved a moment ago to be a listener of this test's own fake.
fn end_server(tool: &VerifiedTool, endpoint: SocketAddrV4) {
    if let Ok(lease) = LoopbackServerLease::acquire(tool, endpoint) {
        let _ = Command::new("/bin/kill")
            .args(["-9", &lease.identity().pid.to_string()])
            .status();
    }
}

fn free_endpoint() -> SocketAddrV4 {
    let port = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
}

fn reachable(endpoint: SocketAddrV4) -> bool {
    TcpStream::connect_timeout(&SocketAddr::V4(endpoint), Duration::from_millis(100)).is_ok()
}

fn budget() -> LifecycleBudget {
    LifecycleBudget {
        probe_deadline: Duration::from_secs(5),
        ..LifecycleBudget::default()
    }
}

#[test]
fn the_actual_command_and_the_launch_identity_are_swift_s() {
    let fake = FakeHdc::compile("facts", 0);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710);
    let restart = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
    assert_eq!(restart.arguments, ["-s", "127.0.0.1:8710", "kill", "-r"]);
    assert_eq!(restart.executable, fake.binary);
    let stop = LifecycleCommand::new(LifecycleAction::Stop, endpoint, &fake.tool);
    assert_eq!(stop.arguments, ["-s", "127.0.0.1:8710", "kill"]);
    let prepared = PreparedLifecycle::prepare(&fake.tool, restart.clone(), 1).unwrap();
    assert_eq!(prepared.command(), &restart);
    let identity = prepared.identity();
    let metadata = fs::metadata(&fake.binary).unwrap();
    use std::os::unix::fs::MetadataExt;
    assert_eq!(identity.authorized_path, fake.binary);
    assert_eq!(
        identity.inode_launch_path,
        format!("/.vol/{}/{}", metadata.dev(), metadata.ino())
    );
    assert_eq!(
        (identity.device, identity.inode),
        (metadata.dev(), metadata.ino())
    );
    assert_eq!(identity.file_size, metadata.len());
    assert_eq!(identity.mode & 0o777, 0o700);
    assert_eq!(identity.sha256, fake.tool.sha256());
}

#[test]
fn a_changed_executable_is_not_prepared() {
    let fake = FakeHdc::compile("changed", 0);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710);
    let command = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
    let mut bytes = fs::read(&fake.binary).unwrap();
    bytes.push(0);
    fs::write(&fake.binary, bytes).unwrap();
    let error = PreparedLifecycle::prepare(&fake.tool, command, 1)
        .err()
        .expect("a tool that no longer verifies is not prepared");
    assert_eq!(error.kind(), ErrorKind::PermissionDenied);
}

#[test]
fn a_confirmed_restart_succeeds_only_with_a_strictly_newer_generation() {
    let fake = FakeHdc::compile("restart", 0);
    let endpoint = free_endpoint();
    let (server, expected) = fake.server(endpoint);
    let old_pid = server.0.id();
    let command = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
    let receipt = PreparedLifecycle::prepare(&fake.tool, command, expected)
        .unwrap()
        .launch(&budget());
    let LifecycleOutcome::Succeeded {
        resulting_generation,
    } = &receipt.outcome
    else {
        panic!("expected the restart to succeed: {receipt:?}");
    };
    assert!(*resulting_generation > expected);
    assert_eq!(
        receipt.observation,
        Some(PostDispatchObservation::Generation(*resulting_generation))
    );
    assert_eq!(receipt.termination, Some(ToolTermination::Exited(0)));
    assert!(receipt.stdout.is_empty() && receipt.stderr.is_empty());
    let lease = LoopbackServerLease::acquire(&fake.tool, endpoint).unwrap();
    assert_ne!(u32::try_from(lease.identity().pid).unwrap(), old_pid);
    drop(server);
    end_server(&fake.tool, endpoint);
}

#[test]
fn a_confirmed_stop_ends_in_an_unavailable_endpoint() {
    let fake = FakeHdc::compile("stop", 0);
    let endpoint = free_endpoint();
    let (server, expected) = fake.server(endpoint);
    let command = LifecycleCommand::new(LifecycleAction::Stop, endpoint, &fake.tool);
    let receipt = PreparedLifecycle::prepare(&fake.tool, command, expected)
        .unwrap()
        .launch(&budget());
    assert_eq!(receipt.outcome, LifecycleOutcome::Stopped, "{receipt:?}");
    assert_eq!(
        receipt.observation,
        Some(PostDispatchObservation::Unavailable)
    );
    assert!(!reachable(endpoint));
    drop(server);
}

#[test]
fn a_nonzero_exit_leaves_the_outcome_unknown() {
    let fake = FakeHdc::compile("nonzero", 1);
    let endpoint = free_endpoint();
    let (server, expected) = fake.server(endpoint);
    let command = LifecycleCommand::new(LifecycleAction::Restart, endpoint, &fake.tool);
    let receipt = PreparedLifecycle::prepare(&fake.tool, command, expected)
        .unwrap()
        .launch(&LifecycleBudget {
            probe_deadline: Duration::from_millis(500),
            ..LifecycleBudget::default()
        });
    assert_eq!(
        receipt.outcome,
        LifecycleOutcome::OutcomeUnknown(
            "lifecycle launch window was entered and the process did not exit zero; post-dispatch state requires reconciliation".into()
        )
    );
    assert_eq!(receipt.termination, Some(ToolTermination::Exited(23)));
    assert_eq!(receipt.observation, None);
    drop(server);
}

#[test]
fn unregistered_stderr_leaves_the_outcome_unknown() {
    let fake = FakeHdc::compile("stderr", 2);
    let endpoint = free_endpoint();
    let (server, expected) = fake.server(endpoint);
    let command = LifecycleCommand::new(LifecycleAction::Stop, endpoint, &fake.tool);
    let receipt = PreparedLifecycle::prepare(&fake.tool, command, expected)
        .unwrap()
        .launch(&LifecycleBudget {
            probe_deadline: Duration::from_millis(500),
            ..LifecycleBudget::default()
        });
    assert_eq!(
        receipt.outcome,
        LifecycleOutcome::OutcomeUnknown(
            "lifecycle process emitted unregistered stderr; post-dispatch state is not trusted"
                .into()
        )
    );
    assert_eq!(receipt.stderr, b"kill: unexpected condition\n");
    drop(server);
}

#[test]
fn a_command_that_changes_nothing_cannot_be_re_proved() {
    let fake = FakeHdc::compile("noop", 3);
    let endpoint = free_endpoint();
    let (server, expected) = fake.server(endpoint);
    for action in [LifecycleAction::Restart, LifecycleAction::Stop] {
        let command = LifecycleCommand::new(action, endpoint, &fake.tool);
        let receipt = PreparedLifecycle::prepare(&fake.tool, command, expected)
            .unwrap()
            .launch(&LifecycleBudget {
                probe_deadline: Duration::from_millis(700),
                ..LifecycleBudget::default()
            });
        assert_eq!(
            receipt.outcome,
            LifecycleOutcome::OutcomeUnknown(
                "lifecycle process completed but server state could not be re-probed".into()
            ),
            "{action:?}"
        );
        assert_eq!(receipt.observation, None);
    }
    assert!(reachable(endpoint));
    drop(server);
}
