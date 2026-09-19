//! What Swift's engine adds to a device run for `capture.screen-sequence@1`:
//! the record keeps what a run of stills measured (`screenSequence`, from the
//! capture's verified summary), and a received product is the bytes that
//! landed on the host or nothing — published from the landed file as Swift's
//! `RuntimeArtifactStore.publishFile` publishes it, after which the landing
//! copy, sensitive capture data, does not outlive the publication.
use super::Stop;
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::artifact_read_owner::swift_string;
use crate::job_run::{JobRunner, Run};
use crate::operation_catalog::CatalogArtifact;
use crate::swift_decoding::swift_value;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_hdc::{FileReceipt, Landed};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

/// Swift `RuntimeScreenSequence` from a verified summary that carries both
/// frame counts: the counts, and each frame's own span in capture order, as
/// Swift's `Double` reads the provider's `%.3f` list. Held as Swift's
/// `JSONValue` holds a number, so that a span with no fraction reads back as
/// the integer Foundation writes for it.
pub(super) fn measured(summary: &BTreeMap<String, String>) -> Option<Value> {
    let requested: i64 = summary.get("requestedFrameCount")?.parse().ok()?;
    let captured: i64 = summary.get("capturedFrameCount")?.parse().ok()?;
    let durations: Vec<f64> = summary
        .get("frameDurationsSeconds")
        .map(|list| {
            list.split(',')
                .filter_map(|span| span.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    Some(swift_value(&json!({
        "requestedFrameCount": requested,
        "capturedFrameCount": captured,
        "frameDurationsSeconds": durations,
    })))
}

fn io_failure(detail: &str) -> String {
    format!("ioFailure({})", swift_string(detail))
}

fn errno(error: &std::io::Error) -> i32 {
    error.raw_os_error().unwrap_or(0)
}

/// Swift `publishFile`'s source checks, then the bytes it copies: an absolute,
/// non-empty binary file of the declared digest, opened without following a
/// link, still the declared regular file of the declared size, read whole
/// (a received file is at most 64 MiB) and unchanged — the same inode, size
/// and timestamps — once read. Those exact bytes are then published, which a
/// binary product does not redact, under the identity the digest names.
fn publish_file(
    publisher: &ArtifactPublisher<'_>,
    product: &Product<'_>,
    landed: &Landed,
) -> Result<Value, String> {
    let digest = landed.sha256.as_deref().unwrap_or_default();
    if !landed.path.is_absolute()
        || landed.byte_count == 0
        || !crate::job_record::digest(digest)
        || product.media_type.starts_with("text/")
        || product.media_type == "application/json"
    {
        return Err(io_failure(
            "file-backed publication requires an absolute binary file with exact size and SHA-256",
        ));
    }
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&landed.path)
        .map_err(|error| {
            io_failure(&format!(
                "cannot open file-backed Artifact source (errno {})",
                errno(&error)
            ))
        })?;
    let declared = || io_failure("file-backed Artifact source is not the declared regular file");
    let before = file.metadata().map_err(|_| declared())?;
    if !before.is_file() || before.len() != landed.byte_count {
        return Err(declared());
    }
    let mut bytes = Vec::new();
    (&file)
        .take(landed.byte_count.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| {
            io_failure(&format!(
                "cannot read file-backed Artifact source (errno {})",
                errno(&error)
            ))
        })?;
    let unchanged = file.metadata().is_ok_and(|after| {
        (after.dev(), after.ino(), after.len()) == (before.dev(), before.ino(), before.len())
            && (after.mtime(), after.mtime_nsec()) == (before.mtime(), before.mtime_nsec())
            && (after.ctime(), after.ctime_nsec()) == (before.ctime(), before.ctime_nsec())
    });
    if bytes.len() as u64 != landed.byte_count || sha256_hex(&bytes) != digest || !unchanged {
        return Err(io_failure(
            "file-backed Artifact source changed while being published",
        ));
    }
    publisher.publish(product, &bytes)
}

impl JobRunner<'_> {
    /// Swift `publishDeclaredArtifacts` for a file-backed product: an
    /// optional one no file landed for is absent by contract; otherwise it
    /// needs a landed, digested file, or it is recorded missing and the Job's
    /// publication fails. Published, the landing copy is removed; refused, it
    /// is recorded missing with the refusal and the Job's publication fails.
    /// Swift's job byte budget bounds `capture.diagnostics@1` products only,
    /// and no file leg of that operation runs here yet.
    pub(super) fn publish_received(
        &self,
        run: &mut Run,
        product: &Product<'_>,
        declaration: &CatalogArtifact,
        receipt: &FileReceipt,
    ) -> Result<(), Stop> {
        if receipt.landed.is_none() && !declaration.required {
            return Ok(());
        }
        let publisher = self.publisher();
        let Some(landed) = receipt
            .landed
            .as_ref()
            .filter(|landed| landed.sha256.is_some())
        else {
            let detail = format!("{} has no received host file to publish", product.name);
            let _ = publisher.record_missing(product, &detail);
            return Err(Stop::Publication(detail));
        };
        match publish_file(&publisher, product, landed) {
            Ok(metadata) => {
                // The store now owns the bytes; the landing copy is sensitive
                // capture data and does not outlive the publication.
                let _ = fs::remove_file(&landed.path);
                run.record.timeline.push(format!(
                    "artifact {} -> {}",
                    product.name,
                    metadata["artifactID"].as_str().unwrap_or_default()
                ));
                Ok(())
            }
            Err(error) => {
                let _ = publisher.record_missing(product, &error);
                run.record
                    .timeline
                    .push(format!("artifact {} missing: {error}", product.name));
                Err(Stop::Publication(format!(
                    "{} could not be published: {error}",
                    product.name
                )))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job_record::JobRecord;
    use crate::operation_catalog::CatalogOperation;

    const FIXTURE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tests/fixtures/screen-sequence"
    );

    fn record(job: &str) -> JobRecord {
        let path = format!("{FIXTURE}/store/jobs/{job}/job-record.json");
        JobRecord::decode(&fs::read(path).unwrap()).unwrap()
    }

    fn sequence(record: &JobRecord) -> String {
        let descriptor = CatalogOperation::lookup("capture.screen-sequence", Some(1)).unwrap();
        let names = ["sequence.json"];
        String::from_utf8(
            crate::capture_documents::contents("sequence.json", descriptor, record, &[], &names)
                .unwrap(),
        )
        .unwrap()
    }

    /// `sequence.json` is Foundation's sorted, pretty-printed document: the
    /// oracle's own for a measured run, the recorded absence for a record
    /// that measured nothing, and a span with no fraction written as Swift
    /// writes a whole `Double`. A record holding such a span stays durable:
    /// it reads back as the record that wrote it.
    #[test]
    fn a_sequence_document_reads_the_record_as_swift_does() {
        let captured = record("job-1198f33479543de487d86dc88ce0f332");
        assert_eq!(
            sequence(&captured),
            fs::read_to_string(format!(
                "{FIXTURE}/artifacts/job-1198f33479543de487d86dc88ce0f332/ART-decf112a7c165ed56e8fbda9edd57349"
            ))
            .unwrap()
        );
        let unmeasured = record("job-37566e5bcffbc70d17f829dd42011e15");
        assert_eq!(
            sequence(&unmeasured),
            "{\n  \"measured\" : false,\n  \"reason\" : \"the capture step published no observed \
             frame timings\",\n  \"schemaVersion\" : \"1.0.0\"\n}"
        );
        let mut whole = captured;
        whole.set_screen_sequence(
            measured(&summary(&[
                ("requestedFrameCount", "3"),
                ("capturedFrameCount", "2"),
                ("frameDurationsSeconds", "1.000,0.500"),
            ]))
            .unwrap(),
        );
        assert_eq!(
            sequence(&whole),
            "{\n  \"capturedFrameCount\" : 2,\n  \"frameDurationsSeconds\" : [\n    1,\n    0.5\n  \
             ],\n  \"framesMissing\" : 1,\n  \"observedFramesPerSecond\" : 1.3333333333333333,\n  \
             \"requestedFrameCount\" : 3,\n  \"schemaVersion\" : \"1.0.0\"\n}"
        );
        let bytes = whole.durable_bytes().unwrap();
        assert_eq!(
            JobRecord::decode(&bytes).unwrap().screen_sequence(),
            whole.screen_sequence()
        );
    }

    fn summary(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    /// Both counts are needed; each span is read as Swift's `Double` reads
    /// it, one Foundation writes without a fraction reads back as an integer,
    /// and a span no `Double` reads is dropped.
    #[test]
    fn a_verified_summary_measures_a_run_of_stills_as_swift_does() {
        assert_eq!(
            measured(&summary(&[
                ("requestedFrameCount", "4"),
                ("capturedFrameCount", "3"),
                ("frameDurationsSeconds", "0.500,1.000,,x,0.035"),
            ])),
            Some(json!({"requestedFrameCount": 4, "capturedFrameCount": 3,
                "frameDurationsSeconds": [0.5, 1, 0.035]}))
        );
        assert_eq!(
            measured(&summary(&[
                ("requestedFrameCount", "2"),
                ("capturedFrameCount", "0")
            ])),
            Some(json!({"requestedFrameCount": 2, "capturedFrameCount": 0,
                "frameDurationsSeconds": []}))
        );
        assert_eq!(measured(&summary(&[("requestedFrameCount", "2")])), None);
        assert_eq!(
            measured(&summary(&[
                ("requestedFrameCount", "2"),
                ("capturedFrameCount", "two")
            ])),
            None
        );
    }
}
