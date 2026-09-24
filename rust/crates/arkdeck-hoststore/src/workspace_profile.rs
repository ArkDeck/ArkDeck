//! Swift `WorkspaceProjectProfile` and `WorkspaceProjectProfileRegistry`
//! (`WorkspaceOperationsProvider.swift`) for the Rust workspace provider
//! (TASK-XPA-015, M3): the closed profile a registered project resolves to,
//! the derived profile of a Runtime-owned isolated copy, the registry both
//! live in, and the availability, registration and authorization facts the
//! engine asks of them.
//!
//! A registered project's profile is built by its kind exactly as Swift's
//! composition root builds it (`arkDeck`, `waterFlowDemo`), with its code-owned
//! presets and pinned system tools. The presets a caller registers through
//! `workspace.preset.*` are not composed yet: the operations that run them are
//! not materialized by this Runtime, and their tools are not part of the
//! identities re-measured below.
use crate::operation_catalog::CatalogOperation;
use crate::workspace_support::{
    self as support, foundation_resolved, foundation_standardized, is_identifier, is_safe_glob,
    is_safe_relative_path, is_sha256,
};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::{Mutex, OnceLock};

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

/// Swift `WorkspaceCommandPreset`, less the verified resources no composed
/// preset carries yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceCommandPreset {
    preset_id: String,
    executable: ExecutableIdentity,
    argument_zero: Option<String>,
    fixed_arguments: Vec<String>,
    timeout_seconds: i64,
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
        Self::new(
            preset_id,
            ExecutableIdentity::hashing(path)?,
            argument_zero.map(str::to_owned),
            fixed_arguments.iter().map(|&a| a.to_owned()).collect(),
            timeout_seconds,
        )
    }

    fn new(
        preset_id: &str,
        executable: ExecutableIdentity,
        argument_zero: Option<String>,
        fixed_arguments: Vec<String>,
        timeout_seconds: i64,
    ) -> Result<Self, String> {
        if !is_identifier(preset_id) {
            return Err("workspace preset id is malformed".into());
        }
        if !(1..=7_200).contains(&timeout_seconds) {
            return Err("workspace preset timeout is outside 1...7200".into());
        }
        let bounded = |value: &str| !value.contains('\0') && value.len() <= 4_096;
        if !argument_zero
            .as_deref()
            .is_none_or(|zero| !zero.is_empty() && bounded(zero))
            || fixed_arguments.len() > 128
            || !fixed_arguments.iter().all(|argument| bounded(argument))
        {
            return Err("workspace preset arguments or verified resources are not bounded".into());
        }
        Ok(Self {
            preset_id: preset_id.into(),
            executable,
            argument_zero,
            fixed_arguments,
            timeout_seconds,
        })
    }

    /// Swift `EvolutionWorkspaceManager.derivedProfile`'s `rebased`: every
    /// argument naming the source root names the copy's instead.
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
        )
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
            kind: ProfileKind::Primary,
            source_project_ref: None,
        })
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
    /// for a registered project, whose registered presets are not composed.
    pub fn water_flow(root: &str, project_ref: &str, home: &str) -> Result<Self, String> {
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
                ..ProfilePresets::default()
            },
        )
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

    /// Swift `runtimeAvailability(for:profile:)` for the operations this
    /// Runtime materializes: the reason it is unavailable, if it is.
    pub(crate) fn unavailability(&self, reference: &str, isolation: bool) -> Option<String> {
        let has_preset = match reference {
            "workspace.prepare-isolated-copy@1" => isolation && self.kind == ProfileKind::Primary,
            _ => return Some("workspace.unsupportedOperation".into()),
        };
        if !has_preset {
            return Some("workspace.presetUnavailable".into());
        }
        for identity in self.executable_identities() {
            match ExecutableIdentity::hashing(&identity.path) {
                Ok(measured) if measured.sha256 == identity.sha256 => {}
                Ok(_) => return Some("workspace.toolIdentityDrift".into()),
                Err(_) => return Some("workspace.toolchainUnavailable".into()),
            }
        }
        None
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
        assert_eq!(
            copy.unavailability("workspace.prepare-isolated-copy@1", true)
                .as_deref(),
            Some("workspace.presetUnavailable"),
            "a copy is never copied again"
        );
        assert_eq!(
            primary
                .unavailability("workspace.prepare-isolated-copy@1", false)
                .as_deref(),
            Some("workspace.presetUnavailable")
        );
        fs::remove_dir_all(&root).unwrap();
        fs::remove_dir_all(&copy_root).unwrap();
    }
}
