//! Swift `RockchipPostFlashHDCBinding` and the decisions of its store
//! (`RockchipPostFlashHDCBinding.swift`), without a file behind them: the
//! record that keeps an adopted Target usable after a flash rotates its HDC
//! serial, its canonical bytes, its validation, the three-way publication,
//! the archive name of a superseded epoch, and the reconciliation of a
//! reissued lineage. `PostFlashAliasStore` keeps the bytes; the routing that
//! decides whether an alias may serve a Target (`covers`, the facts port's
//! `flash.postFlash*` refusals) is the ArkForge lane's.
use crate::format_time::valid_format_timestamp;
use arkdeck_contract::{canonical_json, sha256_hex};
use serde_json::{Map, Value};
use std::fmt;

/// Swift `RockchipPostFlashHDCBinding.currentSchemaVersion`.
pub const SCHEMA_VERSION: &str = "1.0.0";

/// The one error family the store raises: Swift
/// `RockchipFlashExecutionError.productionConfigurationUnavailable(detail)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PostFlashAliasError(String);

impl PostFlashAliasError {
    pub(crate) fn new(detail: impl Into<String>) -> Self {
        Self(detail.into())
    }

    /// The detail Swift's error carries.
    pub fn detail(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for PostFlashAliasError {
    /// Swift's `errorDescription`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "product execution configuration unavailable: {}", self.0)
    }
}

impl std::error::Error for PostFlashAliasError {}

const INVALID: &str = "post-flash binding document is invalid";

/// Swift `RockchipPostFlashHDCBinding`. The field names are the durable keys;
/// on disk they are sorted, so `bindingRevision` comes first and
/// `usbTopology` last.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PostFlashBinding {
    /// Always [`SCHEMA_VERSION`] for a record the store accepts.
    pub schema_version: String,
    pub target_id: String,
    pub binding_revision: i64,
    pub stable_loader_identity_sha256: String,
    pub previous_hdc_identity_sha256: String,
    pub hdc_identity_sha256: String,
    pub hdc_connect_key: String,
    pub usb_topology: String,
    pub product_model: String,
    pub build_version: String,
    pub job_id: String,
    pub established_at_utc: String,
}

impl PostFlashBinding {
    /// Swift `sameProof(as:)`: every field but `establishedAtUTC` — the
    /// crash-retry idempotency key.
    pub fn same_proof(&self, other: &Self) -> bool {
        self.schema_version == other.schema_version
            && self.target_id == other.target_id
            && self.binding_revision == other.binding_revision
            && self.stable_loader_identity_sha256 == other.stable_loader_identity_sha256
            && self.previous_hdc_identity_sha256 == other.previous_hdc_identity_sha256
            && self.hdc_identity_sha256 == other.hdc_identity_sha256
            && self.hdc_connect_key == other.hdc_connect_key
            && self.usb_topology == other.usb_topology
            && self.product_model == other.product_model
            && self.build_version == other.build_version
            && self.job_id == other.job_id
    }

    /// Swift `RockchipPostFlashHDCBindingStore.validate`: the closed shape,
    /// one message for every failure.
    pub fn validate(&self) -> Result<(), PostFlashAliasError> {
        let valid = self.schema_version == SCHEMA_VERSION
            && !self.target_id.is_empty()
            && self.binding_revision > 0
            && is_sha256(&self.stable_loader_identity_sha256)
            && is_sha256(&self.previous_hdc_identity_sha256)
            && is_sha256(&self.hdc_identity_sha256)
            && !self.hdc_connect_key.is_empty()
            && self.hdc_connect_key.len() <= 1_024
            && !self
                .hdc_connect_key
                .chars()
                .any(arkdeck_platform::host_control_character)
            && sha256_hex(self.hdc_connect_key.as_bytes()) == self.hdc_identity_sha256
            && !self.usb_topology.is_empty()
            && self.usb_topology.bytes().all(|byte| byte.is_ascii_digit())
            && !self.product_model.is_empty()
            && !self.build_version.is_empty()
            && !self.job_id.is_empty()
            && valid_format_timestamp(&self.established_at_utc);
        if valid {
            Ok(())
        } else {
            Err(PostFlashAliasError::new(INVALID))
        }
    }

    /// The record as Swift's `JSONEncoder` sees it, sorted.
    pub fn value(&self) -> Value {
        let mut object = Map::new();
        let fields: [(&str, &str); 11] = [
            ("schemaVersion", &self.schema_version),
            ("targetID", &self.target_id),
            (
                "stableLoaderIdentitySHA256",
                &self.stable_loader_identity_sha256,
            ),
            (
                "previousHDCIdentitySHA256",
                &self.previous_hdc_identity_sha256,
            ),
            ("hdcIdentitySHA256", &self.hdc_identity_sha256),
            ("hdcConnectKey", &self.hdc_connect_key),
            ("usbTopology", &self.usb_topology),
            ("productModel", &self.product_model),
            ("buildVersion", &self.build_version),
            ("jobID", &self.job_id),
            ("establishedAtUTC", &self.established_at_utc),
        ];
        for (key, text) in fields {
            object.insert(key.to_owned(), Value::String(text.to_owned()));
        }
        object.insert(
            "bindingRevision".to_owned(),
            Value::from(self.binding_revision),
        );
        Value::Object(object)
    }

    /// Swift `CanonicalJSONEncoders.canonical()` (`.sortedKeys`,
    /// `.withoutEscapingSlashes`) plus the one trailing newline `commit` and
    /// `archiveSuperseded` append: the bytes on disk.
    pub fn encode(&self) -> Result<Vec<u8>, PostFlashAliasError> {
        let mut bytes = canonical_json(&self.value())
            .map_err(|_| PostFlashAliasError::new("post-flash binding cannot be encoded"))?;
        bytes.push(b'\n');
        Ok(bytes)
    }

    /// Swift `JSONDecoder().decode(RockchipPostFlashHDCBinding.self, ...)`:
    /// unknown members ignored, a duplicate member's last value taken, and
    /// an integer spelled with a zero fraction accepted. Nothing is
    /// validated here; `validate` follows a decode.
    pub fn decode(bytes: &[u8]) -> Result<Self, PostFlashAliasError> {
        let undecodable = || PostFlashAliasError::new("post-flash binding cannot be decoded");
        let value: Value = serde_json::from_slice(bytes).map_err(|_| undecodable())?;
        let object = value.as_object().ok_or_else(undecodable)?;
        let text = |key: &str| -> Result<String, PostFlashAliasError> {
            object
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(undecodable)
        };
        Ok(Self {
            schema_version: text("schemaVersion")?,
            target_id: text("targetID")?,
            binding_revision: integer(object.get("bindingRevision")).ok_or_else(undecodable)?,
            stable_loader_identity_sha256: text("stableLoaderIdentitySHA256")?,
            previous_hdc_identity_sha256: text("previousHDCIdentitySHA256")?,
            hdc_identity_sha256: text("hdcIdentitySHA256")?,
            hdc_connect_key: text("hdcConnectKey")?,
            usb_topology: text("usbTopology")?,
            product_model: text("productModel")?,
            build_version: text("buildVersion")?,
            job_id: text("jobID")?,
            established_at_utc: text("establishedAtUTC")?,
        })
    }

    /// Swift `archiveSuperseded`'s name for this record once superseded:
    /// `post-flash-superseded-<alphanumerics of establishedAtUTC>.json`, or
    /// `unknown` when nothing alphanumeric remains. (Swift filters
    /// `CharacterSet.alphanumerics`; a timestamp the store accepted is ASCII,
    /// where Rust's `is_alphanumeric` agrees.)
    pub fn archive_name(&self) -> String {
        let stamp: String = self
            .established_at_utc
            .chars()
            .filter(|character| character.is_alphanumeric())
            .collect();
        format!(
            "post-flash-superseded-{}.json",
            if stamp.is_empty() { "unknown" } else { &stamp }
        )
    }
}

/// Swift's `Int` decoding as Foundation performs it: any number without a
/// fraction, however it is spelled.
fn integer(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    if let Some(integer) = number.as_i64() {
        return Some(integer);
    }
    let float = number.as_f64()?;
    const EXACT: f64 = 9_007_199_254_740_992.0;
    (float.fract() == 0.0 && float.abs() < EXACT).then_some(float as i64)
}

/// Swift `RockchipPostFlashHDCBindingStore.isSHA256`: 64 lowercase hex
/// characters.
pub fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// What `publish` does with a candidate against the stored record, decided
/// under the store's lock.
#[derive(Debug, PartialEq, Eq)]
pub enum Publication<'a> {
    /// The stored record is the same proof (every field but its time): it is
    /// returned unchanged and nothing is written — a crash retry.
    Idempotent(&'a PostFlashBinding),
    /// A revision advance opens a new epoch: the stored record is archived,
    /// then the candidate committed.
    ArchiveThenCommit,
    /// The first record, or a same-revision rotation whose chain names the
    /// stored alias: committed.
    Commit,
}

/// Swift `publish`'s two checks before the root and the lock: the candidate
/// must be a valid record, and the expected previous alias must be a digest
/// that the candidate itself names as its previous alias.
pub fn admit(
    candidate: &PostFlashBinding,
    expected_previous_hdc_identity_sha256: &str,
) -> Result<(), PostFlashAliasError> {
    candidate.validate()?;
    if !is_sha256(expected_previous_hdc_identity_sha256)
        || candidate.previous_hdc_identity_sha256 != expected_previous_hdc_identity_sha256
    {
        return Err(PostFlashAliasError::new(
            "post-flash binding previous alias is invalid",
        ));
    }
    Ok(())
}

/// Swift `publish`'s three-way resolution against what the store holds.
/// The fourth conjunct of the refusal — the stored alias must be the one the
/// caller expected to supersede — is what keeps a stale Job from rotating a
/// newer route.
pub fn resolve<'a>(
    existing: Option<&'a PostFlashBinding>,
    candidate: &PostFlashBinding,
    expected_previous_hdc_identity_sha256: &str,
) -> Result<Publication<'a>, PostFlashAliasError> {
    let Some(existing) = existing else {
        return Ok(Publication::Commit);
    };
    if existing.same_proof(candidate) {
        return Ok(Publication::Idempotent(existing));
    }
    if existing.target_id == candidate.target_id
        && existing.binding_revision < candidate.binding_revision
    {
        return Ok(Publication::ArchiveThenCommit);
    }
    if existing.target_id == candidate.target_id
        && existing.binding_revision == candidate.binding_revision
        && existing.stable_loader_identity_sha256 == candidate.stable_loader_identity_sha256
        && existing.hdc_identity_sha256 == expected_previous_hdc_identity_sha256
    {
        return Ok(Publication::Commit);
    }
    Err(PostFlashAliasError::new(
        "post-flash binding changed before verified alias publication",
    ))
}

/// The live Target a reissued lineage is reconciled against (the three
/// fields of Swift's `RuntimeTargetRecord` the store reads).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveTarget<'a> {
    pub target_id: &'a str,
    pub stable_identity_sha256: &'a str,
    pub binding_revision: i64,
}

/// The HDC-normal device observed on the host right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ObservedHdc<'a> {
    pub identity_sha256: &'a str,
    pub connect_key: &'a str,
    pub usb_topology: &'a str,
}

/// Swift `ReissuedLineageReconciliation`: what the store proved and did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reconciliation {
    pub archived_revision: i64,
    pub published_revision: i64,
    pub target_id: String,
    pub hdc_identity_sha256: String,
}

/// Swift `reconcileReissuedLineage`'s decision: a stored alias ahead of the
/// live Target's revision, agreeing with it and with the observed device on
/// every identity fact, is republished at the live revision naming itself as
/// its previous alias; any disagreement is `None`, never a refusal.
/// `buildVersion` is not a precondition: it can only be read over HDC, and
/// this is a host-local repair.
pub fn reissue(
    existing: &PostFlashBinding,
    target: &LiveTarget<'_>,
    observed: &ObservedHdc<'_>,
    now_utc: &str,
) -> Option<PostFlashBinding> {
    if existing.binding_revision <= target.binding_revision {
        return None;
    }
    let agrees = existing.target_id == target.target_id
        && existing.stable_loader_identity_sha256 == target.stable_identity_sha256
        && existing.hdc_identity_sha256 == observed.identity_sha256
        && existing.hdc_connect_key == observed.connect_key
        && existing.usb_topology == observed.usb_topology
        && is_sha256(observed.identity_sha256)
        && sha256_hex(observed.connect_key.as_bytes()) == observed.identity_sha256
        && valid_format_timestamp(now_utc);
    if !agrees {
        return None;
    }
    Some(PostFlashBinding {
        binding_revision: target.binding_revision,
        previous_hdc_identity_sha256: existing.hdc_identity_sha256.clone(),
        established_at_utc: now_utc.to_owned(),
        ..existing.clone()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(revision: i64, key: &str, at: &str) -> PostFlashBinding {
        PostFlashBinding {
            schema_version: SCHEMA_VERSION.to_owned(),
            target_id: "TGT-HOST".to_owned(),
            binding_revision: revision,
            stable_loader_identity_sha256: "a".repeat(64),
            previous_hdc_identity_sha256: sha256_hex(key.as_bytes()),
            hdc_identity_sha256: sha256_hex(key.as_bytes()),
            hdc_connect_key: key.to_owned(),
            usb_topology: "42".to_owned(),
            product_model: "ohos".to_owned(),
            build_version: "OpenHarmony-7.0.0.36".to_owned(),
            job_id: "job-host".to_owned(),
            established_at_utc: at.to_owned(),
        }
    }

    #[test]
    fn the_bytes_are_sorted_compact_and_newline_terminated() {
        let bytes = record(3, "old-key", "2026-08-14T08:09:51Z")
            .encode()
            .unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(
            text.starts_with("{\"bindingRevision\":3,\"buildVersion\":\"OpenHarmony-7.0.0.36\",")
        );
        assert!(text.ends_with("\"targetID\":\"TGT-HOST\",\"usbTopology\":\"42\"}\n"));
        assert!(!text.contains(' '));
        assert_eq!(
            PostFlashBinding::decode(&bytes).unwrap(),
            record(3, "old-key", "2026-08-14T08:09:51Z")
        );
    }

    #[test]
    fn decoding_is_as_lenient_as_foundation_and_validation_is_not() {
        let mut lenient = record(3, "old-key", "2026-08-14T08:09:51Z").value();
        lenient["bindingRevision"] = serde_json::json!(3.0);
        lenient["unknown"] = serde_json::json!("ignored");
        let decoded = PostFlashBinding::decode(&serde_json::to_vec(&lenient).unwrap()).unwrap();
        assert_eq!(decoded.binding_revision, 3);
        decoded.validate().unwrap();
        lenient["bindingRevision"] = serde_json::json!(3.5);
        assert!(PostFlashBinding::decode(&serde_json::to_vec(&lenient).unwrap()).is_err());
        assert!(PostFlashBinding::decode(b"[]").is_err());
        assert!(PostFlashBinding::decode(b"{\"bindingRevision\":\"3\"}").is_err());

        let invalid = [
            PostFlashBinding {
                schema_version: "2.0.0".into(),
                ..record(3, "k", "2026-08-14T08:09:51Z")
            },
            record(0, "k", "2026-08-14T08:09:51Z"),
            PostFlashBinding {
                hdc_identity_sha256: "b".repeat(64),
                ..record(3, "k", "2026-08-14T08:09:51Z")
            },
            PostFlashBinding {
                hdc_connect_key: "k\u{7}".into(),
                ..record(3, "k", "2026-08-14T08:09:51Z")
            },
            PostFlashBinding {
                usb_topology: "4a".into(),
                ..record(3, "k", "2026-08-14T08:09:51Z")
            },
            record(3, "k", "yesterday"),
            PostFlashBinding {
                job_id: String::new(),
                ..record(3, "k", "2026-08-14T08:09:51Z")
            },
        ];
        for candidate in invalid {
            assert_eq!(
                candidate.validate().unwrap_err().detail(),
                "post-flash binding document is invalid",
                "{candidate:?}"
            );
        }
    }

    #[test]
    fn the_archive_name_is_the_time_s_alphanumerics() {
        assert_eq!(
            record(3, "k", "2026-08-14T08:09:51Z").archive_name(),
            "post-flash-superseded-20260814T080951Z.json"
        );
        assert_eq!(
            record(3, "k", "2026-09-02T07:00:39.250+08:00").archive_name(),
            "post-flash-superseded-20260902T0700392500800.json"
        );
        assert_eq!(
            record(3, "k", "---").archive_name(),
            "post-flash-superseded-unknown.json"
        );
    }

    #[test]
    fn publication_is_idempotent_advances_or_follows_the_chain() {
        let stored = record(3, "old-key", "2026-08-14T08:09:51Z");
        let expected = sha256_hex(b"old-key");
        admit(&stored, &expected).unwrap();
        assert_eq!(
            admit(&stored, "not-a-digest").unwrap_err().detail(),
            "post-flash binding previous alias is invalid"
        );
        assert_eq!(
            admit(&stored, &sha256_hex(b"other")).unwrap_err().detail(),
            "post-flash binding previous alias is invalid"
        );
        assert_eq!(
            resolve(None, &stored, &expected).unwrap(),
            Publication::Commit
        );
        let retry = record(3, "old-key", "2026-08-14T09:00:00Z");
        assert_eq!(
            resolve(Some(&stored), &retry, &expected).unwrap(),
            Publication::Idempotent(&stored)
        );
        let advance = record(4, "new-key", "2026-08-18T04:30:00Z");
        assert_eq!(
            resolve(Some(&stored), &advance, &sha256_hex(b"new-key")).unwrap(),
            Publication::ArchiveThenCommit
        );
        assert_eq!(
            resolve(Some(&advance), &retry, &expected)
                .unwrap_err()
                .detail(),
            "post-flash binding changed before verified alias publication"
        );
        let rotated = PostFlashBinding {
            previous_hdc_identity_sha256: sha256_hex(b"new-key"),
            hdc_identity_sha256: sha256_hex(b"newer-key"),
            hdc_connect_key: "newer-key".into(),
            ..record(4, "new-key", "2026-08-19T00:00:00Z")
        };
        assert_eq!(
            resolve(Some(&advance), &rotated, &sha256_hex(b"new-key")).unwrap(),
            Publication::Commit
        );
        let other_loader = PostFlashBinding {
            stable_loader_identity_sha256: "c".repeat(64),
            ..advance.clone()
        };
        assert!(resolve(Some(&advance), &other_loader, &sha256_hex(b"new-key")).is_err());
    }

    #[test]
    fn a_reissued_lineage_is_republished_at_the_live_revision_or_declined() {
        let stored = record(4, "newer-key", "2026-08-19T00:00:00Z");
        let live = LiveTarget {
            target_id: "TGT-HOST",
            stable_identity_sha256: &"a".repeat(64),
            binding_revision: 2,
        };
        let observed = ObservedHdc {
            identity_sha256: &sha256_hex(b"newer-key"),
            connect_key: "newer-key",
            usb_topology: "42",
        };
        let republished = reissue(&stored, &live, &observed, "2026-09-08T08:05:00Z").unwrap();
        assert_eq!(republished.binding_revision, 2);
        assert_eq!(
            republished.previous_hdc_identity_sha256,
            sha256_hex(b"newer-key")
        );
        assert_eq!(republished.established_at_utc, "2026-09-08T08:05:00Z");
        assert_eq!(republished.hdc_connect_key, "newer-key");
        republished.validate().unwrap();

        let behind = LiveTarget {
            binding_revision: 9,
            ..live
        };
        assert_eq!(
            reissue(&stored, &behind, &observed, "2026-09-08T08:05:00Z"),
            None
        );
        let moved = ObservedHdc {
            usb_topology: "43",
            ..observed
        };
        assert_eq!(
            reissue(&stored, &live, &moved, "2026-09-08T08:05:00Z"),
            None
        );
        let other = LiveTarget {
            target_id: "TGT-OTHER",
            ..live
        };
        assert_eq!(
            reissue(&stored, &other, &observed, "2026-09-08T08:05:00Z"),
            None
        );
        assert_eq!(reissue(&stored, &live, &observed, "now"), None);
    }
}
