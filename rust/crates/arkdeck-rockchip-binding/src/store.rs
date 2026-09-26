//! Swift `RockchipProductBindingStore`, `RockchipProductBindingSnapshot` and
//! `RockchipProductBindingBootstrap` (`RockchipDeviceBinding.swift`): the
//! owner-only cross-mode binding of a DAYU200, `rockchip-binding.json` in the
//! Application Support root (the parent of the daemon state directory), its
//! document, its lock and every write of it — the CLI's install and the
//! Loader binding owner's compare-and-swap writes.
//!
//! Every access prepares the root as Swift's does — created owner-only when
//! absent and made owner-only whether or not it existed — and every refusal
//! is Swift's `productionConfigurationUnavailable` detail.
use crate::identity::{ROCKUSB_VENDOR_ID, registered_dayu200_devices};
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{
    DocumentPublishError, HostDirectory, OwnerOnlyReadFailure, RegistryUnavailable, UsbHostDevice,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Swift `RockchipFlashExecutionError.productionConfigurationUnavailable`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingError(&'static str);

impl BindingError {
    pub fn detail(&self) -> &'static str {
        self.0
    }

    /// The error as Swift's daemon interpolates it.
    pub fn swift(&self) -> String {
        format!(
            "productionConfigurationUnavailable({})",
            swift_quoted(self.0)
        )
    }
}

/// A refusal with its Swift detail; every detail is a static ASCII literal.
pub fn refuse(detail: &'static str) -> BindingError {
    BindingError(detail)
}

/// The store at one root.
pub struct RockchipBindingStore {
    root: PathBuf,
}

/// Swift `RockchipProductBindingSnapshot`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingSnapshot {
    pub revision: i64,
    pub serial: String,
    pub usb_topology: String,
    pub evidence: Vec<String>,
}

impl RockchipBindingStore {
    /// Swift `bindingFileName`.
    pub const FILE_NAME: &'static str = "rockchip-binding.json";
    /// Swift `maximumDocumentBytes`.
    pub const MAXIMUM_BYTES: usize = 64 * 1_024;
    /// Swift `lockFileName`.
    pub const LOCK_NAME: &'static str = ".rockchip-binding.lock";

    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    /// Swift `loadIfPresent()`: the root prepared, then the document read
    /// without a lock — `None` when absent.
    pub fn load_if_present(&self) -> Result<Option<BindingSnapshot>, BindingError> {
        let root = self.prepare_root()?;
        Self::load(&root)
    }

    /// Swift `loadExisting()`: as [`Self::load_if_present`], but an absent
    /// binding refuses.
    pub fn load_existing(&self) -> Result<BindingSnapshot, BindingError> {
        self.load_if_present()?
            .ok_or_else(|| refuse("durable Rockchip binding is not installed"))
    }

    /// Swift `install(_:rebind:)`: under the binding's lock, the binding
    /// already naming the candidate's serial on its port is kept as it is
    /// (`false`); another binding is replaced only when the operator said so
    /// (`rebind`); otherwise the candidate is published, refusing to clobber
    /// a binding a writer outside the lock published meanwhile, then read
    /// back (`true`).
    pub fn install(
        &self,
        candidate: &BindingSnapshot,
        rebind: bool,
    ) -> Result<(BindingSnapshot, bool), BindingError> {
        candidate.validate()?;
        let root = self.prepare_root()?;
        let _lock = self.lock(&root)?;
        if let Some(existing) = Self::load(&root)? {
            if existing.serial == candidate.serial
                && existing.usb_topology == candidate.usb_topology
            {
                return Ok((existing, false));
            }
            // A board moved to another port, or another board on the bench:
            // every destructive admission matches this binding, so it drifts
            // only when a person says so.
            if !rebind {
                return Err(refuse(
                    "durable binding differs from the only connected Loader; explicit rebind is \
                     required",
                ));
            }
        }
        let document = candidate.encode();
        if document.len() > Self::MAXIMUM_BYTES {
            return Err(refuse("binding document exceeds its product limit"));
        }
        // Swift renames with `RENAME_EXCL` unless this is a rebind, the one
        // write that must replace a binding. Its temporary file's failures
        // are one refusal here: nothing was renamed into place.
        let published = if rebind {
            root.publish_document(Self::FILE_NAME, &document, Self::MAXIMUM_BYTES)
        } else {
            root.publish_exclusive(Self::FILE_NAME, &document)
        };
        published.map_err(|error| {
            refuse(match error {
                DocumentPublishError::BeforePublication(_) => {
                    "binding publication cannot be committed"
                }
                DocumentPublishError::OutcomeUnknown(_) => {
                    "binding directory cannot be synchronized"
                }
            })
        })?;
        match Self::load(&root)? {
            Some(readback) if readback == *candidate => Ok((readback, true)),
            _ => Err(refuse("binding write-readback failed")),
        }
    }

    /// Swift `replace(expectedRevision:expectedSerialSHA256:with:)`: exactly
    /// the expected binding replaced by the one adjacent revision a Loader
    /// rebind observed. The caller has applied the rebind policy.
    pub fn replace(
        &self,
        expected_revision: i64,
        expected_serial_sha256: &str,
        candidate: &BindingSnapshot,
    ) -> Result<BindingSnapshot, BindingError> {
        self.compare_and_swap(
            expected_revision,
            expected_serial_sha256,
            expected_revision.saturating_add(1),
            candidate,
            "durable binding changed before Loader rebind",
        )
    }

    /// Swift `activateSelectedInitialTarget(expectedRevision:
    /// expectedSerialSHA256:with:)`: the singleton binding switched to an
    /// adopted revision-1 Target of another identity, with the selection it
    /// was made by — never a revision advance.
    pub fn activate_selected_initial_target(
        &self,
        expected_revision: i64,
        expected_serial_sha256: &str,
        candidate: &BindingSnapshot,
    ) -> Result<BindingSnapshot, BindingError> {
        if candidate.revision != 1
            || candidate.identity() == expected_serial_sha256
            || !candidate
                .evidence
                .iter()
                .any(|entry| entry.starts_with("rebind:user-selection-sha256="))
        {
            return Err(refuse("selected initial target binding is invalid"));
        }
        self.compare_and_swap(
            expected_revision,
            expected_serial_sha256,
            1,
            candidate,
            "durable binding changed before selected target activation",
        )
    }

    /// Swift `compareAndSwap`: under the binding's lock, the document
    /// replaced only while it is still the expected revision of the expected
    /// serial, then read back.
    pub fn compare_and_swap(
        &self,
        expected_revision: i64,
        expected_serial_sha256: &str,
        required_candidate_revision: i64,
        candidate: &BindingSnapshot,
        mismatch: &'static str,
    ) -> Result<BindingSnapshot, BindingError> {
        candidate.validate()?;
        let root = self.prepare_root()?;
        let _lock = self.lock(&root)?;
        let existing = Self::load(&root)?
            .ok_or_else(|| refuse("durable Rockchip binding is not installed"))?;
        if existing.revision != expected_revision
            || existing.identity() != expected_serial_sha256
            || candidate.revision != required_candidate_revision
        {
            return Err(refuse(mismatch));
        }
        let document = candidate.encode();
        if document.len() > Self::MAXIMUM_BYTES {
            return Err(refuse("binding document exceeds its product limit"));
        }
        root.publish_document(Self::FILE_NAME, &document, Self::MAXIMUM_BYTES)
            .map_err(|error| {
                refuse(match error {
                    // Nothing was renamed into place.
                    DocumentPublishError::BeforePublication(_) => {
                        "binding replacement cannot be committed"
                    }
                    // Renamed, but not proved durable.
                    DocumentPublishError::OutcomeUnknown(_) => {
                        "binding directory cannot be synchronized"
                    }
                })
            })?;
        match Self::load(&root)? {
            Some(readback) if readback == *candidate => Ok(readback),
            _ => Err(refuse("binding replacement readback failed")),
        }
    }

    /// Swift's binding lock: `.rockchip-binding.lock`, created owner-only
    /// when absent, exactly mode 0600, taken exclusively and waited for; it
    /// is unlocked explicitly when dropped.
    fn lock(&self, root: &HostDirectory) -> Result<arkdeck_platform::HostReadLock, BindingError> {
        let lock = root.wait_lock(Self::LOCK_NAME, false).map_err(|error| {
            refuse(match error.kind() {
                std::io::ErrorKind::InvalidData => {
                    "binding lock must be an owner-only regular file"
                }
                // A blocking exclusive `flock` on an open regular file fails
                // only where the volume has no locks; every other failure is
                // the open's (a link in the lock's place, a missing root).
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Unsupported => {
                    "binding lock cannot be acquired"
                }
                _ => "binding lock cannot be opened",
            })
        })?;
        match root.document_metadata(Self::LOCK_NAME) {
            Ok(metadata)
                if std::os::unix::fs::PermissionsExt::mode(&metadata.permissions()) & 0o777
                    == 0o600 =>
            {
                Ok(lock)
            }
            _ => Err(refuse("binding lock must be an owner-only regular file")),
        }
    }

    /// Swift `load(rootDescriptor:)`: the document at the prepared root read
    /// owner-only, its four members decoded and validated; `None` when absent.
    fn load(root: &HostDirectory) -> Result<Option<BindingSnapshot>, BindingError> {
        let Some(bytes) = root
            .read_owner_only_detailed(Self::FILE_NAME, Self::MAXIMUM_BYTES)
            .map_err(|refused| {
                refuse(match refused {
                    OwnerOnlyReadFailure::Open(_) => "durable binding cannot be opened",
                    OwnerOnlyReadFailure::Identity => {
                        "durable binding must be an owner-only regular file"
                    }
                    OwnerOnlyReadFailure::Size => "durable binding size is invalid",
                    OwnerOnlyReadFailure::Truncated => "durable binding was truncated",
                })
            })?
        else {
            return Ok(None);
        };
        let snapshot = decode(&bytes)?;
        snapshot.validate()?;
        Ok(Some(snapshot))
    }

    /// Swift `prepareRoot()`: an absolute root that is no link, created
    /// owner-only when absent and made owner-only.
    fn prepare_root(&self) -> Result<HostDirectory, BindingError> {
        if !self.root.is_absolute() {
            return Err(refuse("binding root must be an absolute file URL"));
        }
        if std::fs::symlink_metadata(&self.root).is_ok_and(|metadata| metadata.is_symlink()) {
            return Err(refuse("binding root cannot be a symbolic link"));
        }
        HostDirectory::open_or_create_private(&self.root)
            .map_err(|_| refuse("binding root cannot be opened"))
    }
}

/// Swift `RockchipDeviceBindingInstallationReceipt`: the binding an install
/// left, and whether it wrote it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingInstallation {
    pub revision: i64,
    pub usb_topology: String,
    pub serial_digest_sha256: String,
    pub created: bool,
}

/// Swift `RockchipProductBindingBootstrap.installCurrentTarget(rebind:)`
/// (`arkdeck flash install-binding [--rebind]`) over one census of the host's
/// I/O Registry: exactly one DAYU200 in a registered personality, HDC-normal
/// or Loader (`RockchipProductUSBProbe.singleDAYU200()`), durably adopted as
/// the cross-mode binding. A rebind continues the lineage from the binding it
/// replaces, with the operator's selection. The census is only read: nothing
/// is dispatched to the device. `Err` is the refusal as Swift's CLI
/// interpolates it.
pub fn install_current_target(
    census: impl FnOnce() -> Result<Vec<UsbHostDevice>, RegistryUnavailable>,
    store: &RockchipBindingStore,
    rebind: bool,
) -> Result<BindingInstallation, String> {
    let admission = |detail: &str| format!("admissionRejected({})", swift_quoted(detail));
    let devices = census().map_err(|_| admission("USB registry unavailable"))?;
    let mut found = registered_dayu200_devices(devices);
    let identity = match found.len() {
        1 => found.remove(0),
        0 => return Err(admission("DAYU200 target unavailable")),
        _ => return Err(admission("DAYU200 target ambiguous")),
    };
    if identity.serial.is_empty()
        || identity.topology.is_empty()
        || !identity.topology.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(admission(
            "the single USB identity is not a registered DAYU200 mode",
        ));
    }
    let mut evidence = vec![
        "product:e0-iokit-single-dayu200-readback".to_owned(),
        format!(
            "usb:vendor={},profile=dayu200-cross-mode",
            ROCKUSB_VENDOR_ID
        ),
        format!(
            "identity:serial-sha256={}",
            sha256_hex(identity.serial.as_bytes())
        ),
    ];
    // A rebind continues the lineage rather than restarting it: without the
    // previous identity, revision and port, the adjacent edge a Job bound to
    // the old identity is settled along would not exist.
    let mut revision = 1;
    if rebind && let Some(previous) = store.load_if_present().map_err(|error| error.swift())? {
        revision = previous.revision.saturating_add(1);
        evidence.push(format!(
            "identity:previous-serial-sha256={}",
            previous.identity()
        ));
        evidence.push(format!("binding:previous-revision={}", previous.revision));
        evidence.push(format!(
            "binding:previous-usb-topology={}",
            previous.usb_topology
        ));
        // What the operator selected — this device on this port — rather
        // than a bare yes.
        evidence.push(format!(
            "rebind:user-selection-sha256={}",
            sha256_hex(format!("{}|{}", identity.serial, identity.topology).as_bytes())
        ));
    }
    let candidate = BindingSnapshot {
        revision,
        serial: identity.serial,
        usb_topology: identity.topology,
        evidence,
    };
    let (snapshot, created) = store
        .install(&candidate, rebind)
        .map_err(|error| error.swift())?;
    Ok(BindingInstallation {
        revision: snapshot.revision,
        serial_digest_sha256: snapshot.identity(),
        usb_topology: snapshot.usb_topology,
        created,
    })
}

/// Swift `load(rootDescriptor:)` after the read: the top level must be an
/// object with exactly the four members, then `JSONDecoder` reads them.
fn decode(bytes: &[u8]) -> Result<BindingSnapshot, BindingError> {
    // Swift's `JSONSerialization` failure escapes unwrapped as Foundation's
    // own error; a document that is not JSON is refused as undecodable here.
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| refuse("durable binding cannot be decoded"))?;
    let schema = || refuse("durable binding schema is invalid");
    let object = value.as_object().ok_or_else(schema)?;
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    if keys != ["evidence", "revision", "serial", "usbTopology"] {
        return Err(schema());
    }
    let undecodable = || refuse("durable binding cannot be decoded");
    let text = |key: &str| {
        object[key]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(undecodable)
    };
    Ok(BindingSnapshot {
        revision: object["revision"]
            .as_number()
            .and_then(swift_integer)
            .ok_or_else(undecodable)?,
        serial: text("serial")?,
        usb_topology: text("usbTopology")?,
        evidence: object["evidence"]
            .as_array()
            .ok_or_else(undecodable)?
            .iter()
            .map(|entry| entry.as_str().map(str::to_owned).ok_or_else(undecodable))
            .collect::<Result<_, _>>()?,
    })
}

impl BindingSnapshot {
    /// The document as Swift's store writes it: `JSONEncoder` with
    /// `.sortedKeys` (every slash escaped) and one trailing newline.
    pub fn encode(&self) -> Vec<u8> {
        let text = |value: &str| {
            serde_json::to_string(value)
                .expect("a string always encodes")
                .replace('/', "\\/")
        };
        let evidence: Vec<String> = self.evidence.iter().map(|entry| text(entry)).collect();
        format!(
            "{{\"evidence\":[{}],\"revision\":{},\"serial\":{},\"usbTopology\":{}}}\n",
            evidence.join(","),
            self.revision,
            text(&self.serial),
            text(&self.usb_topology)
        )
        .into_bytes()
    }

    /// Swift `validate(_:)`.
    pub fn validate(&self) -> Result<(), BindingError> {
        let valid = self.revision > 0
            && !self.serial.is_empty()
            && !self.usb_topology.is_empty()
            && self.usb_topology.bytes().all(|byte| byte.is_ascii_digit())
            && !self.evidence.is_empty()
            && self
                .evidence
                .iter()
                .all(|entry| !entry.is_empty() && !entry.contains(self.serial.as_str()));
        if valid {
            Ok(())
        } else {
            Err(refuse("durable binding snapshot is invalid"))
        }
    }

    /// Swift `values(prefix:)`: every entry's text after the prefix, in order.
    pub fn values(&self, prefix: &str) -> Vec<&str> {
        self.evidence
            .iter()
            .filter_map(|entry| entry.strip_prefix(prefix))
            .collect()
    }

    /// The digest of the bound serial, the identity every comparison uses.
    pub fn identity(&self) -> String {
        sha256_hex(self.serial.as_bytes())
    }
}

/// Swift's `debugDescription` of a `String` for the ASCII text every detail
/// here is: `\0`, `\t`, `\n`, `\r`, `\"`, `\'` and `\\` escaped, any other
/// ASCII control spelled `\u{XX}` with two upper-case digits, anything else
/// as itself, between quotes. (The Runtime's general rendering, which also
/// spells the marks and joiners a non-ASCII text may carry, is
/// `arkdeck-hoststore`'s; no detail of this store has one.)
pub(crate) fn swift_quoted(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for scalar in text.chars() {
        match scalar {
            '\0' => quoted.push_str("\\0"),
            '\t' => quoted.push_str("\\t"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '"' => quoted.push_str("\\\""),
            '\'' => quoted.push_str("\\'"),
            '\\' => quoted.push_str("\\\\"),
            control if control.is_ascii_control() => {
                quoted.push_str(&format!("\\u{{{:02X}}}", u32::from(control)));
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

/// Foundation's `Int` of a JSON number: an integer, or a number with no
/// fraction, inside `Int`'s range.
fn swift_integer(number: &serde_json::Number) -> Option<i64> {
    number.as_i64().or_else(|| {
        number
            .as_f64()
            .filter(|float| {
                float.fract() == 0.0 && *float >= i64::MIN as f64 && *float < i64::MAX as f64
            })
            .map(|float| float as i64)
    })
}
