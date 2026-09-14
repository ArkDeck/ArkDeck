//! The file legs of `capture.diagnostics@1` driven through the real process
//! dispatch over the shared fake HDC driver: the argv each leg sends (read
//! back from the driver's log), the verdicts Swift reaches on the driver's
//! answers, the bytes a `file recv` leaves on the host and the verdict read
//! off them, a stale landing cleared before the transfer, and the sequence
//! rule — a capture whose tool exits non-zero still gets its readback.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    FileAction, FilePlan, HdcDispatch, ImageType, LivenessRequest, Outcome, OwnedRemoteDirectory,
    OwnedRemotePath, PNG_MAGIC, RECEIVE_MAXIMUM_BYTES, ReceiveArtifact, STDOUT_BUDGET,
    ScreenSequenceRequest, TraceRequest, run,
};
use common::{CONNECT_KEY, SharedFake};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// What the fake answers for these legs, by mode. Every readback is a fixed
/// `ls -l` line (or the not-found grammar in mode `missing`); `file recv`
/// writes a PNG-headed payload to the host path it is given (nothing in mode
/// `nothing`); `hitrace` exits non-zero in mode `traceFails`; the cleanup
/// listing still shows the directory in mode `residue`.
const ANSWERS: &str = r#"# capture.diagnostics@1 file-leg answers, by mode.
key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"-t $key shell uitest dumpLayout -p "*)
  printf 'DumpLayout saved to:%s\n' "$7" ;;
"-t $key shell snapshot_display -t "*)
  printf 'success\n' ;;
"-t $key shell hitrace -t "*)
  if [ "$mode" = traceFails ]; then exit 1; fi
  printf 'hitrace done\n' ;;
"-t $key shell ls -l "*)
  if [ "$mode" = missing ]; then
    printf 'ls: %s: No such file or directory\n' "$6"
  else
    printf '%s\n' "-rw-r--r-- 1 root root 4096 2026-07-31 00:00 $6"
  fi ;;
"-t $key shell ls -ld "*)
  if [ "$mode" = residue ]; then
    printf '%s\n' "drwxr-xr-x 2 root root 4096 2026-07-31 00:00 $6"
  else
    printf 'ls: %s: No such file or directory\n' "$6"
  fi ;;
"-t $key shell rm -f "*|"-t $key shell rmdir "*|"-t $key shell mkdir -p "*|"-t $key shell tar -c -f "*)
  ;;
"-t $key file recv "*)
  if [ "$mode" != nothing ]; then printf '\211PNG\r\n\032\n%s' received-bytes > "$6"; fi
  printf 'FileTransfer finish, Size:22\n' ;;
"-t $key shell hidumper -s 1201 -a -p Faultlogger -l")
  printf '******\ncppcrash-demo-1\n******\n' ;;
"-t $key shell pidof com.example.demo")
  printf '3421 3422\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac
"#;

fn verified(facts: &[(&str, &str)]) -> Outcome {
    Outcome::Verified(
        facts
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect::<BTreeMap<_, _>>(),
    )
}

/// The driver logs every call as its arguments each followed by U+001F.
fn logged(fake: &SharedFake) -> Vec<String> {
    String::from_utf8(fake.invocations())
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn line(arguments: &[&str]) -> String {
    arguments
        .iter()
        .map(|argument| format!("{argument}\u{1f}"))
        .collect()
}

fn execute(action: &FileAction, step_id: &str, fake: &SharedFake, host_root: &Path) -> Outcome {
    let plan = action.lower(step_id, Some(CONNECT_KEY), host_root).unwrap();
    let receipt = run(&plan, &fake.dispatch as &dyn HdcDispatch).unwrap();
    action.verify(&receipt, "2026-09-14T00:00:00Z")
}

#[test]
fn the_file_legs_send_swift_s_argv_and_are_judged_by_the_driver_s_readbacks() {
    let fake = SharedFake::with_answers(ANSWERS, None);
    let host_root = fake.root.join("host");
    let tree_path = OwnedRemotePath::stable("job-1", "capture-ui-tree", ImageType::Png).unwrap();
    let tree = FileAction::CaptureComponentTree {
        path: tree_path.clone(),
    };
    assert_eq!(
        execute(&tree, "capture-ui-tree", &fake, &host_root),
        verified(&[("remoteByteCount", "4096")])
    );
    assert_eq!(
        logged(&fake),
        vec![
            line(&[
                "-t",
                CONNECT_KEY,
                "shell",
                "uitest",
                "dumpLayout",
                "-p",
                &tree_path.remote_path
            ]),
            line(&[
                "-t",
                CONNECT_KEY,
                "shell",
                "ls",
                "-l",
                &tree_path.remote_path
            ]),
        ]
    );

    // The still, then its receive: the bytes the driver wrote land under
    // the remote basename and decide the verdict, magic included.
    fake.clear_invocations();
    let still_path =
        OwnedRemotePath::stable("job-1", "capture-screenshot", ImageType::Png).unwrap();
    let still = FileAction::CaptureScreenshot {
        image_type: ImageType::Png,
        path: still_path.clone(),
    };
    assert_eq!(
        execute(&still, "capture-screenshot", &fake, &host_root),
        verified(&[("remoteByteCount", "4096")])
    );
    let receive = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
        path: still_path.clone(),
        expected_sha256: None,
        maximum_bytes: RECEIVE_MAXIMUM_BYTES,
        expected_leading_bytes: Some(PNG_MAGIC.to_vec()),
    });
    let payload = [&PNG_MAGIC[..], b"received-bytes"].concat();
    let landed = host_root.join(still_path.basename());
    assert_eq!(
        execute(&receive, "receive-screenshot", &fake, &host_root),
        verified(&[
            ("localArtifact", still_path.basename()),
            ("byteCount", "22"),
            ("sha256", &format!("{:x}", Sha256::digest(&payload))),
        ])
    );
    assert_eq!(fs::read(&landed).unwrap(), payload);
    assert_eq!(
        logged(&fake)[2],
        line(&[
            "-t",
            CONNECT_KEY,
            "file",
            "recv",
            &still_path.remote_path,
            &landed.to_string_lossy(),
        ])
    );
    // A JPEG pin on PNG bytes is the wrong format, not an artifact.
    let wrong = FileAction::ReceiveOwnedArtifact(ReceiveArtifact {
        path: still_path.clone(),
        expected_sha256: None,
        maximum_bytes: RECEIVE_MAXIMUM_BYTES,
        expected_leading_bytes: Some(vec![0xFF, 0xD8, 0xFF, 0xE0]),
    });
    assert!(matches!(
        execute(&wrong, "receive-screenshot", &fake, &host_root),
        Outcome::Failed {
            code: "unexpectedFormat",
            ..
        }
    ));
    // Nothing lands: the stale file from the previous transfer is cleared
    // first, so the outcome is unknown rather than yesterday's bytes.
    fake.set_mode("nothing");
    assert!(landed.exists());
    assert!(matches!(
        execute(&receive, "receive-screenshot", &fake, &host_root),
        Outcome::Unknown(_)
    ));
    assert!(!landed.exists());

    // A readback that finds no file is unknown, never a clean failure.
    fake.set_mode("missing");
    assert!(matches!(
        execute(&tree, "capture-ui-tree", &fake, &host_root),
        Outcome::Unknown(_)
    ));

    // hitrace exits non-zero and the readback still runs and decides.
    fake.set_mode("traceFails");
    fake.clear_invocations();
    let trace_path = OwnedRemotePath::stable("job-1", "capture-trace", ImageType::Png).unwrap();
    let trace = FileAction::CaptureTrace {
        request: TraceRequest::new(2, vec!["ohos".into()], 8192, false, None).unwrap(),
        path: trace_path.clone(),
    };
    assert_eq!(
        execute(&trace, "capture-trace", &fake, &host_root),
        verified(&[("remoteByteCount", "4096")])
    );
    assert_eq!(
        logged(&fake).len(),
        2,
        "the readback runs after a failed capture"
    );
    fake.set_mode("normal");

    // The sequence and its cleanup, then the cleanup that finds residue.
    let request = ScreenSequenceRequest::new(2, ImageType::Jpeg, None, None, None).unwrap();
    let frames = OwnedRemoteDirectory::stable_frames("job-1", "capture-screen-sequence").unwrap();
    let archive =
        OwnedRemotePath::stable("job-1", "capture-screen-sequence", ImageType::Png).unwrap();
    let sequence = FileAction::CaptureScreenSequence {
        request: request.clone(),
        frames: frames.clone(),
        archive: archive.clone(),
    };
    let Outcome::Verified(summary) =
        execute(&sequence, "capture-screen-sequence", &fake, &host_root)
    else {
        panic!("the sequence verifies on the driver's listing")
    };
    assert_eq!(summary["capturedFrameCount"], "2");
    assert_eq!(summary["remoteByteCount"], "4096");
    let cleanup = FileAction::CleanupScreenSequence {
        request,
        frames,
        archive,
    };
    assert_eq!(
        execute(&cleanup, "cleanup-screen-sequence-temp", &fake, &host_root),
        verified(&[("cleaned", "true")])
    );
    fake.set_mode("residue");
    assert!(matches!(
        execute(&cleanup, "cleanup-screen-sequence-temp", &fake, &host_root),
        Outcome::Failed {
            code: "sequenceCleanupResidue",
            ..
        }
    ));
    fake.set_mode("normal");

    // The stdout legs and the single-path cleanup.
    assert_eq!(
        execute(
            &FileAction::CaptureCrashIndex {
                byte_budget: STDOUT_BUDGET
            },
            "capture-crash-index",
            &fake,
            &host_root
        ),
        verified(&[("entryCount", "1"), ("byteCount", "30")])
    );
    let liveness = FileAction::ObserveApplicationLiveness(
        LivenessRequest::new("com.example.demo", None, None, None).unwrap(),
    );
    let Outcome::Verified(summary) =
        execute(&liveness, "observe-application-liveness", &fake, &host_root)
    else {
        panic!("liveness is always a fact")
    };
    assert_eq!(summary["state"], "HEALTHY");
    assert_eq!(summary["reasonCode"], "targetProcessRunning");
    assert_eq!(summary["observedAtUtc"], "2026-09-14T00:00:00Z");
    let cleanup = FileAction::CleanupOwnedRemotePath {
        path: trace_path.clone(),
    };
    assert_eq!(
        execute(&cleanup, "cleanup-remote-temp", &fake, &host_root),
        verified(&[("cleaned", &trace_path.remote_path)])
    );
    // An argv the driver does not register (a crash log by name) exits 23
    // with nothing on stdout: the verdict is unknown, never a fact.
    let FilePlan::Process(_) = FileAction::CaptureCrashIndex {
        byte_budget: STDOUT_BUDGET,
    }
    .lower("capture-crash-index", Some(CONNECT_KEY), &host_root)
    .unwrap() else {
        panic!("one process")
    };
}
