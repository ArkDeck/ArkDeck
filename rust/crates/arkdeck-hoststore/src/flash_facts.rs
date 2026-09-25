//! The Rockchip facts of the Flash host reads: Swift's
//! `ProductRockchipBootloaderStatusObserver` (`flash.bootloader-status`) and
//! `TargetStoreRockchipRuntimeFactsPort` (`currentFacts`, projected by
//! `flash.prerequisites`), over the Target store, the Rockchip binding and the
//! post-flash alias of the Application Support root, the Runtime's USB
//! census, the measured native RockUSB identity and the live mode probe.
//!
//! Both only read. The census reads the host's I/O Registry; the probe runs
//! one `hdc list targets -v`, and when the board is there one allowlisted
//! `param get`, or asks the ArkForge lane for its dual-source Loader
//! observation; nothing is written but the owner-only mode of the Application
//! Support root, which every Swift read of its stores sets. The facts are the
//! pre-admission portrait: a probe that cannot see the board reports it
//! absent rather than failing, and the fail-closed gates stay the engine's
//! fresh readback and reservation at the consume point.
use crate::post_flash_alias::PostFlashBinding;
use crate::post_flash_alias_store::PostFlashAliasStore;
use crate::rockchip_binding::{BindingError, BindingSnapshot, BoundTarget, RockchipBindingStore};
use crate::strict_json::swift_quoted;
use crate::target_owner::TargetStore;
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{
    HdcDispatch, HdcIdentity, LiveModeProbe, LoaderIdentity, LoaderObserver, UsbProbe,
    is_dayu200_hdc_normal, is_dayu200_loader, registered_dayu200_devices,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

#[path = "flash_lane_preview.rs"]
mod lane_preview;
pub use lane_preview::{
    LANE_PREVIEW_UNAVAILABLE, LanePreview, lane_plan_preview, preview_before_lane,
};

/// The host's USB devices, as the Runtime's census reads them.
type Census = dyn Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync;

/// Swift `ArkForgeNativeRockUSBToolchain.identifier`.
pub const NATIVE_ROCKUSB_TOOLCHAIN: &str = "arkforged-native-rockusb";
/// Swift `RockchipFlashProfile.dayu200`: the published firmware fingerprint
/// that alone names the profile, and the profile it names.
const DAYU200_FIRMWARE: &str = "OpenHarmony-7.0.0.35-20260728_180253";
const DAYU200_PROFILE: &str = "dayu200";

/// Swift `RuntimeDispatchFailure.failed(detail)` as it is interpolated.
fn failed(detail: &str) -> String {
    format!("failed({})", swift_quoted(detail))
}

/// Swift `RockchipFlashExecutionError.admissionRejected(detail)`.
fn admission(detail: &str) -> String {
    format!("admissionRejected({})", swift_quoted(detail))
}

pub(crate) fn post_flash(error: crate::post_flash_alias::PostFlashAliasError) -> String {
    format!(
        "productionConfigurationUnavailable({})",
        swift_quoted(error.detail())
    )
}

fn binding(error: BindingError) -> String {
    error.swift()
}

/// Swift `ArkForgeNativeRockUSBExecutableResolver`: the `arkforged` the
/// ArkForge lane was configured with, measured again on every read, so that
/// an update after the lane was configured is caught before any admission.
#[derive(Clone, Debug, Default)]
pub struct NativeRockUsbIdentity {
    daemon: Option<String>,
    declared_sha256: Option<String>,
}

impl NativeRockUsbIdentity {
    /// No lane configured: every read answers so.
    pub fn unconfigured() -> Self {
        Self::default()
    }

    /// The daemon path and the digest the lane declared for it.
    pub fn configured(daemon: Option<String>, declared_sha256: Option<String>) -> Self {
        Self {
            daemon,
            declared_sha256: declared_sha256.map(|digest| digest.to_lowercase()),
        }
    }

    /// Swift `resolveExecutable(providerID: "rockchip")`: the measured digest,
    /// or the error Swift interpolates.
    pub fn resolve(&self) -> Result<String, String> {
        let (Some(path), Some(declared)) = (
            self.daemon.as_deref().filter(|path| !path.is_empty()),
            self.declared_sha256
                .as_deref()
                .filter(|digest| !digest.is_empty()),
        ) else {
            return Err(failed("ArkForge native RockUSB lane is not configured"));
        };
        // Swift `FixedExecutableResolver.hashing(path:providerID:)`.
        if !path.starts_with('/') {
            return Err(failed(
                "provider executable path must be explicit and absolute",
            ));
        }
        let resolved = crate::workspace_support::foundation_resolved(path);
        let regular = || {
            failed(&format!(
                "provider executable must be a regular executable file: {resolved}"
            ))
        };
        let metadata = std::fs::metadata(&resolved).map_err(|error| error.to_string())?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
            return Err(regular());
        }
        let measured = sha256_hex(&std::fs::read(&resolved).map_err(|error| error.to_string())?);
        if measured != declared {
            return Err(failed(
                "arkforged executable digest changed after LaunchAgent installation",
            ));
        }
        Ok(measured)
    }
}

/// The durable Target a read found, as Swift's `RuntimeTargetRecord`.
#[derive(Clone, Debug)]
pub(crate) struct TargetRecord {
    pub(crate) target_id: String,
    pub(crate) identity: String,
    pub(crate) binding_revision: i64,
    pub(crate) connect_key: String,
    pub(crate) adopted_at: String,
}

impl TargetRecord {
    fn bound(&self) -> BoundTarget<'_> {
        BoundTarget {
            target_id: &self.target_id,
            identity_sha256: &self.identity,
            binding_revision: self.binding_revision,
            connect_key: &self.connect_key,
        }
    }
}

/// Swift `RuntimeTargetStore.list()`, with Swift's `storeFailure` when the
/// store cannot be read.
pub(crate) fn target_records(targets: &TargetStore) -> Result<Vec<TargetRecord>, String> {
    let records = targets.records().map_err(|error| {
        format!(
            "storeFailure({})",
            swift_quoted(&format!("undecodable target store: {}", error.message))
        )
    })?;
    Ok(records
        .iter()
        .filter_map(|record| {
            Some(TargetRecord {
                target_id: record["targetID"].as_str()?.to_owned(),
                identity: record["stablePhysicalIdentitySHA256"].as_str()?.to_owned(),
                binding_revision: record["bindingRevision"].as_i64()?,
                connect_key: record["connectKey"].as_str()?.to_owned(),
                adopted_at: record["adoptedAtUTC"].as_str()?.to_owned(),
            })
        })
        .collect())
}

/// Swift `RockchipPostFlashHDCBinding.covers(target:binding:)`.
pub(crate) fn alias_covers(
    alias: &PostFlashBinding,
    target: &TargetRecord,
    binding: &BindingSnapshot,
) -> Result<bool, String> {
    Ok(target.target_id == alias.target_id
        && target.binding_revision == alias.binding_revision
        && target.identity == alias.stable_loader_identity_sha256
        && binding
            .covers_runtime_target(&target.bound())
            .map_err(self::binding)?)
}

/// Swift `ProductRockchipRuntimeUSBProbe` over the Runtime's census: exactly
/// one registered DAYU200 in the personality asked for.
struct CensusProbe<'a>(&'a Census);

impl CensusProbe<'_> {
    fn single(&self, matches: impl Fn(&UsbHostDevice) -> bool) -> Result<UsbHostDevice, String> {
        let devices = (self.0)().map_err(|_| admission("USB registry unavailable"))?;
        let mut found: Vec<UsbHostDevice> = devices.into_iter().filter(|d| matches(d)).collect();
        match found.len() {
            1 => Ok(found.remove(0)),
            0 => Err(admission("DAYU200 target unavailable")),
            _ => Err(admission("DAYU200 target ambiguous")),
        }
    }
}

impl UsbProbe for CensusProbe<'_> {
    fn single_loader(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        let device = self.single(|device| {
            is_dayu200_loader(device)
                && sha256_hex(device.serial.as_bytes()) == stable_identity_sha256
        })?;
        Ok(LoaderIdentity {
            serial_digest_sha256: sha256_hex(device.serial.as_bytes()),
            topology: device.topology,
        })
    }

    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        let device = self.single(|device| {
            is_dayu200_hdc_normal(device)
                && sha256_hex(device.serial.as_bytes()) == stable_identity_sha256
        })?;
        Ok(LoaderIdentity {
            serial_digest_sha256: sha256_hex(device.serial.as_bytes()),
            topology: device.topology,
        })
    }

    fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
        let device =
            self.single(|device| is_dayu200_hdc_normal(device) && device.topology == usb_topology)?;
        Ok(HdcIdentity {
            serial_digest_sha256: sha256_hex(device.serial.as_bytes()),
            connect_key: device.serial,
            topology: device.topology,
        })
    }
}

/// Swift `ProductArkForgeLoaderObserver`: the dual-source proof that the device
/// at the bound identity is a settled DAYU200 RockUSB Loader. The Runtime's
/// census proves the exact bound serial and its current port; the ArkForge
/// lane's daemon, through its public socket, proves independently that the
/// device at that port is that Loader. Read-only; composed whether or not a
/// lane runs — without a daemon on the socket, every observation refuses and
/// the probe reports the board absent.
pub struct ArkForgeLoader {
    census: Arc<Census>,
    runtime_directory: PathBuf,
    timeout: Duration,
}

impl ArkForgeLoader {
    /// Over `census`, reading the lane daemon's public socket in
    /// `runtime_directory` with Swift's 15-second bound.
    pub fn new(
        census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
        runtime_directory: &Path,
    ) -> Self {
        Self::shared(Arc::new(census), runtime_directory)
    }

    fn shared(census: Arc<Census>, runtime_directory: &Path) -> Self {
        Self {
            census,
            runtime_directory: runtime_directory.to_path_buf(),
            timeout: arkdeck_provider_arkforge::LOADER_OBSERVATION_TIMEOUT,
        }
    }
}

impl LoaderObserver for ArkForgeLoader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        let identity = CensusProbe(&*self.census)
            .single_loader(stable_identity_sha256)
            .map_err(|detail| format!("IOKit did not observe the exact bound Loader: {detail}"))?;
        self.confirm_loader(
            &identity,
            stable_identity_sha256,
            expected_usb_topology,
            request_id,
        )
    }

    fn confirm_loader(
        &self,
        identity: &LoaderIdentity,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        if identity.serial_digest_sha256 != stable_identity_sha256 {
            return Err("IOKit Loader identity does not match the bound target".into());
        }
        if let Some(expected) = expected_usb_topology.filter(|expected| !expected.is_empty())
            && identity.topology != expected
        {
            return Err(format!(
                "IOKit observed the bound Loader at USB topology {}, not the admitted topology \
                 {expected}",
                identity.topology
            ));
        }
        arkdeck_provider_arkforge::confirm_loader(
            &self.runtime_directory,
            self.timeout,
            &identity.topology,
        )?;
        Ok(identity.clone())
    }
}

/// The ArkForge lane's Loader observation where none is composed: every
/// observation refuses, which the probe reports as the board being absent.
pub struct NoArkForgeLane;

impl LoaderObserver for NoArkForgeLane {
    fn observe_loader(
        &self,
        _stable_identity_sha256: &str,
        _expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        Err("the ArkForge lane is not composed".to_owned())
    }
}

/// What the facts port measured of one Target (Swift `ProviderFacts`, the
/// fields this Runtime reads).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RockchipFacts {
    pub target_id: String,
    pub binding_revision: i64,
    pub identity_sha256: String,
    pub tool_sha256: String,
    pub execution_connect_key: String,
    pub device_mode: String,
    pub build_fingerprint: Option<String>,
    pub profile_id: String,
    pub server_facts: BTreeMap<String, String>,
}

/// Swift `TargetStoreRockchipRuntimeFactsPort`'s server fact names.
const CROSS_MODE_BINDING: &str = "dayu200CrossModeBinding";
const ALIAS_IDENTITY: &str = "dayu200HDCNormalAliasSHA256";
const ALIAS_TOPOLOGY: &str = "dayu200HDCNormalAliasUSBTopology";

/// The owner of the Rockchip facts over one Application Support root.
pub struct FlashHostFacts {
    bindings: RockchipBindingStore,
    aliases: PostFlashAliasStore,
    census: Arc<Census>,
    rockusb: NativeRockUsbIdentity,
    loader: Box<dyn LoaderObserver + Send + Sync>,
}

impl FlashHostFacts {
    /// Swift's composition over `applicationSupportRoot`: no ArkForge lane
    /// until one is configured, and no Loader observation without it.
    pub fn new(
        application_support_root: &Path,
        census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
    ) -> Self {
        Self {
            bindings: RockchipBindingStore::new(application_support_root),
            aliases: PostFlashAliasStore::new(application_support_root),
            census: Arc::new(census),
            rockusb: NativeRockUsbIdentity::unconfigured(),
            loader: Box::new(NoArkForgeLane),
        }
    }

    /// The `arkforged` the ArkForge lane measures its identity from.
    pub fn with_rockusb(mut self, identity: NativeRockUsbIdentity) -> Self {
        self.rockusb = identity;
        self
    }

    /// The lane's dual-source Loader observation.
    pub fn with_loader_observer(mut self, loader: Box<dyn LoaderObserver + Send + Sync>) -> Self {
        self.loader = loader;
        self
    }

    /// Swift's product Loader observation over this facts owner's census and
    /// the ArkForge lane's public socket in `runtime_directory`, as the live
    /// probe composes it.
    pub fn with_arkforge_loader(self, runtime_directory: &Path) -> Self {
        let loader = ArkForgeLoader::shared(Arc::clone(&self.census), runtime_directory);
        self.with_loader_observer(Box::new(loader))
    }

    /// `flash.bootloader-status`, as Swift's handler answers it.
    pub fn bootloader_status(&self, targets: &TargetStore) -> Result<Value, WireError> {
        self.observe_bootloader_status(targets)
            .map_err(|error| WireError {
                code: "rejected".into(),
                message: format!("Rockchip bootloader status could not be observed: {error}"),
                details: None,
            })
    }

    /// Swift `observeBootloaderStatus()`.
    fn observe_bootloader_status(&self, targets: &TargetStore) -> Result<Value, String> {
        let status =
            |disposition: &str, count: usize, mode: Option<&str>, target: Option<&TargetRecord>| {
                json!({
                    "disposition": disposition,
                    "observationCount": count,
                    "mode": mode,
                    "targetId": target.map(|target| target.target_id.clone()),
                    "bindingRevision": target.map(|target| target.binding_revision),
                })
            };
        let devices = registered_dayu200_devices(
            (self.census)().map_err(|_| admission("USB registry unavailable"))?,
        );
        let [device] = devices.as_slice() else {
            let disposition = if devices.is_empty() {
                "absent"
            } else {
                "ambiguous"
            };
            return Ok(status(disposition, devices.len(), None, None));
        };
        let mode = if is_dayu200_loader(device) {
            "loader"
        } else {
            "hdcNormal"
        };
        let digest = sha256_hex(device.serial.as_bytes());
        let binding = self.bindings.load_if_present().map_err(self::binding)?;
        if is_dayu200_hdc_normal(device)
            && let Some(binding) = &binding
            && let Some(routed) = self.aliases.load_if_present().map_err(post_flash)?
            && let Some(target) = target_records(targets)?
                .into_iter()
                .find(|target| target.target_id == routed.target_id)
            && alias_covers(&routed, &target, binding)?
            && routed.hdc_identity_sha256 == digest
            && routed.usb_topology == device.topology
        {
            if targets.has_conflicting_hdc_alias_owner(
                &target.target_id,
                &routed.hdc_connect_key,
                &routed.hdc_identity_sha256,
                &routed.job_id,
            )? {
                return Ok(status("ambiguous", 1, Some(mode), None));
            }
            return Ok(status("exactBoundTarget", 1, Some(mode), Some(&target)));
        }
        let matching: Vec<TargetRecord> = target_records(targets)?
            .into_iter()
            .filter(|target| target.identity == digest)
            .collect();
        let target = match matching.as_slice() {
            [] => return Ok(status("unbound", 1, Some(mode), None)),
            [target] => target,
            _ => return Ok(status("ambiguous", 1, Some(mode), None)),
        };
        // A decoded historical or otherwise incomplete binding is a safe,
        // actionable onboarding state: it covers nothing, and is no failure.
        let covered = binding.as_ref().is_some_and(|binding| {
            binding
                .covers_runtime_target(&target.bound())
                .unwrap_or(false)
                && binding
                    .matches_confirmed_live_identity(device)
                    .unwrap_or(false)
        });
        Ok(status(
            if covered {
                "exactBoundTarget"
            } else {
                "targetBindingUnprepared"
            },
            1,
            Some(mode),
            Some(target),
        ))
    }

    /// `flash.prerequisites` once its parameters were read, as Swift's
    /// handler answers it; `hdc` is the HDC the live probe reads, none when
    /// the daemon composes no HDC.
    pub fn prerequisites(
        &self,
        targets: &TargetStore,
        hdc: Option<&dyn HdcDispatch>,
        target_id: &str,
        profile_reference: &str,
    ) -> Result<Value, WireError> {
        let rejected = |error: String| WireError {
            code: "rejected".into(),
            message: format!("Flash prerequisites could not be observed: {error}"),
            details: None,
        };
        let Some(target) = target_records(targets)
            .map_err(rejected)?
            .into_iter()
            .find(|target| target.target_id == target_id)
        else {
            return Err(WireError {
                code: "notFound".into(),
                message: "target is not adopted".into(),
                details: None,
            });
        };
        let facts = self
            .current_facts(targets, hdc, target_id)
            .map_err(rejected)?;
        let ready = facts
            .server_facts
            .get(CROSS_MODE_BINDING)
            .map(String::as_str)
            == Some("satisfied");
        let statuses: [&str; 4] = match facts.device_mode.as_str() {
            "loader" if ready => ["satisfied", "satisfied", "satisfied", "unknown"],
            "loader" => ["unknown", "unsatisfied", "unknown", "unknown"],
            "maskrom" => ["unsatisfied", "unsatisfied", "unknown", "unknown"],
            "hdc" if ready => ["satisfied", "satisfied", "satisfied", "unknown"],
            "hdc" => ["unknown", "unsatisfied", "unknown", "unknown"],
            _ => ["unknown", "unknown", "unknown", "unknown"],
        };
        let observations: Vec<Value> = ["loader", "recoveryPath", "unlocked", "stablePower"]
            .iter()
            .zip(statuses)
            .map(|(identifier, status)| json!({"identifier": identifier, "status": status}))
            .collect();
        Ok(json!({
            "targetId": target.target_id,
            "bindingRevision": target.binding_revision,
            "profileReference": profile_reference,
            "observations": observations,
        }))
    }

    /// Swift `TargetStoreRockchipRuntimeFactsPort.currentFacts(targetID:)`,
    /// with the binding store composed as the daemon composes it.
    pub fn current_facts(
        &self,
        targets: &TargetStore,
        hdc: Option<&dyn HdcDispatch>,
        target_id: &str,
    ) -> Result<RockchipFacts, String> {
        let target = target_records(targets)?
            .into_iter()
            .find(|target| target.target_id == target_id)
            .ok_or_else(|| format!("target {target_id} has not been adopted"))?;
        let tool_sha256 = self
            .rockusb
            .resolve()
            .map_err(|error| format!("ArkForge native RockUSB identity is unavailable: {error}"))?;
        let mut execution_connect_key = target.connect_key.clone();
        let mut covered_binding = None;
        let mut server_facts = BTreeMap::from([
            ("rockusbBackend".to_owned(), "native".to_owned()),
            (
                "arkForgeToolchainID".to_owned(),
                NATIVE_ROCKUSB_TOOLCHAIN.to_owned(),
            ),
        ]);
        let covered = match self.bindings.load_if_present().map_err(binding)? {
            Some(binding) => {
                let covered = binding
                    .covers_runtime_target(&target.bound())
                    .map_err(self::binding)?;
                if covered {
                    let mut alias = binding
                        .confirmed_hdc_normal_alias()
                        .map_err(self::binding)?;
                    if let Some(routed) = self.aliases.load_if_present().map_err(post_flash)? {
                        alias = self.route(targets, &target, &binding, &routed, alias)?;
                        if routed.binding_revision == target.binding_revision {
                            execution_connect_key = routed.hdc_connect_key.clone();
                        }
                    }
                    if let Some((identity, topology)) = alias {
                        server_facts.insert(ALIAS_IDENTITY.into(), identity);
                        server_facts.insert(ALIAS_TOPOLOGY.into(), topology);
                    }
                    covered_binding = Some(binding);
                }
                covered
            }
            None => false,
        };
        server_facts.insert(
            CROSS_MODE_BINDING.into(),
            if covered { "satisfied" } else { "unprepared" }.into(),
        );
        let (device_mode, build_fingerprint, profile_id, usb_topology) =
            self.live_facts(hdc, &execution_connect_key, &target.identity);
        let execution_identity = sha256_hex(execution_connect_key.as_bytes());
        // A cable move keeps the alias's connect key and identity but changes
        // its port: a fresh HDC observation of that very alias names the port
        // for this read only; nothing durable is rewritten.
        if device_mode == "hdc"
            && let Some(topology) = &usb_topology
            && !topology.is_empty()
            && topology.bytes().all(|byte| byte.is_ascii_digit())
            && server_facts.get(ALIAS_IDENTITY) == Some(&execution_identity)
        {
            server_facts.insert(ALIAS_TOPOLOGY.into(), topology.clone());
        }
        // A revision-1 adoption can itself be the exact HDC-normal personality:
        // its binding pins the live serial and topology, used only after a
        // fresh HDC-mode probe.
        if !server_facts.contains_key(ALIAS_IDENTITY)
            && device_mode == "hdc"
            && let Some(binding) = &covered_binding
            && execution_identity == sha256_hex(binding.serial.as_bytes())
            && !binding.usb_topology.is_empty()
            && binding
                .usb_topology
                .bytes()
                .all(|byte| byte.is_ascii_digit())
        {
            server_facts.insert(ALIAS_IDENTITY.into(), execution_identity.clone());
            server_facts.insert(ALIAS_TOPOLOGY.into(), binding.usb_topology.clone());
        }
        Ok(RockchipFacts {
            target_id: target.target_id,
            binding_revision: target.binding_revision,
            identity_sha256: target.identity,
            tool_sha256,
            execution_connect_key,
            device_mode,
            build_fingerprint,
            profile_id,
            server_facts,
        })
    }

    /// The post-flash alias's route for a covered Target: refused when it
    /// cannot be this Target's current route, the alias it names when it is.
    fn route(
        &self,
        targets: &TargetStore,
        target: &TargetRecord,
        binding: &BindingSnapshot,
        routed: &PostFlashBinding,
        alias: Option<(String, String)>,
    ) -> Result<Option<(String, String)>, String> {
        if routed.target_id != target.target_id {
            return Err(
                "flash.postFlashHDCBindingConflict: the stored alias belongs to another target"
                    .into(),
            );
        }
        if routed.binding_revision > target.binding_revision {
            // The alias's revision copies the Target store's counter, which a
            // retired state directory restarts: an alias naming this Target
            // and this Loader cannot be a newer route, only a reissued one.
            if routed.stable_loader_identity_sha256 == target.identity {
                return Err(format!(
                    "flash.postFlashHDCAliasLineageReissued: the stored alias names this target \
                     and Loader identity at revision {} while the live target is at revision {}. \
                     The revision counter was reissued, so the two are not comparable. Reconcile \
                     the stored alias against fresh device facts with `arkdeck flash \
                     reconcile-alias --target {} --expected-binding-revision {}`, with the board \
                     attached in hdc-normal mode",
                    routed.binding_revision,
                    target.binding_revision,
                    target.target_id,
                    target.binding_revision
                ));
            }
            return Err(format!(
                "flash.postFlashHDCBindingConflict: stored alias revision {} is newer than target \
                 revision {}",
                routed.binding_revision, target.binding_revision
            ));
        }
        if routed.binding_revision < target.binding_revision {
            return Ok(alias);
        }
        if !alias_covers(routed, target, binding)? {
            return Err(
                "flash.postFlashHDCBindingConflict: the stored alias has a different \
                        Loader identity at the current target revision"
                    .into(),
            );
        }
        if targets.has_conflicting_hdc_alias_owner(
            &target.target_id,
            &routed.hdc_connect_key,
            &routed.hdc_identity_sha256,
            &routed.job_id,
        )? {
            return Err("verified post-flash HDC alias is owned by another adopted target".into());
        }
        Ok(Some((
            routed.hdc_identity_sha256.clone(),
            routed.usb_topology.clone(),
        )))
    }

    /// Swift `liveFacts(connectKey:stableIdentitySHA256:)`: unknown without a
    /// probe, absent when the probe cannot see the board — never an error.
    fn live_facts(
        &self,
        hdc: Option<&dyn HdcDispatch>,
        connect_key: &str,
        identity: &str,
    ) -> (String, Option<String>, String, Option<String>) {
        let Some(hdc) = hdc else {
            return ("unknown".into(), None, "unknown".into(), None);
        };
        let usb = CensusProbe(&*self.census);
        let usb: &dyn UsbProbe = &usb;
        match LiveModeProbe::new(hdc, &*self.loader, Some(usb)).observe(connect_key, identity) {
            Ok(observation) => {
                let profile = if observation.build_fingerprint.as_deref() == Some(DAYU200_FIRMWARE)
                {
                    DAYU200_PROFILE
                } else {
                    "unknown"
                };
                (
                    observation.device_mode.as_str().to_owned(),
                    observation.build_fingerprint,
                    profile.to_owned(),
                    observation.usb_topology,
                )
            }
            Err(_) => ("absent".into(), None, "unknown".into(), None),
        }
    }
}
