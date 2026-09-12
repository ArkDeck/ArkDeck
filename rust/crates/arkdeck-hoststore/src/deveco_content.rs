//! Revalidate the exact current DevEco root and five sealed child roles. No
//! SDK enumeration, registration, selection, process execution or activation.
use crate::deveco_registry::{Child, Record, RootIdentity, Trust, identifier, version};
use arkdeck_contract::{canonical_json, sha256_hex, strict_json};
use arkdeck_platform::{
    DevEcoRole, DevEcoRoot, inspect_deveco_publisher_signature, inspect_native_code_signature,
    verify_deveco_resource_envelope,
};
use serde::Deserialize;
use serde_json::json;
use std::{io, path::Path};
fn unreadable() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "registered DevEco root, manifests or child tools changed",
    )
}
fn denied() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "DevEco manifests, platform, version or native trust are unsupported",
    )
}
fn read_child(root: &DevEcoRoot, role: DevEcoRole) -> io::Result<Child> {
    let read = root.read_role(role)?;
    let facts = read.facts;
    let trust = if matches!(role, DevEcoRole::Node) {
        Some(Trust::native(inspect_native_code_signature(
            &root.path().join(role.path()),
        )?))
    } else {
        None
    };
    Ok(Child {
        role: role.name().into(),
        relative_path: role.path().into(),
        device: facts.device,
        inode: facts.inode,
        byte_count: facts.byte_count as i64,
        modified_seconds: facts.modified_seconds,
        modified_nanos: facts.modified_nanos,
        changed_seconds: facts.changed_seconds,
        changed_nanos: facts.changed_nanos,
        sha256: sha256_hex(&read.bytes),
        executable: facts.mode & 0o111 != 0,
        trust,
    })
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProductInfo {
    name: String,
    version: String,
    build_number: String,
    product_code: String,
    product_vendor: String,
    launch: Vec<Launch>,
}
#[derive(Deserialize)]
struct Launch {
    os: String,
    arch: String,
}
#[derive(Deserialize)]
struct SdkPackage {
    data: SdkData,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SdkData {
    api_version: String,
    platform_version: String,
    version: String,
}
pub(crate) fn inspect_root(path: &Path) -> io::Result<Record> {
    let root = DevEcoRoot::open(path)?;
    let facts = &root.identity;
    let root_identity = RootIdentity {
        path: root.path().to_str().ok_or_else(unreadable)?.into(),
        device: facts.device,
        inode: facts.inode,
        modified_seconds: facts.modified_seconds,
        modified_nanos: facts.modified_nanos,
        changed_seconds: facts.changed_seconds,
        changed_nanos: facts.changed_nanos,
    };
    let mut children = Vec::new();
    for role in [
        DevEcoRole::ProductManifest,
        DevEcoRole::SdkManifest,
        DevEcoRole::Node,
        DevEcoRole::Hvigor,
        DevEcoRole::SignedResourceEnvelope,
    ] {
        children.push(read_child(&root, role)?);
    }
    root.verify_sdk_directory()?;
    let product_bytes = root.read_role(DevEcoRole::ProductManifest)?.bytes;
    let sdk_bytes = root.read_role(DevEcoRole::SdkManifest)?.bytes;
    if sha256_hex(&product_bytes) != children[0].sha256
        || sha256_hex(&sdk_bytes) != children[1].sha256
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            arkdeck_platform::DevEcoIdentityChanged,
        ));
    }
    let product: ProductInfo =
        serde_json::from_value(strict_json(&product_bytes).map_err(|_| unreadable())?)
            .map_err(|_| unreadable())?;
    let sdk: SdkPackage =
        serde_json::from_value(strict_json(&sdk_bytes).map_err(|_| unreadable())?)
            .map_err(|_| unreadable())?;
    if product.name != "DevEco Studio"
        || product.product_code != "DS"
        || product.product_vendor != "Huawei"
        || !version(&product.version)
        || !identifier(&product.build_number)
        || !product
            .launch
            .iter()
            .any(|v| v.os == "macOS" && ["aarch64", "x86_64"].contains(&v.arch.as_str()))
        || !version(&sdk.data.version)
        || !version(&sdk.data.platform_version)
        || !identifier(&sdk.data.api_version)
        || children[2]
            .trust
            .as_ref()
            .is_none_or(|t| t.signature != "verified")
    {
        return Err(denied());
    }
    let bundle_trust = Trust::native(inspect_deveco_publisher_signature(
        root.path().parent().ok_or_else(unreadable)?,
    )?);
    let envelope = root.read_role(DevEcoRole::SignedResourceEnvelope)?.bytes;
    verify_deveco_resource_envelope(
        &envelope,
        [
            &children[0].sha256,
            &children[1].sha256,
            &children[2].sha256,
            &children[3].sha256,
        ],
    )?;
    root.require_linked()?;
    let digest=sha256_hex(&canonical_json(&json!({"schemaVersion":"arkdeck.deveco-toolchain-content/2","kind":"deveco","productVersion":product.version,"buildNumber":product.build_number,"sdkVersion":sdk.data.version,"apiVersion":sdk.data.api_version,"bundleTrust":bundle_trust.value(),"children":children.iter().map(Child::value).collect::<Vec<_>>()})).map_err(|_|unreadable())?);
    Ok(Record {
        reference: format!("toolchain:sha256:{digest}"),
        content_digest: digest,
        root: root_identity,
        product_version: product.version,
        build_number: product.build_number,
        sdk_version: sdk.data.version,
        api_version: sdk.data.api_version,
        registered_at: "1970-01-01T00:00:00Z".into(),
        bundle_trust,
        children,
        generation: 1,
        state: "available".into(),
        references: Vec::new(),
    })
}
pub(crate) fn verify(record: &Record) -> io::Result<()> {
    let measured = inspect_root(Path::new(&record.root.path))?;
    if !matches_record(record, &measured) {
        return Err(unreadable());
    }
    Ok(())
}

pub(crate) fn matches_record(record: &Record, measured: &Record) -> bool {
    measured.reference == record.reference
        && measured.content_digest == record.content_digest
        && measured.root == record.root
        && measured.product_version == record.product_version
        && measured.build_number == record.build_number
        && measured.sdk_version == record.sdk_version
        && measured.api_version == record.api_version
        && measured.bundle_trust == record.bundle_trust
        && measured.children == record.children
}
