//! Closed OpenHarmony SDK release profile and certificate-chain generation.
use crate::SigningError;
use serde_json::{Value, json};

pub struct GeneratedProfile {
    pub bytes: Vec<u8>,
    pub app_certificate: String,
    pub not_before: i64,
    pub not_after: i64,
}

pub(crate) fn valid_bundle_name(value: &str) -> bool {
    value.len() <= 255
        && value.split('.').count() >= 2
        && value.split('.').all(|part| {
            !part.is_empty()
                && part.as_bytes()[0].is_ascii_alphabetic()
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        })
}

pub fn generate_profile(
    bytes: &[u8],
    bundle_name: &str,
    now: i64,
    uuid: &str,
) -> Result<GeneratedProfile, SigningError> {
    if !valid_bundle_name(bundle_name) {
        return Err(SigningError::InvalidConfiguration(
            "bundleName is malformed".into(),
        ));
    }
    let invalid = || {
        SigningError::InvalidConfiguration(
            "SDK release profile template is outside the closed OpenHarmony shape".into(),
        )
    };
    let mut object: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    let object = object.as_object_mut().ok_or_else(invalid)?;
    if object.get("type").and_then(Value::as_str) != Some("release")
        || object.get("app-distribution-type").and_then(Value::as_str) != Some("os_integration")
        || object.get("issuer").and_then(Value::as_str) != Some("pki_internal")
        || object.contains_key("debug-info")
    {
        return Err(invalid());
    }
    let bundle = object
        .get_mut("bundle-info")
        .and_then(Value::as_object_mut)
        .ok_or_else(invalid)?;
    if bundle.get("apl").and_then(Value::as_str) != Some("normal")
        || bundle.get("app-feature").and_then(Value::as_str) != Some("hos_normal_app")
    {
        return Err(invalid());
    }
    let certificate = bundle
        .get("distribution-certificate")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?
        .to_owned();
    if !certificate.starts_with("-----BEGIN CERTIFICATE-----\n")
        || !(certificate.ends_with("-----END CERTIFICATE-----\n")
            || certificate.ends_with("-----END CERTIFICATE-----"))
    {
        return Err(invalid());
    }
    let not_before = now.checked_sub(300).ok_or_else(invalid)?;
    let not_after = now.checked_add(365 * 24 * 60 * 60).ok_or_else(invalid)?;
    bundle.insert("bundle-name".into(), json!(bundle_name));
    object.insert("uuid".into(), json!(uuid));
    object.insert(
        "validity".into(),
        json!({"not-before":not_before,"not-after":not_after}),
    );
    let bytes = serde_json::to_vec_pretty(&Value::Object(object.clone())).map_err(|_| invalid())?;
    Ok(GeneratedProfile {
        bytes,
        app_certificate: certificate,
        not_before,
        not_after,
    })
}

pub fn application_chain(profile_chain: &str, application: &str) -> Result<Vec<u8>, SigningError> {
    fn blocks(mut text: &str) -> Result<Vec<String>, SigningError> {
        let mut result = Vec::new();
        let begin = "-----BEGIN CERTIFICATE-----";
        let end = "-----END CERTIFICATE-----";
        let invalid = || {
            SigningError::InvalidConfiguration(
                "SDK release certificate has invalid PEM framing".into(),
            )
        };
        while let Some(start) = text.find(begin) {
            if !text[..start].trim().is_empty() {
                return Err(invalid());
            }
            let tail = &text[start + begin.len()..];
            let finish = tail.find(end).ok_or_else(invalid)? + start + begin.len() + end.len();
            result.push(format!("{}\n", &text[start..finish]));
            text = &text[finish..];
        }
        if result.is_empty() || !text.trim().is_empty() {
            return Err(invalid());
        }
        Ok(result)
    }
    let chain = blocks(profile_chain)?;
    let leaf = blocks(application)?;
    if chain.len() != 3 || leaf.len() != 1 {
        return Err(SigningError::InvalidConfiguration(
            "SDK release certificates are outside the closed three-certificate chain shape".into(),
        ));
    }
    Ok([chain[0].as_str(), chain[1].as_str(), leaf[0].as_str()]
        .concat()
        .into_bytes())
}

pub(crate) fn verified_readback(
    document: &Value,
    bundle: &str,
    not_before: i64,
    not_after: i64,
) -> bool {
    let content = &document["content"];
    document["verifiedPassed"] == Value::Bool(true)
        && content["type"] == "release"
        && content
            .as_object()
            .is_some_and(|object| !object.contains_key("debug-info"))
        && content["bundle-info"]["bundle-name"] == bundle
        && content["validity"]["not-before"].as_i64() == Some(not_before)
        && content["validity"]["not-after"].as_i64() == Some(not_after)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pem(value: &str) -> String {
        format!("-----BEGIN CERTIFICATE-----\n{value}\n-----END CERTIFICATE-----\n")
    }
    fn template() -> Value {
        json!({"type":"release","app-distribution-type":"os_integration","issuer":"pki_internal","bundle-info":{"apl":"normal","app-feature":"hos_normal_app","distribution-certificate":pem("application")}})
    }
    #[test]
    fn release_profile_binds_bundle_and_validity_without_debug_allowlists() {
        let generated = generate_profile(
            &serde_json::to_vec(&template()).unwrap(),
            "com.example.app",
            1_000_000,
            "fixture-uuid",
        )
        .unwrap();
        let value: Value = serde_json::from_slice(&generated.bytes).unwrap();
        assert_eq!(value["bundle-info"]["bundle-name"], "com.example.app");
        assert_eq!(value["validity"]["not-before"], 999_700);
        assert_eq!(value["validity"]["not-after"], 32_536_000);
        assert!(value.get("debug-info").is_none());
        assert_eq!(generated.app_certificate, pem("application"));
    }
    #[test]
    fn template_and_bundle_shape_are_closed() {
        for bundle in [
            "",
            "one",
            "1app.example",
            "com.1app",
            "com.example-app",
            "com..app",
        ] {
            assert!(
                generate_profile(
                    &serde_json::to_vec(&template()).unwrap(),
                    bundle,
                    0,
                    "fixture-uuid"
                )
                .is_err()
            );
        }
        let mut bad = template();
        bad["debug-info"] = Value::Null;
        assert!(
            generate_profile(
                &serde_json::to_vec(&bad).unwrap(),
                "com.example.app",
                0,
                "fixture-uuid"
            )
            .is_err()
        );
        let mut bad = template();
        bad["type"] = json!("debug");
        assert!(
            generate_profile(
                &serde_json::to_vec(&bad).unwrap(),
                "com.example.app",
                0,
                "fixture-uuid"
            )
            .is_err()
        );
        assert!(
            generate_profile(
                &serde_json::to_vec(&template()).unwrap(),
                "com.example.app",
                i64::MAX,
                "fixture-uuid"
            )
            .is_err()
        );
    }
    #[test]
    fn verification_must_bind_the_exact_bundle_and_validity() {
        let good = json!({"verifiedPassed":true,"content":{"type":"release","bundle-info":{"bundle-name":"com.example.app"},"validity":{"not-before":100,"not-after":200}}});
        assert!(verified_readback(&good, "com.example.app", 100, 200));
        for (pointer, value) in [
            ("/verifiedPassed", json!(false)),
            ("/content/type", json!("debug")),
            ("/content/bundle-info/bundle-name", json!("com.other.app")),
            ("/content/validity/not-before", json!(99)),
            ("/content/validity/not-after", json!(201)),
        ] {
            let mut changed = good.clone();
            *changed.pointer_mut(pointer).unwrap() = value;
            assert!(!verified_readback(&changed, "com.example.app", 100, 200));
        }
        let mut changed = good;
        changed["content"]["debug-info"] = Value::Null;
        assert!(!verified_readback(&changed, "com.example.app", 100, 200));
    }

    #[test]
    fn application_chain_keeps_root_and_ca_and_replaces_only_profile_leaf() {
        let source = format!("{}{}{}", pem("root"), pem("ca"), pem("profile"));
        let leaf = pem("application");
        assert_eq!(
            application_chain(&source, &leaf).unwrap(),
            format!("{}{}{}", pem("root"), pem("ca"), leaf).as_bytes()
        );
        assert!(application_chain(&format!("text{source}"), &leaf).is_err());
        assert!(application_chain(&pem("root"), &leaf).is_err());
        assert!(application_chain(&source, &format!("{leaf}{leaf}")).is_err());
    }
}
