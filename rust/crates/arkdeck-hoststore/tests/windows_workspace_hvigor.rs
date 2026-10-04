//! The Hvigor build and test presets on Windows (TASK-XPA-011, GJ-5): a
//! registered OpenHarmony project's Runtime-owned copy is built and tested
//! through the production dispatch, as the macOS build oracle drives its
//! planner, admitter and runner (`workspace_build_oracle.rs`).
//!
//! The preset's Node launcher is this test binary, copied into a toolchain
//! directory beside a pinned `hvigorw.js`: run with the script as its first
//! argument it answers as Hvigor does for `assembleHap` (the module's
//! unsigned HAP landed where the preset declares it) and `test`, and records
//! what its environment named. So the run measures:
//!
//! * the build of the copy plans, is admitted under the Runtime's own
//!   capability, runs Node with the preset's closed argv in the copy's root,
//!   and publishes the landed product as `unsigned.hap` with the build log;
//!   the child's environment is the clean base, the account's profile and
//!   temporary directories (`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`,
//!   `TMP`) and the composition's `DEVECO_SDK_HOME`;
//! * the test preset runs in the copy and publishes its report;
//! * the person's own tree is never built: it is refused before admission;
//! * a Hvigor script that changed after the composition pinned it is never
//!   run: the build fails before its child starts.
//!
//! No DevEco, SDK, device or credential is involved.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments
        .get(1)
        .is_some_and(|argument| argument.ends_with("hvigorw.js"))
    {
        windows::fake_hvigor(&arguments[1..]);
    }
    windows::run_tests(&arguments[1..]);
}

#[cfg(windows)]
mod windows {
    use arkdeck_contract::sha256_hex;
    use arkdeck_hoststore::{
        ArtifactReadStore, CapabilityStore, DeviceHolds, JobAdmitter, JobPlanner, JobResultReader,
        JobRunner, JobStore, MutationAuthority, MutationExecution, ProfilePresets,
        VerifiedResource, WorkspaceCommandPreset, WorkspaceComposition, WorkspaceProfile,
        hvigor_environment,
    };
    use serde_json::{Map, Value, json};
    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    const PROFILE: &str = "waterflow-openharmony@1";
    const PROJECT: &str = "HvigorProject";
    const DEBUG: &str = "waterflow-debug";
    const TESTS: &str = "waterflow-tests";
    const PRODUCT: &str = "entry/build/default/outputs/default/entry-default-unsigned.hap";
    const INDEX: &str = "entry/src/main/ets/pages/Index.ets";

    /// Hvigor for `assembleHap` and `test`: the product landed below the
    /// working directory (a ZIP local header, then what the environment
    /// named), or a report on stdout; anything else fails.
    pub fn fake_hvigor(arguments: &[String]) -> ! {
        let task = arguments.get(1).map(String::as_str).unwrap_or_default();
        let named = |key: &str| std::env::var(key).unwrap_or_else(|_| "<unset>".into());
        let environment = format!(
            "DEVECO_SDK_HOME={}\nUSERPROFILE={}\nTEMP={}\nHOME={}\nPATH={}\nNoDefaultCurrentDirectoryInExePath={}\n",
            named("DEVECO_SDK_HOME"),
            named("USERPROFILE"),
            named("TEMP"),
            named("HOME"),
            named("PATH"),
            named("NoDefaultCurrentDirectoryInExePath"),
        );
        match task {
            "assembleHap" => {
                let product = Path::new(PRODUCT);
                fs::create_dir_all(product.parent().unwrap()).unwrap();
                let mut bytes = b"PK\x03\x04".to_vec();
                bytes.extend(environment.as_bytes());
                fs::write(product, bytes).unwrap();
                println!("> hvigor BUILD SUCCESSFUL");
                std::process::exit(0);
            }
            "test" => {
                println!("> hvigor test: 1 passed");
                std::process::exit(0);
            }
            _ => std::process::exit(2),
        }
    }

    type Test = (&'static str, fn());
    const TESTS_RUN: &[Test] = &[(
        "a_copy_is_built_and_tested_through_the_pinned_node_and_hvigor_script",
        a_copy_is_built_and_tested_through_the_pinned_node_and_hvigor_script,
    )];

    pub fn run_tests(arguments: &[String]) -> ! {
        let filters: Vec<&String> = arguments
            .iter()
            .filter(|argument| !argument.starts_with('-'))
            .collect();
        if arguments.iter().any(|argument| argument == "--list") {
            for (name, _) in TESTS_RUN {
                println!("{name}: test");
            }
            std::process::exit(0);
        }
        let selected: Vec<&Test> = TESTS_RUN
            .iter()
            .filter(|(name, _)| {
                filters.is_empty() || filters.iter().any(|f| name.contains(f.as_str()))
            })
            .collect();
        println!("\nrunning {} tests", selected.len());
        let mut failed = 0;
        for (name, test) in &selected {
            let ok = std::panic::catch_unwind(test).is_ok();
            println!("test {name} ... {}", if ok { "ok" } else { "FAILED" });
            failed += usize::from(!ok);
        }
        println!(
            "\ntest result: {}. {} passed; {failed} failed; 0 ignored; 0 measured; 0 filtered out\n",
            if failed == 0 { "ok" } else { "FAILED" },
            selected.len() - failed
        );
        std::process::exit(if failed == 0 { 0 } else { 101 });
    }

    fn now() -> Option<String> {
        arkdeck_hoststore::runtime_now()
    }

    fn text(path: &Path) -> String {
        path.to_str().unwrap().to_owned()
    }

    /// A fresh directory below the temporary directory in its plain
    /// canonical spelling, removed afterwards.
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let temporary = std::env::temp_dir().canonicalize().unwrap();
            let temporary = text(&temporary);
            let temporary = temporary.strip_prefix(r"\\?\").unwrap_or(&temporary);
            let path = Path::new(temporary).join(format!("ad-winhvigor-{nonce:016x}"));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// The toolchain: this binary as Node, a pinned `hvigorw.js`, an SDK.
    struct Toolchain {
        node: PathBuf,
        hvigor: PathBuf,
        sdk: PathBuf,
        /// The pinned JDK's directory a registered Windows toolchain leads
        /// its Hvigor children's search path with.
        jdk: PathBuf,
    }

    fn toolchain(root: &Path) -> Toolchain {
        let tools = root.join("toolchain");
        fs::create_dir_all(tools.join("sdk")).unwrap();
        fs::create_dir_all(tools.join("jbr").join("bin")).unwrap();
        let node = tools.join("node.exe");
        fs::copy(std::env::current_exe().unwrap(), &node).unwrap();
        let hvigor = tools.join("hvigorw.js");
        fs::write(&hvigor, "// hvigor wrapper stand-in\n").unwrap();
        Toolchain {
            node,
            hvigor,
            sdk: tools.join("sdk"),
            jdk: tools.join("jbr").join("bin"),
        }
    }

    fn hvigor_preset(tools: &Toolchain, id: &str, task: &str) -> WorkspaceCommandPreset {
        let script = text(&tools.hvigor);
        let bytes = fs::read(&tools.hvigor).unwrap();
        WorkspaceCommandPreset::hashing_with_resources(
            id,
            &text(&tools.node),
            None,
            &[
                &script,
                task,
                "--mode",
                "module",
                "-p",
                "module=entry@default",
                "-p",
                "product=default",
                "-p",
                "buildMode=debug",
                "--analyze=normal",
                "--parallel",
                "--incremental",
                "--no-daemon",
            ],
            120,
            vec![VerifiedResource {
                path: script.clone(),
                sha256: sha256_hex(&bytes),
                byte_count: bytes.len() as u64,
                require_executable: false,
            }],
        )
        .unwrap()
    }

    fn profile(source: &Path, tools: &Toolchain) -> WorkspaceProfile {
        let node = text(&tools.node);
        let fixed = |id: &str| WorkspaceCommandPreset::hashing(id, &node, None, &[], 10).unwrap();
        WorkspaceProfile::primary(
            PROFILE,
            PROJECT,
            &text(source),
            &["entry/src/main/ets/**"],
            fixed("inspect"),
            fixed("patch"),
            ProfilePresets {
                build: vec![hvigor_preset(tools, DEBUG, "assembleHap")],
                test: vec![hvigor_preset(tools, TESTS, "test")],
                build_products: [(DEBUG.to_owned(), PRODUCT.to_owned())].into(),
                ..ProfilePresets::default()
            },
        )
        .unwrap()
    }

    /// The Runtime around one composition, as the macOS build oracle
    /// composes it: a capability store beside the Job state, no Session
    /// writer, no HDC.
    struct Owners {
        root: PathBuf,
        jobs: JobStore,
        artifacts: ArtifactReadStore,
        capabilities: CapabilityStore,
        holds: DeviceHolds,
        workspace: WorkspaceComposition,
    }

    impl Owners {
        fn new(root: &Path, workspace: WorkspaceComposition) -> Self {
            for owner in ["artifacts", "jobs-state"] {
                arkdeck_platform::HostDirectory::open_or_create_private(&root.join(owner)).unwrap();
            }
            Self {
                jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
                artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
                capabilities: CapabilityStore::open(&root.join("jobs-state").join("capabilities"))
                    .unwrap(),
                holds: DeviceHolds::default(),
                workspace,
                root: root.to_owned(),
            }
        }
        fn authority<'a>(&'a self, default_root: &'a Path) -> MutationAuthority<'a> {
            MutationAuthority {
                default_root,
                sessions: None,
                capabilities: &self.capabilities,
                holds: &self.holds,
            }
        }
        fn planner(&self) -> JobPlanner<'_> {
            JobPlanner {
                artifacts: Some(&self.artifacts),
                imports: None,
                analyzer: None,
                state_root: &self.root,
                hdc: None,
                workspace: Some(&self.workspace),
            }
        }
        fn plan(&self, params: &Value) -> Result<Value, String> {
            self.planner()
                .handle(params.as_object().unwrap())
                .map_err(|refusal| format!("{}: {}", refusal.code, refusal.message))
        }
        fn submit(&self, params: &Value) -> Result<String, String> {
            let default_root = self.root.join("jobs-state");
            let admitter = JobAdmitter {
                planner: self.planner(),
                jobs: &self.jobs,
                now,
                authority: Some(self.authority(&default_root)),
            };
            admitter
                .handle(params.as_object().unwrap())
                .map(|result| result["jobId"].as_str().unwrap().to_owned())
                .map_err(|refusal| format!("{}: {}", refusal.code, refusal.message))
        }
        fn run(&self, job: &str) -> Value {
            let default_root = self.root.join("jobs-state");
            let runner = JobRunner {
                mutation: Some(MutationExecution {
                    authority: self.authority(&default_root),
                    state_root: &self.root,
                }),
                jobs: &self.jobs,
                artifacts: &self.artifacts,
                imports: None,
                analyzer: None,
                quota: 8 * 1024 * 1024 * 1024,
                home: "C:\\nonexistent-home",
                now,
                precise_now: now,
                sessions: None,
                cancellation: None,
                after_commit: None,
                hdc: None,
                workspace: Some(&self.workspace),
            };
            runner
                .handle(json!({"jobId": job}).as_object().unwrap())
                .unwrap_or_else(|refusal| panic!("{}: {}", refusal.code, refusal.message))
        }
        fn result(&self, job: &str) -> Value {
            JobResultReader {
                jobs: &self.jobs,
                artifacts: &self.artifacts,
            }
            .handle("job.result", json!({"jobId": job}).as_object().unwrap())
            .unwrap()
        }
        /// The bytes of `job`'s derived Artifact `name`.
        fn artifact(&self, job: &str, name: &str) -> Vec<u8> {
            let result = self.result(job);
            let artifact = result["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .find(|artifact| artifact["name"] == name)
                .unwrap_or_else(|| panic!("{name} in {result}"));
            fs::read(
                self.root
                    .join("artifacts")
                    .join(job)
                    .join(artifact["artifactId"].as_str().unwrap()),
            )
            .unwrap()
        }
    }

    fn request(label: &str, operation: &str, inputs: Value) -> Value {
        json!({"requestJson": json!({
            "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
            "requestId": format!("request-{label}"),
            "idempotencyKey": format!("idempotency-{label}"),
            "target": {"targetId": "workspace-host"},
            "operation": {"id": operation, "version": 1},
            "inputs": inputs,
            "requestedOutputs": ["derivedArtifacts"],
        }).to_string()})
    }

    /// Swift's revision of a tree outside any git working copy.
    fn revision(files: &[(&str, &[u8])]) -> String {
        let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
        for (path, bytes) in files {
            material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
        }
        sha256_hex(material.as_bytes())
    }

    fn a_copy_is_built_and_tested_through_the_pinned_node_and_hvigor_script() {
        let root = Root::new();
        let source = root.0.join("source");
        for (path, bytes) in [
            ("build-profile.json5", "{}\n"),
            ("entry/src/main/module.json5", "{}\n"),
            (INDEX, "@Entry\n"),
        ] {
            let file = source.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, bytes).unwrap();
        }
        let tools = toolchain(&root.0);
        let profile = profile(&source, &tools);
        // What the composition gives a registered toolchain's Node children.
        let environment = hvigor_environment(&text(&tools.sdk));
        let overlay: Vec<(&str, &str)> = environment
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();
        let workspace = WorkspaceComposition::with_profiles(
            vec![profile],
            &root.0.join("evolution-workspaces"),
            now,
        )
        .unwrap()
        .with_child_environment(&text(&tools.node), &overlay)
        .with_child_search_directory(&text(&tools.node), &text(&tools.jdk));
        let owners = Owners::new(&root.0, workspace);

        // The copy of the whole scope.
        let base = revision(&[(INDEX, b"@Entry\n")]);
        let copy_job = owners
            .submit(&request(
                "copy",
                "workspace.prepare-isolated-copy",
                json!({"projectRef": PROJECT, "allowedFileGlobs": ["entry/src/main/ets/**"],
                    "expectedWorkspaceRevision": base}),
            ))
            .unwrap();
        assert_eq!(owners.run(&copy_job)["state"], "succeeded");
        let digest = sha256_hex(format!("runtime-{copy_job}|{PROJECT}|{base}").as_bytes());
        let (workspace_id, copy) = (
            format!("evo-{}", &digest[..24]),
            format!("evolution-{}", &digest[..20]),
        );
        let copy_root = root
            .0
            .join("evolution-workspaces")
            .join(&workspace_id)
            .join("workspace");

        // The build of the copy.
        let build = request(
            "build",
            "workspace.build-openharmony",
            json!({"projectRef": copy, "buildPresetRef": DEBUG}),
        );
        let planned = owners.plan(&build).unwrap();
        assert_eq!(planned["effectiveEffect"], "deviceMutation", "{planned}");
        let built = owners.submit(&build).unwrap();
        let ran = owners.run(&built);
        assert_eq!(ran["state"], "succeeded", "{ran}");
        let result = owners.result(&built);
        assert_eq!(result["evidence"]["status"], "verified", "{result}");
        assert_eq!(
            result["evidence"]["authority"]["kind"], "runtimeCapability",
            "{result}"
        );
        let landed = owners.artifact(&built, "unsigned.hap");
        assert!(landed.starts_with(b"PK"), "the landed HAP is published");
        let environment = String::from_utf8_lossy(&landed[4..]).into_owned();
        assert!(
            environment.contains(&format!("DEVECO_SDK_HOME={}\n", text(&tools.sdk))),
            "{environment}"
        );
        for key in ["USERPROFILE", "TEMP"] {
            let inherited = std::env::var(key).unwrap();
            assert!(
                environment.contains(&format!("{key}={inherited}\n")),
                "{key}: {environment}"
            );
        }
        assert!(environment.contains("HOME=<unset>\n"), "{environment}");
        // Node and `cmd.exe` never resolve a bare command in the copy.
        assert!(
            environment.contains("NoDefaultCurrentDirectoryInExePath=1\n"),
            "{environment}"
        );
        // The pinned JDK's directory, then the system directory: nothing else.
        let system =
            std::path::PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join("System32");
        assert!(
            environment.contains(&format!("PATH={};{}\n", text(&tools.jdk), text(&system))),
            "{environment}"
        );
        assert!(
            String::from_utf8_lossy(&owners.artifact(&built, "build.log"))
                .contains("BUILD SUCCESSFUL"),
            "the build log is the child's output"
        );

        // The test preset in the copy.
        let tests = request(
            "tests",
            "workspace.run-tests",
            json!({"projectRef": copy, "testPresetRef": TESTS}),
        );
        let tested = owners.submit(&tests).unwrap();
        let ran = owners.run(&tested);
        assert_eq!(ran["state"], "succeeded", "{ran}");

        // The person's own tree is never built.
        let primary = request(
            "primary",
            "workspace.build-openharmony",
            json!({"projectRef": PROJECT, "buildPresetRef": DEBUG}),
        );
        let refused = owners.submit(&primary).unwrap_err();
        assert!(refused.starts_with("admissionDenied"), "{refused}");
        assert!(!source.join(PRODUCT).exists());

        // A script that changed after the composition pinned it never runs.
        let _ = fs::remove_file(copy_root.join(PRODUCT));
        fs::write(&tools.hvigor, "// changed\n").unwrap();
        let again = request(
            "again",
            "workspace.build-openharmony",
            json!({"projectRef": copy, "buildPresetRef": DEBUG}),
        );
        match owners.submit(&again) {
            Err(refusal) => assert!(!refusal.is_empty()),
            Ok(job) => {
                let ran = owners.run(&job);
                assert_eq!(ran["state"], "failed", "{ran}");
            }
        }
        assert!(!copy_root.join(PRODUCT).exists(), "nothing was built");
        let _ = Map::<String, Value>::new();
        let _ = std::io::stdout().flush();
    }
}
