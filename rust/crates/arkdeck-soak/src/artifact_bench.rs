//! Host-only InputArtifact benchmark publication through the actual Import owner.
//! Synthetic binding stays inside this fixture; no TargetStore or device facts.
use crate::{Result, canonical_root, error};
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use arkdeck_platform::{ContinuousInstant, HostDirectory};
use serde_json::{Value, json};
use std::{fs, io::Write, path::Path};

fn binding(intent: &ImportIntent) -> std::result::Result<ImportBinding, WireError> {
    Ok(ImportBinding {
        target_id: intent.target_id.clone(),
        binding_revision: Some(intent.binding_revision),
        // Fixed synthetic identity, never read from or written to TargetStore.
        stable_identity_sha256: Some(sha256_hex(b"arkdeck-host-only-artifact-benchmark")),
    })
}

pub fn seed(root: &Path, count: u64, digest: &str) -> Result<Value> {
    if ![1_048_576, 134_217_728, 1_073_741_824].contains(&count)
        || digest.len() != 64
        || !digest
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err("artifact benchmark requires 1/128/1024 MiB and SHA256".into());
    }
    let root = canonical_root(root)?;
    let names: Vec<_> = fs::read_dir(&root)
        .map_err(error)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<std::io::Result<_>>()
        .map_err(error)?;
    if names.len() != 1 || names[0] != "fixture.tar.gz" {
        return Err(
            "artifact benchmark requires only its generated fixture in a private root".into(),
        );
    }
    let directory = HostDirectory::open(&root).map_err(error)?;
    let input = directory
        .open_document("fixture.tar.gz", count as usize)
        .map_err(error)?;
    // Check declared size and retained descriptor identity without a whole-file allocation.
    input.check(count).map_err(error)?;
    directory.private_child("artifacts").map_err(error)?;
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).map_err(error)?;
    let uploads = ImportUploadStore::open(&root.join("artifacts")).map_err(error)?;
    let now = crate::now()?;
    let started = ContinuousInstant::now().map_err(error)?;
    let intent = json!({"schemaVersion":"arkdeck.import-intent/1", "importRequestId":"artifact-benchmark",
        "kind":"flash-bundle", "targetId":"host-fixture", "bindingRevision":"1",
        "deviceProfile":"dayu200", "name":"images.tar.gz", "byteCount":count.to_string(), "sha256":digest});
    let begun = uploads
        .handle_resource(
            "artifact.import.begin",
            intent.as_object().unwrap(),
            &now,
            false,
            binding,
        )
        .map_err(error)?;
    let id = begun["importId"]
        .as_str()
        .ok_or("missing Import identity")?;
    let mut offset = 0_u64;
    while offset < count {
        if started.elapsed().map_err(error)?.as_secs() >= 600 {
            return Err("artifact seed deadline".into());
        }
        let end = (offset + 2 * 1024 * 1024).min(count);
        let bytes = input.read_range(offset..end).map_err(error)?;
        let request = json!({"importId":id,"generation":"1", "offset":offset.to_string(),
            "byteCount":bytes.len().to_string(), "sha256":sha256_hex(&bytes), "base64":encode_import_chunk(&bytes).map_err(error)?});
        uploads
            .handle_resource(
                "artifact.import.append",
                request.as_object().unwrap(),
                &now,
                false,
                binding,
            )
            .map_err(error)?;
        let mut output = std::io::stdout().lock();
        writeln!(
            output,
            "{}",
            json!({"kind":"artifactUpload", "offset":offset,"nextOffset":end})
        )
        .map_err(error)?;
        output.flush().map_err(error)?;
        offset = end;
    }
    input.check(count).map_err(error)?;
    let request = json!({"importId":id,"generation":"1"});
    let committed = uploads
        .commit(
            request.as_object().unwrap(),
            &now,
            false,
            &artifacts,
            count,
            binding,
        )
        .map_err(error)?;
    if committed["state"] != "committed" {
        return Err("Import did not commit".into());
    }
    // Publication has already passed the production gzip/tar/board validator.
    Ok(committed["receipt"].clone())
}
