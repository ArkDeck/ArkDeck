//! `job plan`: the request-file and flag forms, what they refuse, the client
//! deadline, the plan projection check and the zero-dispatch error mapping.
use arkdeck_cli::{CliError, job_plan_params, parse, validate_plan};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};
use std::path::PathBuf;

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

/// A scratch directory this test owns and removes.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-cli-job-plan-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn file(&self, name: &str, contents: &str) -> String {
        let path = self.0.join(name);
        std::fs::write(&path, contents).unwrap();
        path.to_str().unwrap().to_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn plan_document(argv: &[&str]) -> Result<Value, CliError> {
    let params = job_plan_params(&parse(&args(argv))?)?;
    assert_eq!(params.len(), 1);
    Ok(serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap())
}

#[test]
fn a_request_file_is_sent_verbatim_within_the_default_deadline() {
    let scratch = Scratch::new("verbatim");
    let text = "{ \"schemaVersion\" : \"1.0.0\" }\n";
    let path = scratch.file("request.json", text);
    let invocation = parse(&args(&["job", "plan", "--request-file", &path])).unwrap();
    assert_eq!(
        (invocation.command, invocation.method, invocation.timeout_ms),
        ("job.plan", "job.plan", Some(30_000))
    );
    assert_eq!(job_plan_params(&invocation).unwrap()["requestJson"], text);
    let bounded = parse(&args(&[
        "job",
        "plan",
        "--request-file",
        &path,
        "--timeout",
        "2s",
    ]))
    .unwrap();
    assert_eq!(bounded.timeout_ms, Some(2_000));
}

#[test]
fn the_flag_form_writes_the_current_request_envelope() {
    let scratch = Scratch::new("flags");
    let inputs = scratch.file(
        "inputs.json",
        r#"{"sourceArtifactRef":"lease-v1:job-a:ART-0"}"#,
    );
    let document = plan_document(&[
        "job",
        "plan",
        "--target",
        "TGT-ORACLE",
        "--operation",
        "analyzer.extract-crash-signature@1",
        "--inputs-file",
        &inputs,
        "--request-id",
        "req-cli",
        "--idempotency-key",
        "idem-cli-0001",
    ])
    .unwrap();
    assert_eq!(
        document,
        json!({
            "documentType": "runtime-operation-request",
            "schemaVersion": "1.0.0",
            "requestId": "req-cli",
            "idempotencyKey": "idem-cli-0001",
            "target": {"targetId": "TGT-ORACLE"},
            "operation": {"id": "analyzer.extract-crash-signature", "version": 1},
            "inputs": {"sourceArtifactRef": "lease-v1:job-a:ART-0"},
            "requestedOutputs": ["derivedArtifacts"],
        })
    );
    let pinned = plan_document(&[
        "job",
        "plan",
        "--target",
        "TGT-A",
        "--operation",
        "observe.device@1",
        "--expected-binding-revision",
        "3",
    ])
    .unwrap();
    assert_eq!(
        pinned["target"],
        json!({"targetId": "TGT-A", "expectedBindingRevision": 3})
    );
    assert_eq!(pinned["inputs"], json!({}));
    // A caller that fixes neither identity gets a generated pair, as the
    // Swift CLI generates one.
    let request_id = pinned["requestId"].as_str().unwrap();
    let key = pinned["idempotencyKey"].as_str().unwrap();
    assert!(request_id.len() == 12 && request_id.starts_with("cli-"));
    assert!(key.len() == 40 && key.starts_with("cli-") && key.as_bytes()[18] == b'4');
}

#[test]
fn both_forms_refuse_what_the_swift_cli_refuses() {
    let scratch = Scratch::new("refusals");
    let request = scratch.file("request.json", "{}");
    let refused = |argv: &[&str]| plan_document(argv).unwrap_err();
    let exclusive = refused(&[
        "job",
        "plan",
        "--request-file",
        &request,
        "--target",
        "TGT-A",
    ]);
    assert_eq!(
        (
            exclusive.code,
            exclusive.exit_code(),
            exclusive.message.as_str()
        ),
        (
            "invalidOption",
            64,
            "`job plan` accepts only one of --request-file, --target"
        )
    );
    assert_eq!(
        refused(&["job", "plan"]).message,
        "job plan requires --target <id> --operation <reference> [--inputs-file <typed-inputs.json>], or --request-file <path>"
    );
    let device = ["job", "plan", "--target", "TGT-A", "--operation"];
    assert_eq!(
        refused(
            &[
                &device[..],
                &["observe.device@1", "--expected-binding-revision", "0"]
            ]
            .concat()
        )
        .code,
        "invalidOption"
    );
    assert_eq!(
        refused(&[&device[..], &["observe.device@0"]].concat()).message,
        "invalid operation version"
    );
    assert_eq!(
        refused(&[&device[..], &["observe.device@1"]].concat()).message,
        "observe.device@1 is device-bound: pass --expected-binding-revision <n> (the revision `arkdeck target list` reports for this target)"
    );
    let analyzer = [
        "job",
        "plan",
        "--target",
        "TGT-A",
        "--operation",
        "analyzer.extract-crash-signature@1",
    ];
    assert_eq!(
        refused(&[&analyzer[..], &["--expected-binding-revision", "2"]].concat()).message,
        "analyzer.extract-crash-signature@1 is host-only: it has no binding revision to pin"
    );
    let whole = scratch.file("whole.json", r#"{"schemaVersion":"1.0.0","inputs":{}}"#);
    assert_eq!(
        refused(&[&analyzer[..], &["--inputs-file", &whole]].concat()).message,
        "--inputs-file looks like a complete request document; pass it with --request-file, or reduce it to the inputs object"
    );
    let list = scratch.file("list.json", "[]");
    assert!(
        refused(&[&analyzer[..], &["--inputs-file", &list]].concat())
            .message
            .starts_with("--inputs-file must be a JSON object of typed inputs: ")
    );
    let absent = scratch.0.join("absent.json");
    assert!(
        refused(&["job", "plan", "--request-file", absent.to_str().unwrap()])
            .message
            .starts_with("cannot read ")
    );
}

#[test]
fn only_a_complete_unadmitted_plan_projection_is_accepted() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../tests/fixtures/job-plan-analyzer/cases.json"
    ))
    .unwrap();
    let planned =
        cases.iter().find(|case| case["name"] == "planned").unwrap()["response"]["result"].clone();
    validate_plan(&planned).unwrap();
    for (field, value) in [
        ("jobAdmitted", json!(true)),
        ("dispatchDisposition", json!("dispatched")),
        ("materializedPlanDigest", json!("ABC")),
        ("stepSetDigestSHA256", json!("ABC")),
        ("bindingRevision", json!(0)),
        ("authorizationPolicy", json!("anything")),
        ("providerAdmissionBlocker", json!("")),
    ] {
        let mut changed = planned.clone();
        changed[field] = value;
        assert_eq!(
            validate_plan(&changed).unwrap_err().code,
            "recordUnreadable",
            "{field}"
        );
    }
    let mut with_review = planned.clone();
    with_review["stepSetDigestSHA256"] =
        json!("a06552647a3ebed582afc39bd534a856e40263d79623edd8b8bd85b1f476c509");
    validate_plan(&with_review).unwrap();
    arkdeck_contract::validate_method_value("job.plan", "result", &with_review).unwrap();
    let mut unknown = planned.clone();
    unknown["extra"] = json!(1);
    assert!(validate_plan(&unknown).is_err());
    let mut step = planned.clone();
    step["steps"][0]["optional"] = json!("no");
    assert_eq!(
        validate_plan(&step).unwrap_err().message,
        "the target Job plan contains an invalid step"
    );
}

#[test]
fn plan_refusals_keep_their_codes_only_with_zero_dispatch_proof() {
    let proof = json!({"phase": "preAdmission", "newDispatchCount": 0});
    for (code, expected, proven) in [
        ("invalidInput", "invalidInput", true),
        ("operationUnavailable", "operationUnavailable", true),
        ("inputTooLarge", "inputTooLarge", true),
        ("admissionDenied", "admissionDenied", true),
        ("rejected", "admissionDenied", true),
        ("operationUnavailable", "internalError", false),
        ("invalidInput", "internalError", false),
        ("rejected", "operationFailed", false),
    ] {
        let error = CliError::from_client(
            ClientError::Remote(WireError {
                code: code.into(),
                message: "refused".into(),
                details: proven.then(|| serde_json::from_value(proof.clone()).unwrap()),
            }),
            "job.plan",
        );
        assert_eq!(error.code, expected, "{code} proven={proven}");
    }
}
