//! The production composition's pieces, in process and over temporary homes
//! only: every root resolves below the home it is given, the claim takes
//! Swift's lock and the facade's before anything else, the registry selects
//! the HDC as Swift's does, `compose` opens every owner in Swift's layout,
//! and the Runtime's own USB relations are read only beside the managed
//! registered HDC, over a census the test hands it. The daemon's own start,
//! single instance and serving are `tests/production_composition.rs`'s. No
//! real account root, Mach service, LaunchAgent, HDC or USB device is
//! touched.
use super::*;
use arkdeck_provider_hdc::{
    DAYU200_NORMAL_PRODUCT_ID, NoUsbRelations, ROCKUSB_VENDOR_ID, UsbRelation,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::sync::atomic::{AtomicUsize, Ordering};

/// A temporary home: physical, owner-only, short enough that the installed
/// socket's path fits `sun_path`, and removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adu-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn layout(&self) -> Layout {
        Layout::for_home(&self.0, true).unwrap()
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn every_root_is_swifts_below_the_one_home() {
    let home = Path::new("/private/tmp/adu-home");
    let layout = Layout::for_home(home, true).unwrap();
    let support = home.join("Library/Application Support/ArkDeck");
    let state = support.join("Agentd");
    assert_eq!(layout.state, state);
    assert_eq!(layout.socket, state.join("agentd.sock"));
    for (root, name) in [
        (&layout.capabilities, "capabilities"),
        (&layout.targets, "targets"),
        (&layout.artifacts, "artifacts"),
        (&layout.agent_executions, "agent-executions"),
        (&layout.human_actions, "human-action-snapshots"),
        (&layout.control_actions, "control-action-snapshots"),
        (&layout.hdc_control_actions, "hdc-control-actions"),
        (&layout.workspace_projects, "workspace-projects"),
    ] {
        assert_eq!(root, &state.join(name));
    }
    assert_eq!(layout.application_support, support);
    assert_eq!(layout.sessions, support.join("Sessions"));
    assert_eq!(layout.bootstrap, support.join("Bootstrap/v1"));
    assert_eq!(
        layout.trace_cache,
        home.join(
            "Library/Containers/com.arkdeck.desktop/Data/Library/Caches/ArkDeck/Trace/traces"
        )
    );
    for (name, root) in layout.roots() {
        assert!(root.starts_with(home), "{name}: {}", root.display());
    }
    assert!(Layout::for_home(Path::new("relative"), false).is_err());
}

#[test]
fn only_production_is_requested_and_other_compositions_refuse_it() {
    assert_eq!(requested(None), Ok(false));
    assert_eq!(requested(Some(OsStr::new("production"))), Ok(true));
    for value in ["", "Production", "installed", "production "] {
        assert_eq!(
            requested(Some(OsStr::new(value))),
            Err("ARKDECK_RUNTIME_COMPOSITION accepts only production".into()),
            "{value:?}"
        );
    }
    assert_eq!(refuse_other_compositions(&|_| false, false), Ok(()));
    for name in REFUSED {
        let refused = refuse_other_compositions(&|set| set == name, false).unwrap_err();
        assert!(refused.contains(name), "{refused}");
    }
    assert!(
        refuse_other_compositions(&|_| false, true)
            .unwrap_err()
            .contains("facade executable")
    );
}

#[test]
fn the_claim_holds_swifts_lock_and_the_transport_and_names_this_process() {
    let home = Home::new();
    let layout = home.layout();
    let Claim::Owned(authority) = claim(&layout, "2026-09-24T00:00:00Z").unwrap() else {
        panic!("a fresh home is claimed");
    };
    let document: Value =
        serde_json::from_slice(&fs::read(layout.state.join("instance.json")).unwrap()).unwrap();
    assert_eq!(
        document,
        json!({"pid": std::process::id(), "protocolVersion": "1.0.0",
            "socketPath": layout.socket, "startedAtUTC": "2026-09-24T00:00:00Z"})
    );
    for (path, mode) in [
        (&layout.state, 0o700),
        (&layout.state.join("instance.lock"), 0o600),
        (&layout.state.join("instance.json"), 0o600),
        (&layout.socket, 0o600),
    ] {
        assert_eq!(
            fs::symlink_metadata(path).unwrap().mode() & 0o777,
            mode,
            "{path:?}"
        );
    }
    assert!(
        fs::symlink_metadata(&layout.socket)
            .unwrap()
            .file_type()
            .is_socket()
    );
    // A second Runtime meets the lock held, and the document naming this one.
    let Claim::AlreadyRunning(instance) = claim(&layout, "later").unwrap() else {
        panic!("the lock is held");
    };
    assert_eq!(
        instance.running(),
        format!(
            "arkdeck-agentd already running: pid {}, socket {}, protocol 1.0.0",
            std::process::id(),
            layout.socket.display()
        )
    );
    // The facade's transport lock is held as well.
    assert!(LocalListener::bind_facade(&LocalEndpoint::new(layout.socket.clone())).is_err());
    drop(authority);
    // Let go of, the account is claimed again; this Runtime's own socket went.
    assert!(!layout.socket.exists());
    assert!(matches!(claim(&layout, "again").unwrap(), Claim::Owned(_)));
}

#[test]
fn a_held_transport_or_a_live_listener_refuses_the_claim_and_lets_go_of_the_lock() {
    let home = Home::new();
    let layout = home.layout();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&layout.state)
        .unwrap();
    // The installed facade holds its transport lock and the socket.
    let facade = LocalListener::bind_facade(&LocalEndpoint::new(layout.socket.clone())).unwrap();
    let facade_socket = fs::symlink_metadata(&layout.socket).unwrap().ino();
    let refused = claim(&layout, "now").err().unwrap();
    assert!(
        refused.contains("another facade owns the public transport directory"),
        "{refused}"
    );
    assert_eq!(
        fs::symlink_metadata(&layout.socket).unwrap().ino(),
        facade_socket
    );
    assert!(!layout.state.join("instance.json").exists());
    // Swift's lock was let go of with the refusal.
    let state = HostDirectory::open(&layout.state).unwrap();
    drop(state.lock_document("instance.lock").unwrap());
    drop(facade);

    // A live listener that holds neither lock.
    let foreign = std::os::unix::net::UnixListener::bind(&layout.socket).unwrap();
    fs::set_permissions(&layout.socket, fs::Permissions::from_mode(0o600)).unwrap();
    let refused = claim(&layout, "now").err().unwrap();
    assert!(refused.contains("already occupied"), "{refused}");
    assert!(layout.socket.exists());
    drop(state.lock_document("instance.lock").unwrap());
    // Dropped, it leaves a stale socket, which the claim reclaims.
    drop(foreign);
    assert!(layout.socket.exists());
    assert!(matches!(claim(&layout, "now").unwrap(), Claim::Owned(_)));
}

#[test]
fn a_lock_held_without_its_document_refuses_the_claim_and_one_with_it_names_the_holder() {
    let home = Home::new();
    let layout = home.layout();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&layout.state)
        .unwrap();
    // Swift's second instance would find its lock held the same way.
    let state = HostDirectory::open(&layout.state).unwrap();
    let _swift = state.lock_document("instance.lock").unwrap();
    let refused = claim(&layout, "now").err().unwrap();
    assert!(refused.contains("left no instance document"), "{refused}");
    // Swift's JSONEncoder escapes every slash.
    fs::write(
        layout.state.join("instance.json"),
        br#"{"pid":4242,"protocolVersion":"1.0.0","socketPath":"\/Users\/someone\/Library\/Application Support\/ArkDeck\/Agentd\/agentd.sock","startedAtUTC":"2026-09-24T00:00:00Z"}"#,
    )
    .unwrap();
    let Claim::AlreadyRunning(instance) = claim(&layout, "now").unwrap() else {
        panic!("the lock is held");
    };
    assert_eq!(
        instance.running(),
        "arkdeck-agentd already running: pid 4242, socket /Users/someone/Library/Application \
         Support/ArkDeck/Agentd/agentd.sock, protocol 1.0.0"
    );
    // Nothing but Swift's two entries is there.
    let mut names: Vec<_> = fs::read_dir(&layout.state)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["instance.json", "instance.lock"]);
}

/// The Swift-recorded executables of `rust/tests/fixtures/tool-selection-registry`,
/// written as source files, with the published identity those marked
/// published carry.
struct Executables {
    paths: std::collections::BTreeMap<String, PathBuf>,
    references: std::collections::BTreeMap<String, String>,
    published: Vec<String>,
    identity: Value,
    registered_at: String,
}

fn executables(directory: &Path) -> Executables {
    let oracle: Value = serde_json::from_slice(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/tool-selection-registry/oracle.json"),
        )
        .unwrap(),
    )
    .unwrap();
    fs::DirBuilder::new().mode(0o700).create(directory).unwrap();
    let mut executables = Executables {
        paths: Default::default(),
        references: Default::default(),
        published: Vec::new(),
        identity: oracle["publishedIdentity"].clone(),
        registered_at: oracle["registeredAt"].as_str().unwrap().into(),
    };
    for (label, executable) in oracle["executables"].as_object().unwrap() {
        let bytes = base64(executable["base64"].as_str().unwrap());
        assert_eq!(
            arkdeck_contract::sha256_hex(&bytes),
            executable["sha256"].as_str().unwrap()
        );
        let path = directory.join(format!("hdc-{label}"));
        fs::write(&path, &bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        executables.paths.insert(label.clone(), path);
        executables.references.insert(
            label.clone(),
            executable["toolRef"].as_str().unwrap().into(),
        );
        if executable["published"] == true {
            executables
                .published
                .push(executable["sha256"].as_str().unwrap().into());
        }
    }
    executables
}

fn base64(text: &str) -> Vec<u8> {
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let (mut bits, mut count, mut bytes) = (0_u32, 0, Vec::new());
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        bits = (bits << 6) | alphabet.iter().position(|a| *a == byte).unwrap() as u32;
        count += 6;
        if count >= 8 {
            count -= 8;
            bytes.push((bits >> count) as u8);
        }
    }
    bytes
}

#[test]
fn the_registry_adopts_the_configured_hdc_once_and_a_pending_selection_refuses() {
    let home = Home::new();
    let layout = home.layout();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&layout.bootstrap)
        .unwrap();
    let tools = executables(&home.0.join("sources"));
    let (published, identity) = (tools.published.clone(), tools.identity.clone());
    let registry = arkdeck_hoststore::ToolRegistryStore::open_existing(&layout.bootstrap)
        .unwrap()
        .with_published_identities(Arc::new(move |sha256: &str| {
            published
                .iter()
                .any(|known| known == sha256)
                .then(|| identity.clone())
        }));
    let now = tools.registered_at.as_str();
    // An executable without a published identity is never selected.
    let refused = registered_hdc(&registry, &tools.paths["unpublished"], now).unwrap_err();
    assert!(
        refused.contains("installed HDC has no published executable identity"),
        "{refused}"
    );
    assert!(registry.startup_selection().unwrap().is_none());
    // The first configured HDC is adopted and selected: its retained copy in
    // the registry, never the configured path, is what the server runs.
    let selection = registered_hdc(&registry, &tools.paths["a"], now).unwrap();
    assert_eq!(selection.tool_ref, tools.references["a"]);
    assert_eq!(selection.active_generation, 1);
    assert_eq!(selection.pending_action_id, None);
    assert!(selection.executable.starts_with(&layout.bootstrap));
    assert_eq!(
        selection.executable_sha256,
        arkdeck_contract::sha256_hex(&fs::read(&tools.paths["a"]).unwrap())
    );
    // Once a selection exists the configured path is not read again.
    assert_eq!(
        registered_hdc(&registry, &tools.paths["b"], now)
            .unwrap()
            .tool_ref,
        tools.references["a"]
    );
    // A pending selection refuses the start and is left as it is.
    registry.register(&tools.paths["b"], now).unwrap();
    registry
        .prepare_selection("select-b", &tools.references["b"], "1")
        .unwrap();
    let refused = registered_hdc(&registry, &tools.paths["a"], now).unwrap_err();
    assert!(refused.contains("select-b is pending"), "{refused}");
    assert_eq!(
        registry
            .startup_selection()
            .unwrap()
            .unwrap()
            .pending_action_id
            .as_deref(),
        Some("select-b")
    );
}

#[test]
fn compose_opens_every_owner_in_swifts_layout_below_the_home() {
    let home = Home::new();
    let layout = home.layout();
    let Claim::Owned(authority) = claim(&layout, "now").unwrap() else {
        panic!("a fresh home is claimed");
    };
    let composition = compose(&layout, &Inputs::default(), Host::from_environment(), "now")
        .map_err(|error| error.to_string())
        .unwrap();
    // Without an HDC there is no managed server, so no USB relation reader
    // either (`usbRegistryRelations` is not among them).
    assert_eq!(
        composition.host.owner_census(),
        [
            "jobs",
            "capabilities",
            "mutationAuthority",
            "targets",
            "artifacts",
            "imports",
            "storage",
            "history",
            "workspaceProjects",
            "workspaceOperations",
            "bootstrap",
            "planning",
            "agentExecutions",
            "humanActions",
            "controlActions",
            "flashAliasReconciler",
            "flashInvocations",
        ]
    );
    // The Flash invocation owner's directories, created owner-only beside
    // the Job state as Swift's controller creates them.
    for name in [
        "runtime-debug-invocations",
        "runtime-debug-invocation-snapshots",
    ] {
        let metadata = std::fs::symlink_metadata(layout.state.join(name)).unwrap();
        assert!(metadata.is_dir(), "{name}");
        assert_eq!(
            std::os::unix::fs::PermissionsExt::mode(&metadata.permissions()) & 0o777,
            0o700,
            "{name}"
        );
    }
    assert_eq!(
        composition.host.mutation_root(),
        Some(layout.state.as_path())
    );
    assert!(composition.managed.is_none());
    // Over an overridden home the account's Mach service is not composed.
    assert!(composition.ingress.is_none());
    for omitted in ["HDC: no executable", "Trace cache", "App ingress"] {
        assert!(
            composition
                .omitted
                .iter()
                .any(|line| line.starts_with(omitted)),
            "{omitted}: {:?}",
            composition.omitted
        );
    }
    assert_eq!(composition.omitted.len(), 3, "{:?}", composition.omitted);
    // Swift's Job index is at the state root, beside the other owners.
    assert!(layout.state.join("runtime-jobs.sqlite3").is_file());
    // Everything created is below the home and owner-only; the App's
    // container is never created.
    assert!(!home.0.join("Library/Containers").exists());
    let mut pending = vec![home.0.clone()];
    let mut seen = 0;
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            let metadata = fs::symlink_metadata(&path).unwrap();
            assert!(path.starts_with(&home.0));
            assert_eq!(metadata.uid(), arkdeck_platform::effective_user_id());
            assert_eq!(metadata.mode() & 0o077, 0, "{path:?}");
            if metadata.is_dir() {
                pending.push(path);
            }
            seen += 1;
        }
    }
    assert!(seen > 20, "{seen} entries");
    drop(composition);
    drop(authority);

    // Over the account's own home, the App ingress is composed (making its
    // configuration registers nothing).
    let Claim::Owned(_authority) = claim(&layout, "now").unwrap() else {
        panic!("the account is claimed again");
    };
    let own = Layout {
        overridden: false,
        ..layout
    };
    let composition = compose(&own, &Inputs::default(), Host::from_environment(), "now")
        .map_err(|error| error.to_string())
        .unwrap();
    assert!(composition.ingress.is_some());
    assert!(
        !composition
            .omitted
            .iter()
            .any(|line| line.starts_with("App ingress"))
    );
}

/// A DAYU200 in HDC-normal mode as the I/O Registry lists it.
fn board(attachment: u64) -> UsbHostDevice {
    UsbHostDevice {
        serial: "0123456789ABCDEF".into(),
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
        topology: "337641472".into(),
        product_name: Some("\"HDC Device\"".into()),
        registry_entry_id: Some(attachment),
    }
}

/// The Runtime's own reader over a census the test hands it in place of the
/// host's I/O Registry, so that nothing here depends on this host's USB
/// devices: the board, and another vendor's device the reader passes over.
/// The census counts its reads.
fn registry(
    reads: Arc<AtomicUsize>,
) -> UsbRegistryRelations<impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable>> {
    UsbRegistryRelations::new(move || {
        reads.fetch_add(1, Ordering::SeqCst);
        Ok(vec![
            board(17),
            UsbHostDevice {
                vendor_id: 0x05ac,
                ..board(18)
            },
        ])
    })
}

#[test]
fn the_runtimes_own_usb_relations_are_read_only_beside_the_managed_registered_hdc() {
    // Beside the registered HDC the composition started as its managed
    // server: the Runtime's own reader, which the owner census names.
    // Composing it reads nothing; every read takes a census of its own.
    let reads = Arc::new(AtomicUsize::new(0));
    let beside = with_trusted_usb(Host::from_environment(), true, registry(reads.clone()));
    assert!(beside.owner_census().contains(&"usbRegistryRelations"));
    assert_eq!(reads.load(Ordering::SeqCst), 0);
    let proved = UsbRelation {
        serial: "0123456789ABCDEF".into(),
        location: "337641472".into(),
        attachment_id: 17,
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
    };
    assert_eq!(beside.usb_relations().relations(), Ok(vec![proved.clone()]));
    assert_eq!(beside.usb_relations().relations(), Ok(vec![proved]));
    assert_eq!(reads.load(Ordering::SeqCst), 2);
    // Another source put in its place is not named as the Runtime's own.
    assert!(
        !beside
            .with_usb_relations(Arc::new(NoUsbRelations))
            .owner_census()
            .contains(&"usbRegistryRelations")
    );

    // Without that server nothing is composed or read: no observation is
    // proved, so adoption stays refused.
    let reads = Arc::new(AtomicUsize::new(0));
    let without = with_trusted_usb(Host::from_environment(), false, registry(reads.clone()));
    assert!(!without.owner_census().contains(&"usbRegistryRelations"));
    assert_eq!(without.usb_relations().relations(), Ok(Vec::new()));
    assert_eq!(reads.load(Ordering::SeqCst), 0);
}
