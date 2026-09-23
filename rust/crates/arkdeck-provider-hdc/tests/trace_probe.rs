//! Swift `FoundationTraceRuntimeProbe` and `TraceProbeAdapter` over scripted
//! dispatch: the registered families as the Swift oracle recorded them
//! (`rust/tests/fixtures/trace-probe`, whose resources the Swift oracle holds
//! byte-equal to the integration registry's), the fixed reads and budgets,
//! their concurrency, and each failure's honest verdict. The replay of the
//! Swift oracle through real processes is the daemon's
//! (`arkdeck-agentd` `trace_probe_control`).
use arkdeck_provider_hdc::{
    BYTRACE_HELP_FAMILY, DispatchFailure, HITRACE_HELP_FAMILY, HdcDispatch, ProcessPlan, Receipt,
    TRACE_PARAMETERS, TraceParameterObservation, TraceSelection, TraceTool, evaluate_help,
    evaluate_tag_list, trace_probe,
};
use serde_json::Value;
use std::{
    sync::{
        Barrier, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

const HITRACE_HELP: &[u8] =
    include_bytes!("../../../tests/fixtures/trace-probe/resources/hitrace-help.stdout.bin");
const BYTRACE_HELP: &[u8] =
    include_bytes!("../../../tests/fixtures/trace-probe/resources/bytrace-help.stdout.bin");
const HITRACE_TAGS: &[u8] =
    include_bytes!("../../../tests/fixtures/trace-probe/resources/hitrace-tags.stdout.bin");
const BYTRACE_TAGS: &[u8] =
    include_bytes!("../../../tests/fixtures/trace-probe/resources/bytrace-tags.stdout.bin");
const CASES: &str = include_str!("../../../tests/fixtures/trace-probe/cases.json");
const KEY: &str = "exact-connect-key";

fn receipt(stdout: &[u8], stderr: &[u8], exit_status: i32, truncated: bool) -> Receipt {
    Receipt {
        exit_status,
        stdout: stdout.to_vec(),
        stderr: stderr.to_vec(),
        truncated,
        duration: Duration::ZERO,
    }
}
fn ok(stdout: &[u8]) -> Result<Receipt, DispatchFailure> {
    Ok(receipt(stdout, b"", 0, false))
}
fn restamped(bytes: &[u8], stamp: &str) -> Vec<u8> {
    [stamp.as_bytes(), &bytes[20..]].concat()
}
/// What Swift answered for the full portrait.
fn recorded_tags() -> Vec<String> {
    let cases: Value = serde_json::from_str(CASES).unwrap();
    let portrait = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "probe.captureEligible")
        .unwrap();
    serde_json::from_value(portrait["answer"]["result"]["supportedTags"].clone()).unwrap()
}

type Answer<'a> = dyn Fn(&[&str]) -> Result<Receipt, DispatchFailure> + Sync + 'a;
/// Answers by command, after the route's `-t <key>`; records every plan.
struct Script<'a> {
    answer: &'a Answer<'a>,
    plans: Mutex<Vec<ProcessPlan>>,
}
impl HdcDispatch for Script<'_> {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.plans.lock().unwrap().push(plan.clone());
        assert_eq!(&plan.arguments[..2], ["-t", KEY]);
        let command: Vec<&str> = plan.arguments[2..].iter().map(String::as_str).collect();
        (self.answer)(&command)
    }
}
fn script<'a>(answer: &'a Answer<'a>) -> Script<'a> {
    Script {
        answer,
        plans: Mutex::new(vec![]),
    }
}
/// The registered device: both help families, the hitrace tag list, and a
/// value for every parameter.
fn device(command: &[&str]) -> Result<Receipt, DispatchFailure> {
    match command {
        ["shell", "hitrace", "--help"] => ok(HITRACE_HELP),
        ["shell", "bytrace", "--help"] => ok(BYTRACE_HELP),
        ["shell", "hitrace", "-l"] => ok(HITRACE_TAGS),
        ["shell", "param", "get", name] => ok(format!("{name} = 1\n").as_bytes()),
        _ => panic!("unexpected command {command:?}"),
    }
}
fn states(parameters: &[TraceParameterObservation]) -> Vec<&'static str> {
    parameters.iter().map(|parameter| parameter.state).collect()
}

#[test]
fn only_a_tool_s_own_registered_help_family_selects_it() {
    assert_eq!(
        evaluate_help(TraceTool::Hitrace, HITRACE_HELP, b""),
        TraceSelection::CaptureEligible(HITRACE_HELP_FAMILY)
    );
    assert_eq!(
        evaluate_help(TraceTool::Bytrace, BYTRACE_HELP, b""),
        TraceSelection::ProbeOnly(BYTRACE_HELP_FAMILY)
    );
    // Another capture time is the same family; nothing else is.
    let stamp = "2026/09/14 08:30:00 ";
    assert_eq!(
        evaluate_help(TraceTool::Hitrace, &restamped(HITRACE_HELP, stamp), b""),
        TraceSelection::CaptureEligible(HITRACE_HELP_FAMILY)
    );
    let mut drifted = HITRACE_HELP.to_vec();
    drifted[100] ^= 0x20;
    let longer = [HITRACE_HELP, b"\n"].concat();
    for (tool, stdout, stderr) in [
        (TraceTool::Hitrace, BYTRACE_HELP.to_vec(), &b""[..]),
        (TraceTool::Bytrace, HITRACE_HELP.to_vec(), b""),
        (TraceTool::Hitrace, HITRACE_HELP.to_vec(), b"note\n"),
        (TraceTool::Hitrace, drifted, b""),
        (TraceTool::Hitrace, longer, b""),
        (TraceTool::Hitrace, HITRACE_HELP[..3381].to_vec(), b""),
        (
            TraceTool::Hitrace,
            restamped(HITRACE_HELP, "2026/13/14 08:30:00 "),
            b"",
        ),
        (
            TraceTool::Hitrace,
            restamped(HITRACE_HELP, "2026/09/14 08:30:00\t"),
            b"",
        ),
    ] {
        assert_eq!(
            evaluate_help(tool, &stdout, stderr),
            TraceSelection::Unsupported
        );
    }
}

#[test]
fn only_the_registered_tag_list_names_tags() {
    let (selection, tags) = evaluate_tag_list(TraceTool::Hitrace, HITRACE_TAGS, b"");
    assert_eq!(
        selection,
        TraceSelection::CaptureEligible(HITRACE_HELP_FAMILY)
    );
    assert_eq!(tags, recorded_tags());
    assert_eq!(tags.len(), 81);
    let restamped = restamped(HITRACE_TAGS, "2026/09/14 08:30:00 ");
    assert_eq!(
        evaluate_tag_list(TraceTool::Hitrace, &restamped, b"").1,
        tags
    );
    let (selection, bytrace) = evaluate_tag_list(TraceTool::Bytrace, BYTRACE_TAGS, b"");
    assert_eq!(selection, TraceSelection::ProbeOnly(BYTRACE_HELP_FAMILY));
    assert!(!bytrace.is_empty());
    let mut drifted = HITRACE_TAGS.to_vec();
    drifted[200] ^= 0x20;
    for (tool, stdout, stderr) in [
        (TraceTool::Hitrace, BYTRACE_TAGS.to_vec(), &b""[..]),
        (TraceTool::Bytrace, HITRACE_TAGS.to_vec(), b""),
        (TraceTool::Hitrace, HITRACE_TAGS.to_vec(), b"note\n"),
        (TraceTool::Hitrace, drifted, b""),
        (TraceTool::Hitrace, HITRACE_HELP.to_vec(), b""),
    ] {
        assert_eq!(
            evaluate_tag_list(tool, &stdout, stderr),
            (TraceSelection::Unsupported, vec![])
        );
    }
}

#[test]
fn reads_are_fixed_target_bound_budgeted_and_concurrent() {
    // The two help reads and the nine parameter reads must all be in flight
    // together; the tag list follows both help reads.
    let initial = AtomicUsize::new(0);
    let helps_done = AtomicUsize::new(0);
    let barrier = Barrier::new(11);
    let answer = |command: &[&str]| {
        if command == ["shell", "hitrace", "-l"] {
            assert_eq!(helps_done.load(Ordering::SeqCst), 2);
            return device(command);
        }
        assert!(initial.fetch_add(1, Ordering::SeqCst) < 11);
        barrier.wait();
        let reply = device(command);
        if command.last() == Some(&"--help") {
            helps_done.fetch_add(1, Ordering::SeqCst);
        }
        reply
    };
    let dispatch = script(&answer);
    let probe = trace_probe(&dispatch, KEY).unwrap();
    assert_eq!(probe.adapter_disposition, "captureEligible");
    assert_eq!(probe.tool, Some("hitrace"));
    assert_eq!(probe.family, Some(HITRACE_HELP_FAMILY));
    assert_eq!(probe.supported_tags, recorded_tags());
    assert_eq!(
        probe.raw_help.as_deref(),
        Some(std::str::from_utf8(HITRACE_HELP).unwrap())
    );
    assert_eq!(
        probe.raw_help_sha256.as_deref(),
        Some("9ab0718d7da1d5beb459c74548f89cc69775a931be7931686637d6e584d70e39")
    );
    assert_eq!(
        probe
            .tools
            .each_ref()
            .map(|tool| (tool.tool, tool.disposition)),
        [("hitrace", "captureEligible"), ("bytrace", "probeOnly")]
    );
    assert_eq!(
        probe
            .parameters
            .iter()
            .map(|parameter| parameter.name)
            .collect::<Vec<_>>(),
        TRACE_PARAMETERS
    );
    assert!(
        probe
            .parameters
            .iter()
            .all(|parameter| parameter.value.as_deref() == Some("1"))
    );
    let plans = dispatch.plans.lock().unwrap();
    assert_eq!(plans.len(), 12);
    for plan in plans.iter() {
        assert_eq!(plan.timeout, Duration::from_secs(15));
        let parameter = plan.arguments[3] == "param";
        assert_eq!(
            plan.capture_bytes,
            if parameter { 4 * 1024 } else { 64 * 1024 }
        );
    }
    assert_eq!(
        plans.last().unwrap().arguments,
        ["-t", KEY, "shell", "hitrace", "-l"]
    );
}

#[test]
fn no_tag_list_is_read_unless_the_hitrace_help_is_registered() {
    let answer = |command: &[&str]| match command {
        ["shell", "hitrace", "--help"] => ok(b"hitrace: usage\n"),
        ["shell", "hitrace", "-l"] => panic!("the tag list must not be read"),
        _ => device(command),
    };
    let dispatch = script(&answer);
    let probe = trace_probe(&dispatch, KEY).unwrap();
    assert_eq!(probe.adapter_disposition, "unsupported");
    assert_eq!((probe.tool, probe.family), (None, None));
    assert!(probe.supported_tags.is_empty());
    assert_eq!(probe.raw_help.as_deref(), Some("hitrace: usage\n"));
    assert_eq!(probe.tools[0].disposition, "unrecognized");
    assert_eq!(probe.tools[1].disposition, "probeOnly");
    assert_eq!(dispatch.plans.lock().unwrap().len(), 11);
}

#[test]
fn a_help_read_that_cannot_complete_is_probe_failed_never_unrecognized() {
    for failure in [
        Err(DispatchFailure::Unobservable(
            "process timed out before completion".into(),
        )),
        Err(DispatchFailure::Refused(
            "dispatch refused: identity".into(),
        )),
        Ok(receipt(&HITRACE_HELP[..100], b"", 0, true)),
    ] {
        let answer = |command: &[&str]| match command {
            ["shell", "hitrace", "--help"] => failure.clone(),
            _ => device(command),
        };
        let probe = trace_probe(&script(&answer), KEY).unwrap();
        assert_eq!(probe.adapter_disposition, "unsupported");
        assert_eq!((probe.raw_help, probe.raw_help_sha256), (None, None));
        assert_eq!(probe.tools[0].disposition, "probeFailed");
        assert_eq!(
            probe.tools[0].detail,
            Some("read-only probe could not complete")
        );
        assert_eq!(probe.tools[0].raw_help_sha256, None);
    }
    // Only a stderr past its capture: Swift's runner kept the whole stdout.
    let answer = |command: &[&str]| match command {
        ["shell", "hitrace", "--help"] => Ok(receipt(HITRACE_HELP, &[b'e'; 65536], 0, true)),
        _ => device(command),
    };
    let probe = trace_probe(&script(&answer), KEY).unwrap();
    assert_eq!(probe.tools[0].disposition, "unrecognized");
    assert!(probe.raw_help.is_some());
}

#[test]
fn a_tag_list_that_cannot_be_read_fails_the_probe_with_swift_s_reason() {
    for (reply, reason) in [
        (
            Err(DispatchFailure::Unobservable(
                "process timed out before completion".into(),
            )),
            r#"outcomeUnknown("process timed out before completion")"#,
        ),
        (
            Err(DispatchFailure::Refused(
                "dispatch refused: it's gone".into(),
            )),
            r#"failed("dispatch refused: it\'s gone")"#,
        ),
        (
            Ok(receipt(HITRACE_TAGS, b"", 1, false)),
            "read-only HDC probe exited 1",
        ),
        (
            Ok(receipt(
                b"[Fail]ExecuteCommand need connect-key?\n",
                b"",
                0,
                false,
            )),
            "read-only HDC probe failed: HDC reported an explicit failure",
        ),
        (
            Ok(receipt(b"", b"device offline\n", 0, false)),
            "read-only HDC probe failed: target is offline",
        ),
        (
            Ok(receipt(&[b'x'; 65536], b"", 0, true)),
            "read-only HDC probe output was truncated",
        ),
    ] {
        let answer = |command: &[&str]| match command {
            ["shell", "hitrace", "-l"] => reply.clone(),
            _ => device(command),
        };
        let dispatch = script(&answer);
        assert_eq!(trace_probe(&dispatch, KEY), Err(reason.to_owned()));
        // Every parameter read was still made, and none twice.
        assert_eq!(dispatch.plans.lock().unwrap().len(), 12);
    }
    // A tag list the registry does not name is no authority, not a failure.
    let answer = |command: &[&str]| match command {
        ["shell", "hitrace", "-l"] => Ok(receipt(HITRACE_TAGS, b"note\n", 0, false)),
        _ => device(command),
    };
    let probe = trace_probe(&script(&answer), KEY).unwrap();
    assert_eq!(probe.adapter_disposition, "unsupported");
    assert!(probe.supported_tags.is_empty());
    assert_eq!(probe.tools[0].disposition, "captureEligible");
}

#[test]
fn each_parameter_is_judged_on_its_own_read() {
    // Swift's concurrent reads can leave a sibling of a hung read timed out
    // too (its spawns share descriptors); here only the read that ran past
    // its budget is unknown.
    let answer = |command: &[&str]| match command {
        ["shell", "param", "get", name] => match *name {
            "persist.ace.trace.syntax.enabled" => Err(DispatchFailure::Unobservable(
                "process timed out before completion".into(),
            )),
            "persist.ace.trace.layout.enabled" => {
                ok(format!("\u{feff}Get parameter \"{name}\" fail! errNum is:106!\n").as_bytes())
            }
            "persist.ace.trace.build.enabled" => ok(format!(
                "\u{feff}\u{feff}Get parameter \"{name}\" fail! errNum is:106!\n"
            )
            .as_bytes()),
            "persist.ace.trace.measure.debug.enabled" => {
                Ok(receipt(b"true\n", &[b'n'; 4096], 0, true))
            }
            "persist.ace.trace.sync.debug.enabled" => ok(b"\xef\xbb\xbf\n  \n"),
            "persist.ace.debug.enabled" => ok(&[b'y'; 400]),
            "persist.ace.performance.monitor.enabled" => ok(&[b'y'; 401]),
            "persist.sys.graphic.openDebugTrace" => Ok(receipt(b"1\n", b"", 139, false)),
            _ => ok(b"false\n"),
        },
        _ => device(command),
    };
    let probe = trace_probe(&script(&answer), KEY).unwrap();
    assert_eq!(
        states(&probe.parameters),
        [
            "unreadable",
            "missing",
            "unreadable",
            "value",
            "missing",
            "value",
            "unreadable",
            "unreadable",
            "value"
        ]
    );
    let details: Vec<_> = probe
        .parameters
        .iter()
        .map(|parameter| parameter.detail.as_deref())
        .collect();
    assert_eq!(
        details,
        [
            Some(r#"outcomeUnknown("process timed out before completion")"#),
            None,
            Some("read-only HDC probe failed: HDC reported an explicit failure"),
            None,
            None,
            None,
            Some("parameter value is oversized"),
            Some("read-only HDC probe exited 139"),
            None,
        ]
    );
    assert_eq!(probe.parameters[3].value.as_deref(), Some("true"));
    assert_eq!(probe.adapter_disposition, "captureEligible");
}
