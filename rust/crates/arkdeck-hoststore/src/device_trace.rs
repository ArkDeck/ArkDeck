//! What Swift's engine adds to a device run for a `capture.diagnostics@1`
//! request that selects its Trace legs (`executeStepsWithTraceEvidence`):
//! the step loop is bracketed by two Runtime-owned snapshots of the trace
//! tool and its nine parameters, read over the Target's own route by the
//! Trace Runtime probe (`FoundationTraceRuntimeProbe`) and kept on the record
//! (`traceProbeBefore`, `traceProbeAfter`). A snapshot counts only when it
//! names the request's Target and binding, a capture-eligible `hitrace`
//! offering every requested tag and the whole parameter catalog. The first
//! must hold before any step runs; the second is taken once the steps end,
//! whatever they ended with, and one that cannot be taken fails a Job whose
//! steps succeeded, is noted beside a cancellation and is noted beside a
//! step's own failure, which it never replaces.
use super::Stop;
use crate::artifact_read_owner::swift_string;
use crate::device_facts::{DeviceFacts, HdcComposition};
use crate::job_cancel::RunCancellation;
use crate::job_run::{JobRunner, Run};
use crate::operation_catalog::CatalogOperation;
use arkdeck_provider_hdc::{TRACE_PARAMETERS, TraceProbe};
use serde_json::{Map, Value, json};

const CAPTURE: &str = "capture.diagnostics@1";
/// Swift `validateTraceRuntimeProbe`'s refusal.
const MISMATCH: &str =
    "Trace probe facts do not match target, binding, adapter, tags, or parameter catalog";

/// Why a snapshot is not kept: its facts do not match the request (Swift's
/// `RuntimeDispatchFailure.failed`), or the probe could not be taken, with
/// Swift's description of why.
enum Unkept {
    Mismatch,
    Probe(String),
}

impl Unkept {
    /// Swift's `\(error)` of it: `RuntimeDispatchFailure`'s own description,
    /// or the probe error's.
    fn described(&self) -> String {
        match self {
            Self::Mismatch => format!("failed({})", swift_string(MISMATCH)),
            Self::Probe(error) => error.clone(),
        }
    }
}

/// The tags a capture's request names when it selects its Trace legs, or
/// Swift's refusal when one of them is not a string; none for any other
/// request.
fn requested_tags(run: &Run) -> Option<Result<Vec<String>, Stop>> {
    if run.record.operation() != CAPTURE {
        return None;
    }
    let values = run.record.request["inputs"]["traceCategories"]
        .as_array()
        .filter(|values| !values.is_empty())?;
    let tags: Vec<String> = values
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    Some(if tags.len() == values.len() {
        Ok(tags)
    } else {
        Err(Stop::Failed(
            "Trace tag request lost its typed string shape".into(),
        ))
    })
}

/// Swift `probeTraceRuntime` over the Target's route, then
/// `validateTraceRuntimeProbe`: the snapshot as the record keeps it.
fn snapshot(
    hdc: &HdcComposition<'_>,
    target_id: &str,
    revision: Option<i64>,
    tags: &[String],
) -> Result<Value, Unkept> {
    let facts = hdc.facts(target_id).map_err(Unkept::Probe)?;
    let probe = arkdeck_provider_hdc::trace_probe(hdc.dispatch, &facts.connect_key)
        .map_err(Unkept::Probe)?;
    let mut names: Vec<&str> = probe
        .parameters
        .iter()
        .map(|reading| reading.name)
        .collect();
    let mut catalog = TRACE_PARAMETERS.to_vec();
    names.sort_unstable();
    names.dedup();
    catalog.sort_unstable();
    let matches = facts.target_id == target_id
        && revision == Some(facts.binding_revision)
        && probe.adapter_disposition == "captureEligible"
        && probe.tool == Some("hitrace")
        && probe.family.is_some()
        && !probe.supported_tags.is_empty()
        && tags.iter().all(|tag| probe.supported_tags.contains(tag))
        && probe.parameters.len() == TRACE_PARAMETERS.len()
        && names == catalog;
    if !matches {
        return Err(Unkept::Mismatch);
    }
    Ok(recorded(&facts, &probe))
}

/// Swift's `Codable` form of `TraceRuntimeProbeSnapshot`, which the record
/// keeps: the route's Target and binding, the adapter's verdict with the tool,
/// family, tags and help it read, both tools' observations and every
/// parameter's reading, an absent member omitted.
fn recorded(facts: &DeviceFacts, probe: &TraceProbe) -> Value {
    let mut snapshot = Map::from_iter([
        ("targetID".to_owned(), json!(facts.target_id)),
        ("bindingRevision".to_owned(), json!(facts.binding_revision)),
        (
            "adapterDisposition".to_owned(),
            json!(probe.adapter_disposition),
        ),
        ("supportedTags".to_owned(), json!(probe.supported_tags)),
    ]);
    let optional = |fields: &mut Map<String, Value>, key: &str, value: Option<&str>| {
        if let Some(value) = value {
            fields.insert(key.to_owned(), json!(value));
        }
    };
    optional(&mut snapshot, "tool", probe.tool);
    optional(&mut snapshot, "family", probe.family);
    optional(&mut snapshot, "rawHelp", probe.raw_help.as_deref());
    optional(
        &mut snapshot,
        "rawHelpSHA256",
        probe.raw_help_sha256.as_deref(),
    );
    let tools: Vec<Value> = probe
        .tools
        .iter()
        .map(|observation| {
            let mut tool = Map::from_iter([
                ("tool".to_owned(), json!(observation.tool)),
                ("disposition".to_owned(), json!(observation.disposition)),
            ]);
            optional(&mut tool, "family", observation.family);
            optional(
                &mut tool,
                "rawHelpSHA256",
                observation.raw_help_sha256.as_deref(),
            );
            optional(&mut tool, "detail", observation.detail);
            Value::Object(tool)
        })
        .collect();
    let parameters: Vec<Value> = probe
        .parameters
        .iter()
        .map(|reading| {
            let mut parameter = Map::from_iter([
                ("name".to_owned(), json!(reading.name)),
                ("state".to_owned(), json!(reading.state)),
            ]);
            optional(&mut parameter, "value", reading.value.as_deref());
            optional(&mut parameter, "detail", reading.detail.as_deref());
            Value::Object(parameter)
        })
        .collect();
    snapshot.insert("tools".into(), json!(tools));
    snapshot.insert("parameters".into(), json!(parameters));
    Value::Object(snapshot)
}

impl JobRunner<'_> {
    /// Swift `executeStepsWithTraceEvidence`: [`Self::steps`], bracketed by
    /// the two Trace snapshots when the request selects its Trace legs.
    pub(super) fn traced_steps(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
    ) -> Result<(), Stop> {
        let Some(tags) = requested_tags(run) else {
            return self.steps(run, hdc, descriptor);
        };
        let tags = tags?;
        let target_id = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let revision = run.record.request["target"]["expectedBindingRevision"].as_i64();
        let before = snapshot(hdc, &target_id, revision, &tags).map_err(|unkept| match unkept {
            Unkept::Mismatch => Stop::Failed(MISMATCH.into()),
            Unkept::Probe(error) => Stop::Failed(format!("Trace before snapshot failed: {error}")),
        })?;
        run.record.set_trace_probe(true, Some(before));
        run.record
            .timeline
            .push("trace parameters snapshotted before capture".into());
        run.persist(self.jobs)?;
        // The step loop leaves at a safe boundary on cancellation, which
        // Swift's does without an error: the second snapshot is taken then
        // too, and one that cannot be is noted rather than failing the drain.
        let executed = self.steps(run, hdc, descriptor);
        let after = snapshot(hdc, &target_id, revision, &tags);
        match executed {
            Ok(()) | Err(Stop::Cancelled) => {
                let kept = match after {
                    Ok(after) => {
                        run.record.set_trace_probe(false, Some(after));
                        run.record
                            .timeline
                            .push("trace parameters snapshotted after capture".into());
                        run.persist(self.jobs)?;
                        Ok(())
                    }
                    Err(unkept)
                        if matches!(executed, Err(Stop::Cancelled))
                            || self.cancellation.is_some_and(RunCancellation::pending) =>
                    {
                        run.record.timeline.push(match unkept {
                            Unkept::Mismatch => {
                                "Trace after snapshot unavailable during cancellation".into()
                            }
                            Unkept::Probe(error) => format!(
                                "Trace after snapshot unavailable during cancellation: {error}"
                            ),
                        });
                        Ok(())
                    }
                    Err(Unkept::Mismatch) => Err(Stop::Failed(MISMATCH.into())),
                    Err(Unkept::Probe(error)) => Err(Stop::Failed(format!(
                        "Trace after snapshot failed: {error}"
                    ))),
                };
                kept.and(executed)
            }
            // A step's own failure stands; the snapshot that follows it is
            // kept when it can be, and noted when it cannot.
            Err(stop) => {
                match after {
                    Ok(after) => {
                        run.record.set_trace_probe(false, Some(after));
                        run.record
                            .timeline
                            .push("trace parameters snapshotted after capture".into());
                        // Swift keeps the snapshot only once it is durable.
                        if run.persist(self.jobs).is_err() {
                            run.record.set_trace_probe(false, None);
                            run.record.timeline.pop();
                            run.record.timeline.push(
                                "Trace after snapshot unavailable after execution failure: \
                                 the Job record is unwritable"
                                    .into(),
                            );
                        }
                    }
                    Err(unkept) => run.record.timeline.push(format!(
                        "Trace after snapshot unavailable after execution failure: {}",
                        unkept.described()
                    )),
                }
                Err(stop)
            }
        }
    }
}
