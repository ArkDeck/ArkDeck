//! Swift `ArkForgeAuthoritySupport` (`ArkForgeAuthoritySupport.swift`):
//! ArkDeck's independent support key for the authority half of ArkForge
//! Flash.
//!
//! Mechanics maturity answers whether the provider, profile, artifact and
//! toolchain are ready. It cannot answer whether this exact authority build,
//! managed-control mapping, HDC build and permit codec are. This key binds
//! those axes before a controller materialization can become executable.

use arkdeck_contract::sha256_hex;

/// Swift `ArkForgeAuthoritySupport.namespace`.
pub const NAMESPACE: &str = "arkdeck";
/// Swift `ArkForgeAuthoritySupport.implementationVersion`.
pub const IMPLEMENTATION_VERSION: &str = "1.0.0";

/// Swift `managedControlMapping`: the executable control lowering ArkDeck
/// implements, as a closed protocol description rather than a source digest.
/// A refactor that keeps the mapping keeps the key; a semantic change must
/// change this text and so rotates the key. Swift's multi-line literal: lines
/// joined by a newline, none after the last.
const MANAGED_CONTROL_MAPPING: &str = "arkdeck.arkforge-managed-control/v1
enterUpdater=observeHDCNormalUSB+enterLoader+waitForHDCDisconnect+waitForLoader+rebindLoader
rebootToNormal=waitForBoundHDCReconnect
readProductFacts=verifyBoundBuild:const.product.model
readBuildFacts=verifyBoundBuild:const.ohos.fullname
acceptedReceiptEvidence=sha256(sorted-utf8-key=value-newline)
forbiddenReceiptFacts=argv,connectKey,hdcEndpoint,hdcExecutablePath,serverLifecycleAction,shell";

/// Swift `permitCodec`: the permit representation and replay discipline the
/// execution authority implements.
const PERMIT_CODEC: &str = "arkdeck.arkforge-step-permit/rfc8949-canonical-cbor-v1+hmac-sha256
tag=HMAC-SHA256(pairing-secret,canonical-body)
pairingEpoch=per-daemon-generation
singleUse=true
retransmit=exact-stored-body-and-tag";

/// Swift `pendingDetail`: the detail of the deliberately non-executable first
/// controller pass, which retrieves the daemon's real mechanics state while
/// proving the controller echoes the authority-support fields.
pub const PENDING_DETAIL: &str =
    "the exact mechanics maturity key has not yet been bound to ArkDeck authority support";

/// Swift `pendingKeySHA256`: SHA-256 of `arkdeck.authority-support-pending/v1`.
pub fn pending_key_sha256() -> [u8; 32] {
    digest_bytes(b"arkdeck.authority-support-pending/v1")
}

/// Swift `SupportError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SupportError {
    InvalidDigest { axis: String, value: String },
    InvalidIdentifier { axis: String, value: String },
}

impl std::fmt::Display for SupportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidDigest { axis, .. } => {
                write!(f, "{axis} must be exactly 32 lowercase hex-encoded bytes")
            }
            Self::InvalidIdentifier { axis, .. } => write!(
                f,
                "{axis} must be a non-empty single-line identifier without '='"
            ),
        }
    }
}

impl std::error::Error for SupportError {}

/// Swift `ArkForgeAuthoritySupport.Key`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Key {
    pub authority_namespace: String,
    pub authority_implementation_version: String,
    pub authority_implementation_sha256: String,
    pub managed_control_mapping_sha256: String,
    pub managed_control_tool_sha256: String,
    pub permit_codec_sha256: String,
    pub mechanics_maturity_key_sha256: String,
    pub host_platform: String,
}

impl Key {
    /// Swift `digestBytes()`: SHA-256 over `arkdeck.authority-support-key/v1`
    /// and a newline, then each field as `name=value` and a newline in the
    /// byte order of the names. Five axes must be exact lowercase SHA-256
    /// text, and three non-empty single-line identifiers without `=`, so the
    /// projection is reviewable in either language.
    pub fn digest_bytes(&self) -> Result<[u8; 32], SupportError> {
        for (axis, value) in [
            (
                "authorityImplementationSHA256",
                &self.authority_implementation_sha256,
            ),
            (
                "managedControlMappingSHA256",
                &self.managed_control_mapping_sha256,
            ),
            (
                "managedControlToolSHA256",
                &self.managed_control_tool_sha256,
            ),
            ("permitCodecSHA256", &self.permit_codec_sha256),
            (
                "mechanicsMaturityKeySHA256",
                &self.mechanics_maturity_key_sha256,
            ),
        ] {
            if !is_lowercase_sha256(value) {
                return Err(SupportError::InvalidDigest {
                    axis: axis.to_owned(),
                    value: value.clone(),
                });
            }
        }
        for (axis, value) in [
            ("authorityNamespace", &self.authority_namespace),
            (
                "authorityImplementationVersion",
                &self.authority_implementation_version,
            ),
            ("hostPlatform", &self.host_platform),
        ] {
            if value.is_empty() || value.contains('\n') || value.contains('=') {
                return Err(SupportError::InvalidIdentifier {
                    axis: axis.to_owned(),
                    value: value.clone(),
                });
            }
        }
        // Already in the byte order of the names.
        let fields = [
            (
                "authorityImplementationSHA256",
                &self.authority_implementation_sha256,
            ),
            (
                "authorityImplementationVersion",
                &self.authority_implementation_version,
            ),
            ("authorityNamespace", &self.authority_namespace),
            ("hostPlatform", &self.host_platform),
            (
                "managedControlMappingSHA256",
                &self.managed_control_mapping_sha256,
            ),
            (
                "managedControlToolSHA256",
                &self.managed_control_tool_sha256,
            ),
            (
                "mechanicsMaturityKeySHA256",
                &self.mechanics_maturity_key_sha256,
            ),
            ("permitCodecSHA256", &self.permit_codec_sha256),
        ];
        let mut body = b"arkdeck.authority-support-key/v1\n".to_vec();
        for (name, value) in fields {
            body.extend_from_slice(format!("{name}={value}\n").as_bytes());
        }
        Ok(digest_bytes(&body))
    }
}

/// Swift `ArkForgeAuthoritySupport.Configuration`: this authority build's
/// digest, the managed-control HDC's, and the operator-named campaign (empty,
/// the normal state, cannot execute).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Configuration {
    pub authority_implementation_sha256: String,
    pub managed_control_tool_sha256: String,
    pub hardware_campaign: String,
}

impl Configuration {
    pub fn new(
        authority_implementation_sha256: &str,
        managed_control_tool_sha256: &str,
        hardware_campaign: &str,
    ) -> Self {
        Self {
            authority_implementation_sha256: authority_implementation_sha256.to_lowercase(),
            managed_control_tool_sha256: managed_control_tool_sha256.to_lowercase(),
            hardware_campaign: hardware_campaign.to_owned(),
        }
    }

    /// Swift `key(mechanicsMaturityKeySHA256:)`.
    pub fn key(&self, mechanics_maturity_key_sha256: &str) -> Key {
        Key {
            authority_namespace: NAMESPACE.to_owned(),
            authority_implementation_version: IMPLEMENTATION_VERSION.to_owned(),
            authority_implementation_sha256: self.authority_implementation_sha256.clone(),
            managed_control_mapping_sha256: sha256_hex(MANAGED_CONTROL_MAPPING.as_bytes()),
            managed_control_tool_sha256: self.managed_control_tool_sha256.clone(),
            permit_codec_sha256: sha256_hex(PERMIT_CODEC.as_bytes()),
            mechanics_maturity_key_sha256: mechanics_maturity_key_sha256.to_owned(),
            host_platform: host_platform().to_owned(),
        }
    }

    /// Swift `seal(mechanicsMaturityKeySHA256:)`: without a campaign the key
    /// is hardware-gated and may not execute; a campaign seals it as that
    /// campaign's.
    pub fn seal(&self, mechanics_maturity_key_sha256: &str) -> Result<Seal, SupportError> {
        let key = self.key(mechanics_maturity_key_sha256);
        let key_sha256 = key.digest_bytes()?;
        if self.hardware_campaign.is_empty() {
            return Ok(Seal {
                key,
                key_sha256,
                state: "hardwareGated".to_owned(),
                detail: "the exact ArkDeck authority build/control-map/HDC/permit-codec/\
                         mechanics/platform combination has no reviewed production support \
                         record"
                    .to_owned(),
            });
        }
        if self.hardware_campaign.contains('\n') {
            return Err(SupportError::InvalidIdentifier {
                axis: "hardwareCampaign".to_owned(),
                value: self.hardware_campaign.clone(),
            });
        }
        Ok(Seal {
            key,
            key_sha256,
            state: "hardwareCampaign".to_owned(),
            detail: self.hardware_campaign.clone(),
        })
    }
}

/// Swift `ArkForgeAuthoritySupport.Seal`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Seal {
    pub key: Key,
    pub key_sha256: [u8; 32],
    pub state: String,
    pub detail: String,
}

impl Seal {
    /// Swift `keyHex`.
    pub fn key_hex(&self) -> String {
        self.key_sha256
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    /// Swift `permitsExecution`.
    pub fn permits_execution(&self) -> bool {
        self.state == "productionVerified" || self.state == "hardwareCampaign"
    }

    /// Swift `campaign`: the detail of a campaign seal, else empty.
    pub fn campaign(&self) -> &str {
        if self.state == "hardwareCampaign" {
            &self.detail
        } else {
            ""
        }
    }
}

/// Swift `currentHostPlatform`: `<os>/<arch>` of this build.
fn host_platform() -> &'static str {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "macos/arm64",
        ("macos", "x86_64") => "macos/x86_64",
        ("windows", "aarch64") => "windows/arm64",
        ("windows", "x86_64") => "windows/x86_64",
        ("linux", "aarch64") => "linux/arm64",
        ("linux", "x86_64") => "linux/x86_64",
        ("macos", _) => "macos/unknown-arch",
        ("windows", _) => "windows/unknown-arch",
        ("linux", _) => "linux/unknown-arch",
        (_, "aarch64") => "unknown-os/arm64",
        (_, "x86_64") => "unknown-os/x86_64",
        _ => "unknown-os/unknown-arch",
    }
}

/// Swift `isLowercaseSHA256`: exactly 64 of `0-9a-f`.
fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn digest_bytes(bytes: &[u8]) -> [u8; 32] {
    let hex = sha256_hex(bytes);
    let mut digest = [0u8; 32];
    for (index, slot) in digest.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16)
            .expect("sha256_hex spells lowercase hex");
    }
    digest
}

#[cfg(test)]
mod tests {
    //! Swift `ArkForgeAuthoritySupportContractTests`, with the digests of the
    //! two closed texts and of a key pinned, which Swift asserts only as
    //! "every axis rotates it".
    use super::*;

    fn base_key() -> Key {
        Key {
            authority_namespace: "arkdeck".to_owned(),
            authority_implementation_version: "1.0.0".to_owned(),
            authority_implementation_sha256: "1".repeat(64),
            managed_control_mapping_sha256: "2".repeat(64),
            managed_control_tool_sha256: "3".repeat(64),
            permit_codec_sha256: "4".repeat(64),
            mechanics_maturity_key_sha256: "5".repeat(64),
            host_platform: "macos/arm64".to_owned(),
        }
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn the_authority_support_key_is_deterministic_and_every_axis_rotates_it() {
        let base = base_key();
        let digest = base.digest_bytes().unwrap();
        assert_eq!(digest, base.digest_bytes().unwrap());
        let rotated: [fn(&mut Key); 8] = [
            |key| key.authority_namespace = "arkdeck.other".to_owned(),
            |key| key.authority_implementation_version = "1.0.1".to_owned(),
            |key| key.authority_implementation_sha256 = "6".repeat(64),
            |key| key.managed_control_mapping_sha256 = "6".repeat(64),
            |key| key.managed_control_tool_sha256 = "6".repeat(64),
            |key| key.permit_codec_sha256 = "6".repeat(64),
            |key| key.mechanics_maturity_key_sha256 = "6".repeat(64),
            |key| key.host_platform = "windows/x86_64".to_owned(),
        ];
        for rotate in rotated {
            let mut candidate = base.clone();
            rotate(&mut candidate);
            assert_ne!(candidate.digest_bytes().unwrap(), digest, "{candidate:?}");
        }
    }

    /// The key's text, byte for byte: the prefix, then `name=value` lines in
    /// the byte order of the names.
    #[test]
    fn the_key_digest_is_the_canonical_text() {
        let text = format!(
            "arkdeck.authority-support-key/v1\n\
             authorityImplementationSHA256={}\n\
             authorityImplementationVersion=1.0.0\n\
             authorityNamespace=arkdeck\n\
             hostPlatform=macos/arm64\n\
             managedControlMappingSHA256={}\n\
             managedControlToolSHA256={}\n\
             mechanicsMaturityKeySHA256={}\n\
             permitCodecSHA256={}\n",
            "1".repeat(64),
            "2".repeat(64),
            "3".repeat(64),
            "5".repeat(64),
            "4".repeat(64)
        );
        assert_eq!(
            hex(&base_key().digest_bytes().unwrap()),
            sha256_hex(text.as_bytes())
        );
        assert_eq!(
            hex(&base_key().digest_bytes().unwrap()),
            "80cde5b283efbeefb74bef26815f050eef81c7d8f1ea70e31e93a5c3365a1a43"
        );
    }

    /// The two closed texts Swift hashes, as its multi-line literals read.
    #[test]
    fn the_mapping_and_codec_texts_are_swifts() {
        let key = Configuration::new(&"a".repeat(64), &"b".repeat(64), "").key(&"c".repeat(64));
        assert_eq!(
            key.managed_control_mapping_sha256,
            "cc7cd19db3e1fb4ad44fb7e9cdf897c0ce8acd631b3b136b225c1a24204f0d94"
        );
        assert_eq!(
            key.permit_codec_sha256,
            "4ee06e55647e135a0bc481cbb98ef8c107bebdc476b1458ffd153414e2d54bab"
        );
        assert!(!MANAGED_CONTROL_MAPPING.ends_with('\n'));
        assert!(!PERMIT_CODEC.ends_with('\n'));
        assert_eq!(key.authority_namespace, "arkdeck");
        assert_eq!(key.authority_implementation_version, "1.0.0");
    }

    #[test]
    fn no_campaign_is_hardware_gated_and_cannot_execute() {
        let seal = Configuration::new(&"A".repeat(64), &"b".repeat(64), "")
            .seal(&"c".repeat(64))
            .unwrap();
        assert_eq!(seal.state, "hardwareGated");
        assert!(!seal.permits_execution());
        assert!(seal.campaign().is_empty());
        assert_eq!(
            seal.detail,
            "the exact ArkDeck authority build/control-map/HDC/permit-codec/mechanics/platform \
             combination has no reviewed production support record"
        );
        // The configuration's digests are lowercased, as Swift's are.
        assert_eq!(seal.key.authority_implementation_sha256, "a".repeat(64));
        assert_eq!(seal.key_hex(), hex(&seal.key_sha256));
    }

    #[test]
    fn a_campaign_seals_the_key_as_that_campaigns() {
        let seal = Configuration::new(&"a".repeat(64), &"b".repeat(64), "gj4-20260926")
            .seal(&"c".repeat(64))
            .unwrap();
        assert_eq!(seal.state, "hardwareCampaign");
        assert!(seal.permits_execution());
        assert_eq!(seal.campaign(), "gj4-20260926");
        assert_eq!(
            Configuration::new(&"a".repeat(64), &"b".repeat(64), "two\nlines")
                .seal(&"c".repeat(64)),
            Err(SupportError::InvalidIdentifier {
                axis: "hardwareCampaign".to_owned(),
                value: "two\nlines".to_owned(),
            })
        );
        let production = Seal {
            state: "productionVerified".to_owned(),
            ..seal
        };
        assert!(production.permits_execution());
        assert!(production.campaign().is_empty());
    }

    #[test]
    fn a_malformed_axis_cannot_be_padded_or_truncated_into_a_key() {
        let mut malformed = base_key();
        malformed.managed_control_tool_sha256 = "abc".to_owned();
        let error = malformed.digest_bytes().unwrap_err();
        assert_eq!(
            error,
            SupportError::InvalidDigest {
                axis: "managedControlToolSHA256".to_owned(),
                value: "abc".to_owned(),
            }
        );
        assert_eq!(
            error.to_string(),
            "managedControlToolSHA256 must be exactly 32 lowercase hex-encoded bytes"
        );
        let mut uppercase = base_key();
        uppercase.mechanics_maturity_key_sha256 = "A".repeat(64);
        assert!(uppercase.digest_bytes().is_err());
        for (axis, value) in [
            ("authorityNamespace", ""),
            ("authorityImplementationVersion", "1.0\n0"),
            ("hostPlatform", "macos=arm64"),
        ] {
            let mut key = base_key();
            match axis {
                "authorityNamespace" => key.authority_namespace = value.to_owned(),
                "authorityImplementationVersion" => {
                    key.authority_implementation_version = value.to_owned()
                }
                _ => key.host_platform = value.to_owned(),
            }
            let error = key.digest_bytes().unwrap_err();
            assert_eq!(
                error.to_string(),
                format!("{axis} must be a non-empty single-line identifier without '='")
            );
        }
    }

    #[test]
    fn the_pending_seal_is_swifts() {
        assert_eq!(
            hex(&pending_key_sha256()),
            sha256_hex(b"arkdeck.authority-support-pending/v1")
        );
        assert_eq!(
            PENDING_DETAIL,
            "the exact mechanics maturity key has not yet been bound to ArkDeck authority support"
        );
    }

    #[test]
    fn the_host_platform_is_swifts_spelling() {
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        assert_eq!(host_platform(), "macos/arm64");
        #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
        assert_eq!(host_platform(), "macos/x86_64");
        assert!(host_platform().contains('/'));
    }
}
