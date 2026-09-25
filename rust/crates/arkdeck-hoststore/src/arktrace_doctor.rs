//! Swift `ProductionArkTraceDoctorProbe`: the reviewed ArkTrace CLI's own
//! self-test (`doctor --self-test --json`), run at its canonical path inside
//! its signed bundle with every pinned file and tree held, under a private
//! home, and accepted only as a silent, whole, closed envelope that names this
//! executable and passes all nine of its checks.
use crate::arktrace_profile::{DoctorContract, DoctorProbe};
use arkdeck_platform::{
    ToolLimits, ToolRequest, ToolTermination, VerifiedNamespace, VerifiedResource, VerifiedTool,
};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Swift `StrictJSONIntegerTokenValidator`: every number outside a string is
/// an integer that fits in 64 bits.
pub(crate) fn integer_tokens(bytes: &[u8]) -> bool {
    let delimiter = |byte: u8| matches!(byte, b',' | b']' | b'}' | b' ' | b'\t' | b'\r' | b'\n');
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                index += 1;
                loop {
                    match bytes.get(index) {
                        None => return false,
                        Some(b'"') => {
                            index += 1;
                            break;
                        }
                        Some(b'\\') => index += 2,
                        Some(_) => index += 1,
                    }
                }
            }
            b'-' | b'0'..=b'9' => {
                let start = index;
                while index < bytes.len() && !delimiter(bytes[index]) {
                    index += 1;
                }
                let valid = std::str::from_utf8(&bytes[start..index])
                    .ok()
                    .is_some_and(swift_int64);
                if !valid {
                    return false;
                }
            }
            _ => index += 1,
        }
    }
    true
}

/// `Int64(String)`: an optional sign and decimal digits, within range.
fn swift_int64(token: &str) -> bool {
    let digits = token
        .strip_prefix('-')
        .or_else(|| token.strip_prefix('+'))
        .unwrap_or(token);
    !digits.is_empty()
        && digits.bytes().all(|byte| byte.is_ascii_digit())
        && token.parse::<i64>().is_ok()
}

pub(crate) fn exact_keys(object: &Map<String, Value>, keys: &[&str]) -> bool {
    object.keys().map(String::as_str).collect::<BTreeSet<_>>()
        == keys.iter().copied().collect::<BTreeSet<_>>()
}

/// `NSNumber` whose type is a Boolean.
pub(crate) fn boolean(value: Option<&Value>) -> Option<bool> {
    value?.as_bool()
}

/// `NSNumber` whose type is not a Boolean, as a 64-bit integer.
pub(crate) fn integer(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_i64(),
        _ => None,
    }
}

fn safe_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.chars().any(arkdeck_platform::host_control_character)
}

/// Swift `ArkTraceDoctorEnvelopeValidator.validate`.
pub(crate) fn valid_envelope(bytes: &[u8], contract: &DoctorContract) -> bool {
    if crate::strict_json::validate(bytes).is_err() || !integer_tokens(bytes) {
        return false;
    }
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    let object = |key: &str| root.get(key).and_then(Value::as_object);
    let closed = exact_keys(
        &root,
        &[
            "schemaVersion",
            "tool",
            "request",
            "trace",
            "provenance",
            "limits",
            "dataQuality",
            "truncation",
            "result",
        ],
    ) && root.get("schemaVersion").and_then(Value::as_str) == Some("1.0")
        && root.get("trace") == Some(&Value::Null)
        && root.get("provenance") == Some(&Value::Null);
    if !closed {
        return false;
    }
    let (Some(tool), Some(request), Some(limits), Some(quality), Some(truncation), Some(result)) = (
        object("tool"),
        object("request"),
        object("limits"),
        object("dataQuality"),
        object("truncation"),
        object("result"),
    ) else {
        return false;
    };
    fn text<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
        fields.get(key).and_then(Value::as_str)
    }
    let empty = |value: Option<&Value>| value.and_then(Value::as_array).is_some_and(Vec::is_empty);
    let well_formed = exact_keys(tool, &["name", "version", "buildRevision"])
        && text(tool, "name") == Some("arktrace")
        && text(tool, "version") == Some(contract.product_version.as_str())
        && text(tool, "buildRevision") == Some(contract.executable.sha256.as_str())
        && exact_keys(request, &["command", "parameters"])
        && text(request, "command") == Some("doctor")
        && request
            .get("parameters")
            .and_then(Value::as_object)
            .is_some_and(|parameters| {
                exact_keys(parameters, &["selfTest"])
                    && boolean(parameters.get("selfTest")) == Some(true)
            })
        && exact_keys(
            limits,
            &["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"],
        )
        && integer(limits.get("timeoutMs")) == Some(contract.timeout_seconds * 1_000)
        && integer(limits.get("maxRows")) == Some(10_000)
        && integer(limits.get("maxEvents")) == Some(10_000)
        && integer(limits.get("maxOutputBytes")) == Some(contract.output_byte_budget as i64)
        && exact_keys(quality, &["status", "warnings"])
        && text(quality, "status") == Some("ok")
        && empty(quality.get("warnings"))
        && exact_keys(truncation, &["truncated", "sections"])
        && boolean(truncation.get("truncated")) == Some(false)
        && empty(truncation.get("sections"))
        && exact_keys(result, &["checks", "selfTest"])
        && boolean(result.get("selfTest")) == Some(true);
    if !well_formed {
        return false;
    }
    let Some(checks) = result.get("checks").and_then(Value::as_array) else {
        return false;
    };
    let Some(checks) = checks
        .iter()
        .map(Value::as_object)
        .collect::<Option<Vec<_>>>()
    else {
        return false;
    };
    const CODES: [&str; 9] = [
        "tool",
        "os",
        "architecture",
        "parserManifest",
        "parserIdentity",
        "sqlite",
        "cache",
        "schemaAdapter",
        "selfTest",
    ];
    checks.len() == CODES.len()
        && checks.iter().zip(CODES).all(|(check, code)| {
            exact_keys(check, &["code", "name", "status"])
                && text(check, "code") == Some(code)
                && text(check, "status") == Some("ok")
                && text(check, "name").is_some_and(safe_name)
        })
}

/// Swift `ProductionArkTraceDoctorProbe`, over a private home the probe owns.
pub struct ProductionDoctorProbe {
    home: PathBuf,
}

impl ProductionDoctorProbe {
    pub fn new(home: &Path) -> Self {
        Self {
            home: home.to_owned(),
        }
    }

    /// Swift `preparePrivateHome`: the home and its `Library`, `Caches` and
    /// `Application Support`, each an existing physical directory or created,
    /// and made `0700`.
    fn prepare_private_home(&self) -> io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        for directory in [
            self.home.clone(),
            self.home.join("Library"),
            self.home.join("Library/Caches"),
            self.home.join("Library/Application Support"),
        ] {
            let text = directory
                .to_str()
                .ok_or_else(|| io::Error::other("the private home is not text"))?;
            let physical = crate::hilog_summary::profile_path(text, false).ok();
            match std::fs::symlink_metadata(&directory) {
                Ok(metadata) => {
                    if !metadata.is_dir()
                        || !physical
                            .as_ref()
                            .is_some_and(arkdeck_platform::has_no_symlink_component)
                    {
                        return Err(io::Error::other("the private home is not a directory"));
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    std::fs::DirBuilder::new().mode(0o700).create(&directory)?;
                }
                Err(error) => return Err(error),
            }
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
            if !physical
                .as_ref()
                .is_some_and(arkdeck_platform::is_physical_directory)
            {
                return Err(io::Error::other(
                    "the private home is not a physical directory",
                ));
            }
        }
        Ok(())
    }

    fn run(&self, contract: &DoctorContract) -> io::Result<bool> {
        self.prepare_private_home()?;
        let executable = &contract.executable;
        let namespace = executable
            .canonical_namespace_root
            .as_deref()
            .map(VerifiedNamespace::open_owner_only)
            .transpose()?;
        let trees_hold = executable.verified_trees.iter().all(|tree| {
            crate::hilog_summary::profile_path(&tree.path, false)
                .is_ok_and(|path| arkdeck_platform::tree_matches(&path, &tree.path, &tree.sha256))
        });
        if !trees_hold {
            return Ok(false);
        }
        let resources = executable
            .verified_resources
            .iter()
            .map(|pin| {
                let resource = VerifiedResource::open(
                    &pin.path,
                    &pin.sha256,
                    pin.byte_count,
                    pin.require_executable,
                )?;
                if resource.byte_count() != pin.byte_count {
                    return Err(io::Error::other("a pinned file changed its length"));
                }
                Ok(resource)
            })
            .collect::<io::Result<Vec<_>>>()?;
        let tool = VerifiedTool::open(&executable.path, &executable.sha256)?;
        let home = self.home.as_os_str().to_owned();
        let arguments: Vec<OsString> = [
            "doctor".to_owned(),
            "--self-test".to_owned(),
            "--json".to_owned(),
            "--no-cache".to_owned(),
            "--timeout-ms".to_owned(),
            (contract.timeout_seconds * 1_000).to_string(),
            "--max-output-bytes".to_owned(),
            contract.output_byte_budget.to_string(),
        ]
        .into_iter()
        .map(OsString::from)
        .collect();
        let environment = [
            (OsString::from("CFFIXED_USER_HOME"), home.clone()),
            (OsString::from("HOME"), home),
        ];
        let bound = || -> io::Result<()> {
            if let Some(namespace) = &namespace {
                namespace.revalidate()?;
            }
            resources.iter().try_for_each(VerifiedResource::revalidate)
        };
        let execution = tool
            .run_tool_at_canonical_path(
                &ToolRequest {
                    arguments: &arguments,
                    environment: &environment,
                    working_directory: None,
                    limits: ToolLimits {
                        timeout: Duration::from_secs(contract.timeout_seconds as u64 + 5),
                        capture_bytes: contract.output_byte_budget as usize,
                    },
                },
                &bound,
                &|| false,
            )
            .map_err(|_| io::Error::other("the doctor did not run to its end"))?;
        Ok(execution.termination == ToolTermination::Exited(0)
            && !execution.truncated
            && execution.stderr.is_empty()
            && valid_envelope(&execution.stdout, contract))
    }
}

impl DoctorProbe for ProductionDoctorProbe {
    fn probe(&self, contract: &DoctorContract) -> bool {
        self.run(contract).unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_tokens_are_swift_int64_outside_strings() {
        assert!(integer_tokens(br#"{"a":1,"b":[-2, 3],"c":"1.5e3"}"#));
        assert!(integer_tokens(b"9223372036854775807"));
        for refused in [
            &b"1.0"[..],
            b"1e3",
            b"9223372036854775808",
            b"{\"a\":-}",
            b"\"unterminated",
            b"[1,2.5]",
        ] {
            assert!(
                !integer_tokens(refused),
                "{}",
                String::from_utf8_lossy(refused)
            );
        }
    }
}
