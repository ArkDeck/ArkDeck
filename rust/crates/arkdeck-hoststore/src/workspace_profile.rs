//! Swift `WorkspaceProjectProfile` and `WorkspaceProjectProfileRegistry`
//! (`WorkspaceOperationsProvider.swift`) for the Rust workspace provider
//! (TASK-XPA-015, M3): the closed profile a registered project resolves to,
//! the derived profile of a Runtime-owned isolated copy, the registry both
//! live in, and the availability, registration and authorization facts the
//! engine asks of them.
//!
//! A registered project's profile is built by its kind exactly as Swift's
//! composition root builds it (`arkDeck`, `waterFlowDemo`), with its code-owned
//! presets and pinned system tools, and — for an OpenHarmony project — the
//! Hvigor build presets registered through `workspace.preset.*` whose DevEco
//! toolchain resolved at start-up (`RegisteredBuildPreset`).
use crate::operation_catalog::CatalogOperation;
use crate::workspace_support::{
    self as support, foundation_resolved, foundation_standardized, is_identifier, is_safe_glob,
    is_safe_relative_path, is_sha256,
};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::{Mutex, OnceLock};

/// Why an operation is unavailable: the `operation.list` reason code Swift's
/// `RuntimeAvailabilityReasonCode` spells, and Swift's reason.
pub(crate) type Unavailability = (&'static str, String);

/// Swift `RuntimeAvailabilityReasonCode.workspacePresetUnavailable`.
pub(crate) const PRESET_UNAVAILABLE: &str = "workspace_preset_unavailable";

/// Swift `WorkspaceExecutableIdentity`: a canonical absolute path and the
/// SHA-256 of its bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecutableIdentity {
    path: String,
    sha256: String,
}

/// The file identity behind Swift's executable digest memo
/// (`RuntimeFileDerivedCaches.executableDigest`): a file whose identity has not
/// moved is not read again.
type FileIdentity = (String, u64, u64, u64, i64, i64, i64, i64);

fn digest_memo() -> &'static Mutex<HashMap<FileIdentity, String>> {
    static MEMO: OnceLock<Mutex<HashMap<FileIdentity, String>>> = OnceLock::new();
    MEMO.get_or_init(|| Mutex::new(HashMap::new()))
}

impl ExecutableIdentity {
    /// Swift `WorkspaceExecutableIdentity.hashing(path:)`.
    pub fn hashing(path: &str) -> Result<Self, String> {
        let canonical = foundation_standardized(path);
        let metadata = fs::metadata(&canonical).map_err(|error| format!("{canonical}: {error}"))?;
        let key = (
            canonical.clone(),
            metadata.dev(),
            metadata.ino(),
            metadata.size(),
            metadata.mtime(),
            metadata.mtime_nsec(),
            metadata.ctime(),
            metadata.ctime_nsec(),
        );
        if let Some(cached) = digest_memo()
            .lock()
            .ok()
            .and_then(|memo| memo.get(&key).cloned())
        {
            return Self::new(canonical, cached);
        }
        let bytes = fs::read(&canonical).map_err(|error| format!("{canonical}: {error}"))?;
        let digest = support::sha256(&bytes);
        if let Ok(mut memo) = digest_memo().lock() {
            memo.insert(key, digest.clone());
        }
        Self::new(canonical, digest)
    }

    /// Swift's initializer: canonical, absolute and a lowercase digest.
    fn new(path: String, sha256: String) -> Result<Self, String> {
        if !path.starts_with('/') || foundation_standardized(&path) != path {
            return Err("workspace executable path must be canonical and absolute".into());
        }
        if !is_sha256(&sha256) {
            return Err("workspace executable identity must be a lowercase SHA-256".into());
        }
        Ok(Self { path, sha256 })
    }
}

/// Swift `ResolvedExecutableResource`: a file a preset's executable reads,
/// pinned by its path, SHA-256 and length and held open while the child runs
/// (a registered toolchain's Hvigor script, its manifests).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VerifiedResource {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
    pub require_executable: bool,
}

/// Swift `WorkspaceCommandPreset`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceCommandPreset {
    preset_id: String,
    executable: ExecutableIdentity,
    argument_zero: Option<String>,
    fixed_arguments: Vec<String>,
    timeout_seconds: i64,
    verified_resources: Vec<VerifiedResource>,
}

impl WorkspaceCommandPreset {
    /// Swift's initializer over the executable at `path`, hashed.
    pub fn hashing(
        preset_id: &str,
        path: &str,
        argument_zero: Option<&str>,
        fixed_arguments: &[&str],
        timeout_seconds: i64,
    ) -> Result<Self, String> {
        Self::hashing_with_resources(
            preset_id,
            path,
            argument_zero,
            fixed_arguments,
            timeout_seconds,
            Vec::new(),
        )
    }

    /// Swift's initializer with the files the executable reads, each pinned
    /// by the caller (a registered toolchain's record).
    pub fn hashing_with_resources(
        preset_id: &str,
        path: &str,
        argument_zero: Option<&str>,
        fixed_arguments: &[&str],
        timeout_seconds: i64,
        verified_resources: Vec<VerifiedResource>,
    ) -> Result<Self, String> {
        Self::new(
            preset_id,
            ExecutableIdentity::hashing(path)?,
            argument_zero.map(str::to_owned),
            fixed_arguments.iter().map(|&a| a.to_owned()).collect(),
            timeout_seconds,
            verified_resources,
        )
    }

    fn new(
        preset_id: &str,
        executable: ExecutableIdentity,
        argument_zero: Option<String>,
        fixed_arguments: Vec<String>,
        timeout_seconds: i64,
        verified_resources: Vec<VerifiedResource>,
    ) -> Result<Self, String> {
        if !is_identifier(preset_id) {
            return Err("workspace preset id is malformed".into());
        }
        if !(1..=7_200).contains(&timeout_seconds) {
            return Err("workspace preset timeout is outside 1...7200".into());
        }
        let bounded = |value: &str| !value.contains('\0') && value.len() <= 4_096;
        let mut paths: Vec<&str> = verified_resources.iter().map(|r| r.path.as_str()).collect();
        paths.sort_unstable();
        paths.dedup();
        if !argument_zero
            .as_deref()
            .is_none_or(|zero| !zero.is_empty() && bounded(zero))
            || fixed_arguments.len() > 128
            || !fixed_arguments.iter().all(|argument| bounded(argument))
            || verified_resources.len() > 16
            || paths.len() != verified_resources.len()
            || !verified_resources.iter().all(|resource| {
                resource.path.starts_with('/')
                    && foundation_standardized(&resource.path) == resource.path
                    && is_sha256(&resource.sha256)
                    && resource.byte_count > 0
            })
        {
            return Err("workspace preset arguments or verified resources are not bounded".into());
        }
        Ok(Self {
            preset_id: preset_id.into(),
            executable,
            argument_zero,
            fixed_arguments,
            timeout_seconds,
            verified_resources,
        })
    }

    /// Swift `EvolutionWorkspaceManager.derivedProfile`'s `rebased`: every
    /// argument naming the source root names the copy's instead. Like Swift's,
    /// the rebased preset keeps no verified resources of its own: a dispatch
    /// holds the resources the start-up profiles pinned for its executable.
    fn rebased(&self, source: &str, destination: &str) -> Result<Self, String> {
        let rebase = |value: &String| {
            if value == source {
                destination.to_owned()
            } else if let Some(rest) = value.strip_prefix(&format!("{source}/")) {
                format!("{destination}/{rest}")
            } else {
                value.clone()
            }
        };
        Self::new(
            &self.preset_id,
            self.executable.clone(),
            self.argument_zero.clone(),
            self.fixed_arguments.iter().map(rebase).collect(),
            self.timeout_seconds,
            Vec::new(),
        )
    }
}

/// Swift `WorkspaceSigningPreset`: a registered signing preset — a closed
/// identity, the credential it pinned by content reference, a timeout. It is
/// not a path, a key alias or a secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SigningPresetRef {
    pub(crate) preset_id: String,
    pub(crate) credential_ref: String,
    pub(crate) timeout_seconds: i64,
}

impl SigningPresetRef {
    /// Swift's initializer: an identifier, a `credential:sha256-` reference,
    /// a timeout within 1...3600 seconds.
    pub fn new(
        preset_id: &str,
        credential_ref: &str,
        timeout_seconds: i64,
    ) -> Result<Self, String> {
        let digest = credential_ref.strip_prefix("credential:sha256-");
        if !is_identifier(preset_id)
            || !digest.is_some_and(is_sha256)
            || !(1..=3_600).contains(&timeout_seconds)
        {
            return Err("workspace signing preset is malformed".into());
        }
        Ok(Self {
            preset_id: preset_id.into(),
            credential_ref: credential_ref.into(),
            timeout_seconds,
        })
    }
}

/// Swift `WorkspaceProjectProfileKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileKind {
    Primary,
    /// A Runtime-owned isolated copy of a primary project.
    Evolution,
}

/// Swift `WorkspaceProjectProfile`. The host root and the executables stay in
/// the Runtime; no projection publishes them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceProfile {
    pub(crate) profile_id: String,
    pub(crate) project_ref: String,
    pub(crate) project_root: String,
    pub(crate) allowed_file_globs: Vec<String>,
    inspection: WorkspaceCommandPreset,
    source_control: Option<WorkspaceCommandPreset>,
    source_reader: Option<WorkspaceCommandPreset>,
    archive_checkpoint: Option<WorkspaceCommandPreset>,
    patch: WorkspaceCommandPreset,
    build: BTreeMap<String, WorkspaceCommandPreset>,
    test: BTreeMap<String, WorkspaceCommandPreset>,
    symbol: BTreeMap<String, WorkspaceCommandPreset>,
    build_products: BTreeMap<String, String>,
    /// Swift `signingPresets`: the registered signing presets, by reference.
    pub(crate) signing: BTreeMap<String, SigningPresetRef>,
    /// Swift `allowsLegacySigningPresetFallback`: whether a profile with no
    /// registered signing preset may sign with the installed receipt named by
    /// its fixed preset identity. A registered project never may.
    pub(crate) allows_legacy_signing: bool,
    pub(crate) kind: ProfileKind,
    pub(crate) source_project_ref: Option<String>,
}

/// The optional presets of a profile, by role.
#[derive(Clone, Debug, Default)]
pub struct ProfilePresets {
    pub source_control: Option<WorkspaceCommandPreset>,
    pub source_reader: Option<WorkspaceCommandPreset>,
    pub archive_checkpoint: Option<WorkspaceCommandPreset>,
    pub build: Vec<WorkspaceCommandPreset>,
    pub test: Vec<WorkspaceCommandPreset>,
    pub symbol: Vec<WorkspaceCommandPreset>,
    pub build_products: BTreeMap<String, String>,
}

fn keyed(presets: Vec<WorkspaceCommandPreset>) -> BTreeMap<String, WorkspaceCommandPreset> {
    presets
        .into_iter()
        .map(|preset| (preset.preset_id.clone(), preset))
        .collect()
}

impl WorkspaceProfile {
    /// Swift's initializer for a primary profile.
    pub fn primary(
        profile_id: &str,
        project_ref: &str,
        project_root: &str,
        allowed_file_globs: &[&str],
        inspection: WorkspaceCommandPreset,
        patch: WorkspaceCommandPreset,
        presets: ProfilePresets,
    ) -> Result<Self, String> {
        Self::validated(Self {
            profile_id: profile_id.into(),
            project_ref: project_ref.into(),
            project_root: project_root.into(),
            allowed_file_globs: allowed_file_globs.iter().map(|&g| g.into()).collect(),
            inspection,
            source_control: presets.source_control,
            source_reader: presets.source_reader,
            archive_checkpoint: presets.archive_checkpoint,
            patch,
            build: keyed(presets.build),
            test: keyed(presets.test),
            symbol: keyed(presets.symbol),
            build_products: presets.build_products,
            signing: BTreeMap::new(),
            allows_legacy_signing: true,
            kind: ProfileKind::Primary,
            source_project_ref: None,
        })
    }

    /// The same profile with its registered signing presets, and whether it
    /// may fall back to the installed receipt when it has none (Swift's
    /// `signingPresets` and `allowsLegacySigningPresetFallback`).
    pub fn with_signing(
        mut self,
        presets: Vec<SigningPresetRef>,
        allows_legacy_signing: bool,
    ) -> Self {
        self.signing = presets
            .into_iter()
            .map(|preset| (preset.preset_id.clone(), preset))
            .collect();
        self.allows_legacy_signing = allows_legacy_signing;
        self
    }

    /// Swift `WorkspaceProjectProfile.init`'s checks, the root made
    /// canonical as Foundation resolves it.
    fn validated(mut profile: Self) -> Result<Self, String> {
        let canonical = foundation_resolved(&profile.project_root);
        if !profile.project_root.starts_with('/')
            || !fs::metadata(&canonical).is_ok_and(|metadata| metadata.is_dir())
        {
            return Err("workspace project root must be an existing canonical directory".into());
        }
        let malformed = !is_identifier(&profile.profile_id)
            || !is_identifier(&profile.project_ref)
            || profile.allowed_file_globs.is_empty()
            || profile.allowed_file_globs.len() > 64
            || !profile.allowed_file_globs.iter().all(|g| is_safe_glob(g))
            || !profile
                .build_products
                .keys()
                .all(|preset| profile.build.contains_key(preset))
            || !profile
                .build_products
                .values()
                .all(|path| is_safe_relative_path(path))
            || !profile
                .source_project_ref
                .as_deref()
                .is_none_or(is_identifier)
            || profile.source_project_ref.as_deref() == Some(profile.project_ref.as_str());
        if malformed {
            return Err("workspace ProjectProfile is malformed".into());
        }
        profile.project_root = canonical;
        Ok(profile)
    }

    /// Swift `WorkspaceProjectProfile.arkDeck(rootURL:projectRef:)`.
    pub fn ark_deck(root: &str, project_ref: &str) -> Result<Self, String> {
        let root = foundation_resolved(root);
        let grep =
            WorkspaceCommandPreset::hashing("source-inspection", "/usr/bin/grep", None, &[], 30)?;
        let patch =
            WorkspaceCommandPreset::hashing("unified-diff", "/usr/bin/patch", None, &[], 120)?;
        let source_control = if fs::metadata(format!("{root}/.git")).is_ok() {
            Some(WorkspaceCommandPreset::hashing(
                "git",
                "/usr/bin/git",
                None,
                &[],
                120,
            )?)
        } else {
            None
        };
        let swift_package = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-package",
            "/Library/Developer/CommandLineTools/usr/bin/swift-package",
        ]
        .into_iter()
        .find(|path| {
            fs::metadata(path)
                .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        })
        .ok_or("workspace.toolchainUnavailable: no fixed SwiftPM executable exists")?;
        let bin = &swift_package[..swift_package.rfind('/').unwrap_or(0)];
        let (build_role, test_role) = (format!("{bin}/swift-build"), format!("{bin}/swift-test"));
        if fs::metadata(&build_role).is_err() || fs::metadata(&test_role).is_err() {
            return Err("workspace.toolchainUnavailable: SwiftPM role links are absent".into());
        }
        let package = format!("{root}/Packages/ArkDeckKit");
        if fs::metadata(format!("{package}/Package.swift")).is_err() {
            return Err(
                "workspace.projectProfileUnavailable: ArkDeck Package.swift is absent".into(),
            );
        }
        let build = WorkspaceCommandPreset::hashing(
            "arkdeck-debug",
            swift_package,
            Some(&build_role),
            &["--package-path", &package],
            900,
        )?;
        let tests = WorkspaceCommandPreset::hashing(
            "arkdeck-tests",
            swift_package,
            Some(&test_role),
            &[
                "--package-path",
                &package,
                "--skip",
                "ArkDeckContractTests.AgentDaemonContractTests/testDaemonBinaryStaysAliveAndServesRequests",
            ],
            900,
        )?;
        Self::primary(
            "workspace-host@1",
            project_ref,
            &root,
            &["Packages/ArkDeckKit/**", "Catalog/**", "docs/**"],
            grep,
            patch,
            ProfilePresets {
                source_control,
                build: vec![build],
                test: vec![tests],
                ..ProfilePresets::default()
            },
        )
    }

    /// Swift `WorkspaceProjectProfile.waterFlowDemo(rootURL:projectRef:...)`
    /// for a registered project with no registered preset resolved.
    pub fn water_flow(root: &str, project_ref: &str, home: &str) -> Result<Self, String> {
        Self::water_flow_with(root, project_ref, home, &[])
    }

    /// Swift `waterFlowDemo(rootURL:projectRef:registeredPresets:)` for a
    /// registered project: its code-owned tools, and the Hvigor build and test
    /// presets registered against it whose DevEco toolchain resolved, each as
    /// Node running the pinned `hvigorw.js` with the preset's closed argv.
    pub fn water_flow_with(
        root: &str,
        project_ref: &str,
        home: &str,
        registered: &[RegisteredBuildPreset],
    ) -> Result<Self, String> {
        Self::water_flow_registered(root, project_ref, home, registered, Vec::new())
    }

    /// `water_flow_with`, and the signing presets registered against the
    /// project whose credential resolved. A registered project never falls
    /// back to the installed receipt, as Swift's registered profile does not.
    pub fn water_flow_registered(
        root: &str,
        project_ref: &str,
        home: &str,
        registered: &[RegisteredBuildPreset],
        signing: Vec<SigningPresetRef>,
    ) -> Result<Self, String> {
        let root = foundation_resolved(root);
        let home = foundation_standardized(home);
        if ["Desktop", "Documents", "Downloads"].iter().any(|folder| {
            let protected = foundation_standardized(&format!("{home}/{folder}"));
            root == protected || root.starts_with(&format!("{protected}/"))
        }) {
            return Err(
                "workspace.projectProfileUnavailable: project root is under a macOS \
                        privacy-managed user folder; configure a LaunchAgent-readable path"
                    .into(),
            );
        }
        if fs::metadata(format!("{root}/build-profile.json5")).is_err()
            || fs::metadata(format!("{root}/entry/src/main/module.json5")).is_err()
        {
            return Err(
                "workspace.projectProfileUnavailable: WaterFlow project or Hvigor is absent".into(),
            );
        }
        let inspection =
            WorkspaceCommandPreset::hashing("source-inspection", "/usr/bin/grep", None, &[], 30)?;
        let reader =
            WorkspaceCommandPreset::hashing("source-range", "/usr/bin/sed", None, &[], 30)?;
        let patch =
            WorkspaceCommandPreset::hashing("unified-diff", "/usr/bin/patch", None, &[], 120)?;
        let checkpoint = WorkspaceCommandPreset::hashing(
            "sealed-source-archive",
            "/usr/bin/bsdtar",
            None,
            &[],
            120,
        )?;
        let source_control = if inside_git_working_copy(&root) {
            Some(WorkspaceCommandPreset::hashing(
                "git",
                "/usr/bin/git",
                None,
                &[],
                120,
            )?)
        } else {
            None
        };
        let mut build = Vec::new();
        let mut test = Vec::new();
        let mut build_products = BTreeMap::new();
        for preset in registered {
            let hvigor = foundation_resolved(&preset.hvigor_script_path);
            if !preset.node_path.starts_with('/')
                || !preset.hvigor_script_path.starts_with('/')
                || fs::metadata(&hvigor).is_err()
            {
                return Err(
                    "workspace.presetUnavailable: registered Hvigor toolchain drifted".into(),
                );
            }
            let (module, product, mode) = (&preset.module, &preset.product, &preset.build_mode);
            let (module_product, product_argument, mode_argument) = (
                format!("module={module}@{product}"),
                format!("product={product}"),
                format!("buildMode={mode}"),
            );
            let task = if preset.kind == RegisteredKind::Build {
                "assembleHap"
            } else {
                "test"
            };
            let command = WorkspaceCommandPreset::hashing_with_resources(
                &preset.preset_ref,
                &preset.node_path,
                None,
                &[
                    &hvigor,
                    task,
                    "--mode",
                    "module",
                    "-p",
                    &module_product,
                    "-p",
                    &product_argument,
                    "-p",
                    &mode_argument,
                    "--analyze=normal",
                    "--parallel",
                    "--incremental",
                    "--no-daemon",
                ],
                preset.timeout_seconds,
                preset.verified_resources.clone(),
            )?;
            if preset.kind == RegisteredKind::Build {
                build_products.insert(
                    preset.preset_ref.clone(),
                    format!(
                        "{module}/build/{product}/outputs/{product}/{module}-{product}-unsigned.hap"
                    ),
                );
                build.push(command);
            } else {
                test.push(command);
            }
        }
        Self::primary(
            "waterflow-openharmony@1",
            project_ref,
            &root,
            &[
                "entry/src/main/ets/**",
                "entry/src/main/cpp/**",
                "entry/src/test/**",
                "entry/src/ohosTest/**",
            ],
            inspection,
            patch,
            ProfilePresets {
                source_control,
                source_reader: Some(reader),
                archive_checkpoint: Some(checkpoint),
                build,
                test,
                build_products,
                ..ProfilePresets::default()
            },
        )
        .map(|profile| profile.with_signing(signing, false))
    }

    /// Swift `EvolutionWorkspaceManager.derivedProfile`: the copy is never a
    /// source-control authority, and every preset names the copy's root.
    pub(crate) fn derived(
        &self,
        workspace_root: &str,
        project_ref: &str,
        allowed_paths: &[String],
    ) -> Result<Self, String> {
        let rebased =
            |preset: &WorkspaceCommandPreset| preset.rebased(&self.project_root, workspace_root);
        let rebased_map = |presets: &BTreeMap<String, WorkspaceCommandPreset>| {
            presets
                .iter()
                .map(|(key, preset)| Ok((key.clone(), rebased(preset)?)))
                .collect::<Result<BTreeMap<_, _>, String>>()
        };
        Self::validated(Self {
            profile_id: self.profile_id.clone(),
            project_ref: project_ref.into(),
            project_root: workspace_root.into(),
            allowed_file_globs: allowed_paths.to_vec(),
            inspection: rebased(&self.inspection)?,
            source_control: None,
            source_reader: self.source_reader.as_ref().map(rebased).transpose()?,
            archive_checkpoint: self.archive_checkpoint.as_ref().map(rebased).transpose()?,
            patch: rebased(&self.patch)?,
            build: rebased_map(&self.build)?,
            test: rebased_map(&self.test)?,
            symbol: rebased_map(&self.symbol)?,
            build_products: self.build_products.clone(),
            signing: self.signing.clone(),
            allows_legacy_signing: self.allows_legacy_signing,
            kind: ProfileKind::Evolution,
            source_project_ref: Some(self.project_ref.clone()),
        })
    }

    /// Swift `executableIdentities`: every command preset's executable, once.
    fn executable_identities(&self) -> Vec<&ExecutableIdentity> {
        let mut identities: Vec<&ExecutableIdentity> = Vec::new();
        let presets = [Some(&self.inspection), Some(&self.patch)]
            .into_iter()
            .chain([
                self.source_control.as_ref(),
                self.source_reader.as_ref(),
                self.archive_checkpoint.as_ref(),
            ])
            .flatten()
            .chain(self.build.values())
            .chain(self.test.values())
            .chain(self.symbol.values());
        for preset in presets {
            if !identities.contains(&&preset.executable) {
                identities.push(&preset.executable);
            }
        }
        identities
    }

    /// Swift `runtimeAvailability(for:profile:)`: why the operation cannot
    /// run in this profile, as `operation.list` codes it, if it cannot.
    /// Signing is judged by the composition, which holds the credential
    /// owner.
    pub(crate) fn unavailability(
        &self,
        reference: &str,
        isolation: bool,
    ) -> Option<Unavailability> {
        let has_preset = match reference {
            "workspace.prepare-isolated-copy@1" | "workspace.sweep-isolated-copies@1" => {
                isolation && self.kind == ProfileKind::Primary
            }
            // Every profile carries its patch preset.
            "workspace.apply-patch@1" | "workspace.revert-patch@1" => true,
            "workspace.build-openharmony@1" => !self.build.is_empty(),
            "workspace.run-tests@1" => !self.test.is_empty(),
            "workspace.symbolize-crash@1" => {
                if self.symbol.is_empty() {
                    return Some((
                        PRESET_UNAVAILABLE,
                        "workspace.symbolPresetUnavailable".into(),
                    ));
                }
                true
            }
            "workspace.inspect-git-status@1" | "workspace.inspect-diff@1" => {
                self.source_control.is_some()
            }
            "workspace.create-checkpoint@1" => {
                self.source_control.is_some() || self.archive_checkpoint.is_some()
            }
            "workspace.inspect-source@1" => true,
            "workspace.read-source-range@1" => self.source_reader.is_some(),
            _ => {
                return Some((
                    "operation_not_supported",
                    "workspace.unsupportedOperation".into(),
                ));
            }
        };
        self.preset_unavailability(has_preset)
    }

    /// The rest of Swift's `runtimeAvailability(for:profile:)` once whether
    /// the profile has a preset for the operation is known: a preset, then
    /// every pinned executable measuring as pinned.
    pub(crate) fn preset_unavailability(&self, has_preset: bool) -> Option<Unavailability> {
        if !has_preset {
            return Some((PRESET_UNAVAILABLE, "workspace.presetUnavailable".into()));
        }
        for identity in self.executable_identities() {
            match ExecutableIdentity::hashing(&identity.path) {
                Ok(measured) if measured.sha256 == identity.sha256 => {}
                Ok(_) => {
                    return Some(("tool_identity_drift", "workspace.toolIdentityDrift".into()));
                }
                Err(_) => {
                    return Some((
                        "provider_tool_unavailable",
                        "workspace.toolchainUnavailable".into(),
                    ));
                }
            }
        }
        None
    }

    /// Swift `resolved(operation:preset:arguments:)`: the preset's fixed
    /// arguments, then `arguments`, run by the executable the preset pinned,
    /// in this profile's root.
    fn invocation_of(
        &self,
        preset: &WorkspaceCommandPreset,
        operation: &str,
        arguments: &[&str],
    ) -> crate::workspace_patch::Invocation {
        let mut argv = preset.fixed_arguments.clone();
        argv.extend(arguments.iter().map(|&argument| argument.to_owned()));
        crate::workspace_patch::Invocation {
            operation: operation.into(),
            project_ref: self.project_ref.clone(),
            project_root: self.project_root.clone(),
            preset_id: preset.preset_id.clone(),
            executable_path: preset.executable.path.clone(),
            executable_sha256: preset.executable.sha256.clone(),
            argument_zero: preset.argument_zero.clone(),
            arguments: argv,
            timeout_seconds: preset.timeout_seconds,
        }
    }

    /// Swift `resolved(operation:preset:arguments:)` over the patch preset.
    pub(crate) fn patch_invocation(
        &self,
        operation: &str,
        arguments: &[&str],
    ) -> crate::workspace_patch::Invocation {
        self.invocation_of(&self.patch, operation, arguments)
    }

    /// Swift `resolved(operation:preset:arguments:)` over the pinned
    /// source-control tool; `None` when the profile has none.
    pub(crate) fn source_control_invocation(
        &self,
        operation: &str,
        arguments: &[&str],
    ) -> Option<crate::workspace_patch::Invocation> {
        let preset = self.source_control.as_ref()?;
        Some(self.invocation_of(preset, operation, arguments))
    }

    /// Swift `resolved(operation:preset:arguments:)` over the pinned source
    /// reader; `None` when the profile has none.
    pub(crate) fn source_reader_invocation(
        &self,
        operation: &str,
        arguments: &[&str],
    ) -> Option<crate::workspace_patch::Invocation> {
        let preset = self.source_reader.as_ref()?;
        Some(self.invocation_of(preset, operation, arguments))
    }

    /// Swift `resolved(operation:preset:arguments:)` over a build preset: its
    /// own closed argv, run by the executable it pinned; `None` when the
    /// profile declares no such preset.
    pub(crate) fn build_invocation(
        &self,
        operation: &str,
        preset_id: &str,
    ) -> Option<crate::workspace_patch::Invocation> {
        let preset = self.build.get(preset_id)?;
        Some(crate::workspace_patch::Invocation {
            operation: operation.into(),
            project_ref: self.project_ref.clone(),
            project_root: self.project_root.clone(),
            preset_id: preset.preset_id.clone(),
            executable_path: preset.executable.path.clone(),
            executable_sha256: preset.executable.sha256.clone(),
            argument_zero: preset.argument_zero.clone(),
            arguments: preset.fixed_arguments.clone(),
            timeout_seconds: preset.timeout_seconds,
        })
    }

    /// The deployable product a build preset declares, relative to the root.
    pub(crate) fn build_product(&self, preset_id: &str) -> Option<&str> {
        self.build_products.get(preset_id).map(String::as_str)
    }

    /// Swift `WorkspaceActionExecutableResolver.resourcesByExecutable`: every
    /// verified resource the presets of these profiles pin for each executable,
    /// once, in path order.
    pub(crate) fn resources_by_executable(
        profiles: &[WorkspaceProfile],
    ) -> BTreeMap<(String, String), Vec<VerifiedResource>> {
        let mut resources: BTreeMap<(String, String), Vec<VerifiedResource>> = BTreeMap::new();
        for profile in profiles {
            let presets = [Some(&profile.inspection), Some(&profile.patch)]
                .into_iter()
                .chain([
                    profile.source_control.as_ref(),
                    profile.source_reader.as_ref(),
                    profile.archive_checkpoint.as_ref(),
                ])
                .flatten()
                .chain(profile.build.values())
                .chain(profile.test.values())
                .chain(profile.symbol.values());
            for preset in presets {
                let key = (
                    preset.executable.path.clone(),
                    preset.executable.sha256.clone(),
                );
                let entry = resources.entry(key).or_default();
                for resource in &preset.verified_resources {
                    if !entry.contains(resource) {
                        entry.push(resource.clone());
                    }
                }
                entry.sort_by(|a, b| (&a.path, &a.sha256).cmp(&(&b.path, &b.sha256)));
            }
        }
        resources
    }

    /// Swift `profile.executableIdentities.contains(invocation.executable)`:
    /// whether an invocation's executable is one this profile pinned.
    pub(crate) fn owns_executable(&self, path: &str, sha256: &str) -> bool {
        self.executable_identities()
            .iter()
            .any(|identity| identity.path == path && identity.sha256 == sha256)
    }

    /// Swift `workspaceAuthorizationFacts`: which tree this is, what it holds
    /// now, the profile's own scope, and whether it is a Runtime-owned copy.
    pub(crate) fn authorization_facts(&self) -> Result<WorkspaceAuthorizationFacts, String> {
        let mut globs = self.allowed_file_globs.clone();
        support::swift_sort(&mut globs);
        Ok(WorkspaceAuthorizationFacts {
            identity_sha256: support::sha256(
                format!(
                    "arkdeck-workspace|{}|{}",
                    self.profile_id, self.project_root
                )
                .as_bytes(),
            ),
            revision: support::workspace_revision(
                &self.project_root,
                &self.profile_id,
                &self.allowed_file_globs,
            )?,
            file_scopes_digest: support::sha256(globs.join("\n").as_bytes()),
            isolated_task_copy: self.kind == ProfileKind::Evolution,
        })
    }
}

/// Swift `WorkspaceProjectProfile.isInsideGitWorkingCopy`: the root or any
/// ancestor holds `.git`.
fn inside_git_working_copy(root: &str) -> bool {
    let mut current = foundation_standardized(root);
    loop {
        if fs::metadata(format!("{}/.git", current.trim_end_matches('/'))).is_ok() {
            return true;
        }
        let parent = match current.rfind('/') {
            Some(0) | None => "/".to_owned(),
            Some(index) => current[..index].to_owned(),
        };
        let parent = foundation_standardized(&parent);
        if parent == current {
            return false;
        }
        current = parent;
    }
}

/// Swift `WorkspaceAuthorizationFacts`: what a workspace-scoped capability
/// is matched against.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkspaceAuthorizationFacts {
    pub(crate) identity_sha256: String,
    pub(crate) revision: String,
    pub(crate) file_scopes_digest: String,
    pub(crate) isolated_task_copy: bool,
}

/// Swift `preauthorize`'s issuance rule for a standing-capability mutation
/// the caller names no capability for: a device subject follows the
/// catalog's `defaultPolicyIssuance`; a workspace subject is issued one only
/// when it is a Runtime-owned isolated copy. A person's primary tree always
/// needs a capability a person issued, whatever the catalog says.
pub(crate) fn automatic_issuance_permitted(
    descriptor: &CatalogOperation,
    workspace: Option<&WorkspaceAuthorizationFacts>,
) -> bool {
    match workspace {
        None => descriptor.default_policy_issuance(),
        Some(facts) => facts.isolated_task_copy,
    }
}

/// Which registered Hvigor task a preset runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegisteredKind {
    Build,
    Test,
}

/// Swift `RuntimeWorkspaceResolvedPreset` for a registered Hvigor preset: the
/// preset's closed constraints and the DevEco toolchain its pin resolved to —
/// the Node launcher, the Hvigor script and every other file the record pins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RegisteredBuildPreset {
    pub kind: RegisteredKind,
    pub preset_ref: String,
    pub module: String,
    pub product: String,
    pub build_mode: String,
    pub timeout_seconds: i64,
    pub node_path: String,
    pub hvigor_script_path: String,
    pub sdk_root_path: String,
    pub verified_resources: Vec<VerifiedResource>,
}

/// Swift `WorkspaceProjectProfileRegistry`: every resolvable profile by its
/// reference.
#[derive(Default)]
pub(crate) struct ProfileRegistry {
    profiles: Mutex<BTreeMap<String, WorkspaceProfile>>,
}

impl ProfileRegistry {
    pub(crate) fn profile(&self, reference: &str) -> Option<WorkspaceProfile> {
        self.profiles.lock().ok()?.get(reference).cloned()
    }

    /// Swift `register`: a reference that already resolves to a different
    /// profile is an error, never an overwrite.
    pub(crate) fn register(&self, profile: WorkspaceProfile) -> Result<(), String> {
        let mut profiles = self
            .profiles
            .lock()
            .map_err(|_| "workspace profile registry is unavailable".to_owned())?;
        if let Some(existing) = profiles.get(&profile.project_ref) {
            if *existing != profile {
                return Err("workspace projectRef already resolves to another profile".into());
            }
            return Ok(());
        }
        profiles.insert(profile.project_ref.clone(), profile);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary(label: &str) -> String {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-workspace-profile-{label}-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::create_dir_all(root.join("Sources")).unwrap();
        root.to_str().unwrap().to_owned()
    }

    fn profile(root: &str) -> WorkspaceProfile {
        WorkspaceProfile::primary(
            "profile-test@1",
            "ProfileTest",
            root,
            &["Sources/**"],
            WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
            WorkspaceCommandPreset::hashing("patch", "/usr/bin/patch", None, &[], 10).unwrap(),
            ProfilePresets::default(),
        )
        .unwrap()
    }

    /// A person's primary tree never gets a Runtime-issued capability; a
    /// Runtime-owned copy of it does, whatever the catalog's default says.
    #[test]
    fn only_a_runtime_owned_copy_is_issued_a_workspace_capability() {
        let root = temporary("issuance");
        let primary = profile(&root);
        let copy_root = format!("{root}-copy");
        fs::create_dir_all(&copy_root).unwrap();
        let copy = primary
            .derived(
                &copy_root,
                "evolution-0123456789abcdef0123",
                &["Sources/App.txt".into()],
            )
            .unwrap();
        let apply = CatalogOperation::lookup("workspace.apply-patch", Some(1)).unwrap();
        let primary_facts = primary.authorization_facts().unwrap();
        let copy_facts = copy.authorization_facts().unwrap();
        assert!(!primary_facts.isolated_task_copy);
        assert!(copy_facts.isolated_task_copy);
        assert!(!automatic_issuance_permitted(apply, Some(&primary_facts)));
        assert!(automatic_issuance_permitted(apply, Some(&copy_facts)));
        // A device subject keeps the catalog's own answer.
        let tap = CatalogOperation::lookup("input.tap", Some(1)).unwrap();
        assert!(automatic_issuance_permitted(tap, None));
        assert!(!automatic_issuance_permitted(apply, None));
        assert_ne!(primary_facts.identity_sha256, copy_facts.identity_sha256);
        fs::remove_dir_all(&root).unwrap();
        fs::remove_dir_all(&copy_root).unwrap();
    }

    #[test]
    fn the_registry_refuses_a_second_profile_under_one_reference() {
        let root = temporary("registry");
        let registry = ProfileRegistry::default();
        let first = profile(&root);
        registry.register(first.clone()).unwrap();
        registry.register(first.clone()).unwrap();
        let mut other = first;
        other.allowed_file_globs = vec!["Other/**".into()];
        assert_eq!(
            registry.register(other).unwrap_err(),
            "workspace projectRef already resolves to another profile"
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_derived_profile_drops_source_control_and_rebases_presets() {
        let root = temporary("derived");
        // Presets name the root as Foundation resolves it, as every profile
        // factory builds them.
        let canonical = foundation_resolved(&root);
        let git = WorkspaceCommandPreset::hashing("git", "/usr/bin/git", None, &[], 120).unwrap();
        let build = WorkspaceCommandPreset::hashing(
            "build",
            "/bin/cp",
            None,
            &[&format!("{canonical}/Sources/a"), "relative", &canonical],
            10,
        )
        .unwrap();
        let primary = WorkspaceProfile::primary(
            "profile-test@1",
            "ProfileTest",
            &root,
            &["Sources/**"],
            WorkspaceCommandPreset::hashing("inspect", "/usr/bin/grep", None, &[], 10).unwrap(),
            WorkspaceCommandPreset::hashing("patch", "/usr/bin/patch", None, &[], 10).unwrap(),
            ProfilePresets {
                source_control: Some(git),
                build: vec![build],
                ..ProfilePresets::default()
            },
        )
        .unwrap();
        let copy_root = format!("{root}-copy");
        fs::create_dir_all(&copy_root).unwrap();
        let copy = primary
            .derived(
                &copy_root,
                "evolution-0123456789abcdef0123",
                &["Sources/a".into()],
            )
            .unwrap();
        assert!(copy.source_control.is_none());
        assert_eq!(copy.kind, ProfileKind::Evolution);
        assert_eq!(copy.source_project_ref.as_deref(), Some("ProfileTest"));
        assert_eq!(
            copy.build["build"].fixed_arguments,
            [
                format!("{copy_root}/Sources/a"),
                "relative".into(),
                copy_root.clone()
            ]
        );
        assert!(
            !copy
                .executable_identities()
                .iter()
                .any(|identity| identity.path == "/usr/bin/git")
        );
        assert_eq!(
            primary.unavailability("workspace.prepare-isolated-copy@1", true),
            None
        );
        let preset_unavailable =
            Some((PRESET_UNAVAILABLE, "workspace.presetUnavailable".to_owned()));
        assert_eq!(
            copy.unavailability("workspace.prepare-isolated-copy@1", true),
            preset_unavailable,
            "a copy is never copied again"
        );
        assert_eq!(
            primary.unavailability("workspace.prepare-isolated-copy@1", false),
            preset_unavailable
        );
        // A copy has no source control: its git reads are not offered, while
        // the primary tree's are.
        assert_eq!(
            primary.unavailability("workspace.inspect-git-status@1", true),
            None
        );
        assert_eq!(
            copy.unavailability("workspace.inspect-diff@1", true),
            preset_unavailable
        );
        assert_eq!(
            copy.unavailability("workspace.read-source-range@1", true),
            preset_unavailable,
            "no source reader"
        );
        assert_eq!(
            primary.unavailability("workspace.symbolize-crash@1", true),
            Some((
                PRESET_UNAVAILABLE,
                "workspace.symbolPresetUnavailable".to_owned()
            ))
        );
        assert_eq!(
            primary.unavailability("workspace.nothing@1", true),
            Some((
                "operation_not_supported",
                "workspace.unsupportedOperation".to_owned()
            ))
        );
        fs::remove_dir_all(&root).unwrap();
        fs::remove_dir_all(&copy_root).unwrap();
    }
}
