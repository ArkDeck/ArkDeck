//! Swift `WorkspaceOperationsProvider` for `workspace.build-openharmony@1`
//! (TASK-XPA-015, M3): the typed action — the build preset's resolved
//! invocation, persisted as Swift's `buildOpenHarmony` case — the host
//! landing a Runtime-owned copy declares for its product, and the verdict the
//! provider's `verify` gives a finished child.
//!
//! A build is one process: the preset's pinned executable (a registered DevEco
//! toolchain's Node running its pinned `hvigorw.js`, or ArkDeck's SwiftPM
//! role) with the preset's own closed argv, in the project root. The request
//! selects the preset and supplies no argument. Only a Runtime-owned copy
//! declares a landing: the product its preset names below the copy's root,
//! prepared (its directory made, any stale file removed) before the child
//! starts and read back after it, whatever its status. A person's primary
//! tree yields its log alone, as Swift's.
use crate::workspace_patch::{Detail, Invocation, ToolReceipt, failed_detail, output_summary};
use crate::workspace_support as support;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

/// The operation this module serves.
pub(crate) const BUILD: &str = "workspace.build-openharmony@1";
/// Swift's bound on a landed build product.
pub(crate) const MAXIMUM_PRODUCT_BYTES: u64 = 64 * 1024 * 1024;
const ZIP_MAGIC: [u8; 4] = [0x50, 0x4b, 0x03, 0x04];

/// Swift `WorkspaceProviderAction.buildOpenHarmony`: the invocation the
/// preset resolved to for this Job's project.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BuildAction {
    pub(crate) invocation: Invocation,
}

impl BuildAction {
    /// Swift's synthesized encoding of the action enum.
    fn value(&self) -> Value {
        json!({"buildOpenHarmony": {"_0": self.invocation.value()}})
    }

    /// Swift `PersistedTypedProviderAction`: the workspace action's canonical
    /// JSON, base64.
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let bytes = crate::session_json::encode(&self.value()).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for a build: the
    /// exact typed action a record persisted, or why it cannot be one.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, Detail> {
        let kind = persisted["kind"].as_str().unwrap_or_default();
        if kind != "workspace.action" {
            return Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            ));
        }
        persisted["arguments"]["payload"]
            .as_str()
            .and_then(crate::agent_execution::unbase64)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|payload| Invocation::decode(&payload.get("buildOpenHarmony")?["_0"]))
            .map(|invocation| Self { invocation })
            .ok_or_else(|| "persisted workspace.action is not a build action".to_owned())
    }

    /// Swift `journalStep`'s arguments for `buildWorkspaceOpenHarmony`: the
    /// request's project and preset, as the caller named them.
    pub(crate) fn journal_arguments(inputs: &serde_json::Map<String, Value>) -> Value {
        json!({
            "projectRef": inputs.get("projectRef"),
            "buildPresetRef": inputs.get("buildPresetRef"),
        })
    }
}

/// Swift `HostLandingExpectation` for a copy's build product.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Landing {
    /// The absolute destination the preset names below the copy's root.
    pub(crate) destination: String,
}

/// Swift `ProviderLandedArtifact`: what is actually at the destination.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Landed {
    pub(crate) path: String,
    pub(crate) byte_count: u64,
    /// Absent for an empty or over-budget file, which is not hashed.
    pub(crate) sha256: Option<String>,
    pub(crate) leading: Vec<u8>,
}

impl Landing {
    /// Swift `prepareDestination()`: the directory made, any stale file at
    /// the destination removed, so a leftover can never be read back as this
    /// build's product.
    pub(crate) fn prepare(&self) -> std::io::Result<()> {
        let destination = Path::new(&self.destination);
        if let Some(parent) = destination.parent() {
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
        }
        match fs::symlink_metadata(destination) {
            Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(destination),
            Ok(_) => fs::remove_file(destination),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    /// Swift `inspectLanded()`: the regular file at the destination, never
    /// through a link; an empty or over-budget one is reported unhashed, and
    /// one that cannot be read whole is not reported at all.
    pub(crate) fn inspect(&self) -> Option<Landed> {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&self.destination)
            .ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() {
            return None;
        }
        let byte_count = metadata.size();
        if byte_count == 0 || byte_count > MAXIMUM_PRODUCT_BYTES {
            return Some(Landed {
                path: self.destination.clone(),
                byte_count,
                sha256: None,
                leading: Vec::new(),
            });
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(byte_count.saturating_add(1))
            .read_to_end(&mut bytes)
            .ok()?;
        if bytes.len() as u64 != byte_count {
            return None;
        }
        Some(Landed {
            path: self.destination.clone(),
            byte_count,
            sha256: Some(support::sha256(&bytes)),
            leading: bytes.iter().take(8).copied().collect(),
        })
    }
}

/// How a finished build child was judged: Swift's `.verified` summary or its
/// `.failed` code and detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum BuildVerdict {
    Verified(BTreeMap<String, String>),
    Failed(&'static str, String),
}

/// Swift `WorkspaceOperationsProvider.verify` for `.buildOpenHarmony`: the
/// output complete, the exit status zero, and — for a copy whose preset
/// declares a product — a bounded ZIP-headed product that landed; the
/// summary then names the product's digest and size.
pub(crate) fn verify(
    receipt: &ToolReceipt,
    declares_product: bool,
    landed: Option<&Landed>,
) -> BuildVerdict {
    if receipt.truncated {
        return BuildVerdict::Failed(
            "workspace.outputTruncated",
            "bounded output was truncated; semantic result is incomplete".into(),
        );
    }
    if receipt.exit_status != 0 {
        return BuildVerdict::Failed("workspace.buildFailed", failed_detail(receipt));
    }
    let mut summary: BTreeMap<String, String> = output_summary(receipt)
        .into_iter()
        .filter_map(|(key, value)| Some((key, value.as_str()?.to_owned())))
        .collect();
    if declares_product {
        let Some((landed, sha256)) = landed.and_then(|landed| {
            landed
                .sha256
                .as_ref()
                .filter(|_| landed.byte_count > 0 && landed.leading.starts_with(&ZIP_MAGIC))
                .map(|sha256| (landed, sha256))
        }) else {
            return BuildVerdict::Failed(
                "workspace.buildProductMissing",
                "build succeeded without its declared bounded HAP product".into(),
            );
        };
        summary.insert("unsignedHapSha256".into(), sha256.clone());
        summary.insert("unsignedHapByteCount".into(), landed.byte_count.to_string());
    }
    BuildVerdict::Verified(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invocation() -> Invocation {
        Invocation {
            operation: BUILD.into(),
            project_ref: "evolution-0123456789abcdef0123".into(),
            project_root: "/tmp/root".into(),
            preset_id: "preset-build".into(),
            executable_path: "/tmp/node".into(),
            executable_sha256: "a".repeat(64),
            argument_zero: None,
            arguments: vec!["/tmp/hvigorw.js".into(), "assembleHap".into()],
            timeout_seconds: 60,
        }
    }

    #[test]
    fn a_build_action_round_trips_through_its_persisted_form() {
        let action = BuildAction {
            invocation: invocation(),
        };
        let persisted = action.persisted().unwrap();
        assert_eq!(persisted["kind"], "workspace.action");
        assert_eq!(BuildAction::materialize(&persisted).unwrap(), action);
        let other = json!({"kind": "workspace.action", "arguments": {"payload":
            crate::agent_execution::base64(br#"{"applyPatch":{"_0":{}}}"#)}});
        assert!(BuildAction::materialize(&other).is_err());
    }

    fn receipt(status: i32, truncated: bool) -> ToolReceipt {
        ToolReceipt {
            exit_status: status,
            stdout: b"BUILD SUCCESSFUL\n".to_vec(),
            stderr: Vec::new(),
            truncated,
        }
    }

    #[test]
    fn a_build_is_judged_as_swift_judges_it() {
        let landed = Landed {
            path: "/tmp/p.hap".into(),
            byte_count: 10,
            sha256: Some("b".repeat(64)),
            leading: b"PK\x03\x04xxxx".to_vec(),
        };
        assert_eq!(
            verify(&receipt(0, true), true, Some(&landed)),
            BuildVerdict::Failed(
                "workspace.outputTruncated",
                "bounded output was truncated; semantic result is incomplete".into()
            )
        );
        assert_eq!(
            verify(&receipt(2, false), true, Some(&landed)),
            BuildVerdict::Failed(
                "workspace.buildFailed",
                "real process exit=2 stdoutBytes=17 stderrBytes=0".into()
            )
        );
        let BuildVerdict::Verified(summary) = verify(&receipt(0, false), true, Some(&landed))
        else {
            panic!("a landed product verifies")
        };
        assert_eq!(summary["unsignedHapSha256"], "b".repeat(64));
        assert_eq!(summary["unsignedHapByteCount"], "10");
        let BuildVerdict::Verified(summary) = verify(&receipt(0, false), false, None) else {
            panic!("a tree without a declared product verifies on its log")
        };
        assert!(!summary.contains_key("unsignedHapSha256"));
        for missing in [
            None,
            Some(Landed {
                sha256: None,
                ..landed.clone()
            }),
            Some(Landed {
                leading: b"MZ".to_vec(),
                ..landed.clone()
            }),
        ] {
            assert_eq!(
                verify(&receipt(0, false), true, missing.as_ref()),
                BuildVerdict::Failed(
                    "workspace.buildProductMissing",
                    "build succeeded without its declared bounded HAP product".into()
                )
            );
        }
    }

    #[test]
    fn a_landing_clears_a_stale_product_and_reads_back_what_landed() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-workspace-build-landing-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        let landing = Landing {
            destination: root
                .join("entry/build/default/outputs/default/p.hap")
                .to_str()
                .unwrap()
                .to_owned(),
        };
        landing.prepare().unwrap();
        assert_eq!(landing.inspect(), None, "nothing landed yet");
        fs::write(&landing.destination, b"stale").unwrap();
        landing.prepare().unwrap();
        assert_eq!(landing.inspect(), None, "a stale product is removed");
        fs::write(&landing.destination, b"PK\x03\x04product").unwrap();
        let landed = landing.inspect().unwrap();
        assert_eq!(landed.byte_count, 11);
        assert_eq!(
            landed.sha256.as_deref(),
            Some(support::sha256(b"PK\x03\x04product").as_str())
        );
        assert_eq!(landed.leading, b"PK\x03\x04prod");
        fs::write(&landing.destination, b"").unwrap();
        assert_eq!(landing.inspect().unwrap().sha256, None, "empty is unhashed");
        fs::remove_file(&landing.destination).unwrap();
        std::os::unix::fs::symlink("/etc/hosts", &landing.destination).unwrap();
        assert_eq!(landing.inspect(), None, "a link is never followed");
        fs::remove_dir_all(&root).unwrap();
    }
}
