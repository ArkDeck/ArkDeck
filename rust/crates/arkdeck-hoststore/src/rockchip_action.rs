//! Swift `RockchipProviderAction` (`DeviceProviderContract.swift`): the typed
//! actions the Rockchip host runs itself, their persisted form
//! (`PersistedTypedProviderAction`), whose canonical encoding a host-managed
//! descriptor pins, their effect, and the one catalog binding each to its
//! descriptor identifier (`RockchipHostManagedActionCatalog.swift`).
//!
//! A persisted action decodes back only as Swift's `materialize()` decodes
//! it: the pre-CHG-2026-059 lowering kinds and the retired unbound build
//! verification are refused by name, never re-derived.

use crate::artifact_read_owner::swift_string;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_arkforge::HostAction;
use serde_json::{Map, Value, json};

/// Swift `RockchipHDCReconnectExpectation`: the bound HDC route a reconnect
/// or a post-flash verification must find again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Expectation {
    pub previous_connect_key: String,
    pub previous_identity_sha256: String,
    pub usb_topology: String,
}

/// Swift `HDCHilogCaptureRequest`, validated as its initializer validates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaptureRequest {
    pub duration_seconds: i64,
    pub filters: Vec<String>,
    pub byte_budget: i64,
}

impl CaptureRequest {
    /// Swift `maximumDurationSeconds`, `maximumFilters`, `maximumByteBudget`.
    const MAXIMUM_DURATION_SECONDS: i64 = 600;
    const MAXIMUM_FILTERS: usize = 16;
    const MAXIMUM_BYTE_BUDGET: i64 = 128 * 1024 * 1024;
    /// Swift `minimumCommandTimeoutSeconds` and
    /// `commandStartupAndDrainGraceSeconds`.
    const MINIMUM_COMMAND_TIMEOUT_SECONDS: i64 = 45;
    const STARTUP_AND_DRAIN_GRACE_SECONDS: i64 = 15;

    /// Swift `HDCHilogCaptureRequest.init`, each refusal as Swift
    /// interpolates its `HDCE0RequestError`.
    pub fn new(
        duration_seconds: i64,
        filters: Vec<String>,
        byte_budget: i64,
    ) -> Result<Self, String> {
        if !(1..=Self::MAXIMUM_DURATION_SECONDS).contains(&duration_seconds) {
            return Err(out_of_bounds(
                "durationSeconds",
                &format!("1...{}", Self::MAXIMUM_DURATION_SECONDS),
            ));
        }
        if filters.len() > Self::MAXIMUM_FILTERS {
            return Err(out_of_bounds(
                "filters",
                &format!("at most {}", Self::MAXIMUM_FILTERS),
            ));
        }
        if filters.iter().any(|filter| {
            filter.is_empty()
                || filter.chars().count() > 200
                || !filter
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b":*./_-".contains(&byte))
        }) {
            return Err(format!(
                "malformed(field: {}, detail: {})",
                swift_string("filters"),
                swift_string("filter tokens are bounded ASCII, no shell fragments")
            ));
        }
        if !(1024..=Self::MAXIMUM_BYTE_BUDGET).contains(&byte_budget) {
            return Err(out_of_bounds(
                "byteBudget",
                &format!("1024...{}", Self::MAXIMUM_BYTE_BUDGET),
            ));
        }
        Ok(Self {
            duration_seconds,
            filters,
            byte_budget,
        })
    }

    /// The command's own bound: the duration and the drain's grace, never
    /// under Swift's floor.
    pub fn command_timeout_seconds(&self) -> i64 {
        (self.duration_seconds + Self::STARTUP_AND_DRAIN_GRACE_SECONDS)
            .max(Self::MINIMUM_COMMAND_TIMEOUT_SECONDS)
    }
}

/// Swift `RockchipProviderAction`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RockchipAction {
    EnterLoader(String),
    ObserveHdcNormalUsb(String),
    WaitForHdcDisconnect(String),
    WaitForLoader(String),
    RebindLoader(String),
    RebootToNormal(String),
    WaitForHdcReconnect(String),
    WaitForBoundHdcReconnect(Expectation),
    VerifyBoundBuild {
        expectation: Expectation,
        product_model: String,
        build_version: String,
    },
    CapturePostFlashDiagnostics {
        connect_key: String,
        request: CaptureRequest,
    },
}

impl RockchipAction {
    /// Swift `TypedProviderAction.effect`: the two mode changes mutate the
    /// device; every other action only reads.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::EnterLoader(_) | Self::RebootToNormal(_) => "deviceMutation",
            _ => "readOnly",
        }
    }

    pub fn mutates(&self) -> bool {
        self.effect() == "deviceMutation"
    }

    /// Swift `RockchipHostManagedActionCatalog.identifier(for:)`.
    pub fn identifier(&self) -> &'static str {
        match self {
            Self::EnterLoader(_) => "rockchip.hdc.enter-loader.v1",
            Self::ObserveHdcNormalUsb(_) => "rockchip.iokit.observe-hdc-normal.v1",
            Self::WaitForHdcDisconnect(_) => "rockchip.hdc.wait-disconnect.v1",
            Self::WaitForLoader(_) => "rockchip.rockusb.wait-loader.v1",
            Self::RebindLoader(_) => "rockchip.rockusb.rebind-loader.v1",
            Self::RebootToNormal(_) => "rockchip.rockusb.reboot-normal.v1",
            Self::WaitForHdcReconnect(_) => "rockchip.hdc.wait-reconnect.v1",
            Self::WaitForBoundHdcReconnect(_) => "rockchip.hdc.wait-bound-reconnect.v1",
            Self::VerifyBoundBuild { .. } => "rockchip.hdc.verify-bound-build.v1",
            Self::CapturePostFlashDiagnostics { .. } => "rockchip.hdc.capture-post-flash-hilog.v1",
        }
    }

    /// Swift `PersistedTypedProviderAction(.rockchip(action))`: its kind and
    /// arguments, as a descriptor pins and an intent journals them.
    pub fn persisted(&self) -> Value {
        let expectation = |expectation: &Expectation| {
            json!({
                "previousConnectKey": expectation.previous_connect_key,
                "previousIdentitySha256": expectation.previous_identity_sha256,
                "usbTopology": expectation.usb_topology,
            })
        };
        let (kind, arguments) = match self {
            Self::EnterLoader(key) => ("rockchip.enterLoader", json!({"connectKey": key})),
            Self::ObserveHdcNormalUsb(key) => {
                ("rockchip.observeHDCNormalUSB", json!({"connectKey": key}))
            }
            Self::WaitForHdcDisconnect(key) => {
                ("rockchip.waitForHDCDisconnect", json!({"connectKey": key}))
            }
            Self::WaitForLoader(identity) => (
                "rockchip.waitForLoader",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::RebindLoader(identity) => (
                "rockchip.rebindLoader",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::RebootToNormal(identity) => (
                "rockchip.rebootToNormal",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::WaitForHdcReconnect(key) => {
                ("rockchip.waitForHDCReconnect", json!({"connectKey": key}))
            }
            Self::WaitForBoundHdcReconnect(bound) => {
                ("rockchip.waitForBoundHDCReconnect", expectation(bound))
            }
            Self::VerifyBoundBuild {
                expectation: bound,
                product_model,
                build_version,
            } => {
                let mut arguments = expectation(bound);
                arguments["expectedProductModel"] = json!(product_model);
                arguments["expectedBuildVersion"] = json!(build_version);
                ("rockchip.verifyBoundBuild", arguments)
            }
            Self::CapturePostFlashDiagnostics {
                connect_key,
                request,
            } => (
                "rockchip.capturePostFlashDiagnostics",
                json!({
                    "connectKey": connect_key,
                    "durationSeconds": request.duration_seconds,
                    "filters": request.filters,
                    "byteBudget": request.byte_budget,
                }),
            ),
        };
        json!({"kind": kind, "arguments": arguments})
    }

    /// Swift `RockchipHostManagedActionCatalog.actionSHA256(of:)`: SHA-256 of
    /// the persisted action's canonical encoding.
    pub fn sha256(&self) -> String {
        sha256_hex(
            &crate::session_json::encode(&self.persisted())
                .expect("a persisted Rockchip action holds strings and exact integers only"),
        )
    }

    /// Swift `RockchipHostManagedActionCatalog.descriptor(for:…)`: the
    /// descriptor the durable host's validation accepts for this action.
    #[allow(clippy::too_many_arguments)]
    pub fn descriptor(
        &self,
        job_id: &str,
        step_id: &str,
        target_id: &str,
        binding_revision: i64,
        connect_key: &str,
        expected_identity_sha256: &str,
        provider_executable_sha256: &str,
    ) -> HostAction {
        let persisted = self.persisted();
        HostAction {
            identifier: self.identifier().to_owned(),
            job_id: job_id.to_owned(),
            step_id: step_id.to_owned(),
            target_id: target_id.to_owned(),
            binding_revision,
            connect_key: connect_key.to_owned(),
            expected_identity_sha256: expected_identity_sha256.to_owned(),
            provider_executable_sha256: provider_executable_sha256.to_owned(),
            action_sha256: self.sha256(),
            action: String::from_utf8(
                crate::session_json::encode(&persisted)
                    .expect("a persisted Rockchip action encodes"),
            )
            .expect("canonical JSON is UTF-8"),
            output_byte_budget: None,
        }
    }

    /// Swift `actionMatchesDescriptor(_:descriptor:)`: the catalog's
    /// identifier, and the connect key or identity the action names.
    pub fn matches(&self, descriptor: &HostAction) -> bool {
        if descriptor.identifier != self.identifier() {
            return false;
        }
        match self {
            Self::EnterLoader(key)
            | Self::ObserveHdcNormalUsb(key)
            | Self::WaitForHdcDisconnect(key)
            | Self::WaitForHdcReconnect(key)
            | Self::CapturePostFlashDiagnostics {
                connect_key: key, ..
            } => *key == descriptor.connect_key,
            Self::WaitForLoader(identity)
            | Self::RebindLoader(identity)
            | Self::RebootToNormal(identity) => *identity == descriptor.expected_identity_sha256,
            Self::WaitForBoundHdcReconnect(expectation)
            | Self::VerifyBoundBuild { expectation, .. } => {
                expectation.previous_connect_key == descriptor.connect_key
            }
        }
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for the Rockchip
    /// kinds, each refusal Swift's description of it.
    pub fn from_persisted(persisted: &Value) -> Result<Self, String> {
        let object = persisted
            .as_object()
            .ok_or("a persisted typed provider action is not an object")?;
        let kind = object
            .get("kind")
            .and_then(Value::as_str)
            .ok_or("a persisted typed provider action has no kind")?;
        let empty = Map::new();
        let arguments = object
            .get("arguments")
            .and_then(Value::as_object)
            .unwrap_or(&empty);
        let string = |key: &str| -> Result<String, String> {
            arguments
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("persisted {kind} is missing string {key}"))
        };
        let integer = |key: &str| -> Result<i64, String> {
            arguments
                .get(key)
                .and_then(|value| value.as_i64().filter(|_| value.is_i64() || value.is_u64()))
                .ok_or_else(|| format!("persisted {kind} is missing integer {key}"))
        };
        let expectation = || -> Result<Expectation, String> {
            let previous_connect_key = string("previousConnectKey")?;
            let previous_identity_sha256 = string("previousIdentitySha256")?;
            let usb_topology = string("usbTopology")?;
            if previous_connect_key.is_empty()
                || !lowercase_sha256(&previous_identity_sha256)
                || sha256_hex(previous_connect_key.as_bytes()) != previous_identity_sha256
                || usb_topology.is_empty()
                || !usb_topology.bytes().all(|byte| byte.is_ascii_digit())
            {
                return Err(format!(
                    "persisted {kind} carries an invalid HDC binding expectation"
                ));
            }
            Ok(Expectation {
                previous_connect_key,
                previous_identity_sha256,
                usb_topology,
            })
        };
        match kind {
            "rockchip.enterLoader" => Ok(Self::EnterLoader(string("connectKey")?)),
            "rockchip.observeHDCNormalUSB" => Ok(Self::ObserveHdcNormalUsb(string("connectKey")?)),
            "rockchip.waitForHDCDisconnect" => {
                Ok(Self::WaitForHdcDisconnect(string("connectKey")?))
            }
            "rockchip.waitForLoader" => Ok(Self::WaitForLoader(string("stableIdentitySha256")?)),
            "rockchip.rebindLoader" => Ok(Self::RebindLoader(string("stableIdentitySha256")?)),
            "rockchip.flashPartitions" | "rockchip.verifyFlashReadback" => Err(format!(
                "{kind} is a legacy in-process Rockchip write intent, removed in CHG-2026-059. \
                 The record is intact; the intent is not replayable and cannot be re-derived, \
                 so this job's outcome is unknown until a person reconciles the device."
            )),
            "rockchip.rebootToNormal" => Ok(Self::RebootToNormal(string("stableIdentitySha256")?)),
            "rockchip.waitForHDCReconnect" => Ok(Self::WaitForHdcReconnect(string("connectKey")?)),
            "rockchip.waitForBoundHDCReconnect" => {
                Ok(Self::WaitForBoundHdcReconnect(expectation()?))
            }
            "rockchip.verifyBuild" => Err(format!(
                "{kind} is the retired unbound post-flash verification; it does not prove \
                 device identity and is superseded by rockchip.verifyBoundBuild"
            )),
            "rockchip.verifyBoundBuild" => Ok(Self::VerifyBoundBuild {
                expectation: expectation()?,
                product_model: string("expectedProductModel")?,
                build_version: string("expectedBuildVersion")?,
            }),
            "rockchip.capturePostFlashDiagnostics" => {
                let connect_key = string("connectKey")?;
                let duration = integer("durationSeconds")?;
                let filters = arguments
                    .get("filters")
                    .and_then(Value::as_array)
                    .ok_or_else(|| format!("persisted {kind} is missing array filters"))?
                    .iter()
                    .map(|filter| {
                        filter.as_str().map(str::to_owned).ok_or_else(|| {
                            format!("persisted {kind}.filters contains a non-string")
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let budget = integer("byteBudget")?;
                Ok(Self::CapturePostFlashDiagnostics {
                    connect_key,
                    request: CaptureRequest::new(duration, filters, budget)?,
                })
            }
            _ => Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            )),
        }
    }
}

/// Swift's interpolation of `HDCE0RequestError.outOfBounds`.
fn out_of_bounds(field: &str, detail: &str) -> String {
    format!(
        "outOfBounds(field: {}, detail: {})",
        swift_string(field),
        swift_string(detail)
    )
}

/// Exactly 64 lowercase hexadecimal characters.
fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
mod tests;
