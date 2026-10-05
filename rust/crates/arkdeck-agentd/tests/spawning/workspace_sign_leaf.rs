//! GJ-5's `workspace sign` end to end on Windows (TASK-XPA-011): the real
//! signed `arkdeck.exe` registers an OpenHarmony project, the host's DevEco
//! Studio as its toolchain and a signing preset pinning a fixture credential,
//! then signs a HAP through `workspace.sign-openharmony-hap@1`, against the
//! signed test daemon (`signed_daemon.rs`).
//!
//! A development root composes no signing, and the installed daemon signs
//! only over the account's preset store and Credential Manager, which no test
//! may touch. The test daemon therefore takes a fixture's signing
//! ([`signed_daemon::SIGNING`], `windows_lifecycle::TEST_SIGNING`, compiled
//! into test builds alone): a preset store below this test's scratch
//! directory, holding the Swift signing oracle's receipt
//! (`rust/tests/fixtures/workspace-sign-oracle`) over its material, and the
//! oracle's fake passwords in Credential Manager's `ArkDeck-fixture/<run>/`
//! scope, removed when the test ends. The signer is the oracle's stand-in
//! (`hap-signer.sh`, as the test binary `windows_sign_stand_in`), not
//! DevEco's `hap-sign-tool`: no keystore, real password or certificate is
//! used. The input HAP is the oracle's `good.hap` Artifact.
//!
//! The toolchain is the host's DevEco Studio (`ARKDECK_LIVE_DEVECO_ROOT`,
//! measured, never run): without it, or without the development signer, the
//! test says so and checks nothing. No HDC, device or board is involved.
use crate::gj1_device_leaves::assert_windows_status;
use crate::signed_daemon::{self, SignedDaemon, fixtures, signed_copy, temporary};
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{HostDirectory, KeychainItems, create_private_file};
use arkdeck_provider_workspace::credential_owner::CredentialOwner;
use arkdeck_provider_workspace::secret_envelope::encode_envelope;
use arkdeck_provider_workspace::signing_preset::{KEYCHAIN_SERVICE, SigningPresetStore};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The recording's root, as its receipt names it.
const SWIFT_ROOT: &str = "/tmp/arkdeck-workspace-sign-oracle";
/// The recording's fake passwords: nothing they unlock exists anywhere.
const KEYSTORE_SECRET: &str = "oracle-keystore-password-7f3a";
const KEY_SECRET: &str = "oracle-key-password-2c9e";
/// The recording's unsigned HAP: an Import the oracle published.
const HAP_LEASE: &str = "lease-v1:job-input-hap:ART-81ae19b19ca7ea0d3ce99c554182c815";

/// A private file, its directories created private.
fn private(path: &Path, bytes: &[u8]) {
    HostDirectory::open_or_create_private(path.parent().unwrap()).unwrap();
    let mut file = create_private_file(path).unwrap();
    file.write_all(bytes).unwrap();
    file.sync_all().unwrap();
}

/// The stand-in signer this crate's test build made beside this binary: the
/// newest `windows_sign_stand_in-<hash>.exe` in the same directory.
fn stand_in() -> PathBuf {
    let directory = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();
    fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with("windows_sign_stand_in-") && name.ends_with(".exe")
                })
        })
        .max_by_key(|path| fs::metadata(path).unwrap().modified().unwrap())
        .unwrap_or_else(|| {
            panic!(
                "no windows_sign_stand_in test binary in {}; run `cargo test -p arkdeck-agentd`, \
                 which builds it",
                directory.display()
            )
        })
}

/// The oracle's material below `material`, the stand-in as its Java
/// launcher, and the recorded receipt over them, its project `project`, in
/// the preset store `store`.
fn install_preset(fixture: &Path, material: &Path, store: &Path, project: &str) {
    for (name, text) in [
        ("hap-sign-tool.jar", "oracle hap-sign-tool\n"),
        ("release.p12", "oracle keystore\n"),
        ("release.cer", "oracle certificate\n"),
        ("release.p7b", "oracle profile\n"),
    ] {
        private(&material.join(name), text.as_bytes());
    }
    private(&material.join("java.exe"), &fs::read(stand_in()).unwrap());
    let mut receipt: Value =
        serde_json::from_slice(&fs::read(fixture.join("preset-v1.json")).unwrap()).unwrap();
    for key in [
        "appCertificate",
        "javaExecutable",
        "keystore",
        "signedProfile",
        "signerJAR",
    ] {
        let swift = receipt[key]["path"].as_str().unwrap().to_owned();
        let name = swift
            .strip_prefix(&format!("{SWIFT_ROOT}/"))
            .unwrap()
            .rsplit('/')
            .next()
            .unwrap();
        let host = material.join(if key == "javaExecutable" {
            "java.exe"
        } else {
            name
        });
        let bytes = fs::read(&host).unwrap();
        receipt[key]["path"] = json!(host.to_str().unwrap());
        if key == "javaExecutable" {
            receipt[key]["byteCount"] = json!(bytes.len());
            receipt[key]["sha256"] = json!(sha256_hex(&bytes));
        } else {
            assert_eq!(
                receipt[key]["sha256"].as_str().unwrap(),
                sha256_hex(&bytes),
                "{key} is the recorded file"
            );
        }
    }
    receipt["projectRef"] = json!(project);
    private(
        &store.join("preset-v1.json"),
        &serde_json::to_vec_pretty(&receipt).unwrap(),
    );
}

/// The oracle's input HAPs as the recording published them, in the root's
/// Artifact store.
fn seed_inputs(fixture: &Path, root: &Path) {
    let inputs = root.join("artifacts").join("job-input-hap");
    HostDirectory::open_or_create_private(&root.join("artifacts")).unwrap();
    HostDirectory::open_or_create_private(&inputs).unwrap();
    let directory = HostDirectory::open(&inputs).unwrap();
    for file in fs::read_dir(fixture.join("artifacts").join("job-input-hap")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap().to_str().unwrap().to_owned();
        let bytes = fs::read(&file).unwrap();
        directory.create_document(&name, &bytes).unwrap();
        if name != "index.json" {
            directory.seal_document(&name).unwrap();
        }
    }
}

/// The fixture's secrets in Credential Manager's `ArkDeck-fixture/<run>/`
/// scope, removed on drop.
struct FixtureSecrets {
    items: KeychainItems,
    account: String,
}

impl FixtureSecrets {
    fn install(namespace: &str, account: &str) -> Self {
        let items = KeychainItems::fixture_namespace(KEYCHAIN_SERVICE, namespace).unwrap();
        let target = items.target_name(account).unwrap().unwrap();
        assert!(
            target.starts_with(&format!("ArkDeck-fixture/{namespace}/")),
            "{target}"
        );
        let envelope = encode_envelope(KEYSTORE_SECRET.as_bytes(), KEY_SECRET.as_bytes());
        items.set(account, envelope.as_bytes()).unwrap();
        Self {
            items,
            account: account.to_owned(),
        }
    }
}

impl Drop for FixtureSecrets {
    fn drop(&mut self) {
        let _ = self.items.remove(&self.account);
    }
}

/// No password, as UTF-8 or UTF-16, in any file below `root` but those
/// below `skip` (the test binaries, which hold the fixture's passwords).
fn assert_secret_free(root: &Path, skip: &[PathBuf]) {
    let mut pending = vec![root.to_owned()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if skip.iter().any(|skipped| path.starts_with(skipped)) {
                continue;
            }
            let bytes = fs::read(&path).unwrap();
            for secret in [KEYSTORE_SECRET, KEY_SECRET] {
                let wide: Vec<u8> = secret
                    .encode_utf16()
                    .flat_map(|unit| unit.to_le_bytes())
                    .collect();
                for needle in [secret.as_bytes(), &wide[..]] {
                    assert!(
                        !bytes.windows(needle.len()).any(|window| window == needle),
                        "{} holds a password",
                        path.display()
                    );
                }
            }
        }
    }
}

#[test]
fn the_real_cli_signs_a_hap_with_a_registered_signing_preset() {
    let _turn = crate::turn();
    let Some(deveco) = std::env::var("ARKDECK_LIVE_DEVECO_ROOT")
        .ok()
        .filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_LIVE_DEVECO_ROOT does not name the host's DevEco Studio, which a \
             signing preset pins; nothing was checked"
        );
        return;
    };
    let scratch = temporary("gj5-workspace-sign");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let signing_fixture = fixtures("workspace-sign-oracle");
    // The fake HDC no exchange reaches.
    let hdc_fixture = fixtures("observe-device");
    let (root, fake_root) = (scratch.join("state"), scratch.join("fake"));
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&fake_root).unwrap();
    let (store, material) = (scratch.join("preset"), scratch.join("material"));
    HostDirectory::open_or_create_private(&store).unwrap();
    seed_inputs(&signing_fixture, &root);
    let project = scratch.join("project");
    for (relative, text) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "struct Index {}\n"),
    ] {
        let file = project.join(relative);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
    let namespace = format!(
        "sign-{:016x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    );
    let variables = [(
        signed_daemon::SIGNING,
        format!("{}|{namespace}", store.to_str().unwrap()),
    )];
    let start = |variables: &[(&str, String)]| {
        SignedDaemon::start_with(
            &executable,
            &pin,
            &root,
            &hdc_fixture,
            &fake_root,
            variables,
        )
    };
    let run = |daemon: &SignedDaemon, arguments: &[&str]| -> Value {
        let (status, envelope) = daemon.cli(arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        envelope["result"].clone()
    };

    // The toolchain and the project, registered by a daemon that signs
    // nothing; then the fixture's preset over the project and its secrets,
    // which the next start composes; then the signing preset pinning its
    // credential.
    let daemon = start(&[]);
    let toolchain = run(
        &daemon,
        &[
            "runtime", "tool", "register", "--kind", "deveco", "--root", &deveco,
        ],
    )["toolRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let registered = run(
        &daemon,
        &[
            "workspace",
            "project",
            "register",
            "--registration-request-id",
            "sign-leaf-project",
            "--kind",
            "openharmony",
            "--root",
            project.to_str().unwrap(),
        ],
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    install_preset(&signing_fixture, &material, &store, &registered);
    let receipt: Value =
        serde_json::from_slice(&fs::read(store.join("preset-v1.json")).unwrap()).unwrap();
    let _secrets = FixtureSecrets::install(
        &namespace,
        receipt["secretEnvelopeAccount"].as_str().unwrap(),
    );
    let credential = CredentialOwner::new(SigningPresetStore::new(store.to_str().unwrap()))
        .current()
        .unwrap()
        .credential_ref;
    daemon.stop();
    let daemon = start(&variables);
    let preset = run(
        &daemon,
        &[
            "workspace",
            "preset",
            "register",
            "--registration-request-id",
            "sign-leaf-preset",
            "--project",
            &registered,
            "--kind",
            "signing",
            "--template",
            "openharmony.local-sign@1",
            "--timeout-seconds",
            "600",
            "--toolchain",
            &toolchain,
            "--toolchain-generation",
            "1",
            "--credential",
            &credential,
        ],
    )["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();

    // Composed by the next start: the HAP signed.
    let daemon = start(&variables);
    let listed = run(&daemon, &["operation", "list"]);
    let sign = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|operation| operation["reference"] == "workspace.sign-openharmony-hap@1")
        .cloned()
        .unwrap();
    assert_eq!(sign["availability"], "available", "{sign}");
    let inputs = scratch.join("sign.json");
    fs::write(
        &inputs,
        json!({"projectRef": registered, "signingPresetRef": preset,
            "unsignedHapArtifactLease": HAP_LEASE})
        .to_string(),
    )
    .unwrap();
    let (status, envelope) = daemon.cli(&[
        "workspace",
        "sign",
        "--target",
        "workspace-host",
        "--inputs-file",
        inputs.to_str().unwrap(),
        "--execution-id",
        "exec-windows-workspace-sign",
    ]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["command"], "workspace.sign", "{envelope}");
    let signed = &envelope["result"];
    assert_eq!(
        signed["operationReference"], "workspace.sign-openharmony-hap@1",
        "{signed}"
    );
    assert_eq!(signed["terminalState"], "succeeded", "{signed}");
    assert_eq!(signed["outcomeUnknown"], false, "{signed}");
    let artifacts = signed["artifacts"].as_array().unwrap();
    assert_eq!(artifacts.len(), 2, "{signed}");
    assert!(
        artifacts
            .iter()
            .all(|artifact| artifact["bytesVerified"] == true),
        "{signed}"
    );
    // The Job's Artifacts: the HAP the stand-in signed (the input with its
    // marker appended) and the signing report.
    let job = signed["jobID"].as_str().unwrap();
    let listed = run(&daemon, &["artifact", "list", "--job", job]);
    let items = listed["items"].as_array().unwrap();
    let names: Vec<&str> = items
        .iter()
        .map(|item| item["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["signed.hap", "signing-report.json"], "{listed}");
    let mut expected = fs::read(
        signing_fixture
            .join("artifacts")
            .join("job-input-hap")
            .join(HAP_LEASE.rsplit(':').next().unwrap()),
    )
    .unwrap();
    expected.extend_from_slice(b"arkdeck-signed-fixture");
    assert_eq!(
        items[0]["artifactDigest"],
        sha256_hex(&expected),
        "{listed}"
    );
    daemon.stop();

    // Every attempt directory is gone, and no password reached a file.
    let attempts = root.join("workspace-signing-attempts");
    assert_eq!(
        fs::read_dir(&attempts).map_or(0, |entries| entries.count()),
        0,
        "{}",
        attempts.display()
    );
    assert_secret_free(
        &scratch,
        &[scratch.join("signed-bin"), material.join("java.exe")],
    );
    drop(_secrets);
    assert!(
        !KeychainItems::fixture_namespace(KEYCHAIN_SERVICE, &namespace)
            .unwrap()
            .contains(receipt["secretEnvelopeAccount"].as_str().unwrap()),
        "the fixture's secrets are removed"
    );
    let _ = fs::remove_dir_all(&scratch);
    assert_windows_status(&["workspace.sign-openharmony-hap@1"], "implemented");
}

/// The fixture signing is compiled into test builds alone: the daemon's own
/// build (`arkdeck-agentd.exe`, built without `cfg(test)`) carries none of
/// its text, while it carries the production signing composition's.
#[test]
fn the_daemon_build_has_no_fixture_signing() {
    let daemon = fs::read(env!("CARGO_BIN_EXE_arkdeck-agentd")).unwrap();
    let carries = |text: &str| {
        daemon
            .windows(text.len())
            .any(|window| window == text.as_bytes())
    };
    assert!(carries("the signing credential store is unusable"));
    assert!(!carries("the test build's fixture signing is unusable"));
    assert!(!carries(signed_daemon::SIGNING));
}
