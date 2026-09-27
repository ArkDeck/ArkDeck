//! Public files only. These fixtures never access the real Keychain.
use arkdeck_provider_workspace::{foundation_resolved_path, measure};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::Path,
};

pub fn install(root: &Path) -> Value {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)
        .unwrap();
    let identity = |name: &str, executable: bool| {
        let path = root.join(name);
        fs::write(&path, b"public test material").unwrap();
        fs::set_permissions(
            &path,
            fs::Permissions::from_mode(if executable { 0o700 } else { 0o600 }),
        )
        .unwrap();
        let path = foundation_resolved_path(path.to_str().unwrap()).unwrap();
        serde_json::to_value(measure(&path, name, executable, true).unwrap()).unwrap()
    };
    let receipt = json!({"schemaVersion":"arkdeck-openharmony-signing/v1",
        "installedAtUTC":"2026-09-26T00:00:00Z", "presetID":"openharmony-release@1",
        "projectRef":"demo-app", "javaExecutable":identity("java", true),
        "signerJAR":identity("signer.jar",false), "keystore":identity("source.p12",false),
        "appCertificate":identity("source.pem",false), "signedProfile":identity("source.p7b",false),
        "keyAlias":"release", "signingAlgorithm":"SHA256withECDSA",
        "keystorePasswordAccount":"openharmony-release@1|keystore",
        "keyPasswordAccount":"openharmony-release@1|key",
        "secretEnvelopeAccount":"openharmony-release@1|secret-envelope-5d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f",
        "keychainAccessSchema":"data-protection-access-group-v1",
        "trustedDaemonApplicationSHA256":"a".repeat(64)});
    let path = root.join("preset-v1.json");
    fs::write(&path, serde_json::to_vec(&receipt).unwrap()).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    receipt
}
