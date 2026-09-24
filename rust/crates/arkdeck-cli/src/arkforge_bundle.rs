//! One ArkForge release unit, read and independently verified as ArkForge's
//! Swift `ArkForgeReleaseBundleReader.load` (the pinned `ArkForgeClient`)
//! reads it: the manifest at `Contents/Resources/arkforge-bundle.json` names
//! every member with its byte count and SHA-256, one `arkforge` CLI, one
//! `arkforged` daemon and at least one profile, and nothing else may lie in
//! the bundle. Nothing here runs a member.
//!
//! Paths are physical: a root is resolved with `realpath`, where Foundation's
//! `resolvingSymlinksInPath` also drops a leading `/private` whose remainder
//! exists (see `runtime_service.rs`).
use crate::runtime_service::{lexical, resolved, sha256_file};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

const MANIFEST_PATH: &str = "Contents/Resources/arkforge-bundle.json";
const MANIFEST_SCHEMA: &str = "arkforge.release-bundle/v1";

/// Swift `ArkForgeReleaseBundleError`, whose descriptions name what to fix.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum BundleError {
    Filesystem(String),
    MalformedManifest(String),
    UnsupportedSchema(String),
    UnsafePath(String),
    SymbolicLink(String),
    NonRegularMember(String),
    UndeclaredMember(String),
    MissingMember(String),
    DuplicatePath(String),
    DuplicateRole(String),
    DuplicateProfileId(String),
    InvalidRole(String),
    InvalidDigest {
        path: String,
        value: String,
    },
    SizeMismatch {
        path: String,
        expected: u64,
        actual: u64,
    },
    DigestMismatch {
        path: String,
        expected: String,
        actual: String,
    },
}

impl std::fmt::Display for BundleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Filesystem(detail) => f.write_str(detail),
            Self::MalformedManifest(detail) => {
                write!(f, "malformed ArkForge bundle manifest: {detail}")
            }
            Self::UnsupportedSchema(schema) => {
                write!(f, "unsupported ArkForge bundle schema {schema}")
            }
            Self::UnsafePath(path) => write!(f, "unsafe ArkForge bundle member path: {path}"),
            Self::SymbolicLink(path) => {
                write!(f, "ArkForge bundle member is a symbolic link: {path}")
            }
            Self::NonRegularMember(path) => {
                write!(f, "ArkForge bundle member is not a regular file: {path}")
            }
            Self::UndeclaredMember(path) => {
                write!(f, "ArkForge bundle contains undeclared member: {path}")
            }
            Self::MissingMember(path) => {
                write!(f, "ArkForge bundle is missing declared member: {path}")
            }
            Self::DuplicatePath(path) => {
                write!(f, "ArkForge bundle declares duplicate path: {path}")
            }
            Self::DuplicateRole(role) => {
                write!(f, "ArkForge bundle declares duplicate role: {role}")
            }
            Self::DuplicateProfileId(id) => {
                write!(f, "ArkForge bundle declares duplicate profile id: {id}")
            }
            Self::InvalidRole(detail) => write!(f, "invalid ArkForge bundle role: {detail}"),
            Self::InvalidDigest { path, value } => {
                write!(
                    f,
                    "ArkForge bundle member {path} has invalid SHA-256 {value}"
                )
            }
            Self::SizeMismatch {
                path,
                expected,
                actual,
            } => write!(
                f,
                "ArkForge bundle member {path} is {actual} bytes, expected {expected}"
            ),
            Self::DigestMismatch {
                path,
                expected,
                actual,
            } => write!(
                f,
                "ArkForge bundle member {path} has SHA-256 {actual}, expected {expected}"
            ),
        }
    }
}

/// Swift `ArkForgeBundleManifest` as `JSONDecoder` reads it: unknown members
/// are ignored, `profileId` may be absent or null.
struct Manifest {
    schema: String,
    version: String,
    members: Vec<Member>,
}

struct Member {
    path: String,
    sha256: String,
    bytes: u64,
    role: String,
    profile_id: Option<String>,
}

fn manifest(bytes: &[u8]) -> Result<Manifest, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|error| error.to_string())?;
    let text = |fields: &serde_json::Map<String, Value>, key: &str| {
        fields
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("{key} is missing or not a string"))
    };
    let fields = value.as_object().ok_or("the manifest is not an object")?;
    let members = fields
        .get("members")
        .and_then(Value::as_array)
        .ok_or("members is missing or not an array")?
        .iter()
        .map(|member| {
            let member = member.as_object().ok_or("a member is not an object")?;
            Ok(Member {
                path: text(member, "path")?,
                sha256: text(member, "sha256")?,
                bytes: member
                    .get("bytes")
                    .and_then(Value::as_u64)
                    .ok_or("bytes is missing or not an unsigned integer")?,
                role: text(member, "role")?,
                profile_id: match member.get("profileId") {
                    None | Some(Value::Null) => None,
                    Some(Value::String(id)) => Some(id.clone()),
                    Some(_) => return Err("profileId is not a string".to_owned()),
                },
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(Manifest {
        schema: text(fields, "schema")?,
        version: text(fields, "version")?,
        members,
    })
}

/// Swift `ArkForgeReleaseBundle`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReleaseBundle {
    pub root: PathBuf,
    pub manifest_sha256: String,
    pub daemon: PathBuf,
    pub profiles: BTreeMap<String, PathBuf>,
}

fn inspect(path: &Path) -> Result<fs::Metadata, BundleError> {
    fs::symlink_metadata(path).map_err(|error| {
        BundleError::Filesystem(format!("cannot inspect {}: {error}", path.display()))
    })
}

/// Swift `regularFileFacts`: a regular file (never a link) and its measure.
fn regular_file_facts(path: &Path, relative: &str) -> Result<(u64, String), BundleError> {
    let metadata = inspect(path)?;
    if metadata.file_type().is_symlink() {
        return Err(BundleError::SymbolicLink(relative.to_owned()));
    }
    if !metadata.is_file() {
        return Err(if path.exists() {
            BundleError::NonRegularMember(relative.to_owned())
        } else {
            BundleError::MissingMember(relative.to_owned())
        });
    }
    let digest = sha256_file(path).map_err(|error| {
        BundleError::Filesystem(format!("cannot read {}: {error}", path.display()))
    })?;
    Ok((metadata.len(), digest))
}

/// Swift `validatedMemberURL`: a relative path of plain components that stays
/// under the bundle root once both are resolved.
fn member_path(root: &Path, relative: &str) -> Result<PathBuf, BundleError> {
    if relative.is_empty()
        || relative.starts_with('/')
        || relative.contains('\\')
        || relative
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(BundleError::UnsafePath(relative.to_owned()));
    }
    let candidate = lexical(&root.join(relative));
    let resolved_root = resolved(root);
    let resolved_candidate = resolved(&candidate);
    if !resolved_candidate.starts_with(&resolved_root) || resolved_candidate == resolved_root {
        return Err(BundleError::UnsafePath(relative.to_owned()));
    }
    Ok(candidate)
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// Swift `rejectUndeclaredMembers`: every file below the root is the manifest
/// or a declared member; no link and nothing that is not a directory or a
/// regular file.
fn reject_undeclared(
    root: &Path,
    directory: &Path,
    declared: &BTreeSet<String>,
) -> Result<(), BundleError> {
    let mut entries: Vec<PathBuf> = fs::read_dir(directory)
        .map_err(|error| {
            BundleError::Filesystem(format!("cannot enumerate ArkForge bundle: {error}"))
        })?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<_, _>>()
        .map_err(|error| {
            BundleError::Filesystem(format!("cannot enumerate ArkForge bundle: {error}"))
        })?;
    entries.sort();
    for path in entries {
        let relative = path
            .strip_prefix(root)
            .map(|relative| relative.to_string_lossy().into_owned())
            .unwrap_or_default();
        let metadata = inspect(&path)?;
        if metadata.file_type().is_symlink() {
            return Err(BundleError::SymbolicLink(relative));
        }
        if metadata.is_dir() {
            reject_undeclared(root, &path, declared)?;
            continue;
        }
        if !metadata.is_file() {
            return Err(BundleError::NonRegularMember(relative));
        }
        if relative != MANIFEST_PATH && !declared.contains(&relative) {
            return Err(BundleError::UndeclaredMember(relative));
        }
    }
    Ok(())
}

/// Swift `ArkForgeReleaseBundleReader.load`.
pub(crate) fn load(bundle: &Path) -> Result<ReleaseBundle, BundleError> {
    let requested = lexical(bundle);
    let metadata = inspect(&requested)?;
    if metadata.file_type().is_symlink() {
        return Err(BundleError::SymbolicLink(requested.display().to_string()));
    }
    if !metadata.is_dir() {
        return Err(BundleError::Filesystem(format!(
            "ArkForge bundle root is not a directory: {}",
            requested.display()
        )));
    }
    let root = resolved(&requested);
    let manifest_path = root.join(MANIFEST_PATH);
    let (_, manifest_sha256) = regular_file_facts(&manifest_path, MANIFEST_PATH)?;
    let bytes = fs::read(&manifest_path).map_err(|error| {
        BundleError::Filesystem(format!("cannot read ArkForge bundle manifest: {error}"))
    })?;
    let manifest = manifest(&bytes).map_err(BundleError::MalformedManifest)?;
    if manifest.schema != MANIFEST_SCHEMA {
        return Err(BundleError::UnsupportedSchema(manifest.schema));
    }
    if manifest.version.is_empty() {
        return Err(BundleError::MalformedManifest("version is empty".into()));
    }
    let mut declared = BTreeSet::new();
    let (mut cli, mut daemon) = (None, None);
    let mut profiles = BTreeMap::new();
    for member in &manifest.members {
        if !declared.insert(member.path.clone()) {
            return Err(BundleError::DuplicatePath(member.path.clone()));
        }
        if !lowercase_sha256(&member.sha256) {
            return Err(BundleError::InvalidDigest {
                path: member.path.clone(),
                value: member.sha256.clone(),
            });
        }
        let path = member_path(&root, &member.path)?;
        let (bytes, sha256) = regular_file_facts(&path, &member.path)?;
        if bytes != member.bytes {
            return Err(BundleError::SizeMismatch {
                path: member.path.clone(),
                expected: member.bytes,
                actual: bytes,
            });
        }
        if sha256 != member.sha256 {
            return Err(BundleError::DigestMismatch {
                path: member.path.clone(),
                expected: member.sha256.clone(),
                actual: sha256,
            });
        }
        match member.role.as_str() {
            "cli" => {
                if member.path != "Contents/MacOS/arkforge" || member.profile_id.is_some() {
                    return Err(BundleError::InvalidRole(member.path.clone()));
                }
                if cli.replace(path).is_some() {
                    return Err(BundleError::DuplicateRole("cli".into()));
                }
            }
            "daemon" => {
                if member.path != "Contents/MacOS/arkforged" || member.profile_id.is_some() {
                    return Err(BundleError::InvalidRole(member.path.clone()));
                }
                if daemon.replace(path).is_some() {
                    return Err(BundleError::DuplicateRole("daemon".into()));
                }
            }
            "profile" => {
                let Some(profile) = member.profile_id.clone().filter(|id| {
                    !id.is_empty() && member.path.starts_with("Contents/Resources/profiles/")
                }) else {
                    return Err(BundleError::InvalidRole(member.path.clone()));
                };
                if profiles.insert(profile.clone(), path).is_some() {
                    return Err(BundleError::DuplicateProfileId(profile));
                }
            }
            // Swift decodes the role as a closed enumeration: any other value
            // makes the manifest undecodable.
            other => {
                return Err(BundleError::MalformedManifest(format!(
                    "unknown member role {other}"
                )));
            }
        }
    }
    if cli.is_none() {
        return Err(BundleError::MissingMember("cli".into()));
    }
    let Some(daemon) = daemon else {
        return Err(BundleError::MissingMember("daemon".into()));
    };
    if profiles.is_empty() {
        return Err(BundleError::MissingMember("profile".into()));
    }
    reject_undeclared(&root, &root, &declared)?;
    Ok(ReleaseBundle {
        root,
        manifest_sha256,
        daemon,
        profiles,
    })
}
