//! Load-time validation of the preset records and the retained dependency
//! mutation in the workspace project document, as Swift's `load` checks them
//! before any request reads the document.
use super::*;
use arkdeck_contract::canonical_json;
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, WireError> {
    v[key].as_str().ok_or_else(|| unreadable(()))
}
fn generation(v: &Value) -> bool {
    v.as_u64().is_some_and(|n| n > 0 && n <= i64::MAX as u64)
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn tool(v: &Value) -> bool {
    v.as_str()
        .and_then(|s| s.strip_prefix("toolchain:sha256:"))
        .is_some_and(digest)
}
fn credential(v: &Value) -> bool {
    v.as_str()
        .and_then(|s| s.strip_prefix("credential:"))
        .is_some_and(|s| identifier(s, 128))
}
fn optional(v: &Value, check: fn(&Value) -> bool) -> bool {
    v.is_null() || check(v)
}
fn reference(v: &Value) -> bool {
    v.as_str()
        .is_some_and(|s| s.starts_with("preset-") && identifier(s, 128))
}
pub(super) fn definition(record: &Value, registration: bool) -> Result<String, WireError> {
    let get = |name: &str| -> Value {
        let key = if registration {
            format!("registration{}{}", name[..1].to_uppercase(), &name[1..])
        } else {
            name.into()
        };
        record[&key].clone()
    };
    let kind = get("kind");
    let template = get("templateRef");
    let tool_ref = get("toolchainRef");
    let tool_generation = get("toolchainGeneration");
    let credential_ref = get("credentialRef");
    let timeout = get("timeoutSeconds");
    let constraints = get("constraints");
    let expected = match kind.as_str() {
        Some("build") => "openharmony.hvigor-build@1",
        Some("test") => "openharmony.hvigor-test@1",
        Some("signing") => "openharmony.local-sign@1",
        Some("symbol") => "openharmony.arkts-symbol@1",
        _ => return Err(unreadable(())),
    };
    if template != expected
        || !timeout.as_i64().is_some_and(|n| (1..=3600).contains(&n))
        || tool_ref.is_null() != tool_generation.is_null()
        || !optional(&tool_ref, tool)
        || (!tool_generation.is_null() && !generation(&tool_generation))
        || !optional(&credential_ref, credential)
    {
        return Err(unreadable(()));
    }
    let c = constraints.as_object().ok_or_else(|| unreadable(()))?;
    if c.keys()
        .any(|k| !["module", "product", "buildMode", "relativeSourceMap"].contains(&k.as_str()))
    {
        return Err(unreadable(()));
    }
    let id = |key: &str, max| {
        constraints[key]
            .as_str()
            .is_some_and(|s| identifier(s, max))
    };
    let no = |key: &str| constraints[key].is_null();
    let good = match kind.as_str().unwrap() {
        "build" | "test" => {
            !tool_ref.is_null()
                && credential_ref.is_null()
                && id("module", 128)
                && id("product", 128)
                && id("buildMode", 64)
                && no("relativeSourceMap")
        }
        "signing" => {
            !tool_ref.is_null()
                && !credential_ref.is_null()
                && ["module", "product", "buildMode", "relativeSourceMap"]
                    .iter()
                    .all(|k| no(k))
        }
        "symbol" => {
            tool_ref.is_null()
                && credential_ref.is_null()
                && ["module", "product", "buildMode"].iter().all(|k| no(k))
                && constraints["relativeSourceMap"].as_str().is_some_and(|s| {
                    !s.is_empty()
                        && s.len() <= 1024
                        && !s.contains('\0')
                        && !s.starts_with('/')
                        && s.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
                })
        }
        _ => false,
    };
    if !good {
        return Err(unreadable(()));
    }
    let constraints: Map<String, Value> = c
        .iter()
        .filter(|(_, v)| !v.is_null())
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let document = json!({"schemaVersion":"arkdeck.workspace-preset-definition/1","projectRef":get("projectRef"),"kind":kind,"templateRef":template,"toolchainRef":tool_ref,"toolchainGeneration":tool_generation.as_u64().map(|n|n.to_string()),"credentialRef":credential_ref,"timeoutSeconds":timeout,"constraints":constraints});
    Ok(sha256_hex(&canonical_json(&document).map_err(unreadable)?))
}
fn record(p: &Value, projects: &HashSet<&String>) -> Result<(), WireError> {
    let fields = p.as_object().ok_or_else(|| unreadable(()))?;
    let keys = [
        "presetRef",
        "generation",
        "projectRef",
        "kind",
        "templateRef",
        "toolchainRef",
        "toolchainGeneration",
        "credentialRef",
        "timeoutSeconds",
        "constraints",
        "registrationRequestID",
        "registrationProjectRef",
        "registrationKind",
        "registrationTemplateRef",
        "registrationToolchainRef",
        "registrationToolchainGeneration",
        "registrationCredentialRef",
        "registrationTimeoutSeconds",
        "registrationConstraints",
        "registrationDigest",
        "currentDefinitionDigest",
        "registeredAtUTC",
        "updatedAtUTC",
        "state",
        "lastMutationRequestID",
        "lastMutationDigest",
    ];
    if fields.keys().any(|k| !keys.contains(&k.as_str()))
        || !reference(&p["presetRef"])
        || !generation(&p["generation"])
    {
        return Err(unreadable(()));
    }
    let project = text(p, "projectRef")?;
    let request = text(p, "registrationRequestID")?;
    let mutation = text(p, "lastMutationRequestID")?;
    if !identifier(project, 128) || !identifier(request, 128) || !identifier(mutation, 128) {
        return Err(unreadable(()));
    }
    let generation = p["generation"].as_u64().unwrap();
    let state = text(p, "state")?;
    if state != "available" && !(state == "removed" && generation >= 2) {
        return Err(failure(
            "recordUnreadable",
            "workspace preset state and generation are inconsistent",
        ));
    }
    let registered = definition(p, true)?;
    let current = definition(p, false)?;
    let expected = if state == "removed" {
        sha256_hex(
            format!(
                "remove\0{mutation}\0{project}\0{}\0{}",
                text(p, "presetRef")?,
                generation - 1
            )
            .as_bytes(),
        )
    } else if generation == 1 {
        registered.clone()
    } else {
        sha256_hex(
            format!(
                "update\0{project}\0{}\0{}\0{current}",
                text(p, "presetRef")?,
                generation - 1
            )
            .as_bytes(),
        )
    };
    // Swift's guard, with its message. A removed preset's record may outlive
    // its project: removing a project is refused only while an available
    // preset names it, so the tombstones of its removed presets stay behind,
    // and refusing them made every later read of the store fail with nothing
    // a caller could do. A tombstone grants nothing — every reader that
    // admits a Job, composes a profile or pins a dependency takes only
    // available presets, and one still answers only its own removal's
    // replay. Any other preset must name a registered project.
    if !(state == "removed" || projects.iter().any(|v| v.as_str() == project))
        || p["registrationProjectRef"] != project
        || p["registrationDigest"] != registered
        || p["currentDefinitionDigest"] != current
        || p["lastMutationDigest"] != expected
        || (generation == 1 && mutation != request)
        || !timestamp(text(p, "registeredAtUTC")?)
            .zip(timestamp(text(p, "updatedAtUTC")?))
            .is_some_and(|(a, b)| b >= a)
    {
        return Err(failure(
            "recordUnreadable",
            "workspace preset store record is inconsistent",
        ));
    }
    Ok(())
}
pub(super) fn validate(document: &Value, projects: &HashSet<&String>) -> Result<(), WireError> {
    let empty = Vec::new();
    let presets = if document["presets"].is_null() {
        &empty
    } else {
        document["presets"]
            .as_array()
            .ok_or_else(|| unreadable(()))?
    };
    if presets.len() > 256
        || (document["schemaVersion"] == "arkdeck.workspace-project-store/1"
            && (!presets.is_empty() || !document["pendingToolchainMutation"].is_null()))
    {
        return Err(unreadable(()));
    }
    let mut refs = HashSet::new();
    let mut requests = HashSet::new();
    for p in presets {
        record(p, projects)?;
        if !refs.insert(text(p, "presetRef")?)
            || !requests.insert(text(p, "registrationRequestID")?)
        {
            return Err(unreadable(()));
        }
    }
    let pending = &document["pendingToolchainMutation"];
    if pending.is_null() {
        return Ok(());
    }
    let fields = pending.as_object().ok_or_else(|| unreadable(()))?;
    if fields.keys().any(|k| {
        ![
            "action",
            "toolchainRef",
            "toolchainGeneration",
            "credentialRef",
            "presetRef",
            "proposedRecord",
            "releaseAfterAcquireRef",
            "releaseAfterAcquireCredentialRef",
        ]
        .contains(&k.as_str())
    }) || !matches!(pending["action"].as_str(), Some("acquire" | "release"))
        || !reference(&pending["presetRef"])
        || pending["toolchainRef"].is_null() != pending["toolchainGeneration"].is_null()
        || !optional(&pending["toolchainRef"], tool)
        || (!pending["toolchainGeneration"].is_null()
            && !generation(&pending["toolchainGeneration"]))
        || !optional(&pending["credentialRef"], credential)
        || (pending["toolchainRef"].is_null() && pending["credentialRef"].is_null())
        || !optional(&pending["releaseAfterAcquireRef"], tool)
        || !optional(&pending["releaseAfterAcquireCredentialRef"], credential)
    {
        return Err(failure(
            "recordUnreadable",
            "workspace preset transaction is inconsistent",
        ));
    }
    // The transaction itself, and the proposed record it would publish, are
    // checked where Swift checks them: when it is reconciled.
    Ok(())
}
