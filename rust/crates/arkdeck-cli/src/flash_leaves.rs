//! The Flash leaves that read or repair what the Runtime keeps about a board
//! without changing the board: `flash bootloader-status`, `flash
//! prerequisites`, `flash lane-preview`, `flash reconcile-alias`, `flash
//! bind-loader` and `recovery flash-invocation list|start|evaluate|status`,
//! with `debug start|evaluate|status`, the legacy spelling of the last three.
//! Each is one request, answered as the Runtime answers it (Swift
//! `runFlashObservation` and `emitFlashInvocation`); every judgement of the
//! board, the binding, the alias, the archive and the invocation documents is
//! the Runtime's.
use crate::CliError;
use serde_json::{Map, Value, json};

fn invalid(message: &str) -> CliError {
    CliError::new("invalidOption", message)
}

/// The registry's `hexDigest(length: 64)` grammar, which Swift's parser
/// judges before the handler runs: the refusal names the leaf's path and the
/// option.
fn digest(
    command: &str,
    fields: &Map<String, Value>,
    key: &str,
    option: &str,
) -> Result<(), CliError> {
    if fields
        .get(key)
        .is_some_and(crate::session_resources::digest)
    {
        return Ok(());
    }
    Err(invalid(&format!(
        "`{}` {option} must be 64 lowercase hex digits",
        command.replace('.', " ")
    )))
}

/// The registry's grammar of each leaf's options, judged before any request:
/// the required options present, a revision a positive integer, a page size
/// within 1…1000 (100 when none is given, as Swift sends it).
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if help {
        return Ok(());
    }
    match command {
        // Swift sends the profile as the Runtime's `profileReference`; which
        // profiles are supported is the Runtime's to judge.
        "flash.prerequisites" => {
            if !fields.contains_key("targetId") {
                return Err(invalid("flash prerequisites requires --target"));
            }
            let profile = fields
                .remove("deviceProfile")
                .ok_or_else(|| invalid("flash prerequisites requires --device-profile"))?;
            fields.insert("profileReference".into(), profile);
        }
        // The same two, and the imported archive's digest, which the
        // registry requires as 64 lowercase hex digits (Swift's daemon itself
        // takes any 64 hex digits); which archive it names is the Runtime's.
        "flash.lane-preview" => {
            if !fields.contains_key("targetId") {
                return Err(invalid("flash lane-preview requires --target"));
            }
            let profile = fields
                .remove("deviceProfile")
                .ok_or_else(|| invalid("flash lane-preview requires --device-profile"))?;
            fields.insert("profileReference".into(), profile);
            if !fields.contains_key("archiveSha256") {
                return Err(invalid("flash lane-preview requires --archive-sha256"));
            }
            digest(command, fields, "archiveSha256", "--archive-sha256")?;
        }
        // Both name a Target and the revision the caller saw; Swift sends
        // the revision as an integer.
        "flash.reconcile-alias" | "flash.bind-loader" => {
            let leaf = if command == "flash.bind-loader" {
                "flash bind-loader"
            } else {
                "flash reconcile-alias"
            };
            if !fields.contains_key("targetId") {
                return Err(invalid(&format!("{leaf} requires --target")));
            }
            let text = fields
                .get("expectedBindingRevision")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid(&format!("{leaf} requires --expected-binding-revision")))?;
            let revision = text
                .parse::<i64>()
                .ok()
                .filter(|revision| *revision >= 1 && revision.to_string() == text)
                .ok_or_else(|| {
                    invalid(&format!(
                        "{leaf} --expected-binding-revision must be a positive integer"
                    ))
                })?;
            fields.insert("expectedBindingRevision".into(), json!(revision));
        }
        "recovery.flash-invocation.list" => {
            let size = match fields.get("pageSize") {
                None => 100,
                Some(value) => value
                    .as_str()
                    .and_then(|text| text.parse::<u64>().ok())
                    .filter(|size| (1..=1000).contains(size))
                    .ok_or_else(|| invalid("page-size must be between 1 and 1000"))?,
            };
            fields.insert("pageSize".into(), json!(size));
        }
        "recovery.flash-invocation.status" | "debug.status"
            if !fields.contains_key("invocationId") =>
        {
            return Err(invalid(
                "flash-invocation status requires --invocation <id>",
            ));
        }
        "recovery.flash-invocation.start" | "debug.start"
            if !fields.contains_key("requestFile") =>
        {
            return Err(invalid("flash-invocation requires --request-file"));
        }
        "recovery.flash-invocation.evaluate" | "debug.evaluate" => {
            if ["invocationId", "sourceSha256", "buildSha256"]
                .iter()
                .any(|key| !fields.contains_key(*key))
            {
                return Err(invalid(
                    "flash-invocation evaluate requires --invocation, --action-file, \
                     --source-sha256 and --build-sha256",
                ));
            }
            if !fields.contains_key("actionFile") {
                return Err(invalid("flash-invocation requires --action-file"));
            }
            // The current spelling's registry takes both digests as 64
            // lowercase hex digits; the legacy one takes them opaque, and
            // the Runtime judges what it is sent.
            if command == "recovery.flash-invocation.evaluate" {
                digest(command, fields, "sourceSha256", "--source-sha256")?;
                digest(command, fields, "buildSha256", "--build-sha256")?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Whether `command` is one of the Flash recovery broker's two leaves, each
/// spelled as its current and its legacy path.
pub fn is_broker_leaf(command: &str) -> bool {
    matches!(
        command,
        "recovery.flash-invocation.start"
            | "debug.start"
            | "recovery.flash-invocation.evaluate"
            | "debug.evaluate"
    )
}

/// The broker leaf's request, as Swift's `emitFlashInvocation` sends it:
/// each named document read whole, as UTF-8 text, before anything is sent.
pub fn broker_params(fields: &Map<String, Value>) -> Result<Map<String, Value>, CliError> {
    let document = |key: &str| -> Result<Value, CliError> {
        let path = fields.get(key).and_then(Value::as_str).unwrap_or_default();
        std::fs::read_to_string(path)
            .map(Value::String)
            .map_err(|_| CliError::new("ioFailure", format!("cannot read {path}")))
    };
    if fields.contains_key("requestFile") {
        return Ok(Map::from_iter([(
            "requestJson".to_owned(),
            document("requestFile")?,
        )]));
    }
    let mut params = Map::new();
    for key in ["invocationId", "sourceSha256", "buildSha256"] {
        params.insert(key.into(), fields[key].clone());
    }
    params.insert("actionJson".into(), document("actionFile")?);
    Ok(params)
}

/// Swift `runInstallBinding` (`flash install-binding [--rebind]`), below its
/// rendering: the DAYU200 cross-mode binding installed in this process, as
/// Swift's CLI installs it, from one census of the host's I/O Registry into
/// the Rockchip binding store of the account's Application Support root
/// (`arkdeck-rockchip-binding`, the Runtime's own store). Nothing reaches the
/// Runtime or the device. `Err` is the refusal as Swift's CLI prints it after
/// `arkdeck flash: `.
#[cfg(target_os = "macos")]
pub fn install_binding(
    rebind: bool,
    application_support_root: &std::path::Path,
    census: impl FnOnce() -> Result<
        Vec<arkdeck_platform::UsbHostDevice>,
        arkdeck_platform::RegistryUnavailable,
    >,
) -> Result<arkdeck_rockchip_binding::BindingInstallation, String> {
    arkdeck_rockchip_binding::install_current_target(
        census,
        &arkdeck_rockchip_binding::RockchipBindingStore::new(application_support_root),
        rebind,
    )
}

/// Swift's machine answer of an install: the binding's revision and USB
/// topology, and whether this install wrote it.
#[cfg(target_os = "macos")]
pub fn install_binding_result(installed: &arkdeck_rockchip_binding::BindingInstallation) -> Value {
    json!({
        "created": installed.created,
        "bindingRevision": installed.revision,
        "usbTopology": installed.usb_topology,
    })
}

/// Swift's human answer of an install, line for line.
#[cfg(target_os = "macos")]
pub fn install_binding_human(installed: &arkdeck_rockchip_binding::BindingInstallation) -> String {
    format!(
        "durable DAYU200 cross-mode binding {}\nbinding revision: {}\nUSB topology: {}\n\
         serial sha256: {}\ndevice mutation dispatch: 0",
        if installed.created {
            "installed"
        } else {
            "unchanged"
        },
        installed.revision,
        installed.usb_topology,
        installed.serial_digest_sha256
    )
}

#[cfg(all(test, target_os = "macos"))]
mod install_binding_tests {
    use super::*;
    use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
    use std::os::unix::fs::PermissionsExt;

    /// A private temporary Application Support root, removed however the
    /// test ends; the account's own is never touched.
    struct Root(std::path::PathBuf);

    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("arkdeck-install-binding-{nonce:x}"));
            std::fs::create_dir(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self(root)
        }
    }

    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn board(serial: &str, topology: &str) -> UsbHostDevice {
        UsbHostDevice {
            serial: serial.into(),
            vendor_id: 0x2207,
            product_id: 0x5000,
            topology: topology.into(),
            product_name: Some("\"HDC Device\"".into()),
            registry_entry_id: Some(0x1_0000_0042),
        }
    }

    /// Swift `runInstallBinding`'s two renderings of a receipt: the result
    /// the envelope carries, and the human lines.
    #[test]
    fn an_install_renders_as_swifts_handler_renders_it() {
        let root = Root::new();
        let store = root.0.join("ArkDeck");
        let first = install_binding(false, &store, || {
            Ok(vec![board("150100424a544e4600", "18874368")])
        })
        .unwrap();
        assert_eq!(
            install_binding_result(&first),
            json!({"created": true, "bindingRevision": 1, "usbTopology": "18874368"})
        );
        assert_eq!(
            install_binding_human(&first),
            "durable DAYU200 cross-mode binding installed\nbinding revision: 1\n\
             USB topology: 18874368\n\
             serial sha256: 83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1\n\
             device mutation dispatch: 0"
        );
        let again = install_binding(false, &store, || {
            Ok(vec![board("150100424a544e4600", "18874368")])
        })
        .unwrap();
        assert!(
            install_binding_human(&again)
                .starts_with("durable DAYU200 cross-mode binding unchanged\n")
        );
        assert_eq!(install_binding_result(&again)["created"], json!(false));
    }

    /// A refusal is the error as Swift's CLI interpolates it after
    /// `arkdeck flash: `, and nothing is written.
    #[test]
    fn a_refusal_is_swifts_interpolated_error() {
        let root = Root::new();
        let store = root.0.join("ArkDeck");
        assert_eq!(
            install_binding(false, &store, || Err(RegistryUnavailable::Matching)).unwrap_err(),
            "admissionRejected(\"USB registry unavailable\")"
        );
        assert_eq!(
            install_binding(false, &store, || Ok(Vec::new())).unwrap_err(),
            "admissionRejected(\"DAYU200 target unavailable\")"
        );
        assert!(!store.exists());
    }
}
