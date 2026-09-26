use super::RuntimeUpdateEvent as Event;
use arkdeck_platform::{HostDiagnosticLevel, HostDiagnosticWriter};
use std::{path::Path, sync::Mutex};

pub struct UpdateLogger {
    writer: Mutex<HostDiagnosticWriter>,
    correlation: String,
}
fn fields(
    event: Event,
) -> (
    &'static str,
    &'static str,
    &'static str,
    HostDiagnosticLevel,
) {
    use HostDiagnosticLevel::{Error, Info, Notice};
    match event {
        Event::CheckStarted => ("info", "update.check", "update.started", Info),
        Event::Available => ("notice", "update.check", "update.available", Notice),
        Event::NoUpdate => ("info", "update.check", "update.no-update", Info),
        Event::DownloadStarted => ("notice", "update.download", "update.started", Notice),
        Event::VerificationStarted => ("notice", "update.verification", "update.started", Notice),
        Event::Failed => ("error", "update.verification", "update.failed", Error),
        Event::Cancelled => ("notice", "update.download", "update.cancelled", Notice),
        Event::HandedOff => ("notice", "update.handoff", "update.handoff", Notice),
    }
}
fn record(event: Event, correlation: &str, timestamp: &str) -> Vec<u8> {
    let (level, name, code, _) = fields(event);
    let value = serde_json::json!({"schemaVersion":"1.0.0", "timestamp":timestamp, "level":level, "category":"workflow", "eventName":name, "correlationId":correlation, "fields":{"publicCode":code}});
    let mut bytes = serde_json::to_vec(&value).expect("closed JSON record");
    bytes.push(b'\n');
    bytes
}

fn timestamp(unix_seconds: f64) -> String {
    // Foundation Date stores a Double relative to 2001. ISO8601FormatStyle
    // truncates the represented fraction, so .123 may render .122. Preserve
    // that behavior instead of formatting the input nanoseconds directly.
    let reference = unix_seconds - 978_307_200.0;
    let whole = reference.floor();
    let millis = ((reference - whole) * 1000.0).floor() as u32;
    format!(
        "{}.{millis:03}Z",
        crate::utc_now_at((whole + 978_307_200.0) as u64).trim_end_matches('Z')
    )
}
impl UpdateLogger {
    /// Unavailable diagnostics fall back to the same no-op assembly as Swift.
    pub fn open(directory: &Path) -> Option<Self> {
        let correlation = format!(
            "corr-{}",
            crate::job_plan::uuid()
                .ok()?
                .replace('-', "")
                .to_ascii_lowercase()
        );
        Some(Self {
            writer: Mutex::new(
                HostDiagnosticWriter::open(directory, 16 * 1024 * 1024, 1024 * 1024, 72 * 1024)
                    .ok()?,
            ),
            correlation,
        })
    }
    /// No version, URL, path, Team ID, server error text or arbitrary field
    /// enters either sink. The public interface accepts only the closed enum.
    pub fn event(&self, event: Event) {
        let Ok(mut writer) = self.writer.lock() else {
            return;
        };
        let Ok(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
            return;
        };
        let timestamp = timestamp(now.as_secs_f64());
        if writer
            .append(&record(event, &self.correlation, &timestamp))
            .is_err()
        {
            return;
        }
        let (_, name, code, level) = fields(event);
        let _ = arkdeck_platform::host_diagnostic_log(
            level,
            &format!("{name} correlation={} publicCode={code}", self.correlation),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_update_event_has_only_the_closed_public_record_fields() {
        let events = [
            Event::CheckStarted,
            Event::Available,
            Event::NoUpdate,
            Event::DownloadStarted,
            Event::VerificationStarted,
            Event::Failed,
            Event::Cancelled,
            Event::HandedOff,
        ];
        for event in events {
            let bytes = record(
                event,
                "corr-01234567890123456789012345678901",
                "2026-09-26T00:00:00.123Z",
            );
            assert!(bytes.len() < 400);
            assert_eq!(bytes.iter().filter(|b| **b == b'\n').count(), 1);
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value.as_object().unwrap().len(), 7);
            assert_eq!(value["fields"].as_object().unwrap().len(), 1);
            assert_eq!(value["category"], "workflow");
            assert_eq!(value["fields"]["publicCode"], fields(event).2);
        }
    }

    #[test]
    fn actual_swift_records_rotation_and_retained_bytes_replay() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/logging.json"
        ))
        .unwrap();
        let path =
            std::env::temp_dir().join(format!("arkdeck-update-logs-{}", crate::client_frame_id()));
        struct Root(std::path::PathBuf);
        impl Drop for Root {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = Root(path);
        let mut writer = HostDiagnosticWriter::open(&root.0, 1024, 400, 400).unwrap();
        let events = [
            Event::CheckStarted,
            Event::Available,
            Event::NoUpdate,
            Event::DownloadStarted,
            Event::VerificationStarted,
            Event::Failed,
            Event::Cancelled,
            Event::HandedOff,
        ];
        let rows = fixture["cases"].as_array().unwrap();
        assert_eq!(rows.len(), events.len());
        for (row, event) in rows.iter().zip(events) {
            writer
                .append(&record(
                    event,
                    "corr-01234567890123456789012345678901",
                    &timestamp(fixture["unixSeconds"].as_str().unwrap().parse().unwrap()),
                ))
                .unwrap();
            let mut files = std::fs::read_dir(&root.0)
                .unwrap()
                .map(|e| e.unwrap().path())
                .filter(|p| p.extension().is_some_and(|ext| ext == "jsonl"))
                .collect::<Vec<_>>();
            files.sort();
            let mut total = 0;
            let files: Vec<serde_json::Value> = files.into_iter().map(|path| {
                let bytes = std::fs::read(&path).unwrap();
                total += bytes.len();
                let records: Vec<serde_json::Value> = bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()).map(|line| {
                    let mut value: serde_json::Value = serde_json::from_slice(line).unwrap();
                    value["correlationId"] = serde_json::json!("<correlation>");
                    value
                }).collect();
                serde_json::json!({"name":path.file_name().unwrap().to_str().unwrap(), "records":records})
            }).collect();
            assert_eq!(serde_json::json!(files), row["files"], "{event:?}");
            assert_eq!(serde_json::json!(total), row["totalBytes"], "{event:?}");
        }
        for row in fixture["timestampCases"].as_array().unwrap() {
            assert_eq!(
                timestamp(row["unixSeconds"].as_str().unwrap().parse().unwrap()),
                row["timestamp"].as_str().unwrap()
            );
        }
    }
}
