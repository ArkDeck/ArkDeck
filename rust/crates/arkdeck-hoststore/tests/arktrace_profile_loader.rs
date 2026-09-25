//! Replays the Swift ArkTrace distribution profile loader oracle
//! (`rust/tests/fixtures/arktrace-profile-loader`, produced by
//! `ArkTraceProfileLoaderOracleContractTests`) against the Rust loader: the
//! same distributions and descriptors rebuilt at the same fixed root, the same
//! stub trust checkers, doctor and hooks, and every outcome, every trust and
//! doctor contract, and every entry left afterwards compared with Swift's.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    AnalyzerProfile, ArkTraceContract, ArkTraceLoadError, ArkTraceProfileError,
    ArkTraceProfileLoader, DistributionTrust, DoctorContract, DoctorProbe, LoaderHooks, PinnedFile,
    PinnedTree, TrustContract, TrustEvidence, profile_path,
};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::fs::{self, OpenOptions};
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::Path;

const ROOT: &str = "/private/tmp/arkdeck-arktrace-oracle";
const LOCK: &str = "/private/tmp/arkdeck-arktrace-oracle.lock";

fn tree(path: &str) -> Result<arkdeck_platform::DistributionTree, ArkTraceLoadError> {
    let physical = profile_path(path, false)
        .map_err(|error| ArkTraceLoadError::Other(format!("{error:?}")))?;
    arkdeck_platform::tree_snapshot(&physical, path).map_err(Into::into)
}

/// The oracle's trust checkers, by mode.
struct Trust {
    mode: String,
    case_root: String,
    contracts: RefCell<Vec<TrustContract>>,
}

impl DistributionTrust for Trust {
    fn validate(&self, contract: &TrustContract) -> Result<TrustEvidence, ArkTraceLoadError> {
        self.contracts.borrow_mut().push(contract.clone());
        match self.mode.as_str() {
            "digest" => Ok(TrustEvidence {
                pinned_files: Vec::new(),
                pinned_trees: vec![PinnedTree {
                    path: contract.app_path.clone(),
                    sha256: tree(&contract.app_path)?.sha256,
                }],
            }),
            "tree" => {
                let tree = tree(&contract.app_path)?;
                Ok(TrustEvidence {
                    pinned_files: tree
                        .pinned_files
                        .into_iter()
                        .map(|pin| PinnedFile {
                            path: pin.path,
                            sha256: pin.sha256,
                            byte_count: pin.byte_count,
                            require_executable: pin.require_executable,
                        })
                        .collect(),
                    pinned_trees: vec![PinnedTree {
                        path: contract.app_path.clone(),
                        sha256: tree.sha256,
                    }],
                })
            }
            "replaceRoot" => {
                let distribution = format!("{}/distribution", self.case_root);
                let held = format!("{}/held-distribution", self.case_root);
                fs::rename(&distribution, &held)
                    .and_then(|()| symlink(&held, &distribution))
                    .map_err(|error| ArkTraceLoadError::Other(error.to_string()))?;
                Ok(TrustEvidence::default())
            }
            _ => Err(ArkTraceProfileError::ContractMismatch.into()),
        }
    }
}

struct Doctor {
    result: bool,
    contracts: RefCell<Vec<DoctorContract>>,
}

impl DoctorProbe for Doctor {
    fn probe(&self, contract: &DoctorContract) -> bool {
        self.contracts.borrow_mut().push(contract.clone());
        self.result
    }
}

struct Hooks {
    hook: Option<String>,
    case_root: String,
}

impl LoaderHooks for Hooks {
    fn snapshot_root_bound(&self) -> Result<(), ArkTraceLoadError> {
        if self.hook.as_deref() == Some("replaceBoundSnapshotRoot") {
            let root = &self.case_root;
            fs::rename(
                format!("{root}/bound-snapshot-root"),
                format!("{root}/held-bound-snapshot-root"),
            )
            .and_then(|()| {
                fs::rename(
                    format!("{root}/foreign-replacement-root"),
                    format!("{root}/bound-snapshot-root"),
                )
            })
            .map_err(|error| ArkTraceLoadError::Other(error.to_string()))?;
        }
        Ok(())
    }

    fn before_snapshot_publication(&self, final_name: &str) -> Result<(), ArkTraceLoadError> {
        if self.hook.as_deref() == Some("collideFinalGeneration") {
            let collision = format!("{}/collision-snapshot-root/{final_name}", self.case_root);
            let sentinel = format!("{collision}/sentinel.txt");
            fs::create_dir(&collision)
                .and_then(|()| fs::set_permissions(&collision, fs::Permissions::from_mode(0o755)))
                .and_then(|()| fs::write(&sentinel, b"pre-existing invalid generation"))
                .and_then(|()| fs::set_permissions(&sentinel, fs::Permissions::from_mode(0o644)))
                .map_err(|error| ArkTraceLoadError::Other(error.to_string()))?;
        }
        Ok(())
    }
}

fn contract(value: &Option<ArkTraceContract>) -> Value {
    match value {
        None => Value::Null,
        Some(contract) => json!({
            "toolVersion": contract.tool_version,
            "parserVersion": contract.parser_version,
            "parserUpstreamRevision": contract.parser_upstream_revision,
            "parserSHA256": contract.parser_sha256,
            "parserBuildRecipeVersion": contract.parser_build_recipe_version,
            "parserAdapterVersion": contract.parser_adapter_version,
            "schemaAdapterVersion": contract.schema_adapter_version,
            "indexSchemaVersion": contract.index_schema_version,
        }),
    }
}

fn files(pins: &[PinnedFile]) -> Value {
    Value::Array(
        pins.iter()
            .map(|pin| {
                json!({"path": pin.path, "sha256": pin.sha256, "byteCount": pin.byte_count,
                    "requireExecutable": pin.require_executable})
            })
            .collect(),
    )
}

fn trees(pins: &[PinnedTree]) -> Value {
    Value::Array(
        pins.iter()
            .map(|pin| json!({"path": pin.path, "sha256": pin.sha256}))
            .collect(),
    )
}

fn profile(profile: &AnalyzerProfile) -> Value {
    json!({
        "analyzerRef": profile.analyzer_ref,
        "analyzerVersion": profile.analyzer_version,
        "executablePath": profile.executable_path.to_str().unwrap(),
        "executableSHA256": profile.executable_sha256,
        "canonicalNamespaceRoot": profile.canonical_namespace_root,
        "fixedArguments": profile.fixed_arguments,
        "timeoutSeconds": profile.timeout_seconds,
        "outputByteBudget": profile.output_byte_budget,
        "pinnedFiles": files(&profile.pinned_files),
        "pinnedTrees": trees(&profile.pinned_trees),
        "preflightAvailable": true,
        "arkTraceSummaryContract": contract(&profile.arktrace_summary),
        "arkTraceAnalysisContract": contract(&profile.arktrace_analysis),
    })
}

fn trust_contract(contract: &TrustContract) -> Value {
    json!({
        "appPath": contract.app_path,
        "helperPath": contract.helper_path,
        "resourcePath": contract.resource_path,
        "productVersion": contract.product_version,
        "productBuild": contract.product_build,
        "bundleIdentifier": contract.bundle_identifier,
        "teamIdentifier": contract.team_identifier,
        "signingIdentity": contract.signing_identity,
        "certificateSHA1": contract.certificate_sha1,
        "appCodeDirectoryHash": contract.app_code_directory_hash,
        "helperCodeDirectoryHash": contract.helper_code_directory_hash,
        "appTreeSHA256": contract.app_tree_sha256,
        "resourceTreeSHA256": contract.resource_tree_sha256,
    })
}

fn doctor_contract(contract: &DoctorContract) -> Value {
    json!({
        "executable": {
            "path": contract.executable.path,
            "sha256": contract.executable.sha256,
            "verifiedResources": files(&contract.executable.verified_resources),
            "verifiedTrees": trees(&contract.executable.verified_trees),
            "canonicalNamespaceRoot": contract.executable.canonical_namespace_root,
        },
        "productVersion": contract.product_version,
        "timeoutSeconds": contract.timeout_seconds,
        "outputByteBudget": contract.output_byte_budget,
    })
}

/// The inputs as the oracle recorded them, in path order.
fn rebuild(fixture: &Path) {
    let inputs = support::document(fixture, "inputs.json");
    let blobs = support::document(fixture, "blobs.json");
    let _ = fs::remove_dir_all(ROOT);
    fs::create_dir(ROOT).unwrap();
    fs::set_permissions(ROOT, fs::Permissions::from_mode(0o700)).unwrap();
    for entry in inputs.as_array().unwrap() {
        let path = format!("{ROOT}/{}", entry["path"].as_str().unwrap());
        let mode = entry["mode"]
            .as_str()
            .map(|mode| u32::from_str_radix(mode, 8).unwrap());
        let mode = || fs::Permissions::from_mode(mode.unwrap());
        match entry["kind"].as_str().unwrap() {
            "directory" => {
                fs::create_dir(&path).unwrap();
                fs::set_permissions(&path, mode()).unwrap();
            }
            "file" => {
                let text = blobs[entry["sha256"].as_str().unwrap()].as_str().unwrap();
                fs::write(&path, text).unwrap();
                fs::set_permissions(&path, mode()).unwrap();
            }
            "link" => symlink(entry["target"].as_str().unwrap(), &path).unwrap(),
            other => panic!("{other}"),
        }
    }
}

/// Every entry below the root, as Swift's `subpathsOfDirectory` lists it
/// (links not followed), in path order.
fn after() -> Value {
    fn walk(directory: &Path, prefix: &str, paths: &mut Vec<String>) {
        for entry in fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name().into_string().unwrap();
            let relative = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            if entry.file_type().unwrap().is_dir() {
                walk(&entry.path(), &relative, paths);
            }
            paths.push(relative);
        }
    }
    let mut paths = Vec::new();
    walk(Path::new(ROOT), "", &mut paths);
    paths.sort();
    Value::Array(
        paths
            .into_iter()
            .map(|path| {
                let full = format!("{ROOT}/{path}");
                let metadata = fs::symlink_metadata(&full).unwrap();
                let mut entry =
                    json!({"path": path, "mode": format!("{:o}", metadata.mode() & 0o7777)});
                if metadata.is_dir() {
                    entry["kind"] = json!("directory");
                } else if metadata.file_type().is_symlink() {
                    // A link's own mode is its creator's mask; Swift does not record it.
                    entry.as_object_mut().unwrap().remove("mode");
                    entry["kind"] = json!("link");
                    entry["target"] = json!(fs::read_link(&full).unwrap().to_str().unwrap());
                } else {
                    let bytes = fs::read(&full).unwrap();
                    entry["kind"] = json!("file");
                    entry["sha256"] = json!(arkdeck_contract::sha256_hex(&bytes));
                    entry["byteCount"] = json!(bytes.len());
                }
                entry
            })
            .collect(),
    )
}

#[test]
fn rust_loads_the_swift_arktrace_distributions() {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    let fixture = support::fixture("arktrace-profile-loader");
    rebuild(&fixture);

    let mut differences = Vec::new();
    for recorded in support::document(&fixture, "cases.json")
        .as_array()
        .unwrap()
    {
        let name = recorded["name"].as_str().unwrap();
        let case_root = format!("{ROOT}/{name}");
        let trust = Trust {
            mode: recorded["trust"].as_str().unwrap().to_owned(),
            case_root: case_root.clone(),
            contracts: RefCell::new(Vec::new()),
        };
        let doctor = Doctor {
            result: recorded["doctor"].as_bool().unwrap(),
            contracts: RefCell::new(Vec::new()),
        };
        let hooks = Hooks {
            hook: recorded["hook"].as_str().map(str::to_owned),
            case_root: case_root.clone(),
        };
        let loader = ArkTraceProfileLoader {
            doctor: &doctor,
            trust: &trust,
            snapshot_root: recorded["snapshotRoot"]
                .as_str()
                .map(|root| format!("{case_root}/{root}")),
            hooks: Some(&hooks),
        };
        let descriptor = recorded["descriptor"].as_str().unwrap();
        let outcomes: Vec<Value> = (0..recorded["outcomes"].as_array().unwrap().len())
            .map(|_| match loader.load_profiles(descriptor) {
                Ok(profiles) => {
                    json!({"profiles": profiles.iter().map(profile).collect::<Vec<_>>()})
                }
                Err(error) => json!({
                    "error": error.reason(),
                    "thrown": match error {
                        ArkTraceLoadError::Profile(_) => "profile",
                        ArkTraceLoadError::Other(_) => "other",
                    },
                }),
            })
            .collect();
        let actual = json!({
            "name": name,
            "trust": recorded["trust"],
            "doctor": recorded["doctor"],
            "snapshotRoot": recorded["snapshotRoot"],
            "hook": recorded["hook"],
            "descriptor": descriptor,
            "outcomes": outcomes,
            "trustContracts": trust.contracts.borrow().iter().map(trust_contract).collect::<Vec<_>>(),
            "doctorContracts": doctor.contracts.borrow().iter().map(doctor_contract).collect::<Vec<_>>(),
        });
        if actual != *recorded {
            differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(
        after(),
        support::document(&fixture, "after.json"),
        "what the loads left"
    );
    fs::remove_dir_all(ROOT).unwrap();
}
