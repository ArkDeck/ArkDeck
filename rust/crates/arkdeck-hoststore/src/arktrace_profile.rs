//! Swift `ArkTraceSummaryAnalyzerProfileLoader`: the reviewed descriptor an
//! operator names in `ARKDECK_ARKTRACE_DESCRIPTOR`, the ArkTrace CLI
//! distribution it selects, and the two analyzer profiles one trusted,
//! doctor-probed generation of it serves (`trace-summary@1` and
//! `trace-analysis@1`).
//!
//! The descriptor and every distribution file are read as Swift's bounded
//! physical reader reads them; the manifest is closed over its keys and
//! bound to the reviewed contract; every executable, parser file and receipt
//! must hold its manifest digest; a trust checker proves the App and its
//! helper (in production: their Developer ID signatures, notarization, code
//! directory hashes and trees); with a snapshot root, the distribution is
//! copied into a private generation named by its tree digest, and the
//! profile runs from there; a doctor probe runs the CLI's own self-test;
//! and every path is bound again before the profiles are returned.
//!
//! Strings are read as Swift reads them, over Characters: a path's prefix
//! and components, and the hexadecimal digests (`Character.isHexDigit`, which
//! also admits fullwidth digits). Numbers are read as `JSONSerialization`
//! and `JSONDecoder` read them.
use crate::job_plan::AnalyzerProfile;
use crate::session_graphemes::graphemes;
use arkdeck_platform::{
    DistributionTree, ProfilePath, ProfileReadError, TreeError, copy_tree_snapshot,
    has_no_symlink_component, is_physical_directory, open_or_create_owner_private_directory,
    open_physical_directory, profile_file_matches, read_profile_file, remove_tree_snapshot,
    tree_matches, tree_matches_at, tree_snapshot,
};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::fs::File;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

pub const SUMMARY_REF: &str = "trace-summary@1";
pub const ANALYSIS_REF: &str = "trace-analysis@1";

const MAXIMUM_PROFILE_FILE_BYTES: u64 = 128 * 1024 * 1024;

/// Swift `ArkTraceSummaryProfileError`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArkTraceProfileError {
    NotFound,
    DescriptorInvalid,
    ManifestDrift,
    ContractMismatch,
    ToolDrift,
    ParserDrift,
    SelfTestFailed,
}

impl ArkTraceProfileError {
    pub fn reason(self) -> &'static str {
        match self {
            Self::NotFound => "analyzer.arktraceNotFound",
            Self::DescriptorInvalid => "analyzer.arktraceDescriptorInvalid",
            Self::ManifestDrift => "analyzer.arktraceManifestDrift",
            Self::ContractMismatch => "analyzer.arktraceContractMismatch",
            Self::ToolDrift => "analyzer.arktraceToolDrift",
            Self::ParserDrift => "analyzer.arktraceParserDrift",
            Self::SelfTestFailed => "analyzer.arktraceSelfTestFailed",
        }
    }
}

/// Why a load failed: one of the loader's own reasons, or any other error
/// (a reader or file system failure), which the daemon reports as a
/// descriptor it could not use (Swift `main.swift`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArkTraceLoadError {
    Profile(ArkTraceProfileError),
    Other(String),
}

impl ArkTraceLoadError {
    /// The unavailable reason the daemon composes for both analyzers.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Profile(error) => error.reason(),
            Self::Other(_) => ArkTraceProfileError::DescriptorInvalid.reason(),
        }
    }
}

impl From<ArkTraceProfileError> for ArkTraceLoadError {
    fn from(error: ArkTraceProfileError) -> Self {
        Self::Profile(error)
    }
}

impl From<TreeError> for ArkTraceLoadError {
    fn from(error: TreeError) -> Self {
        match error {
            TreeError::Mismatch => Self::Profile(ArkTraceProfileError::ContractMismatch),
            TreeError::Reader(error) => Self::Other(format!("{error:?}")),
        }
    }
}

use ArkTraceProfileError::{
    ContractMismatch, DescriptorInvalid, ManifestDrift, NotFound, ParserDrift, SelfTestFailed,
    ToolDrift,
};

/// Swift `AnalyzerPinnedFile`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedFile {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
    pub require_executable: bool,
}

/// Swift `AnalyzerPinnedTree`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedTree {
    pub path: String,
    pub sha256: String,
}

/// Swift `ArkTraceSummaryInvocationContract`: the versions a reviewed
/// distribution produces, which every analysis it answers must carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArkTraceContract {
    pub tool_version: String,
    pub parser_version: String,
    pub parser_upstream_revision: String,
    pub parser_sha256: String,
    pub parser_build_recipe_version: String,
    pub parser_adapter_version: String,
    pub schema_adapter_version: String,
    pub index_schema_version: i64,
}

/// Swift `ArkTraceDistributionTrustContract`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrustContract {
    pub app_path: String,
    pub helper_path: String,
    pub resource_path: String,
    pub product_version: String,
    pub product_build: String,
    pub bundle_identifier: String,
    pub team_identifier: String,
    pub signing_identity: String,
    pub certificate_sha1: String,
    pub app_code_directory_hash: String,
    pub helper_code_directory_hash: String,
    pub app_tree_sha256: String,
    pub resource_tree_sha256: String,
}

/// Swift `ArkTraceDistributionTrustEvidence`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrustEvidence {
    pub pinned_files: Vec<PinnedFile>,
    pub pinned_trees: Vec<PinnedTree>,
}

/// Swift `ArkTraceDistributionTrustChecking`.
pub trait DistributionTrust {
    fn validate(&self, contract: &TrustContract) -> Result<TrustEvidence, ArkTraceLoadError>;
}

/// Swift `ResolvedExecutable` of an ArkTrace profile: the executable and
/// everything held open, digest-bound, while it runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedExecutable {
    pub path: String,
    pub sha256: String,
    /// Each pin with a byte count of at least one (Swift
    /// `ResolvedExecutableResource`).
    pub verified_resources: Vec<PinnedFile>,
    pub verified_trees: Vec<PinnedTree>,
    pub canonical_namespace_root: Option<String>,
}

/// Swift `ArkTraceDoctorContract`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DoctorContract {
    pub executable: ResolvedExecutable,
    pub product_version: String,
    pub timeout_seconds: i64,
    pub output_byte_budget: u64,
}

/// Swift `ArkTraceDoctorProbing`.
pub trait DoctorProbe {
    fn probe(&self, contract: &DoctorContract) -> bool;
}

/// Swift's two package-only loader hooks, for the tests that replace a
/// snapshot root once it is bound or collide with a final generation.
pub trait LoaderHooks {
    fn snapshot_root_bound(&self) -> Result<(), ArkTraceLoadError> {
        Ok(())
    }
    fn before_snapshot_publication(&self, _final_name: &str) -> Result<(), ArkTraceLoadError> {
        Ok(())
    }
}

/// Swift `ArkTraceSummaryAnalyzerProfileLoader`.
pub struct ArkTraceProfileLoader<'a> {
    pub doctor: &'a dyn DoctorProbe,
    pub trust: &'a dyn DistributionTrust,
    /// The daemon-private directory that holds snapshot generations, as a
    /// path string; `None` runs the profile from the selected install.
    pub snapshot_root: Option<String>,
    pub hooks: Option<&'a dyn LoaderHooks>,
}

// MARK: Swift strings

fn first_character_is_solidus(path: &str) -> bool {
    graphemes(path).next() == Some("/")
}

/// `split(separator: "/")` over Characters, empty parts omitted.
fn split_components(path: &str) -> Vec<String> {
    let mut parts = vec![String::new()];
    for character in graphemes(path) {
        if character == "/" {
            parts.push(String::new());
        } else if let Some(last) = parts.last_mut() {
            last.push_str(character);
        }
    }
    parts.into_iter().filter(|part| !part.is_empty()).collect()
}

/// Swift's `hasPrefix` over Characters.
fn has_prefix(text: &str, prefix: &str) -> bool {
    let mut text = graphemes(text);
    graphemes(prefix).all(|character| text.next() == Some(character))
}

/// A path string as Swift's reader opens it; one it cannot classify never
/// opens.
fn physical(path: &str) -> Option<ProfilePath> {
    crate::hilog_summary::profile_path(path, false).ok()
}

fn read(path: &str, maximum: u64) -> Result<Vec<u8>, ProfileReadError> {
    let path = physical(path).ok_or(ProfileReadError::PhysicalPath)?;
    read_profile_file(&path, maximum).map(|snapshot| snapshot.bytes)
}

fn matches(
    path: &str,
    sha256: &str,
    byte_count: Option<u64>,
    maximum: u64,
    require_executable: bool,
) -> bool {
    physical(path).is_some_and(|path| {
        profile_file_matches(&path, sha256, byte_count, maximum, require_executable)
    })
}

fn is_directory(path: &str) -> bool {
    physical(path).is_some_and(|path| is_physical_directory(&path))
}

fn no_symlink_component(path: &str) -> bool {
    physical(path).is_some_and(|path| has_no_symlink_component(&path))
}

/// Swift's `/var`, `/tmp` and `/etc` read below `/private`, then the
/// non-empty components, none `.` or `..`.
fn authority_components(path: &str) -> Result<Vec<String>, ProfileReadError> {
    if !first_character_is_solidus(path) {
        return Err(ProfileReadError::PhysicalPath);
    }
    let mapped = ["/var", "/tmp", "/etc"]
        .into_iter()
        .any(|root| path == root || has_prefix(path, &format!("{root}/")));
    let physical = if mapped {
        format!("/private{path}")
    } else {
        path.to_owned()
    };
    let components = split_components(&physical);
    if components.is_empty() || components.iter().any(|part| part == "." || part == "..") {
        return Err(ProfileReadError::PhysicalPath);
    }
    Ok(components)
}

fn owner_only(path: &str, leaf_is_directory: bool) -> bool {
    authority_components(path).is_ok_and(|components| {
        arkdeck_platform::validate_owner_only_authority(&components, leaf_is_directory).is_ok()
    })
}

/// `Character.isHexDigit`: one scalar with the Hex_Digit property, and
/// whether it is uppercase or lowercase.
fn hex_case(character: &str) -> Option<(bool, bool)> {
    let mut scalars = character.chars();
    let scalar = scalars.next()?;
    if scalars.next().is_some() {
        return None;
    }
    match scalar {
        '0'..='9' | '\u{FF10}'..='\u{FF19}' => Some((false, false)),
        'a'..='f' | '\u{FF41}'..='\u{FF46}' => Some((false, true)),
        'A'..='F' | '\u{FF21}'..='\u{FF26}' => Some((true, false)),
        _ => None,
    }
}

/// Swift `isSHA256`: 64 Characters, each a hexadecimal digit that is not
/// uppercase.
pub(crate) fn swift_sha256(value: &str) -> bool {
    graphemes(value).count() == 64
        && graphemes(value).all(|character| hex_case(character).is_some_and(|(upper, _)| !upper))
}

/// The manifest's `isSHA1`: 40 Characters, each a hexadecimal digit that is
/// not lowercase.
fn swift_uppercase_sha1(value: &str) -> bool {
    graphemes(value).count() == 40
        && graphemes(value).all(|character| hex_case(character).is_some_and(|(_, lower)| !lower))
}

// MARK: JSON as Swift reads it

/// `validateDuplicateFreeJSON`.
fn duplicate_free(bytes: &[u8]) -> Result<(), ArkTraceLoadError> {
    crate::strict_json::validate(bytes).map_err(|_| ContractMismatch.into())
}

/// `JSONSerialization.jsonObject(with:)` bridged `as? [String: Any]`.
fn object(bytes: &[u8]) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(bytes).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// `NSNumber as? Int`: a number exactly representable as an integer, or a
/// Boolean, which bridges to 0 or 1.
fn bridged_integer(value: &Value) -> Option<i64> {
    match value {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => number.as_i64().or_else(|| {
            let float = number.as_f64()?;
            (float.fract() == 0.0 && float >= i64::MIN as f64 && float < i64::MAX as f64)
                .then_some(float as i64)
        }),
        _ => None,
    }
}

/// `JSONDecoder` decoding `Int`: a number whose value is an integer.
fn decoded_integer(value: &Value) -> Option<i64> {
    let Value::Number(number) = value else {
        return None;
    };
    number.as_i64().or_else(|| {
        let float = number.as_f64()?;
        (float.fract() == 0.0 && float >= i64::MIN as f64 && float < i64::MAX as f64)
            .then_some(float as i64)
    })
}

fn keys(value: Option<&Value>) -> Option<BTreeSet<&str>> {
    value?
        .as_object()
        .map(|object| object.keys().map(String::as_str).collect())
}

fn key_set(names: &[&'static str]) -> BTreeSet<&'static str> {
    names.iter().copied().collect()
}

/// `validateManifestKeyClosure`.
fn manifest_key_closure(bytes: &[u8]) -> Result<(), ArkTraceLoadError> {
    let Some(root) = object(bytes) else {
        return Err(ContractMismatch.into());
    };
    let root = Value::Object(root);
    let closed = keys(Some(&root))
        == Some(key_set(&[
            "formatVersion",
            "source",
            "product",
            "layout",
            "tool",
            "traceStreamer",
            "signing",
            "notarization",
            "integrity",
            "attribution",
            "upgradePolicy",
        ]))
        && keys(root.get("source")) == Some(key_set(&["revision", "treeSHA256"]))
        && keys(root.get("product"))
            == Some(key_set(&[
                "name",
                "version",
                "build",
                "architecture",
                "bundleIdentifier",
                "jsonContract",
            ]))
        && keys(
            root.get("product")
                .and_then(|product| product.get("jsonContract")),
        ) == Some(key_set(&["major", "minor"]))
        && keys(root.get("layout"))
            == Some(key_set(&[
                "bundle",
                "executable",
                "parserExecutable",
                "parserManifest",
                "parserSigningRecord",
                "resourceBundle",
            ]))
        && keys(root.get("tool"))
            == Some(key_set(&["binarySHA256", "byteCount", "codeDirectoryHash"]))
        && keys(root.get("traceStreamer"))
            == Some(key_set(&[
                "unsignedBinarySHA256",
                "binarySHA256",
                "byteCount",
                "codeDirectoryHash",
                "manifestSHA256",
                "manifestByteCount",
                "signingRecordSHA256",
                "signingRecordByteCount",
                "reportedVersion",
                "upstreamRevision",
                "buildRecipeVersion",
            ]))
        && keys(root.get("signing"))
            == Some(key_set(&[
                "teamIdentifier",
                "identity",
                "certificateSHA1",
                "policy",
            ]))
        && keys(root.get("notarization"))
            == Some(key_set(&[
                "status",
                "submissionID",
                "receipt",
                "receiptSHA256",
                "stapledTicketValidated",
                "gatekeeperAssessment",
            ]))
        && keys(root.get("integrity"))
            == Some(key_set(&[
                "appTreeSHA256",
                "resourceTreeSHA256",
                "appCodeDirectoryHash",
            ]))
        && keys(root.get("attribution"))
            == Some(key_set(&[
                "license",
                "licenseSHA256",
                "licenseByteCount",
                "notice",
                "noticeSHA256",
                "noticeByteCount",
                "inventory",
                "inventorySHA256",
                "inventoryByteCount",
                "licenseFileCount",
                "selfTestFixture",
                "selfTestFixtureSHA256",
                "selfTestFixtureByteCount",
            ]))
        && keys(root.get("upgradePolicy"))
            == Some(key_set(&[
                "identity",
                "installMode",
                "pathSelection",
                "rollback",
            ]));
    if closed {
        Ok(())
    } else {
        Err(ContractMismatch.into())
    }
}

/// Swift's `DistributionManifest`, the members the loader reads, decoded as
/// `JSONDecoder` decodes them: strings as strings, integers as numbers whose
/// value is an integer, Booleans as Booleans.
struct Manifest {
    format_version: i64,
    product_name: String,
    product_version: String,
    product_build: String,
    product_architecture: String,
    bundle_identifier: String,
    json_major: i64,
    json_minor: i64,
    layout_bundle: String,
    layout_executable: String,
    layout_parser_executable: String,
    layout_parser_manifest: String,
    layout_parser_signing_record: String,
    layout_resource_bundle: String,
    source_tree_sha256: String,
    tool_sha256: String,
    tool_byte_count: i64,
    parser_sha256: String,
    parser_byte_count: i64,
    parser_code_directory_hash: String,
    parser_manifest_sha256: String,
    parser_manifest_byte_count: i64,
    signing_record_sha256: String,
    signing_record_byte_count: i64,
    parser_reported_version: String,
    parser_upstream_revision: String,
    parser_build_recipe_version: String,
    team_identifier: String,
    signing_identity: String,
    certificate_sha1: String,
    signing_policy: String,
    notarization_status: String,
    receipt: String,
    receipt_sha256: String,
    stapled_ticket_validated: bool,
    gatekeeper_assessment: String,
    app_tree_sha256: String,
    resource_tree_sha256: String,
    app_code_directory_hash: String,
    upgrade_identity: String,
    install_mode: String,
    path_selection: String,
    rollback: String,
}

impl Manifest {
    fn decode(bytes: &[u8]) -> Option<Self> {
        let root = Value::Object(object(bytes)?);
        let text = |group: &str, key: &str| -> Option<String> {
            root.get(group)?.get(key)?.as_str().map(str::to_owned)
        };
        let integer =
            |group: &str, key: &str| -> Option<i64> { decoded_integer(root.get(group)?.get(key)?) };
        // Every member JSONDecoder decodes, whether or not the loader reads
        // it afterwards: a member of another type fails the whole document.
        for key in ["revision", "treeSHA256"] {
            text("source", key)?;
        }
        for key in ["codeDirectoryHash", "binarySHA256"] {
            text("tool", key)?;
        }
        text("traceStreamer", "unsignedBinarySHA256")?;
        text("notarization", "submissionID")?;
        for key in [
            "license",
            "licenseSHA256",
            "notice",
            "noticeSHA256",
            "inventory",
            "inventorySHA256",
            "selfTestFixture",
            "selfTestFixtureSHA256",
        ] {
            text("attribution", key)?;
        }
        for key in [
            "licenseByteCount",
            "noticeByteCount",
            "inventoryByteCount",
            "licenseFileCount",
            "selfTestFixtureByteCount",
        ] {
            integer("attribution", key)?;
        }
        let contract = root.get("product")?.get("jsonContract")?;
        Some(Self {
            format_version: decoded_integer(root.get("formatVersion")?)?,
            product_name: text("product", "name")?,
            product_version: text("product", "version")?,
            product_build: text("product", "build")?,
            product_architecture: text("product", "architecture")?,
            bundle_identifier: text("product", "bundleIdentifier")?,
            json_major: decoded_integer(contract.get("major")?)?,
            json_minor: decoded_integer(contract.get("minor")?)?,
            layout_bundle: text("layout", "bundle")?,
            layout_executable: text("layout", "executable")?,
            layout_parser_executable: text("layout", "parserExecutable")?,
            layout_parser_manifest: text("layout", "parserManifest")?,
            layout_parser_signing_record: text("layout", "parserSigningRecord")?,
            layout_resource_bundle: text("layout", "resourceBundle")?,
            source_tree_sha256: text("source", "treeSHA256")?,
            tool_sha256: text("tool", "binarySHA256")?,
            tool_byte_count: integer("tool", "byteCount")?,
            parser_sha256: text("traceStreamer", "binarySHA256")?,
            parser_byte_count: integer("traceStreamer", "byteCount")?,
            parser_code_directory_hash: text("traceStreamer", "codeDirectoryHash")?,
            parser_manifest_sha256: text("traceStreamer", "manifestSHA256")?,
            parser_manifest_byte_count: integer("traceStreamer", "manifestByteCount")?,
            signing_record_sha256: text("traceStreamer", "signingRecordSHA256")?,
            signing_record_byte_count: integer("traceStreamer", "signingRecordByteCount")?,
            parser_reported_version: text("traceStreamer", "reportedVersion")?,
            parser_upstream_revision: text("traceStreamer", "upstreamRevision")?,
            parser_build_recipe_version: text("traceStreamer", "buildRecipeVersion")?,
            team_identifier: text("signing", "teamIdentifier")?,
            signing_identity: text("signing", "identity")?,
            certificate_sha1: text("signing", "certificateSHA1")?,
            signing_policy: text("signing", "policy")?,
            notarization_status: text("notarization", "status")?,
            receipt: text("notarization", "receipt")?,
            receipt_sha256: text("notarization", "receiptSHA256")?,
            stapled_ticket_validated: root
                .get("notarization")?
                .get("stapledTicketValidated")?
                .as_bool()?,
            gatekeeper_assessment: text("notarization", "gatekeeperAssessment")?,
            app_tree_sha256: text("integrity", "appTreeSHA256")?,
            resource_tree_sha256: text("integrity", "resourceTreeSHA256")?,
            app_code_directory_hash: text("integrity", "appCodeDirectoryHash")?,
            upgrade_identity: text("upgradePolicy", "identity")?,
            install_mode: text("upgradePolicy", "installMode")?,
            path_selection: text("upgradePolicy", "pathSelection")?,
            rollback: text("upgradePolicy", "rollback")?,
        })
    }

    /// `validateContract`: the one reviewed CLI contract.
    fn validate(&self) -> bool {
        self.format_version == 1
            && self.product_name == "arktrace"
            && self.product_version == "0.1.0"
            && self.product_build == "1"
            && self.product_architecture == "arm64"
            && self.bundle_identifier == "com.arktrace.ArkTrace.CLI"
            && self.json_major == 1
            && self.json_minor == 0
            && self.layout_bundle == "ArkTraceCLI.app"
            && self.layout_executable == "ArkTraceCLI.app/Contents/MacOS/arktrace"
            && self.layout_parser_executable == "ArkTraceCLI.app/Contents/Helpers/trace_streamer"
            && self.layout_parser_manifest
                == "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json"
            && self.layout_parser_signing_record
                == "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json"
            && self.signing_policy == "developer-id-runtime-timestamp"
            && swift_uppercase_sha1(&self.certificate_sha1)
            && self.notarization_status == "Accepted"
            && self.stapled_ticket_validated
            && self.gatekeeper_assessment == "accepted"
            && self.upgrade_identity == "distribution-manifest+tool-parser-hashes"
            && self.install_mode == "versioned-directory"
            && self.path_selection == "reviewed-absolute-descriptor-only"
            && self.rollback == "retain-prior-exact-directory"
            && swift_sha256(&self.source_tree_sha256)
            && swift_sha256(&self.tool_sha256)
            && swift_sha256(&self.parser_sha256)
            && swift_sha256(&self.parser_manifest_sha256)
            && swift_sha256(&self.signing_record_sha256)
            && swift_sha256(&self.receipt_sha256)
            && self.tool_byte_count > 0
            && self.parser_byte_count > 0
            && self.parser_manifest_byte_count > 0
            && self.signing_record_byte_count > 0
    }
}

// MARK: Paths

/// `URL(filePath:directoryHint: .isDirectory).path`: without a trailing
/// solidus.
fn directory_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn appending(root: &str, name: &str) -> String {
    if root == "/" {
        format!("/{name}")
    } else {
        format!("{root}/{name}")
    }
}

/// `physicalPath(root:relative:)`: a relative path of no `.` or `..`
/// component, strictly below the root, through no link.
fn physical_path(root: &str, relative: &str) -> Result<String, ArkTraceLoadError> {
    let components = split_components(relative);
    if first_character_is_solidus(relative)
        || components.iter().any(|part| part == ".." || part == ".")
    {
        return Err(ContractMismatch.into());
    }
    let candidate = directory_path(&appending(root, relative));
    if !candidate.starts_with(&format!("{root}/")) || !no_symlink_component(&candidate) {
        return Err(ContractMismatch.into());
    }
    Ok(candidate)
}

struct Layout {
    manifest: String,
    executable: String,
    parser: String,
    parser_manifest: String,
    signing_record: String,
    receipt: String,
    app: String,
    resources: String,
}

impl Layout {
    /// The manifest, the executables, the parser's records and the receipt
    /// below `root`, in Swift's order; the bundle paths follow (`bundle`).
    fn files(root: &str, manifest: &Manifest) -> Result<Self, ArkTraceLoadError> {
        Ok(Self {
            manifest: appending(root, "distribution-manifest.json"),
            executable: physical_path(root, &manifest.layout_executable)?,
            parser: physical_path(root, &manifest.layout_parser_executable)?,
            parser_manifest: physical_path(root, &manifest.layout_parser_manifest)?,
            signing_record: physical_path(root, &manifest.layout_parser_signing_record)?,
            receipt: physical_path(root, &manifest.receipt)?,
            app: String::new(),
            resources: String::new(),
        })
    }

    /// The App bundle and its resource bundle below `root`.
    fn bundle(mut self, root: &str, manifest: &Manifest) -> Result<Self, ArkTraceLoadError> {
        self.app = physical_path(root, &manifest.layout_bundle)?;
        self.resources = physical_path(root, &manifest.layout_resource_bundle)?;
        Ok(self)
    }

    fn trust_contract(&self, manifest: &Manifest) -> TrustContract {
        TrustContract {
            app_path: self.app.clone(),
            helper_path: self.parser.clone(),
            resource_path: self.resources.clone(),
            product_version: manifest.product_version.clone(),
            product_build: manifest.product_build.clone(),
            bundle_identifier: manifest.bundle_identifier.clone(),
            team_identifier: manifest.team_identifier.clone(),
            signing_identity: manifest.signing_identity.clone(),
            certificate_sha1: manifest.certificate_sha1.clone(),
            app_code_directory_hash: manifest.app_code_directory_hash.clone(),
            helper_code_directory_hash: manifest.parser_code_directory_hash.clone(),
            app_tree_sha256: manifest.app_tree_sha256.clone(),
            resource_tree_sha256: manifest.resource_tree_sha256.clone(),
        }
    }
}

// MARK: Snapshot generations

fn other(error: impl std::fmt::Debug) -> ArkTraceLoadError {
    ArkTraceLoadError::Other(format!("{error:?}"))
}

/// Swift `openRelativeDirectoryIfPresent`.
fn open_relative_directory(parent: &File, name: &str) -> Result<Option<File>, ArkTraceLoadError> {
    arkdeck_platform::open_relative_directory(parent, name).map_err(Into::into)
}

/// Swift `path(_:stillNames:)`: the path still opens, through its physical
/// components, as the retained directory.
fn still_names(path: &str, retained: &File) -> bool {
    let Some(current) = physical(path).and_then(|path| open_physical_directory(&path).ok()) else {
        return false;
    };
    let (Ok(retained), Ok(current)) = (retained.metadata(), current.metadata()) else {
        return false;
    };
    retained.dev() == current.dev()
        && retained.ino() == current.ino()
        && retained.uid() == current.uid()
        && retained.mode() == current.mode()
}

fn random_uuid() -> Result<String, ArkTraceLoadError> {
    let mut bytes = arkdeck_platform::random_bytes::<16>().map_err(other)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

impl ArkTraceProfileLoader<'_> {
    /// Swift `materializePrivateSnapshot`: the generation of the selected
    /// distribution below the snapshot root, made from a descriptor-bound
    /// copy and published under its tree digest, or the existing one when it
    /// already holds that digest; the snapshot root must still be the
    /// directory it was bound to.
    fn materialize(
        &self,
        source_root: &str,
        snapshot_root: &str,
    ) -> Result<String, ArkTraceLoadError> {
        if !first_character_is_solidus(snapshot_root) {
            return Err(ContractMismatch.into());
        }
        let components = authority_components(snapshot_root).map_err(other)?;
        let parent = open_or_create_owner_private_directory(&components).map_err(other)?;
        if let Some(hooks) = self.hooks {
            hooks.snapshot_root_bound()?;
        }
        let source = physical(source_root).ok_or_else(|| other(ProfileReadError::PhysicalPath))?;
        let selected = tree_snapshot(&source, source_root)?;
        let final_name = selected.sha256.clone();
        let final_root = appending(snapshot_root, &final_name);
        if let Some(existing) = open_relative_directory(&parent, &final_name)? {
            if !tree_matches_at(&existing, &final_root, &selected.sha256)
                || !still_names(snapshot_root, &parent)
            {
                return Err(ContractMismatch.into());
            }
            return Ok(final_root);
        }
        let partial_name = format!(".{}.{}.partial", selected.sha256, random_uuid()?);
        let partial_root = appending(snapshot_root, &partial_name);
        let discard = || {
            let _ = remove_tree_snapshot(&parent, &partial_name);
        };
        let copied: DistributionTree =
            match copy_tree_snapshot(&source, source_root, &parent, &partial_name, &partial_root) {
                Ok(copied) => copied,
                Err(error) => {
                    discard();
                    return Err(error.into());
                }
            };
        if copied.sha256 != selected.sha256 {
            discard();
            return Err(ContractMismatch.into());
        }
        if let Some(hooks) = self.hooks
            && let Err(error) = hooks.before_snapshot_publication(&final_name)
        {
            discard();
            return Err(error);
        }
        let renamed = match arkdeck_platform::rename_exclusive(&parent, &partial_name, &final_name)
        {
            Ok(renamed) => renamed,
            Err(_) => {
                discard();
                return Err(ContractMismatch.into());
            }
        };
        if !renamed {
            let Some(existing) = open_relative_directory(&parent, &final_name)? else {
                discard();
                return Err(ContractMismatch.into());
            };
            if !tree_matches_at(&existing, &final_root, &selected.sha256) {
                discard();
                return Err(ContractMismatch.into());
            }
            remove_tree_snapshot(&parent, &partial_name)?;
        }
        let Some(published) = open_relative_directory(&parent, &final_name)? else {
            return Err(ContractMismatch.into());
        };
        if !tree_matches_at(&published, &final_root, &selected.sha256)
            || !still_names(snapshot_root, &parent)
        {
            return Err(ContractMismatch.into());
        }
        Ok(final_root)
    }

    /// Swift `load(descriptorURL:)`: the `trace-summary@1` profile.
    pub fn load(&self, descriptor: &str) -> Result<AnalyzerProfile, ArkTraceLoadError> {
        if !first_character_is_solidus(descriptor) {
            return Err(DescriptorInvalid.into());
        }
        let missing = |path: &str| {
            std::fs::symlink_metadata(path)
                .is_err_and(|error| error.raw_os_error() == Some(libc::ENOENT))
        };
        if missing(descriptor) {
            return Err(NotFound.into());
        }
        if !owner_only(descriptor, false) {
            return Err(DescriptorInvalid.into());
        }
        let descriptor_data = match read(descriptor, 16 * 1024) {
            Ok(data) => data,
            Err(ProfileReadError::Open) => return Err(NotFound.into()),
            Err(ProfileReadError::PhysicalPath) if missing(descriptor) => {
                return Err(NotFound.into());
            }
            Err(_) => return Err(DescriptorInvalid.into()),
        };
        duplicate_free(&descriptor_data)?;
        let fields = object(&descriptor_data).ok_or(DescriptorInvalid)?;
        let valid_keys = fields.keys().map(String::as_str).collect::<BTreeSet<_>>()
            == key_set(&["formatVersion", "distributionRoot", "manifestSHA256"]);
        let root_path = fields.get("distributionRoot").and_then(Value::as_str);
        let manifest_sha256 = fields.get("manifestSHA256").and_then(Value::as_str);
        let (Some(root_path), Some(manifest_sha256)) = (root_path, manifest_sha256) else {
            return Err(DescriptorInvalid.into());
        };
        if !valid_keys
            || fields.get("formatVersion").and_then(bridged_integer) != Some(1)
            || !first_character_is_solidus(root_path)
            || !swift_sha256(manifest_sha256)
        {
            return Err(DescriptorInvalid.into());
        }

        let root = directory_path(root_path);
        if !is_directory(&root) {
            return Err(NotFound.into());
        }
        if !owner_only(&root, true) {
            return Err(DescriptorInvalid.into());
        }
        let manifest_path = appending(&root, "distribution-manifest.json");
        let manifest_data = read(&manifest_path, 64 * 1024).map_err(|_| ManifestDrift)?;
        if arkdeck_contract::sha256_hex(&manifest_data) != manifest_sha256 {
            return Err(ManifestDrift.into());
        }
        duplicate_free(&manifest_data)?;
        manifest_key_closure(&manifest_data)?;
        let manifest = Manifest::decode(&manifest_data).ok_or(ContractMismatch)?;
        if !manifest.validate() {
            return Err(ContractMismatch.into());
        }

        let source = Layout::files(&root, &manifest)?;
        let receipt = read(&source.receipt, 1024 * 1024).map_err(|_| ParserDrift)?;
        if !matches(
            &source.executable,
            &manifest.tool_sha256,
            Some(manifest.tool_byte_count as u64),
            MAXIMUM_PROFILE_FILE_BYTES,
            true,
        ) {
            return Err(ToolDrift.into());
        }
        if !matches(
            &source.parser,
            &manifest.parser_sha256,
            Some(manifest.parser_byte_count as u64),
            MAXIMUM_PROFILE_FILE_BYTES,
            true,
        ) || !matches(
            &source.parser_manifest,
            &manifest.parser_manifest_sha256,
            Some(manifest.parser_manifest_byte_count as u64),
            64 * 1024,
            false,
        ) || !matches(
            &source.signing_record,
            &manifest.signing_record_sha256,
            Some(manifest.signing_record_byte_count as u64),
            64 * 1024,
            false,
        ) || arkdeck_contract::sha256_hex(&receipt) != manifest.receipt_sha256
        {
            return Err(ParserDrift.into());
        }
        let source = source.bundle(&root, &manifest)?;
        let source_evidence = self.trust.validate(&source.trust_contract(&manifest))?;

        // A signed bundle keeps its canonical path for its own resources, so
        // production runs from a private generation no upgrade mutates.
        let runtime = match &self.snapshot_root {
            Some(snapshot_root) => {
                let snapshot_root = directory_path(snapshot_root);
                let generation = self.materialize(&root, &snapshot_root)?;
                Layout::files(&generation, &manifest)?.bundle(&generation, &manifest)?
            }
            None => source,
        };
        if !matches(
            &runtime.manifest,
            manifest_sha256,
            Some(manifest_data.len() as u64),
            64 * 1024,
            false,
        ) || !matches(
            &runtime.receipt,
            &manifest.receipt_sha256,
            Some(receipt.len() as u64),
            1024 * 1024,
            false,
        ) {
            return Err(ManifestDrift.into());
        }
        let evidence = match self.snapshot_root {
            Some(_) => self.trust.validate(&runtime.trust_contract(&manifest))?,
            None => source_evidence,
        };

        let mut pinned_files = vec![
            PinnedFile {
                path: runtime.manifest.clone(),
                sha256: manifest_sha256.to_owned(),
                byte_count: manifest_data.len() as u64,
                require_executable: false,
            },
            PinnedFile {
                path: runtime.parser.clone(),
                sha256: manifest.parser_sha256.clone(),
                byte_count: manifest.parser_byte_count as u64,
                require_executable: true,
            },
            PinnedFile {
                path: runtime.parser_manifest.clone(),
                sha256: manifest.parser_manifest_sha256.clone(),
                byte_count: manifest.parser_manifest_byte_count as u64,
                require_executable: false,
            },
            PinnedFile {
                path: runtime.signing_record.clone(),
                sha256: manifest.signing_record_sha256.clone(),
                byte_count: manifest.signing_record_byte_count as u64,
                require_executable: false,
            },
            PinnedFile {
                path: runtime.receipt.clone(),
                sha256: manifest.receipt_sha256.clone(),
                byte_count: receipt.len() as u64,
                require_executable: false,
            },
        ];
        for pin in evidence.pinned_files {
            match pinned_files
                .iter()
                .find(|existing| existing.path == pin.path)
            {
                Some(existing) => {
                    if existing.sha256 != pin.sha256 || existing.byte_count != pin.byte_count {
                        return Err(ContractMismatch.into());
                    }
                }
                None => pinned_files.push(pin),
            }
        }
        pinned_files.sort_by(|left, right| left.path.as_bytes().cmp(right.path.as_bytes()));

        let output_byte_budget = 8 * 1024 * 1024;
        let summary_timeout_seconds = 30;
        let executable = ResolvedExecutable {
            path: runtime.executable.clone(),
            sha256: manifest.tool_sha256.clone(),
            verified_resources: pinned_files
                .iter()
                .map(|pin| PinnedFile {
                    byte_count: pin.byte_count.max(1),
                    ..pin.clone()
                })
                .collect(),
            verified_trees: evidence.pinned_trees.clone(),
            canonical_namespace_root: Some(runtime.app.clone()),
        };
        if !self.doctor.probe(&DoctorContract {
            executable,
            product_version: manifest.product_version.clone(),
            timeout_seconds: 120,
            output_byte_budget: 256 * 1024,
        }) {
            return Err(SelfTestFailed.into());
        }

        // The doctor may take minutes: every path is bound again before the
        // profile can be admitted.
        if !owner_only(descriptor, false)
            || !owner_only(&root, true)
            || !matches(
                &runtime.executable,
                &manifest.tool_sha256,
                Some(manifest.tool_byte_count as u64),
                MAXIMUM_PROFILE_FILE_BYTES,
                true,
            )
            || !pinned_files.iter().all(|pin| {
                matches(
                    &pin.path,
                    &pin.sha256,
                    Some(pin.byte_count),
                    MAXIMUM_PROFILE_FILE_BYTES,
                    pin.require_executable,
                )
            })
            || !evidence.pinned_trees.iter().all(|tree| {
                physical(&tree.path)
                    .is_some_and(|path| tree_matches(&path, &tree.path, &tree.sha256))
            })
        {
            return Err(ManifestDrift.into());
        }

        Ok(AnalyzerProfile {
            analyzer_ref: SUMMARY_REF.into(),
            analyzer_version: format!("{}+{}", manifest.product_version, manifest.product_build),
            executable_path: PathBuf::from(&runtime.executable),
            executable_sha256: manifest.tool_sha256.clone(),
            fixed_arguments: [
                "summary",
                "--json",
                "--no-cache",
                "--timeout-ms",
                &(summary_timeout_seconds * 1_000).to_string(),
                "--max-rows",
                "1000",
                "--max-events",
                "10000",
                "--max-output-bytes",
                &output_byte_budget.to_string(),
            ]
            .map(str::to_owned)
            .to_vec(),
            timeout_seconds: summary_timeout_seconds,
            output_byte_budget,
            canonical_namespace_root: Some(runtime.app.clone()),
            pinned_files,
            pinned_trees: evidence.pinned_trees,
            arktrace_summary: Some(ArkTraceContract {
                tool_version: manifest.product_version.clone(),
                parser_version: manifest.parser_reported_version.clone(),
                parser_upstream_revision: manifest.parser_upstream_revision.clone(),
                parser_sha256: manifest.parser_sha256.clone(),
                parser_build_recipe_version: manifest.parser_build_recipe_version.clone(),
                // What the reviewed distribution's envelope generation is,
                // which the manifest does not carry (Swift's release coupling:
                // ArkTrace 95ab38d moved the index schema to 3).
                parser_adapter_version: "1".into(),
                schema_adapter_version: "2".into(),
                index_schema_version: 3,
            }),
            arktrace_analysis: None,
        })
    }

    /// Swift `loadProfiles(descriptorURL:)`: one loaded generation serves
    /// the summary and the analysis, which share every pin and differ in
    /// their lowering and budget.
    pub fn load_profiles(
        &self,
        descriptor: &str,
    ) -> Result<Vec<AnalyzerProfile>, ArkTraceLoadError> {
        let summary = self.load(descriptor)?;
        let contract = summary.arktrace_summary.clone().ok_or(ContractMismatch)?;
        let analysis = AnalyzerProfile {
            analyzer_ref: ANALYSIS_REF.into(),
            fixed_arguments: Vec::new(),
            timeout_seconds: 120,
            output_byte_budget: 64 * 1024 * 1024,
            arktrace_summary: None,
            arktrace_analysis: Some(contract),
            ..summary.clone()
        };
        Ok(vec![summary, analysis])
    }
}
