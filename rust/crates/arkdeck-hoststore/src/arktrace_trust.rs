//! Swift `ProductionArkTraceDistributionTrustChecker`: manifest strings are
//! not evidence. The exact App and its nested helper must satisfy a Developer
//! ID and notarization requirement for the reviewed team and show the
//! reviewed leaf certificate and code directory hashes; both reviewed tree
//! projections must reproduce; the App's `Info.plist` must name the reviewed
//! bundle, version and build; and its stapled `CodeResources` must be there.
use crate::arktrace_profile::{
    ArkTraceLoadError, ArkTraceProfileError, DistributionTrust, PinnedFile, PinnedTree,
    TrustContract, TrustEvidence,
};
use crate::session_graphemes::graphemes;
use arkdeck_platform::{PropertyListValue, StaticCodeExpectation};
use std::path::Path;

fn mismatch() -> ArkTraceLoadError {
    ArkTraceProfileError::ContractMismatch.into()
}

/// Swift `isTeamIdentifier`: ten ASCII Characters, each a number or
/// uppercase.
fn team_identifier(value: &str) -> bool {
    graphemes(value).count() == 10
        && graphemes(value).all(|character| {
            character.len() == 1
                && character
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || byte.is_ascii_uppercase())
        })
}

/// `Character.isHexDigit`: one scalar with the Hex_Digit property; and its
/// case.
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

/// Swift `isSHA1`: 40 hexadecimal Characters, none lowercase.
fn certificate_sha1(value: &str) -> bool {
    graphemes(value).count() == 40
        && graphemes(value).all(|character| hex_case(character).is_some_and(|(_, lower)| !lower))
}

/// Swift `isCodeDirectoryHash`: 40 hexadecimal Characters, none uppercase.
fn code_directory_hash(value: &str) -> bool {
    graphemes(value).count() == 40
        && graphemes(value).all(|character| hex_case(character).is_some_and(|(upper, _)| !upper))
}

/// `String(describing: plist["CFBundleVersion"] ?? "")` for the scalar
/// values a bundle version can hold.
fn described(value: Option<&PropertyListValue>) -> String {
    match value {
        None => String::new(),
        Some(PropertyListValue::String(text)) => text.clone(),
        Some(PropertyListValue::Integer(number)) => number.to_string(),
        Some(PropertyListValue::Boolean(flag)) => u8::from(*flag).to_string(),
        Some(PropertyListValue::Real(number)) if number.fract() == 0.0 && number.abs() < 1e15 => {
            format!("{}", *number as i64)
        }
        Some(PropertyListValue::Real(number)) => number.to_string(),
        Some(_) => "<collection>".to_owned(),
    }
}

fn other(error: impl std::fmt::Debug) -> ArkTraceLoadError {
    ArkTraceLoadError::Other(format!("{error:?}"))
}

fn read(path: &str, maximum: u64) -> Result<Vec<u8>, ArkTraceLoadError> {
    let physical = crate::hilog_summary::profile_path(path, false).map_err(other)?;
    arkdeck_platform::read_profile_file(&physical, maximum)
        .map(|snapshot| snapshot.bytes)
        .map_err(other)
}

fn tree(path: &str) -> Result<arkdeck_platform::DistributionTree, ArkTraceLoadError> {
    let physical = crate::hilog_summary::profile_path(path, false).map_err(other)?;
    arkdeck_platform::tree_snapshot(&physical, path).map_err(Into::into)
}

/// Swift `ProductionArkTraceDistributionTrustChecker`.
pub struct ProductionDistributionTrust;

impl DistributionTrust for ProductionDistributionTrust {
    fn validate(&self, contract: &TrustContract) -> Result<TrustEvidence, ArkTraceLoadError> {
        if !team_identifier(&contract.team_identifier)
            || !certificate_sha1(&contract.certificate_sha1)
            || !code_directory_hash(&contract.app_code_directory_hash)
            || !code_directory_hash(&contract.helper_code_directory_hash)
        {
            return Err(mismatch());
        }
        let requirement = format!(
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
             and certificate leaf[subject.OU] = \"{}\" and notarized",
            contract.team_identifier
        );
        let signed = |path: &str, directory: bool, hash: &str, identifier: Option<&str>| {
            arkdeck_platform::static_code_holds(
                Path::new(path),
                directory,
                &StaticCodeExpectation {
                    requirement: &requirement,
                    identity: &contract.signing_identity,
                    team_identifier: &contract.team_identifier,
                    certificate_sha1: &contract.certificate_sha1,
                    code_directory_hash: hash,
                    check_nested_code: directory,
                    identifier,
                },
            )
        };
        if !signed(
            &contract.app_path,
            true,
            &contract.app_code_directory_hash,
            Some(&contract.bundle_identifier),
        ) || !signed(
            &contract.helper_path,
            false,
            &contract.helper_code_directory_hash,
            None,
        ) {
            return Err(mismatch());
        }
        let app_tree = tree(&contract.app_path)?;
        let resource_tree = tree(&contract.resource_path)?;
        if app_tree.sha256 != contract.app_tree_sha256
            || resource_tree.sha256 != contract.resource_tree_sha256
        {
            return Err(mismatch());
        }
        let info = read(
            &format!("{}/Contents/Info.plist", contract.app_path),
            64 * 1024,
        )?;
        let plist = arkdeck_platform::read_property_list(&info).map_err(other)?;
        let Some(plist) = plist.as_dictionary() else {
            return Err(mismatch());
        };
        let text = |key: &str| plist.get(key).and_then(PropertyListValue::as_str);
        if text("CFBundleIdentifier") != Some(contract.bundle_identifier.as_str())
            || text("CFBundleShortVersionString") != Some(contract.product_version.as_str())
            || described(plist.get("CFBundleVersion")) != contract.product_build
        {
            return Err(mismatch());
        }
        // A stapled App carries its bounded physical ticket here; the
        // `notarized` requirement above judged its trust.
        let ticket = read(
            &format!("{}/Contents/CodeResources", contract.app_path),
            1024 * 1024,
        )?;
        if ticket.is_empty() {
            return Err(mismatch());
        }
        Ok(TrustEvidence {
            pinned_files: app_tree
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
                sha256: app_tree.sha256,
            }],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_reviewed_formats_are_read_as_swift_reads_them() {
        assert!(team_identifier("8AQTYW5FKR"));
        assert!(!team_identifier("8aqtyw5fkr"));
        assert!(!team_identifier("8AQTYW5FK"));
        assert!(certificate_sha1(&"A".repeat(40)));
        assert!(!certificate_sha1(&"a".repeat(40)));
        assert!(certificate_sha1(&"\u{FF10}".repeat(40)));
        assert!(code_directory_hash(&"a".repeat(40)));
        assert!(!code_directory_hash(&"A".repeat(40)));
        assert_eq!(described(None), "");
        assert_eq!(described(Some(&PropertyListValue::Integer(1))), "1");
        assert_eq!(described(Some(&PropertyListValue::Real(1.0))), "1");
        assert_eq!(described(Some(&PropertyListValue::Boolean(true))), "1");
        assert_eq!(described(Some(&PropertyListValue::String("1".into()))), "1");
    }

    #[test]
    fn unsigned_bytes_are_refused_whatever_the_manifest_says() {
        let contract = TrustContract {
            app_path: "/usr/bin".into(),
            helper_path: "/usr/bin/true".into(),
            resource_path: "/usr/bin".into(),
            product_version: "0.1.0".into(),
            product_build: "1".into(),
            bundle_identifier: "com.arktrace.ArkTrace.CLI".into(),
            team_identifier: "TEAM123456".into(),
            signing_identity: "Developer ID Application: Test".into(),
            certificate_sha1: "A".repeat(40),
            app_code_directory_hash: "a".repeat(40),
            helper_code_directory_hash: "5".repeat(40),
            app_tree_sha256: "8".repeat(64),
            resource_tree_sha256: "9".repeat(64),
        };
        assert_eq!(
            ProductionDistributionTrust.validate(&contract),
            Err(ArkTraceProfileError::ContractMismatch.into())
        );
        let malformed = TrustContract {
            team_identifier: "team".into(),
            ..contract
        };
        assert_eq!(
            ProductionDistributionTrust.validate(&malformed),
            Err(ArkTraceProfileError::ContractMismatch.into())
        );
    }
}
