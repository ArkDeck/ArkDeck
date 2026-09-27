use crate::update_feed::signed::Payload;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const STATE_SCHEMA: &str = "arkdeck.runtime-update-state/1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Feed {
    pub payload: Payload,
    pub canonical_payload: String,
    #[serde(rename = "payloadSHA256")]
    pub payload_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
    pub byte_length: u64,
    pub mode: u32,
    pub modified_seconds: i64,
    pub modified_nanoseconds: i64,
    pub changed_seconds: i64,
    pub changed_nanoseconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadedArtifact {
    pub url: String,
    pub byte_length: u64,
    pub sha256: String,
    pub identity: FileIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidatedArtifact {
    pub downloaded: DownloadedArtifact,
    pub team_identifier: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    Network,
    Feed,
    Download,
    Artifact,
    Handoff,
    Storage,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoUpdate {
    CurrentVersion,
    UnsupportedSystem,
    UnsupportedArchitecture,
}

/// Swift synthesized Codable uses an object even for empty enum cases, and
/// `_0` for unlabelled associated values. These names are persisted wire data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Idle {},
    Checking {},
    Available {
        #[serde(rename = "_0")]
        feed: Feed,
    },
    NoUpdate {
        #[serde(rename = "_0")]
        reason: NoUpdate,
    },
    Downloading {
        #[serde(rename = "_0")]
        feed: Feed,
    },
    Verifying {
        #[serde(rename = "_0")]
        artifact: DownloadedArtifact,
    },
    AwaitingConsent {
        feed: Feed,
        artifact: ValidatedArtifact,
    },
    HandedOff {
        #[serde(rename = "_0")]
        url: String,
    },
    Failed {
        #[serde(rename = "_0")]
        code: Failure,
    },
    Cancelled {},
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub schema_version: String,
    pub generation: u64,
    pub state: State,
    #[serde(rename = "activeOperationID", skip_serializing_if = "Option::is_none")]
    pub active_operation_id: Option<String>,
    pub cancellation_requested: bool,
    #[serde(rename = "updatedAtUTC")]
    pub updated_at_utc: String,
}

impl Snapshot {
    pub fn initial(now: &str) -> Self {
        Self {
            schema_version: STATE_SCHEMA.into(),
            generation: 0,
            state: State::Idle {},
            active_operation_id: None,
            cancellation_requested: false,
            updated_at_utc: now.into(),
        }
    }

    pub fn is_valid(&self) -> bool {
        if self.schema_version != STATE_SCHEMA
            || arkdeck_contract::import_timestamp(&self.updated_at_utc).is_none()
        {
            return false;
        }
        let active = self.active_operation_id.is_some();
        if self
            .active_operation_id
            .as_deref()
            .is_some_and(|id| !uuid(id))
            || (self.cancellation_requested && !active)
        {
            return false;
        }
        let feed = match &self.state {
            State::Available { feed }
            | State::Downloading { feed }
            | State::AwaitingConsent { feed, .. } => Some(feed),
            _ => None,
        };
        if feed.is_some_and(|feed| !canonical_base64(&feed.canonical_payload)) {
            return false;
        }
        let url = match &self.state {
            State::Verifying { artifact } => Some(&artifact.url),
            State::AwaitingConsent { artifact, .. } => Some(&artifact.downloaded.url),
            State::HandedOff { url } => Some(url),
            _ => None,
        };
        if url.is_some_and(|url| !canonical_url(url)) {
            return false;
        }
        match &self.state {
            State::Checking {} | State::Downloading { .. } | State::Verifying { .. } => active,
            State::AwaitingConsent { .. } => true,
            _ => !active,
        }
    }

    /// Exactly the path-free CLI status projection; private artifact URLs and
    /// signing identities are never copied into this document.
    pub fn projection(&self) -> Value {
        let (phase, feed, artifact, no_update, failure) = match &self.state {
            State::Idle {} => ("idle", None, None, None, None),
            State::Checking {} => ("checking", None, None, None, None),
            State::Available { feed } => ("available", Some(feed), None, None, None),
            State::NoUpdate { reason } => ("noUpdate", None, None, Some(reason), None),
            State::Downloading { feed } => ("downloading", Some(feed), None, None, None),
            State::Verifying { artifact } => ("verifying", None, Some(artifact), None, None),
            State::AwaitingConsent { feed, artifact } => (
                "awaitingConsent",
                Some(feed),
                Some(&artifact.downloaded),
                None,
                None,
            ),
            State::HandedOff { .. } => ("handedOff", None, None, None, None),
            State::Failed { code } => ("failed", None, None, None, Some(code)),
            State::Cancelled {} => ("cancelled", None, None, None, None),
        };
        let busy = self.active_operation_id.is_some();
        json!({"schemaVersion":"arkdeck.runtime-update-status/1", "generation":self.generation,
            "phase":phase,"isBusy":busy,"cancellationRequested":self.cancellation_requested,
            "canCheck":!busy && !["awaitingConsent","handedOff"].contains(&phase),
            "canDownload":!busy && phase == "available", "canHandoff":!busy && phase == "awaitingConsent",
            "updateVersion":feed.map(|feed| &feed.payload.version),
            "releaseNotesSummary":feed.map(|feed| &feed.payload.release_notes_summary),
            "artifactSha256":artifact.map(|artifact| &artifact.sha256),
            "artifactByteLength":artifact.map(|artifact| artifact.byte_length),
            "noUpdateReason":no_update,"failureCode":failure,"updatedAtUtc":self.updated_at_utc})
    }
}

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte)
            }
        })
}

fn canonical_base64(value: &str) -> bool {
    if value.is_empty() {
        return true;
    }
    if !value.len().is_multiple_of(4) {
        return false;
    }
    let padding = value.bytes().rev().take_while(|byte| *byte == b'=').count();
    if padding > 2 {
        return false;
    }
    let count = value.len() / 4 * 3 - padding;
    arkdeck_contract::decode_import_chunk(value, count as u64)
        .and_then(|bytes| arkdeck_contract::encode_import_chunk(&bytes))
        .is_ok_and(|encoded| encoded == value)
}

/// A URL Codable string must already be in its escaped representation. Swift
/// re-encodes raw spaces/Unicode/malformed percent signs before the durable
/// canonical-byte comparison, which makes those source records unreadable.
fn canonical_url(value: &str) -> bool {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&'()*+,;=%".contains(&byte))
    {
        return false;
    }
    let mut bytes = value.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%'
            && (!bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit())
                || !bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit()))
        {
            return false;
        }
    }
    let first_segment = value.split(['/', '?', '#']).next().unwrap_or("");
    let rest = if let Some((scheme, _)) = first_segment.split_once(':') {
        if !scheme
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphabetic)
            || !scheme
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"+-.".contains(&byte))
        {
            return false;
        }
        &value[scheme.len() + 1..]
    } else {
        value
    };
    let suffix = if let Some(after) = rest.strip_prefix("//") {
        let end = after.find(['/', '?', '#']).unwrap_or(after.len());
        let authority = &after[..end];
        if authority.contains(['[', ']']) {
            let host = authority.rsplit('@').next().unwrap_or(authority);
            let Some((address, tail)) =
                host.strip_prefix('[').and_then(|host| host.split_once(']'))
            else {
                return false;
            };
            if address.is_empty()
                || address.contains(['[', ']'])
                || (!tail.is_empty() && !tail.starts_with(':'))
            {
                return false;
            }
        }
        &after[end..]
    } else {
        rest
    };
    !suffix.contains(['[', ']'])
}
