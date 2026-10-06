//! The Windows HDC registration (CHG-2026-078, TASK-WHR-002, amended by r3):
//! the registry `OPENHARMONY-HDC-WINDOWS-PROBES@1.1.0`, its fixtures, the profile and the
//! lock close on exact hashes; the Rust tuple table is the registry's; the
//! registered fixtures classify as their families; every other tool, form
//! and endpoint fails closed; and nothing crosses between the Windows and
//! the macOS registrations.
//!
//! These run on every host: they read files and parse bytes, and launch no
//! process. The fixtures are the redacted capture of 2026-10-04 (#2456); the
//! negative vectors are synthetic and prove fail-closed behaviour only.
use std::fs;
use std::path::{Path, PathBuf};

#[cfg(any(target_os = "macos", windows))]
use arkdeck_provider_hdc::CommandlessIdentity;
use arkdeck_provider_hdc::{
    ObservationFailure, ObservationInput, ObservationTermination, PresenceSnapshot,
    WINDOWS_HDC_TUPLES, WINDOWS_SERVER_STARTUP_LISTING, malformed_windows_tuple,
    parse_registered_presence, parse_registered_windows_presence, windows_tuple,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

const C1_SHA256: &str = "f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b";
const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";
const MACOS_3_2_0D: &str = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260";
const MACOS_3_2_0F: &str = "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83";
const REGISTRY: &str = "openspec/integrations/openharmony/windows-probes.yaml";
const RESOURCES: &str = "rust/tests/fixtures/hdc-windows/resources.json";
const KEY: [u8; 32] = [7; 32];

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read(path: &str) -> Vec<u8> {
    fs::read(repository().join(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

fn text(path: &str) -> String {
    String::from_utf8(read(path)).unwrap()
}

fn json(path: &str) -> Value {
    serde_json::from_slice(&read(path)).unwrap()
}

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn fixtures() -> PathBuf {
    repository().join("rust/tests/fixtures/hdc-windows")
}

fn entry<'a>(registry: &'a Value, family: &str) -> &'a Value {
    registry["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["family"] == family)
        .unwrap_or_else(|| panic!("no {family} entry"))
}

fn exited(stdout: &[u8]) -> ObservationInput<'_> {
    ObservationInput::exited(stdout, b"", 0)
}

fn windows(stdout: &[u8]) -> Result<PresenceSnapshot, ObservationFailure> {
    parse_registered_windows_presence(&exited(stdout), &KEY)
}

#[test]
fn the_tuple_table_is_the_registry_and_names_candidate_2_only() {
    let registry = json(REGISTRY);
    assert_eq!(registry["registryId"], "OPENHARMONY-HDC-WINDOWS-PROBES");
    assert_eq!(registry["registryVersion"], "1.1.0");
    assert_eq!(registry["integrationProfile"], "OPENHARMONY-TOOLS@0.7.1");
    assert_eq!(registry["toolContext"]["platform"], "windows");
    assert!(registry.get("draftNotice").is_none());

    let candidates = registry["toolContext"]["candidates"].as_array().unwrap();
    let registered: Vec<&Value> = candidates
        .iter()
        .filter(|candidate| candidate["registered"] == true)
        .collect();
    assert_eq!(registered.len(), WINDOWS_HDC_TUPLES.len());
    for (candidate, tuple) in registered.iter().zip(WINDOWS_HDC_TUPLES) {
        assert_eq!(candidate["label"], tuple.candidate);
        assert_eq!(candidate["executableSHA256"], tuple.executable_sha256);
        assert_eq!(candidate["reportedVersion"], tuple.reported_version);
        assert_eq!(
            candidate["versionBytes"].as_str().unwrap().as_bytes(),
            tuple.version_stdout
        );
        assert_eq!(malformed_windows_tuple(tuple), None);
    }
    assert_eq!(WINDOWS_HDC_TUPLES.len(), 1);
    let tuple = windows_tuple(C2_SHA256).expect("candidate 2 is registered");
    assert_eq!(tuple.reported_version, "3.2.0g");
    assert_eq!(tuple.version_stdout, b"Ver: 3.2.0g\r\n");
    assert_eq!(tuple.endpoint.to_string(), "127.0.0.1:8710");

    // Candidate 1 was sampled and is recorded, but registers nothing.
    let c1 = candidates
        .iter()
        .find(|candidate| candidate["label"] == "c1")
        .unwrap();
    assert_eq!(c1["executableSHA256"], C1_SHA256);
    assert_eq!(c1["registered"], false);

    // Every entry names the registered executable and its observed endpoint.
    for entry in registry["entries"].as_array().unwrap() {
        assert_eq!(entry["platform"], "windows");
        assert_eq!(entry["executableIdentityPolicy"]["sha256"], C2_SHA256);
        assert!(
            entry["id"]
                .as_str()
                .unwrap()
                .ends_with("-3.2.0g-windows-c7951849"),
            "{}",
            entry["id"]
        );
        for endpoint in [
            &entry["endpointPolicy"]["exactEndpoint"],
            &entry["endpointPolicy"]["endpoint"],
        ] {
            if !endpoint.is_null() {
                assert_eq!(endpoint.as_str(), Some("127.0.0.1:8710"));
            }
        }
    }
}

#[test]
fn registry_resources_profile_and_lock_close_on_exact_hashes() {
    let registry_sha256 = sha256(&read(REGISTRY));
    let resources_bytes = read(RESOURCES);
    let resources_sha256 = sha256(&resources_bytes);
    let resources: Value = serde_json::from_slice(&resources_bytes).unwrap();
    let profile = text("openspec/integrations/openharmony/profile.md");
    let lock = text("openspec/integrations/INTEGRATION-PROFILES.lock.yaml");

    assert_eq!(resources["canonicalRegistry"]["path"], REGISTRY);
    assert_eq!(resources["canonicalRegistry"]["sha256"], registry_sha256);
    assert_eq!(resources["executableSHA256"], C2_SHA256);
    for pin in [&registry_sha256, &resources_sha256] {
        assert!(profile.contains(pin.as_str()), "profile lacks {pin}");
        assert!(lock.contains(pin.as_str()), "lock lacks {pin}");
    }
    assert_eq!(
        profile.matches("> Version：0.8.0").count(),
        1,
        "the current profile is OPENHARMONY-TOOLS@0.8.0"
    );
    assert!(lock.contains("lock: INTEGRATION-PROFILES-0.9.0"));
    assert!(lock.contains("  - id: OPENHARMONY-TOOLS\n    version: 0.8.0\n"));

    // Every manifest entry matches its file, and every file is listed.
    let mut listed = Vec::new();
    for file in resources["files"].as_array().unwrap() {
        let path = file["file"].as_str().unwrap();
        let bytes = fs::read(fixtures().join(path)).unwrap();
        assert_eq!(
            bytes.len() as u64,
            file["bytes"].as_u64().unwrap(),
            "{path}"
        );
        assert_eq!(sha256(&bytes), file["sha256"].as_str().unwrap(), "{path}");
        listed.push(path.to_owned());
    }
    let mut present = Vec::new();
    let mut stack = vec![fixtures()];
    while let Some(directory) = stack.pop() {
        for item in fs::read_dir(directory).unwrap() {
            let path = item.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else if path.file_name().unwrap() != "resources.json" {
                let relative = path.strip_prefix(fixtures()).unwrap();
                present.push(relative.to_str().unwrap().replace('\\', "/"));
            }
        }
    }
    listed.sort();
    present.sort();
    assert_eq!(listed, present);

    // The lock pins every fixture file, the manifest included, by its bytes.
    let lines: Vec<&str> = lock.lines().collect();
    let mut pinned = 0;
    for (index, line) in lines.iter().enumerate() {
        if let Some(path) = line
            .trim()
            .strip_prefix("path: rust/tests/fixtures/hdc-windows/")
        {
            let digest = lines[index + 1].trim().strip_prefix("sha256: ").unwrap();
            assert_eq!(
                sha256(&fs::read(fixtures().join(path)).unwrap()),
                digest,
                "{path}"
            );
            pinned += 1;
        }
    }
    assert_eq!(
        pinned,
        present.len() + 1,
        "every fixture and the manifest are pinned"
    );
}

#[test]
fn the_registered_fixtures_classify_as_their_families() {
    let registry = json(REGISTRY);
    let resources = json(RESOURCES);
    let families = &resources["families"];

    let version = &families["version"][0];
    let bytes = fs::read(fixtures().join(version["file"].as_str().unwrap())).unwrap();
    assert_eq!(bytes, WINDOWS_HDC_TUPLES[0].version_stdout);
    let contract = &entry(&registry, "version")["inputContract"];
    assert_eq!(contract["observedSHA256"].as_str().unwrap(), sha256(&bytes));
    assert_eq!(contract["observedTerminator"], "CRLF");

    let checkserver = &families["healthyCheckserver"][0];
    let bytes = fs::read(fixtures().join(checkserver["file"].as_str().unwrap())).unwrap();
    assert_eq!(
        bytes,
        b"Client version:Ver: 3.2.0g, server version:Ver: 3.2.0g\r\n"
    );

    let observations = families["deviceObservationSnapshot"].as_array().unwrap();
    assert_eq!(observations.len(), 7);
    for fixture in observations {
        let path = fixture["file"].as_str().unwrap();
        let bytes = fs::read(fixtures().join(path)).unwrap();
        if fixture["expectedOutcome"] == "notYetObservable" {
            // r3: the server-startup listing is unknown and retryable, never
            // a snapshot.
            assert_eq!(bytes, WINDOWS_SERVER_STARTUP_LISTING, "{path}");
            let failure = windows(&bytes).unwrap_err();
            assert!(failure.is_not_yet_observable(), "{path}: {failure:?}");
            assert_eq!(failure.classification(), "unknown");
            continue;
        }
        let snapshot = windows(&bytes).unwrap_or_else(|failure| panic!("{path}: {failure}"));
        match fixture["expectedOutcome"].as_str().unwrap() {
            "observedEmpty" => assert_eq!(snapshot, PresenceSnapshot::ObservedEmpty, "{path}"),
            "observedConnectedSet:1" => match snapshot {
                PresenceSnapshot::ObservedConnectedSet(set) => {
                    assert_eq!(set.len(), 1, "{path}");
                    // The raw (here redacted) key never leaves the parser.
                    assert!(set[0].starts_with("redacted-device-"));
                    assert!(!set[0].contains("aaaa"));
                }
                other => panic!("{path}: {other:?}"),
            },
            other => panic!("{path}: unexpected outcome {other}"),
        }
        // The macOS grammar never reads a Windows snapshot.
        assert!(
            matches!(
                parse_registered_presence(&exited(&bytes), &KEY),
                Err(ObservationFailure::Unknown(_))
            ),
            "{path}"
        );
    }

    // The supervisor brackets: one loopback listener owned by the
    // registered executable, the same process in every phase.
    let mut owners = Vec::new();
    for fixture in families["serverIdentityGeneration"].as_array().unwrap() {
        let sample = json(&format!(
            "rust/tests/fixtures/hdc-windows/{}",
            fixture["file"].as_str().unwrap()
        ));
        for command in sample["commands"].as_array().unwrap() {
            for bracket in [&command["serverBefore"], &command["serverAfter"]] {
                let listeners = bracket["listeners8710"].as_array().unwrap();
                if listeners.is_empty() {
                    continue;
                }
                assert_eq!(listeners.len(), 1);
                assert_eq!(listeners[0]["localAddress"], "127.0.0.1");
                assert_eq!(listeners[0]["localPort"], 8710);
                let owner = &bracket["listenerOwners"][0];
                assert_eq!(owner["imageSha256"], C2_SHA256);
                assert_eq!(owner["imageIsSelectedTool"], true);
                owners.push((owner["pid"].clone(), owner["startSeconds"].clone()));
            }
        }
    }
    owners.dedup();
    assert_eq!(owners.len(), 1, "one server process across every phase");
}

#[test]
fn every_form_outside_the_registered_windows_family_fails_closed() {
    let connected = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\thdc\r\n";
    let uart = b"COM1\t\tUART\tReady\tunknown...\thdc\r\nCOM2\t\tUART\tReady\tunknown...\thdc\r\n";

    // Accepted: UART rows alone are no device; LF ends a row as CR LF does;
    // Offline USB rows beside UART rows are no device either.
    assert_eq!(windows(uart), Ok(PresenceSnapshot::ObservedEmpty));
    assert_eq!(
        windows(b"COM3\t\tUART\tReady\tunknown...\thdc\n"),
        Ok(PresenceSnapshot::ObservedEmpty)
    );
    assert_eq!(
        windows(
            b"bbbb\t\tUSB\tOffline\tlocalhost\thdc\r\nCOM1\t\tUART\tReady\tunknown...\thdc\r\n"
        ),
        Ok(PresenceSnapshot::ObservedEmpty)
    );
    assert!(matches!(
        windows(&[connected.as_slice(), uart].concat()),
        Ok(PresenceSnapshot::ObservedConnectedSet(set)) if set.len() == 1
    ));

    let unknown: [(&str, &[u8]); 16] = [
        ("zero bytes", b""),
        ("the [Empty] marker", b"[Empty]\r\n"),
        ("the [Empty] marker, LF", b"[Empty]\n"),
        (
            "a macOS five-column row",
            b"aaaa\t\tUSB\tConnected\tlocalhost\n",
        ),
        (
            "a sixth column other than hdc",
            b"aaaa\t\tUSB\tConnected\tlocalhost\tflashd\r\n",
        ),
        (
            "seven columns",
            b"aaaa\t\tUSB\tConnected\tlocalhost\thdc\tx\r\n",
        ),
        (
            "a UART row in another state",
            b"COM1\t\tUART\tConnected\tunknown...\thdc\r\n",
        ),
        (
            "a UART row with a device key",
            b"aaaa\t\tUART\tReady\tunknown...\thdc\r\n",
        ),
        (
            "a UART row with a name",
            b"COM1\tboard\tUART\tReady\tunknown...\thdc\r\n",
        ),
        (
            "a UART row with another hostTag",
            b"COM1\t\tUART\tReady\tlocalhost\thdc\r\n",
        ),
        (
            "an unknown USB state",
            b"aaaa\t\tUSB\tUnauthorized\tlocalhost\thdc\r\n",
        ),
        (
            "an unknown transport",
            b"aaaa\t\tTCP\tConnected\tlocalhost\thdc\r\n",
        ),
        (
            "an unknown hostTag",
            b"aaaa\t\tUSB\tConnected\tremote\thdc\r\n",
        ),
        (
            "a residual CR",
            b"aaaa\t\tUSB\tConnected\tlocalhost\thdc\r\r\n",
        ),
        (
            "a duplicate key",
            b"aaaa\t\tUSB\tConnected\tlocalhost\thdc\r\naaaa\t\tUSB\tOffline\tlocalhost\thdc\r\n",
        ),
        (
            "an unterminated row",
            b"aaaa\t\tUSB\tConnected\tlocalhost\thdc",
        ),
    ];
    for (name, stdout) in unknown {
        assert!(
            matches!(windows(stdout), Err(ObservationFailure::Unknown(_))),
            "{name}: {:?}",
            windows(stdout)
        );
    }

    // The execution, not only the bytes, must be the registered one.
    let unknown_execution = [
        ObservationInput::exited(uart, b"warning", 0),
        ObservationInput::exited(uart, b"", 1),
        ObservationInput {
            stdout: uart,
            stderr: b"",
            termination: ObservationTermination::Exited(0),
            stdout_truncated: true,
        },
        ObservationInput {
            stdout: uart,
            stderr: b"",
            termination: ObservationTermination::Signalled,
            stdout_truncated: false,
        },
    ];
    for execution in &unknown_execution {
        assert!(matches!(
            parse_registered_windows_presence(execution, &KEY),
            Err(ObservationFailure::Unknown(_))
        ));
    }
    for termination in [
        ObservationTermination::TimedOut,
        ObservationTermination::Cancelled,
    ] {
        let execution = ObservationInput {
            stdout: uart,
            stderr: b"",
            termination,
            stdout_truncated: false,
        };
        assert!(matches!(
            parse_registered_windows_presence(&execution, &KEY),
            Err(ObservationFailure::Unavailable(_))
        ));
    }
}

#[test]
fn no_tuple_crosses_between_windows_and_macos() {
    // Candidate 1, the macOS tools, a case fold or a prefix select nothing.
    for digest in [
        C1_SHA256.to_owned(),
        MACOS_3_2_0D.to_owned(),
        MACOS_3_2_0F.to_owned(),
        C2_SHA256.to_uppercase(),
        C2_SHA256[..63].to_owned(),
        "0".repeat(64),
    ] {
        assert_eq!(windows_tuple(&digest), None, "{digest}");
    }

    // The commandless family: on Windows only the registered tuple at its
    // own endpoint; on macOS no Windows tuple selects one (Linux builds no
    // commandless observer).
    #[cfg(any(target_os = "macos", windows))]
    {
        let family = |digest: &str, endpoint: &str| CommandlessIdentity::family(digest, endpoint);
        if cfg!(windows) {
            assert_eq!(family(C2_SHA256, "127.0.0.1:8710"), Some("3.2.0g"));
            assert_eq!(family(C2_SHA256, "127.0.0.1:8711"), None);
            assert_eq!(family(C2_SHA256, "0.0.0.0:8710"), None);
            assert_eq!(family(MACOS_3_2_0F, "127.0.0.1:8710"), None);
            assert_eq!(family(C1_SHA256, "127.0.0.1:8710"), None);
        } else {
            assert_eq!(family(C2_SHA256, "127.0.0.1:8710"), None);
        }
    }

    // No macOS registry names a Windows executable, and the Windows
    // registry names no macOS executable in full.
    for macos in [
        "openspec/integrations/openharmony/readonly-probes.yaml",
        "openspec/integrations/openharmony/device-observation-probes.yaml",
        "openspec/integrations/openharmony/supervisor-observation-probes.yaml",
        "openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml",
    ] {
        let registry = text(macos);
        assert!(
            !registry.contains(C1_SHA256) && !registry.contains(C2_SHA256),
            "{macos}"
        );
    }
    let windows_registry = text(REGISTRY);
    assert!(!windows_registry.contains(MACOS_3_2_0D));
    assert!(!windows_registry.contains(MACOS_3_2_0F));
}

#[test]
fn checkserver_is_never_a_windows_probe() {
    let registry = json(REGISTRY);
    let checkserver = entry(&registry, "healthyCheckserver");
    assert_eq!(checkserver["status"], "unsupported");
    assert_eq!(checkserver["invocationAllowed"], false);
    // No entry that may be invoked runs checkserver.
    for entry in registry["entries"].as_array().unwrap() {
        if entry["invocationAllowed"] == true {
            assert!(
                !entry["exactArgv"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|argument| argument == "checkserver"),
                "{}",
                entry["id"]
            );
        }
    }
    // Server health on Windows is the commandless observation: it runs no
    // HDC at all.
    let health = entry(&registry, "serverIdentityGeneration");
    assert_eq!(health["status"], "supported");
    assert_eq!(health["probeKind"], "platformProcessObservation");
    assert_eq!(health["invocationAllowed"], false);
    assert_eq!(health["exactArgv"], serde_json::json!([]));
    assert!(
        health["forbiddenEffects"]
            .as_array()
            .unwrap()
            .iter()
            .any(|effect| effect == "serverStart")
    );
}

/// CHG-2026-078 r3: the server-startup listing `[Empty]` CR TAB `hdc` CR LF
/// is `notYetObservable` (unknown, retryable) and only that exact form with
/// exit 0 and empty stderr. It is never read as absent: never
/// `observedEmpty`, never a device set. Every near miss is plain `unknown`,
/// and the macOS grammar never reads it.
#[test]
fn the_server_startup_listing_is_not_yet_observable_and_never_absent() {
    assert_eq!(WINDOWS_SERVER_STARTUP_LISTING, b"[Empty]\r\thdc\r\n");
    assert_eq!(WINDOWS_SERVER_STARTUP_LISTING.len(), 14);
    let startup = windows(WINDOWS_SERVER_STARTUP_LISTING);
    assert!(matches!(
        startup,
        Err(ObservationFailure::NotYetObservable(_))
    ));
    assert!(!matches!(startup, Ok(PresenceSnapshot::ObservedEmpty)));
    assert_eq!(startup.unwrap_err().classification(), "unknown");
    assert!(matches!(
        parse_registered_presence(&exited(WINDOWS_SERVER_STARTUP_LISTING), &KEY),
        Err(ObservationFailure::Unknown(_))
    ));

    let uart = "COM1\t\tUART\tReady\tunknown...\thdc\r\n";
    let near_misses: [(&str, Vec<u8>); 9] = [
        ("LF only", b"[Empty]\r\thdc\n".to_vec()),
        ("no final CR LF", b"[Empty]\r\thdc".to_vec()),
        ("no TAB", b"[Empty]\rhdc\r\n".to_vec()),
        ("no hdc", b"[Empty]\r\t\r\n".to_vec()),
        ("another sixth column", b"[Empty]\r\tflashd\r\n".to_vec()),
        ("no CR before the TAB", b"[Empty]\thdc\r\n".to_vec()),
        (
            "twice",
            [
                WINDOWS_SERVER_STARTUP_LISTING,
                WINDOWS_SERVER_STARTUP_LISTING,
            ]
            .concat(),
        ),
        (
            "beside a UART row",
            [WINDOWS_SERVER_STARTUP_LISTING, uart.as_bytes()].concat(),
        ),
        ("lower case", b"[empty]\r\thdc\r\n".to_vec()),
    ];
    for (name, stdout) in near_misses {
        let failure = windows(&stdout).unwrap_err();
        assert!(
            matches!(failure, ObservationFailure::Unknown(_)),
            "{name}: {failure:?}"
        );
    }
    // The execution must be the registered one too.
    for execution in [
        ObservationInput::exited(WINDOWS_SERVER_STARTUP_LISTING, b"warning", 0),
        ObservationInput::exited(WINDOWS_SERVER_STARTUP_LISTING, b"", 1),
        ObservationInput {
            stdout: WINDOWS_SERVER_STARTUP_LISTING,
            stderr: b"",
            termination: ObservationTermination::Exited(0),
            stdout_truncated: true,
        },
    ] {
        assert!(matches!(
            parse_registered_windows_presence(&execution, &KEY),
            Err(ObservationFailure::Unknown(_))
        ));
    }
}

/// CHG-2026-078 r3: a managed start settles past the startup listing,
/// stopping at the first registered enumerated listing, and gives up at its
/// bound without ever turning the startup listing into a snapshot.
#[cfg(any(target_os = "macos", windows))]
#[test]
fn the_managed_start_settles_past_the_startup_listing_within_its_bound() {
    use arkdeck_provider_hdc::{StartupListing, WINDOWS_STARTUP_SETTLE, settle_startup_listing};
    use std::cell::Cell;
    use std::time::{Duration, Instant};

    assert_eq!(WINDOWS_STARTUP_SETTLE, Duration::from_secs(3));
    let uart = b"COM1\t\tUART\tReady\tunknown...\thdc\r\nCOM2\t\tUART\tReady\tunknown...\thdc\r\n";

    // Startup, startup, then enumerated: settled on the third listing.
    let calls = Cell::new(0);
    let settled = settle_startup_listing(
        || {
            calls.set(calls.get() + 1);
            windows(if calls.get() < 3 {
                WINDOWS_SERVER_STARTUP_LISTING
            } else {
                uart
            })
        },
        Duration::from_secs(3),
        Duration::from_millis(5),
    );
    assert_eq!(settled, StartupListing::Settled);
    assert_eq!(calls.get(), 3);

    // Never enumerated: unsettled at the bound, and every listing it read
    // stayed not-yet-observable rather than empty.
    let calls = Cell::new(0);
    let started = Instant::now();
    let unsettled = settle_startup_listing(
        || {
            calls.set(calls.get() + 1);
            let listing = windows(WINDOWS_SERVER_STARTUP_LISTING);
            assert!(matches!(
                listing,
                Err(ObservationFailure::NotYetObservable(_))
            ));
            listing
        },
        Duration::from_millis(200),
        Duration::from_millis(20),
    );
    assert_eq!(unsettled, StartupListing::Unsettled);
    assert!(calls.get() >= 2);
    assert!(started.elapsed() < Duration::from_secs(2));

    // Another unknown form never settles either.
    let unknown = settle_startup_listing(
        || windows(b"[Empty]\r\n"),
        Duration::from_millis(50),
        Duration::from_millis(10),
    );
    assert_eq!(unknown, StartupListing::Unsettled);
}
