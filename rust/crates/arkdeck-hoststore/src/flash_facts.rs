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
use crate::rockchip_binding::{
    BindingError, BindingEvidence, BindingSnapshot, BoundTarget, RockchipBindingStore,
};
use crate::rockchip_records::{NormalIdentitySubject, persist_normal_hardware_identity};
use crate::strict_json::swift_quoted;
use crate::target_owner::TargetStore;
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{
    HdcDispatch, HdcIdentity, LiveModeProbe, LoaderIdentity, LoaderObserver,
    NormalHardwareIdentityObserver, UsbProbe, is_dayu200_hdc_normal, is_dayu200_loader,
    observe_normal_loader_identity, registered_dayu200_devices,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

#[path = "flash_lane_preview.rs"]
mod lane_preview;
pub use lane_preview::{LanePreview, lane_plan_preview, preview_before_lane};

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
        #[cfg(unix)]
        let absolute = path.starts_with('/');
        #[cfg(windows)]
        let absolute = Path::new(path).is_absolute();
        if !absolute {
            return Err(failed(
                "provider executable path must be explicit and absolute",
            ));
        }
        #[cfg(unix)]
        let resolved = crate::workspace_support::foundation_resolved(path);
        // On Windows the physical path, as the lane's bundle reader resolves
        // it (TASK-XPA-010).
        #[cfg(windows)]
        let resolved = std::fs::canonicalize(path)
            .ok()
            .and_then(|physical| physical.to_str().map(str::to_owned))
            .unwrap_or_else(|| path.to_owned());
        let regular = || {
            failed(&format!(
                "provider executable must be a regular executable file: {resolved}"
            ))
        };
        let metadata = std::fs::metadata(&resolved).map_err(|error| error.to_string())?;
        if !metadata.is_file() || !executable(&metadata, &resolved) {
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

/// An executable file: any execute bit on Unix; on Windows, the `.exe` image
/// a Windows child must be.
#[cfg(unix)]
fn executable(metadata: &std::fs::Metadata, _path: &str) -> bool {
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(windows)]
fn executable(_metadata: &std::fs::Metadata, path: &str) -> bool {
    Path::new(path)
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
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
pub struct RockchipUsbProbe(Arc<Census>);

impl RockchipUsbProbe {
    pub fn new(
        census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
    ) -> Self {
        Self(Arc::new(census))
    }
}

impl RockchipUsbProbe {
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

impl UsbProbe for RockchipUsbProbe {
    fn connector_identity(&self, usb_topology: &str) -> Result<String, String> {
        arkdeck_provider_arkforge::host_topology_digest(usb_topology)
            .ok_or_else(|| "physical USB connector observation is unavailable".into())
    }

    fn single_hdc_normal_on_connector(
        &self,
        connector_sha256: &str,
    ) -> Result<HdcIdentity, String> {
        let device = self.single(|device| {
            is_dayu200_hdc_normal(device)
                && arkdeck_provider_arkforge::host_topology_digest(&device.topology).as_deref()
                    == Some(connector_sha256)
        })?;
        Ok(HdcIdentity {
            serial_digest_sha256: sha256_hex(device.serial.as_bytes()),
            connect_key: device.serial,
            topology: device.topology,
        })
    }

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
    resolve_topology: arkdeck_provider_arkforge::TopologyResolver,
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
            resolve_topology: arkdeck_provider_arkforge::host_topology_digest,
        }
    }

    /// Explicit observation port for a synthetic census in tests.
    pub fn with_topology_resolver(
        mut self,
        resolve: arkdeck_provider_arkforge::TopologyResolver,
    ) -> Self {
        self.resolve_topology = resolve;
        self
    }
}

impl LoaderObserver for ArkForgeLoader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        let identity = RockchipUsbProbe(Arc::clone(&self.census))
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
        arkdeck_provider_arkforge::confirm_loader_with_resolver(
            &self.runtime_directory,
            self.timeout,
            &identity.topology,
            self.resolve_topology,
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
pub(crate) const LOADER_FIRST_POSTFLIGHT: &str = "dayu200LoaderFirstPostflight";
pub(crate) const LOADER_FIRST_CONNECTOR: &str = "dayu200LoaderFirstConnectorSHA256";
pub(crate) const LOADER_FIRST_TOPOLOGY: &str = "dayu200LoaderFirstUSBTopology";
pub(crate) const LOADER_FIRST_VERIFIED_JOB: &str = "dayu200LoaderFirstVerifiedJob";
pub(crate) const LOADER_FIRST_VERIFIED_CONNECTOR: &str =
    "dayu200LoaderFirstVerifiedConnectorSHA256";

/// The owner of the Rockchip facts over one Application Support root.
pub struct FlashHostFacts {
    bindings: RockchipBindingStore,
    aliases: PostFlashAliasStore,
    census: Arc<Census>,
    rockusb: NativeRockUsbIdentity,
    loader: Box<dyn LoaderObserver + Send + Sync>,
    normal_identity_records: PathBuf,
    normal_identity_observer: NormalHardwareIdentityObserver,
    recommission_identity_observer: NormalHardwareIdentityObserver,
    recommission_state: Option<PathBuf>,
    resolve_topology: arkdeck_provider_arkforge::TopologyResolver,
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
            normal_identity_records: application_support_root.join("normal-loader-identity"),
            normal_identity_observer: observe_normal_loader_identity,
            recommission_identity_observer: |hdc, usb, key, _| {
                arkdeck_provider_hdc::observe_recommission_identity(hdc, usb, key)
            },
            recommission_state: None,
            resolve_topology: arkdeck_provider_arkforge::host_topology_digest,
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

    /// Runtime-owned observation composition, allowing synthetic ports to
    /// exercise the same persistence and admission. Production retains the
    /// fixed reader; callers cannot select an observer or import an observation.
    pub fn with_normal_identity_observer(
        mut self,
        observer: NormalHardwareIdentityObserver,
    ) -> Self {
        self.normal_identity_observer = observer;
        self
    }

    /// Runtime composition only; no caller can supply identity proof.
    pub fn with_recommission_identity_observer(
        mut self,
        observer: NormalHardwareIdentityObserver,
    ) -> Self {
        self.recommission_identity_observer = observer;
        self
    }

    pub fn with_recommission_state(mut self, state: &Path) -> Self {
        self.recommission_state = Some(state.to_path_buf());
        self
    }

    /// Only the independent recommission operation requests discovery of the
    /// Loader locator. Ordinary Flash retains its bound-identity check.
    pub fn operation_facts(
        &self,
        targets: &TargetStore,
        hdc: Option<&dyn HdcDispatch>,
        target_id: &str,
        recommission: bool,
    ) -> Result<RockchipFacts, String> {
        let mut facts = self.current_facts(targets, hdc, target_id)?;
        if !recommission {
            return Ok(facts);
        }
        let binding = self
            .bindings
            .load_if_present()
            .map_err(self::binding)?
            .ok_or("recommission.originalBindingMissing")?;
        if binding.revision != 1
            || facts.binding_revision != 1
            || facts.device_mode != "hdc"
            || binding.identity() != facts.identity_sha256
            || sha256_hex(facts.execution_connect_key.as_bytes()) != facts.identity_sha256
            || binding
                .confirmed_hdc_normal_alias()
                .map_err(self::binding)?
                .is_some()
            || binding
                .evidence
                .iter()
                .any(|entry| entry == crate::loader_binding::LOADER_FIRST)
        {
            return Err("recommission.requiresOriginalNormalOnlyBinding".into());
        }
        let observation = (self.recommission_identity_observer)(
            hdc.ok_or("recommission.hardwareReadUnavailable")?,
            &RockchipUsbProbe(Arc::clone(&self.census)),
            &facts.execution_connect_key,
            &facts.identity_sha256,
        )
        .map_err(str::to_owned)?;
        if observation.vendor_serial.is_none()
            || observation.normal_identity_sha256 != facts.identity_sha256
            || observation.usb_topology != binding.usb_topology
        {
            return Err("recommission.identityChainIncomplete".into());
        }
        let binding_bytes = serde_json::to_vec(&json!({
            "revision": binding.revision, "serialSHA256": binding.identity(),
            "usbTopology": binding.usb_topology, "evidence": binding.evidence,
        }))
        .map_err(|_| "recommission.bindingEncodingFailed")?;
        let chain = crate::job_owner::flash_recommission::IdentityChain {
            target_id: facts.target_id.clone(),
            binding_revision: facts.binding_revision,
            normal_identity_sha256: observation.normal_identity_sha256.clone(),
            hardware_serial_sha256: observation.hardware_serial_sha256.clone(),
            loader_serial_sha256: observation.loader_serial_sha256().to_owned(),
            connector_sha256: observation.connector_identity_sha256.clone(),
            usb_topology: observation.usb_topology.clone(),
            provider_sha256: facts.tool_sha256.clone(),
            binding_snapshot_sha256: sha256_hex(&binding_bytes),
        };
        chain.validate()?;
        let record = persist_normal_hardware_identity(
            &self.normal_identity_records,
            &NormalIdentitySubject {
                target_id: &facts.target_id,
                binding_revision: facts.binding_revision,
                stable_identity_sha256: &facts.identity_sha256,
                provider_executable_sha256: &facts.tool_sha256,
                job_id: None,
                step_id: None,
            },
            &observation,
        )?;
        facts
            .server_facts
            .insert("dayu200RecommissionObservationSHA256".into(), record);
        facts.server_facts.insert(
            crate::job_owner::flash_recommission::CHAIN_FACT.into(),
            serde_json::to_string(&chain).map_err(|_| "recommission.identityEncodingFailed")?,
        );
        crate::job_owner::flash_recommission::IdentityChain::from_facts(&facts)?;
        Ok(facts)
    }

    /// Host connector observation port. The control surface cannot provide it.
    pub fn with_topology_resolver(
        mut self,
        resolve: arkdeck_provider_arkforge::TopologyResolver,
    ) -> Self {
        self.resolve_topology = resolve;
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
        if let Some(state) = &self.recommission_state {
            let mut proven = Vec::new();
            for target in target_records(targets)? {
                if let Some(chain) = crate::job_owner::flash_recommission::verified_identity_chain(
                    state,
                    &target.target_id,
                    &target.identity,
                )? && target.identity == chain.loader_serial_sha256
                    && target.binding_revision == chain.binding_revision + 1
                    && (is_dayu200_hdc_normal(device) && digest == chain.normal_identity_sha256
                        || is_dayu200_loader(device) && digest == chain.loader_serial_sha256)
                    && (self.resolve_topology)(&device.topology).as_ref()
                        == Some(&chain.connector_sha256)
                {
                    let origin =
                        crate::job_owner::flash_recommission::verified_recovery_job(state, &chain)?;
                    if targets.has_conflicting_hdc_alias_owner(
                        &target.target_id,
                        &target.connect_key,
                        &chain.normal_identity_sha256,
                        &origin,
                    )? {
                        return Ok(status("ambiguous", 1, Some(mode), None));
                    }
                    proven.push(target);
                }
            }
            match proven.as_slice() {
                [target] => return Ok(status("exactBoundTarget", 1, Some(mode), Some(target))),
                [] => (),
                _ => return Ok(status("ambiguous", 1, Some(mode), None)),
            }
        }
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
            == Some("satisfied")
            && crate::job_plan::normal_loader_identity_ready(&facts);
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
                            if let Some(proof) = &routed.loader_hardware_proof {
                                server_facts.insert(
                                    LOADER_FIRST_VERIFIED_JOB.into(),
                                    routed.job_id.clone(),
                                );
                                server_facts.insert(
                                    LOADER_FIRST_VERIFIED_CONNECTOR.into(),
                                    proof.connector_sha256.clone(),
                                );
                            }
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
        let recommission_chain = self
            .recommission_state
            .as_ref()
            .map(|state| {
                crate::job_owner::flash_recommission::verified_identity_chain(
                    state,
                    &target.target_id,
                    &target.identity,
                )
            })
            .transpose()?
            .flatten();
        if let Some(chain) = &recommission_chain {
            let origin = crate::job_owner::flash_recommission::verified_recovery_job(
                self.recommission_state
                    .as_deref()
                    .ok_or("recommission.stateUnavailable")?,
                chain,
            )?;
            if targets.has_conflicting_hdc_alias_owner(
                &target.target_id,
                &execution_connect_key,
                &chain.normal_identity_sha256,
                &origin,
            )? {
                return Err("recommission.conflictingNormalIdentityOwner".into());
            }
            if target.identity != chain.loader_serial_sha256
                || target.binding_revision != chain.binding_revision + 1
                || sha256_hex(execution_connect_key.as_bytes()) != chain.normal_identity_sha256
            {
                return Err("recommission.verifiedBindingProjectionIncomplete".into());
            }
            server_facts.insert(CROSS_MODE_BINDING.into(), "satisfied".into());
            server_facts.insert(ALIAS_IDENTITY.into(), chain.normal_identity_sha256.clone());
            server_facts.insert(ALIAS_TOPOLOGY.into(), chain.usb_topology.clone());
        }
        let (device_mode, build_fingerprint, profile_id, usb_topology) =
            self.live_facts(hdc, &execution_connect_key, &target.identity);
        if let Some(chain) = &recommission_chain
            && device_mode == "loader"
            && usb_topology
                .as_ref()
                .and_then(|topology| (self.resolve_topology)(topology))
                .as_ref()
                != Some(&chain.connector_sha256)
        {
            return Err("recommission.verifiedLoaderConnectorDrifted".into());
        }
        if device_mode == "loader"
            && !server_facts.contains_key(ALIAS_IDENTITY)
            && let Some(binding) = &covered_binding
            && binding.revision == 1
            && binding
                .evidence
                .iter()
                .any(|entry| entry == crate::loader_binding::LOADER_FIRST)
            && binding.values("binding:selected-target-id=") == [target.target_id.as_str()]
            && usb_topology.as_deref() == Some(binding.usb_topology.as_str())
            && let Some(connector) = (self.resolve_topology)(&binding.usb_topology)
            && crate::rockchip_binding::canonical_sha256(&connector)
        {
            server_facts.insert(LOADER_FIRST_POSTFLIGHT.into(), "satisfied".into());
            server_facts.insert(LOADER_FIRST_CONNECTOR.into(), connector);
            server_facts.insert(LOADER_FIRST_TOPOLOGY.into(), binding.usb_topology.clone());
        }
        let execution_identity = sha256_hex(execution_connect_key.as_bytes());
        if device_mode == "hdc" {
            let observed = hdc
                .ok_or("normalLoaderIdentity.hardwareReadUnavailable")
                .and_then(|hdc| {
                    (self.normal_identity_observer)(
                        hdc,
                        &RockchipUsbProbe(Arc::clone(&self.census)),
                        &execution_connect_key,
                        &target.identity,
                    )
                });
            let status = match observed {
                Ok(observation) => {
                    if recommission_chain.as_ref().is_some_and(|chain| {
                        observation.normal_identity_sha256 != chain.normal_identity_sha256
                            || observation.hardware_serial_sha256 != chain.hardware_serial_sha256
                            || observation.loader_serial_sha256() != chain.loader_serial_sha256
                            || observation.connector_identity_sha256 != chain.connector_sha256
                    }) {
                        return Err("recommission.verifiedHardwareLineageDrifted".into());
                    }
                    let persisted = persist_normal_hardware_identity(
                        &self.normal_identity_records,
                        &NormalIdentitySubject {
                            target_id: &target.target_id,
                            binding_revision: target.binding_revision,
                            stable_identity_sha256: &target.identity,
                            provider_executable_sha256: &tool_sha256,
                            job_id: None,
                            step_id: None,
                        },
                        &observation,
                    );
                    match persisted {
                        Ok(record) => {
                            server_facts
                                .insert("dayu200NormalHardwareObservationSHA256".into(), record);
                            server_facts.insert(
                                "dayu200NormalHardwareSerialSHA256".into(),
                                observation.hardware_serial_sha256.clone(),
                            );
                            if observation.vendor_serial.is_some() {
                                server_facts.insert(
                                    "dayu200NormalLoaderSerialSHA256".into(),
                                    observation.loader_serial_sha256().to_owned(),
                                );
                            }
                            if observation.matches_loader(&target.identity) {
                                "satisfied"
                            } else {
                                "normalLoaderIdentity.boundLoaderIdentityMismatch"
                            }
                        }
                        Err(_) => "normalLoaderIdentity.observationPersistenceFailed",
                    }
                }
                Err(reason) => reason,
            };
            server_facts.insert("dayu200NormalLoaderHardwareIdentity".into(), status.into());
        }
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
        let usb = RockchipUsbProbe(Arc::clone(&self.census));
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

impl FlashHostFacts {
    /// Re-prove the durable cross-mode binding, not similarity of a USB arrival.
    /// Identity is the canonical Loader binding; Normal mode must independently
    /// prove the hardware serial before it may represent that identity.
    pub(crate) fn maintenance_identity(
        &self,
        targets: &TargetStore,
        hdc: &dyn HdcDispatch,
        execution: &arkdeck_provider_arkforge::Execution,
    ) -> Result<arkdeck_provider_arkforge::maintenance::Identity, String> {
        let facts = self.current_facts(targets, Some(hdc), &execution.target_id)?;
        if facts.binding_revision != execution.binding_revision
            || facts.identity_sha256 != execution.stable_identity_sha256
            || facts.tool_sha256 != execution.toolchain_sha256
        {
            return Err("maintenance source binding or toolchain changed".into());
        }
        let usb = RockchipUsbProbe(Arc::clone(&self.census));
        let topology = match facts.device_mode.as_str() {
            "hdc"
                if facts
                    .server_facts
                    .get("dayu200NormalLoaderHardwareIdentity")
                    .map(String::as_str)
                    == Some("satisfied") =>
            {
                usb.single_hdc_normal(&sha256_hex(facts.execution_connect_key.as_bytes()))
                    .map_err(|e| format!("{e:?}"))?
                    .topology
            }
            "loader" => {
                usb.single_loader(&execution.stable_identity_sha256)
                    .map_err(|e| format!("{e:?}"))?
                    .topology
            }
            _ => {
                return Err(
                    "maintenance requires a freshly proven Normal or Loader identity".into(),
                );
            }
        };
        if topology != execution.usb_topology {
            return Err("maintenance source topology changed".into());
        }
        let descriptor = usb
            .connector_identity(&topology)
            .map_err(|e| format!("{e:?}"))?;
        Ok(arkdeck_provider_arkforge::maintenance::Identity {
            serial_sha256: facts.identity_sha256,
            topology_sha256: sha256_hex(topology.as_bytes()),
            descriptor_sha256: descriptor,
        })
    }
}
