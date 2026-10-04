//! Host observations around the already-admitted trace-anchor write.
//! These measurements never establish a device clock mapping or tolerance.
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ClockObservation {
    schema_version: String,
    job_id: String,
    anchor: String,
    #[serde(rename = "startedAtHostUTC")]
    started_at_host_utc: String,
    #[serde(rename = "finishedAtHostUTC")]
    finished_at_host_utc: String,
    elapsed_nanoseconds: u64,
    status: String,
}

impl ClockObservation {
    pub(crate) fn new(
        job: &str,
        start: String,
        end: String,
        elapsed_nanoseconds: u64,
    ) -> Option<Self> {
        let status = Self::status(&start, &end, elapsed_nanoseconds)?;
        Some(Self {
            schema_version: "arkdeck.trace-clock-observation/1".into(),
            job_id: job.into(),
            anchor: arkdeck_provider_hdc::TraceRequest::anchor(job, "capture-session-trace"),
            started_at_host_utc: start,
            finished_at_host_utc: end,
            elapsed_nanoseconds,
            status: status.into(),
        })
    }
    fn status(start: &str, end: &str, nanos: u64) -> Option<&'static str> {
        // The operation is bounded to two minutes. Larger observations cannot
        // acquire apparent precision after host suspension or an expired run.
        if nanos > 120_000_000_000 {
            return None;
        }
        if [start, end]
            .iter()
            .any(|value| value.len() != 24 || !value.ends_with('Z'))
        {
            return None;
        }
        let before = arkdeck_contract::import_timestamp(start)?;
        let after = arkdeck_contract::import_timestamp(end)?;
        let wall_nanos = ((after * 1_000.0).round() - (before * 1_000.0).round()) * 1_000_000.0;
        // UTC labels have millisecond precision. This only rejects a broken
        // host bracket; it is never a device alignment error bound.
        Some(
            if wall_nanos >= 0.0 && (wall_nanos - nanos as f64).abs() <= 2_000_000.0 {
                "unvalidated"
            } else {
                "hostClockDiscontinuity"
            },
        )
    }
    pub(crate) fn valid_for(&self, job: &str) -> bool {
        self.schema_version == "arkdeck.trace-clock-observation/1"
            && self.job_id == job
            && self.anchor
                == arkdeck_provider_hdc::TraceRequest::anchor(job, "capture-session-trace")
            && Self::status(
                &self.started_at_host_utc,
                &self.finished_at_host_utc,
                self.elapsed_nanoseconds,
            ) == Some(self.status.as_str())
    }
    pub(crate) fn value(&self) -> Result<serde_json::Value, String> {
        serde_json::to_value(self).map_err(|_| "cannot encode trace clock observation".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const START: &str = "2026-10-04T00:00:00.000Z";
    #[test]
    fn an_observation_never_claims_calibration_and_is_bound_to_its_exact_job_anchor() {
        let measured = ClockObservation::new(
            "job-clock",
            START.into(),
            "2026-10-04T00:00:00.010Z".into(),
            10_000_000,
        )
        .unwrap();
        assert!(measured.valid_for("job-clock"));
        assert!(!measured.valid_for("job-other"));
        assert_eq!(measured.value().unwrap()["status"], "unvalidated");
        let mut changed = measured.value().unwrap();
        changed["status"] = serde_json::json!("calibrated");
        assert!(
            !serde_json::from_value::<ClockObservation>(changed)
                .unwrap()
                .valid_for("job-clock")
        );
    }
    #[test]
    fn clock_jumps_and_invalid_or_unbounded_measurements_cannot_be_used() {
        for end in ["2026-10-03T23:59:59.999Z", "2026-10-04T00:00:01.000Z"] {
            let measured =
                ClockObservation::new("job-clock", START.into(), end.into(), 10_000_000).unwrap();
            assert!(measured.valid_for("job-clock"));
            assert_eq!(
                measured.value().unwrap()["status"],
                "hostClockDiscontinuity"
            );
        }
        assert!(ClockObservation::new("job-clock", "invalid".into(), START.into(), 0).is_none());
        assert!(ClockObservation::new("job-clock", START.into(), START.into(), u64::MAX).is_none());
    }
}
