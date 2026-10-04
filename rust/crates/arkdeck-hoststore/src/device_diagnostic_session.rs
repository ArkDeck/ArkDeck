use super::{JobRunner, Run, materialized_facts};
use crate::device_facts::HdcComposition;
use crate::job_owner::diagnostic_session::{LiveSession, OPERATION};
use crate::job_record::JobRecord;
use crate::operation_catalog::CatalogOperation;
use arkdeck_provider_hdc::{DiagnosticTraceControl, DispatchFailure, FilePlan, FileReceipt};
use serde_json::{Value, json};

struct Control<'a, 'b> {
    live: &'a LiveSession,
    hdc: &'a HdcComposition<'b>,
    record: &'a JobRecord,
    target_id: &'a str,
    revision: Option<i64>,
    connect_key: &'a str,
}

impl DiagnosticTraceControl for Control<'_, '_> {
    fn wait_until_stop(&self, maximum_seconds: u64) -> Result<(), String> {
        self.live.wait(maximum_seconds)
    }

    fn before_finalize(&self) -> Result<(), String> {
        let facts = self.hdc.facts(self.target_id)?;
        if facts.connect_key != self.connect_key
            || materialized_facts(self.record, Some(&facts), self.target_id, self.revision).is_err()
            || !self.hdc.dispatch.mutation_identity_current()
        {
            return Err("Diagnostic Session target, binding or provider identity changed before finalization".into());
        }
        Ok(())
    }
}

impl JobRunner<'_> {
    pub(super) fn run_diagnostic_trace(
        &self,
        run: &Run,
        hdc: &HdcComposition<'_>,
        plan: &FilePlan,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<FileReceipt, DispatchFailure> {
        let FilePlan::DiagnosticTrace { arm, .. } = plan else {
            return Err(DispatchFailure::Refused(
                "not a Diagnostic Session plan".into(),
            ));
        };
        if run.record.operation() != OPERATION {
            return Err(DispatchFailure::Refused(
                "interactive trace belongs to its closed operation".into(),
            ));
        }
        let key = arm
            .first()
            .and_then(|invocation| invocation.arguments.get(1))
            .ok_or_else(|| {
                DispatchFailure::Refused("Diagnostic Session lost its exact route".into())
            })?;
        let guard = self
            .jobs
            .begin_diagnostic_session(&run.record)
            .map_err(|error| DispatchFailure::Refused(error.message))?;
        let control = Control {
            live: &guard.session,
            hdc,
            record: &run.record,
            target_id,
            revision,
            connect_key: key,
        };
        arkdeck_provider_hdc::run_diagnostic_trace(plan, hdc.dispatch, &control)
    }

    pub(super) fn diagnostic_final_artifact(
        &self,
        name: &str,
        descriptor: &CatalogOperation,
        record: &JobRecord,
        recorded: &[Value],
        finalize_names: &[&str],
    ) -> Result<Vec<u8>, String> {
        let document = self
            .jobs
            .diagnostic_document(record)
            .map_err(|error| error.message)?;
        if name == "diagnostic-session.json" {
            let mut value = match &document {
                Some(document) => document.value().map_err(|error| error.message)?,
                None => json!({"schemaVersion":"1.0.0", "jobId":record.job_id,
                    "phase":"notStarted", "markers":[]}),
            };
            value["documentType"] = json!("arkdeck-diagnostic-session");
            value["operationReference"] = json!(OPERATION);
            value["alignment"] = json!("cannotAlign");
            value["traceReadiness"] = json!(if value["armedAtHostUTC"].as_str().is_some() {
                "verifiedUniqueRingAnchor"
            } else {
                "notEstablished"
            });
            value["hilogCoverage"] = json!("retrospectiveDrainOnly");
            value["markerScreenshots"] = json!("notCaptured");
            return crate::session_json::encode_canonical_pretty(&value)
                .map_err(|_| "cannot encode Diagnostic Session".into());
        }
        let bytes =
            crate::capture_documents::contents(name, descriptor, record, recorded, finalize_names)?;
        if name != "markers.json" {
            return Ok(bytes);
        }
        let mut value =
            arkdeck_contract::strict_json(&bytes).map_err(|_| "invalid marker document")?;
        let marks = value["markers"]
            .as_array_mut()
            .ok_or("invalid marker collection")?;
        if let Some(document) = document {
            let mut manual: Vec<Value> = document
                .markers
                .iter()
                .map(|mark| {
                    let mut value = json!({"kind":"manual", "markerId":mark.marker_id,
                    "atHostUTC":mark.at_host_utc, "offsetFromReadyMs":mark.offset_ms});
                    if let Some(label) = &mark.label {
                        value["label"] = json!(label);
                    }
                    value
                })
                .collect();
            manual.append(marks);
            *marks = manual;
        }
        crate::session_json::encode_canonical_pretty(&value)
            .map_err(|_| "cannot encode markers".into())
    }
}
