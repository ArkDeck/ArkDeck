//! The separately versioned Windows CLI distribution contract. No Apple signing
//! field or POSIX mode is interpreted as a Windows trust fact.
use crate::arktrace_envelope::{ArkTraceContract, integer_tokens};
use crate::arktrace_pins::ArkTraceProfileError;
use crate::arktrace_summary::ascii_sha256;
use arkdeck_contract::sha256_hex;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

pub(super) const MANIFEST: &str = "distribution-manifest.json";
pub(super) const EXECUTABLES: [&str; 3] = [
    "arktrace.exe",
    "resources/Helpers/arktrace-host-process.exe",
    "resources/Helpers/trace_streamer.exe",
];
const DIRECTORIES: [&str; 7] = [
    "resources",
    "resources/ArkTraceRust",
    "resources/Helpers",
    "resources/TraceStreamer",
    "resources/licenses",
    "resources/licenses/LICENSES",
    "resources/licenses/LICENSES-windows",
];
const PARSER: &[u8] = include_bytes!(
    "../../../../apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/windows-x86_64/manifest.json"
);
const INVENTORY: &[u8] = include_bytes!(
    "../../../../apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/license-inventory.json"
);
const WINDOWS_INVENTORY: &[u8] = include_bytes!(
    "../../../../apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/windows-license-inventory.json"
);
const RUST_INVENTORY: &[u8] = include_bytes!(
    "../../../../apple/Packages/ArkDeckKit/ThirdParty/ArkTraceRust/dependency-licenses.json"
);
const SELF_TEST: &str = "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe";

type Refusal = ArkTraceProfileError;
fn mismatch() -> Refusal {
    Refusal::ContractMismatch
}
fn require(holds: bool) -> Result<(), Refusal> {
    holds.then_some(()).ok_or_else(mismatch)
}

pub(super) fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, Refusal> {
    require(bytes.len() <= 65_536 && integer_tokens(bytes))?;
    crate::strict_json::validate(bytes).map_err(|_| mismatch())?;
    serde_json::from_slice(bytes).map_err(|_| mismatch())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Descriptor {
    format_version: u32,
    pub distribution_root: String,
    #[serde(rename = "manifestSHA256")]
    pub manifest_sha256: String,
}
impl Descriptor {
    pub fn read(bytes: &[u8]) -> Result<Self, Refusal> {
        let descriptor: Self = decode(bytes).map_err(|_| Refusal::DescriptorInvalid)?;
        require(descriptor.format_version == 1 && ascii_sha256(&descriptor.manifest_sha256))
            .map_err(|_| Refusal::DescriptorInvalid)?;
        Ok(descriptor)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct FilePin {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    revision: String,
    dirty: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Image {
    #[serde(rename = "binarySHA256")]
    binary_sha256: String,
    #[serde(rename = "unsignedBinarySHA256")]
    unsigned_binary_sha256: String,
    byte_count: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Parser {
    #[serde(rename = "binarySHA256")]
    binary_sha256: String,
    #[serde(rename = "unsignedBinarySHA256")]
    unsigned_binary_sha256: String,
    byte_count: u64,
    #[serde(rename = "manifestSHA256")]
    manifest_sha256: String,
    manifest_byte_count: u64,
    reported_version: String,
    upstream_revision: String,
    build_recipe_version: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Integrity {
    tree_digest: String,
    #[serde(rename = "treeSHA256")]
    tree_sha256: String,
    file_count: usize,
    executables: Vec<String>,
    files: Vec<FilePin>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Signing {
    policy: String,
    publisher: Option<String>,
    timestamped: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Manifest {
    schema: String,
    format_version: u32,
    source: Source,
    product: Value,
    layout: Value,
    tool: Image,
    helper: Image,
    trace_streamer: Parser,
    provenance: Value,
    signing: Signing,
    integrity: Integrity,
    attribution: Value,
    upgrade_policy: Value,
}

pub(super) fn safe_relative(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 512
        && path.split('/').all(|part| {
            let stem = part
                .split('.')
                .next()
                .unwrap_or_default()
                .to_ascii_uppercase();
            !part.is_empty()
                && !matches!(part, "." | "..")
                && !part.ends_with('.')
                && !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
                && !(stem.len() == 4
                    && (stem.starts_with("COM") || stem.starts_with("LPT"))
                    && matches!(stem.as_bytes()[3], b'1'..=b'9'))
                && part
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'+' | b'-'))
        })
}

pub(super) fn tree_digest(files: &[FilePin]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"arktrace-windows-x86_64-tree/1\0");
    for file in files {
        hash.update(b"F\0");
        hash.update(if EXECUTABLES.contains(&file.path.as_str()) {
            b"x"
        } else {
            b"r"
        });
        hash.update(b"\0");
        hash.update(file.path.as_bytes());
        hash.update(b"\0");
        hash.update(file.byte_count.to_string().as_bytes());
        hash.update(b"\0");
        hash.update(file.sha256.as_bytes());
        hash.update(b"\0");
    }
    format!("{:x}", hash.finalize())
}

fn rust_license_files() -> Result<Vec<FilePin>, Refusal> {
    let inventory: Value = decode(RUST_INVENTORY)?;
    let dependencies = inventory["dependencies"].as_array().ok_or_else(mismatch)?;
    require(dependencies.len() == 37)?;
    let mut files = Vec::new();
    for dependency in dependencies {
        for entry in dependency["licenseTexts"].as_array().ok_or_else(mismatch)? {
            let path = entry["path"].as_str().ok_or_else(mismatch)?;
            require(safe_relative(path) && path.starts_with("rust/licenses/"))?;
            files.push(FilePin {
                path: format!("resources/licenses/{path}"),
                sha256: entry["sha256"].as_str().ok_or_else(mismatch)?.into(),
                byte_count: entry["byteCount"].as_u64().ok_or_else(mismatch)?,
            });
        }
    }
    require(files.len() == 75)?;
    Ok(files)
}

pub(super) fn directories() -> Result<BTreeSet<String>, Refusal> {
    let mut directories = DIRECTORIES
        .into_iter()
        .map(str::to_owned)
        .collect::<BTreeSet<_>>();
    directories.insert("resources/licenses/rust".into());
    for file in rust_license_files()? {
        let mut path = file.path.as_str();
        while let Some((parent, _)) = path.rsplit_once('/') {
            directories.insert(parent.to_owned());
            path = parent;
        }
    }
    Ok(directories)
}

impl Manifest {
    pub fn read(bytes: &[u8]) -> Result<Self, Refusal> {
        let value: Self = decode(bytes)?;
        require(
            value.schema == "arktrace.cli-distribution.windows-x86_64/1"
                && value.format_version == 1,
        )?;
        require(
            value.source.revision.len() == 40
                && value
                    .source
                    .revision
                    .bytes()
                    .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f')),
        )?;
        // Dirty state is retained as provenance. An operator's exact descriptor
        // may select a development-signed qualification without calling it a release.
        let _dirty = value.source.dirty;
        require(
            value.product
                == json!({"name":"arktrace","version":"0.1.0","build":"1","architecture":"x86_64","jsonContract":{"major":1,"minor":0}}),
        )?;
        require(
            value.layout
                == json!({
                    "executable":EXECUTABLES[0],"helperExecutable":EXECUTABLES[1],"parserExecutable":EXECUTABLES[2],
                    "parserManifest":"resources/TraceStreamer/manifest.json","runtimeManifest":"resources/ArkTraceRust/runtime.json",
                    "selfTestFixture":"resources/zlib.htrace","licenseDirectory":"resources/licenses"
                }),
        )?;
        require(
            value.provenance
                == json!({"parserAdapterVersion":"1","schemaAdapterVersion":"2","indexSchemaVersion":4}),
        )?;
        require(
            value.upgrade_policy
                == json!({"identity":"distribution-manifest+tool-parser-hashes","installMode":"versioned-directory","pathSelection":"reviewed-absolute-descriptor-only","rollback":"retain-prior-exact-directory"}),
        )?;
        require(value.signing.policy == "authenticode-publisher")?;
        let publisher = value.signing.publisher.as_deref().ok_or_else(mismatch)?;
        require(
            !publisher.is_empty()
                && publisher.len() <= 256
                && publisher.trim() == publisher
                && !publisher
                    .chars()
                    .any(arkdeck_platform::host_control_character),
        )?;
        let files = &value.integrity.files;
        require(
            !files.is_empty()
                && files.len() <= 256
                && value.integrity.file_count == files.len()
                && value.integrity.tree_digest == "arktrace-windows-x86_64-tree/1"
                && value.integrity.executables == EXECUTABLES
                && ascii_sha256(&value.integrity.tree_sha256),
        )?;
        let mut names = BTreeSet::new();
        for file in files {
            require(
                safe_relative(&file.path)
                    && file.path != MANIFEST
                    && names.insert(file.path.to_ascii_lowercase())
                    && ascii_sha256(&file.sha256)
                    && (1..=512 * 1024 * 1024).contains(&file.byte_count),
            )?;
        }
        require(
            files
                .windows(2)
                .all(|pair| pair[0].path.as_bytes() < pair[1].path.as_bytes()),
        )?;
        require(tree_digest(files) == value.integrity.tree_sha256)?;
        for image in [&value.tool, &value.helper] {
            require(
                ascii_sha256(&image.binary_sha256)
                    && ascii_sha256(&image.unsigned_binary_sha256)
                    && (1..=512 * 1024 * 1024).contains(&image.byte_count),
            )?;
        }
        for (path, hash, count) in [
            (
                EXECUTABLES[0],
                value.tool.binary_sha256.as_str(),
                value.tool.byte_count,
            ),
            (
                EXECUTABLES[1],
                value.helper.binary_sha256.as_str(),
                value.helper.byte_count,
            ),
            (
                EXECUTABLES[2],
                value.trace_streamer.binary_sha256.as_str(),
                value.trace_streamer.byte_count,
            ),
            (
                "resources/TraceStreamer/manifest.json",
                value.trace_streamer.manifest_sha256.as_str(),
                value.trace_streamer.manifest_byte_count,
            ),
        ] {
            value.matches(path, hash, count)?;
        }
        let parser: Value = decode(PARSER)?;
        require(
            value.trace_streamer.unsigned_binary_sha256 == parser["binarySHA256"]
                && value.trace_streamer.reported_version == parser["reportedVersion"]
                && value.trace_streamer.upstream_revision == parser["upstreamRevision"]
                && value.trace_streamer.build_recipe_version == parser["buildRecipeVersion"],
        )?;
        value.validate_attribution()?;
        Ok(value)
    }

    fn matches(&self, path: &str, hash: &str, count: u64) -> Result<(), Refusal> {
        require(
            ascii_sha256(hash)
                && self
                    .integrity
                    .files
                    .iter()
                    .any(|f| f.path == path && f.sha256 == hash && f.byte_count == count),
        )
    }

    fn validate_attribution(&self) -> Result<(), Refusal> {
        let mut expected = serde_json::Map::new();
        for (key, path) in [
            ("license", "resources/licenses/LICENSE"),
            ("notice", "resources/licenses/THIRD_PARTY_NOTICES.md"),
            ("inventory", "resources/licenses/license-inventory.json"),
            (
                "windowsInventory",
                "resources/licenses/windows-license-inventory.json",
            ),
            (
                "rustInventory",
                "resources/licenses/rust/dependency-licenses.json",
            ),
        ] {
            let file = self
                .integrity
                .files
                .iter()
                .find(|f| f.path == path)
                .ok_or_else(mismatch)?;
            expected.insert(key.into(), json!(path));
            expected.insert(format!("{key}SHA256"), json!(file.sha256));
            expected.insert(format!("{key}ByteCount"), json!(file.byte_count));
        }
        let fixture = self
            .integrity
            .files
            .iter()
            .find(|f| f.path == "resources/zlib.htrace")
            .ok_or_else(mismatch)?;
        require(fixture.sha256 == SELF_TEST)?;
        expected.insert("licenseFileCount".into(), json!(18));
        expected.insert("windowsLicenseFileCount".into(), json!(6));
        expected.insert("rustDependencyCount".into(), json!(37));
        expected.insert("rustLicenseFileCount".into(), json!(75));
        expected.insert("selfTestFixtureSHA256".into(), json!(SELF_TEST));
        expected.insert("selfTestFixtureByteCount".into(), json!(fixture.byte_count));
        require(self.attribution == Value::Object(expected))?;
        self.matches(
            "resources/licenses/license-inventory.json",
            &sha256_hex(INVENTORY),
            INVENTORY.len() as u64,
        )?;
        self.matches(
            "resources/licenses/windows-license-inventory.json",
            &sha256_hex(WINDOWS_INVENTORY),
            WINDOWS_INVENTORY.len() as u64,
        )?;
        self.matches(
            "resources/licenses/rust/dependency-licenses.json",
            &sha256_hex(RUST_INVENTORY),
            RUST_INVENTORY.len() as u64,
        )?;
        let mut wanted: BTreeSet<String> = [
            EXECUTABLES[0],
            EXECUTABLES[1],
            EXECUTABLES[2],
            "resources/TraceStreamer/manifest.json",
            "resources/ArkTraceRust/runtime.json",
            "resources/zlib.htrace",
            "resources/licenses/LICENSE",
            "resources/licenses/THIRD_PARTY_NOTICES.md",
            "resources/licenses/license-inventory.json",
            "resources/licenses/windows-license-inventory.json",
            "resources/licenses/rust/dependency-licenses.json",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        for file in rust_license_files()? {
            self.matches(&file.path, &file.sha256, file.byte_count)?;
            wanted.insert(file.path);
        }
        for bytes in [INVENTORY, WINDOWS_INVENTORY] {
            let document: Value = decode(bytes)?;
            for section in ["components", "buildTools", "staticRuntime"] {
                for entry in document[section].as_array().into_iter().flatten() {
                    let path = format!(
                        "resources/licenses/{}",
                        entry["licenseFile"].as_str().ok_or_else(mismatch)?
                    );
                    self.matches(
                        &path,
                        entry["licenseSHA256"].as_str().ok_or_else(mismatch)?,
                        entry["licenseByteCount"].as_u64().ok_or_else(mismatch)?,
                    )?;
                    wanted.insert(path);
                    for additional in entry["additionalLicenseFiles"]
                        .as_array()
                        .into_iter()
                        .flatten()
                    {
                        let path = format!(
                            "resources/licenses/{}",
                            additional["path"].as_str().ok_or_else(mismatch)?
                        );
                        self.matches(
                            &path,
                            additional["sha256"].as_str().ok_or_else(mismatch)?,
                            additional["byteCount"].as_u64().ok_or_else(mismatch)?,
                        )?;
                        wanted.insert(path);
                    }
                }
            }
        }
        require(
            wanted
                == self
                    .integrity
                    .files
                    .iter()
                    .map(|f| f.path.clone())
                    .collect(),
        )
    }

    pub fn validate_contents(
        &self,
        read: impl Fn(&str) -> Result<Vec<u8>, Refusal>,
    ) -> Result<(), Refusal> {
        let installed_parser: Value = decode(&read("resources/TraceStreamer/manifest.json")?)?;
        let parser: Value = decode(PARSER)?;
        require(installed_parser == parser)?;
        let mut identity = serde_json::Map::new();
        for key in [
            "name",
            "reportedVersion",
            "binarySHA256",
            "upstreamRepository",
            "upstreamRevision",
            "architecture",
            "adapterVersion",
            "buildRecipeVersion",
        ] {
            identity.insert(key.into(), parser[key].clone());
        }
        identity.insert("name".into(), json!("trace_streamer"));
        identity.insert(
            "binarySHA256".into(),
            json!(self.trace_streamer.binary_sha256),
        );
        let runtime: Value = decode(&read("resources/ArkTraceRust/runtime.json")?)?;
        require(
            runtime
                == json!({
                    "formatVersion":1,"productVersion":"0.1.0","architecture":"x86_64","development":false,
                    "helperSHA256":self.helper.binary_sha256,"unsignedParserSHA256":self.trace_streamer.unsigned_binary_sha256,
                    "parser":identity,"maximumSourceBytes":1_073_741_824u64,"maximumDatabaseBytes":4_294_967_296u64,
                    "storageNamespace":"com.arktrace.ArkTrace.CLI"
                }),
        )
    }

    pub fn files(&self) -> &[FilePin] {
        &self.integrity.files
    }
    pub fn tree_sha256(&self) -> &str {
        &self.integrity.tree_sha256
    }
    pub fn publisher(&self) -> &str {
        self.signing.publisher.as_deref().unwrap_or_default()
    }
    pub fn timestamped(&self) -> bool {
        self.signing.timestamped
    }
    pub fn tool_sha256(&self) -> &str {
        &self.tool.binary_sha256
    }
    pub fn source_revision(&self) -> &str {
        &self.source.revision
    }
    pub fn contract(&self) -> ArkTraceContract {
        ArkTraceContract {
            tool_version: "0.1.0".into(),
            parser_version: self.trace_streamer.reported_version.clone(),
            parser_upstream_revision: self.trace_streamer.upstream_revision.clone(),
            parser_sha256: self.trace_streamer.binary_sha256.clone(),
            parser_build_recipe_version: self.trace_streamer.build_recipe_version.clone(),
            parser_adapter_version: "1".into(),
            schema_adapter_version: "2".into(),
            index_schema_version: 4,
        }
    }
    pub fn matches_files(&self, files: &[FilePin]) -> bool {
        files == self.integrity.files
    }
}
