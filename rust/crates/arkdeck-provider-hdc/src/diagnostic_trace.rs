//! Interactive trace is the existing ring recipe with a Runtime-owned host
//! wait. It never accepts caller commands, paths or a replacement target.
use crate::{
    DispatchFailure, FileAction, FilePlan, FileReceipt, HdcDispatch, Invocation, OwnedRemotePath,
    ProcessPlan, Receipt, TraceRequest,
};
use std::path::Path;

/// A live Runtime owner, created for this exact admitted Job. The provider
/// calls it only after reading back the ring's unique anchor. The owner must
/// bound the wait with a monotonic clock, freeze annotations on exit and
/// revalidate the admitted target before allowing finalization.
pub trait DiagnosticTraceControl {
    fn wait_until_stop(&self, maximum_seconds: u64) -> Result<(), String>;
    fn before_finalize(&self) -> Result<(), String>;
}

pub(crate) fn lower(
    request: &TraceRequest,
    path: &OwnedRemotePath,
    connect_key: Option<&str>,
    host_receive_root: Option<&Path>,
) -> Result<FilePlan, String> {
    if !request.ring_buffered || request.coverage_anchor.is_none() {
        return Err("interactive trace requires a unique ring coverage anchor".into());
    }
    let FilePlan::Sequence(mut invocations) = (FileAction::CaptureTrace {
        request: request.clone(),
        path: path.clone(),
    })
    .lower_in("capture-trace", connect_key, host_receive_root)?
    else {
        return Err("interactive trace did not lower to the closed ring recipe".into());
    };
    // begin, write anchor, read anchor, remote sleep, dump, finish, readback.
    // No remote sleep is dispatched by an interactive session.
    if invocations.len() != 7 {
        return Err("interactive trace ring recipe changed".into());
    }
    let finalize = invocations.split_off(4);
    invocations.pop();
    Ok(FilePlan::DiagnosticTrace {
        arm: invocations,
        finalize,
        maximum_seconds: request.duration_seconds as u64,
    })
}

fn unknown(reason: impl Into<String>) -> DispatchFailure {
    DispatchFailure::Unobservable(reason.into())
}

fn observed_text(receipt: &Receipt, suffix: &str) -> bool {
    receipt.exit_status == 0
        && !receipt.truncated
        && std::str::from_utf8(&receipt.stdout).is_ok_and(|text| {
            text.lines()
                .any(|line| line.trim_end_matches('.').ends_with(suffix))
        })
}

fn invoke(dispatch: &dyn HdcDispatch, invocation: &Invocation) -> Result<Receipt, DispatchFailure> {
    dispatch.dispatch(&ProcessPlan {
        arguments: invocation.arguments.clone(),
        timeout: invocation.timeout,
        capture_bytes: 8 * 1024 * 1024,
    })
}

/// Only this entry point can execute the plan with its live owner. After the
/// first mutation, missing semantic evidence or a failed owner callback is
/// unknown, including a later dispatch refusal. Nothing retries or proceeds
/// to another device command in that case.
pub fn run_diagnostic_trace(
    plan: &FilePlan,
    dispatch: &dyn HdcDispatch,
    control: &dyn DiagnosticTraceControl,
) -> Result<FileReceipt, DispatchFailure> {
    let FilePlan::DiagnosticTrace {
        arm,
        finalize,
        maximum_seconds,
    } = plan
    else {
        return Err(DispatchFailure::Refused(
            "not a diagnostic trace plan".into(),
        ));
    };
    if arm.len() != 3 || finalize.len() != 3 || !(1..=120).contains(maximum_seconds) {
        return Err(DispatchFailure::Refused(
            "invalid diagnostic trace plan".into(),
        ));
    }
    let mut subprocesses = Vec::with_capacity(6);
    for (index, invocation) in arm.iter().enumerate() {
        let receipt = invoke(dispatch, invocation).map_err(|error| {
            if index == 0 {
                error
            } else {
                unknown(format!("trace arm interrupted: {error:?}"))
            }
        })?;
        let valid = match index {
            0 => observed_text(&receipt, "OpenRecording done"),
            1 => receipt.exit_status == 0 && !receipt.truncated,
            2 => {
                receipt.exit_status == 0
                    && !receipt.truncated
                    && std::str::from_utf8(&receipt.stdout)
                        .ok()
                        .and_then(|text| text.trim().parse::<u64>().ok())
                        .is_some_and(|count| count > 0)
            }
            _ => false,
        };
        if !valid {
            return Err(unknown(
                "trace ring did not prove its arm and unique anchor",
            ));
        }
        subprocesses.push(receipt);
    }
    control.wait_until_stop(*maximum_seconds).map_err(unknown)?;
    control.before_finalize().map_err(unknown)?;
    for (index, invocation) in finalize.iter().enumerate() {
        let receipt = invoke(dispatch, invocation)
            .map_err(|error| unknown(format!("trace finalization interrupted: {error:?}")))?;
        if receipt.exit_status != 0
            || receipt.truncated
            || (index == 1 && !observed_text(&receipt, "end capture trace"))
        {
            return Err(unknown("trace finish did not prove the ring stopped"));
        }
        subprocesses.push(receipt);
    }
    Ok(FileReceipt {
        subprocesses,
        landed: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ImageType, Outcome};
    use std::sync::Mutex;
    use std::time::Duration;

    struct Device {
        calls: Mutex<Vec<Vec<String>>>,
        fail_at: Option<usize>,
    }
    impl HdcDispatch for Device {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            let mut calls = self.calls.lock().unwrap();
            calls.push(plan.arguments.clone());
            let ordinal = calls.len();
            let stdout = if self.fail_at == Some(ordinal) {
                "unrecognized outcome"
            } else {
                match ordinal {
                    1 => "2026/10/04 OpenRecording done",
                    2 => "",
                    3 => "1\n",
                    4 => "dump done",
                    5 => "2026/10/04 end capture trace.",
                    6 => "-rw-r--r-- 1 shell shell 1234 2026-10-04 00:00 trace.htrace",
                    _ => panic!("unexpected device dispatch"),
                }
            };
            Ok(Receipt {
                exit_status: 0,
                stdout: stdout.as_bytes().to_vec(),
                stderr: vec![],
                truncated: false,
                duration: Duration::from_millis(1),
            })
        }
    }

    struct Control<'a> {
        device: &'a Device,
        refuse_wait: bool,
        drift: bool,
    }
    impl DiagnosticTraceControl for Control<'_> {
        fn wait_until_stop(&self, seconds: u64) -> Result<(), String> {
            assert_eq!(seconds, 60);
            assert_eq!(
                self.device.calls.lock().unwrap().len(),
                3,
                "readiness must follow anchor readback"
            );
            if self.refuse_wait {
                Err("durable host state lost".into())
            } else {
                Ok(())
            }
        }
        fn before_finalize(&self) -> Result<(), String> {
            if self.drift {
                Err("target binding drift".into())
            } else {
                Ok(())
            }
        }
    }

    fn action() -> FileAction {
        FileAction::CaptureDiagnosticTrace {
            request: TraceRequest::new(
                60,
                vec!["ohos".into()],
                8192,
                true,
                Some(TraceRequest::anchor("job-fixture", "capture-session-trace")),
            )
            .unwrap(),
            path: OwnedRemotePath::stable("job-fixture", "capture-trace", ImageType::Png).unwrap(),
        }
    }

    #[test]
    fn closed_plan_has_no_remote_sleep_and_generic_execution_dispatches_nothing() {
        let action = action();
        let plan = action
            .lower_in("capture-session-trace", Some("exact-target"), None)
            .unwrap();
        let FilePlan::DiagnosticTrace {
            arm,
            finalize,
            maximum_seconds,
        } = &plan
        else {
            panic!()
        };
        assert_eq!(*maximum_seconds, 60);
        for invocation in arm.iter().chain(finalize) {
            assert_eq!(&invocation.arguments[..2], &["-t", "exact-target"]);
            assert!(
                !invocation
                    .arguments
                    .iter()
                    .any(|argument| argument == "sleep")
            );
        }
        let device = Device {
            calls: Mutex::new(vec![]),
            fail_at: None,
        };
        assert!(matches!(
            crate::run(&plan, &device),
            Err(DispatchFailure::Refused(_))
        ));
        assert!(device.calls.lock().unwrap().is_empty());
        assert_eq!(action.persisted().0, "hdc.captureDiagnosticTrace");
        assert!(
            action.written_path().is_none(),
            "file presence cannot reconcile an interrupted ring lifecycle"
        );
        let control = Control {
            device: &device,
            refuse_wait: false,
            drift: false,
        };
        let receipt = run_diagnostic_trace(&plan, &device, &control).unwrap();
        assert_eq!(receipt.subprocesses.len(), 6);
        assert!(matches!(
            action.verify(&receipt, "2026-10-04T00:00:00Z"),
            Outcome::Verified(_)
        ));
    }

    #[test]
    fn unknown_arm_anchor_or_finish_never_continues_or_replays() {
        let plan = action()
            .lower_in("capture-session-trace", Some("exact-target"), None)
            .unwrap();
        for failure in [1, 3, 5] {
            let device = Device {
                calls: Mutex::new(vec![]),
                fail_at: Some(failure),
            };
            let control = Control {
                device: &device,
                refuse_wait: false,
                drift: false,
            };
            assert!(matches!(
                run_diagnostic_trace(&plan, &device, &control),
                Err(DispatchFailure::Unobservable(_))
            ));
            assert_eq!(device.calls.lock().unwrap().len(), failure);
        }
    }

    #[test]
    fn control_failure_or_target_drift_dispatches_no_dump() {
        let plan = action()
            .lower_in("capture-session-trace", Some("exact-target"), None)
            .unwrap();
        for (refuse_wait, drift) in [(true, false), (false, true)] {
            let device = Device {
                calls: Mutex::new(vec![]),
                fail_at: None,
            };
            let control = Control {
                device: &device,
                refuse_wait,
                drift,
            };
            assert!(matches!(
                run_diagnostic_trace(&plan, &device, &control),
                Err(DispatchFailure::Unobservable(_))
            ));
            assert_eq!(device.calls.lock().unwrap().len(), 3);
        }
    }
}
