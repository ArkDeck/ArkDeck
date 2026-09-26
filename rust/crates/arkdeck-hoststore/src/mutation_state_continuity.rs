//! RuntimeStateContinuity: a new directory cannot reset mutation authority.
//! Read-only validation of the owner's current index and retained Sessions;
//! no capability, record, journal or retired state is repaired or removed.
//!
//! A retained Session the scan let pass is not read again while its files are
//! unchanged: the scan keeps, in memory only, the identity of each file it
//! read (`SessionVerdicts`). Any difference in a file's device, inode, size,
//! or modification or change time to the nanosecond reads the Session again,
//! and a file changed within the last `SETTLE` is always read and never kept,
//! so no write can share the identity of the bytes a verdict was read from.
//! A refusal is never kept. Swift keeps nothing: its scan never reads a
//! Session's files.
use super::JobStore;
use crate::job_record::JobRecord;
use crate::job_repository::InspectedIndex;
use arkdeck_contract::{WireError, strict_json};
use arkdeck_platform::{HostDirectory, HostEntryKind, HostFileIdentity};
use std::{
    collections::{BTreeSet, HashMap},
    io,
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime},
};

const ENTRY_BOUND: usize = 100_000;
const DOCUMENT_BOUND: usize = 16 * 1024 * 1024;
const JOURNAL_BOUND: usize = 64 * 1024 * 1024;
/// How long ago a file must have last changed for its verdict to be kept: a
/// write within the clock tick of the scan's read could otherwise leave the
/// file's identity as it was.
const SETTLE: Duration = Duration::from_secs(2);

/// A retained Session the scan let pass, by the identity of each file it
/// read: its Manifest and its Journal, `None` where it has none.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Passed {
    manifest: Option<HostFileIdentity>,
    journal: Option<HostFileIdentity>,
}

/// The retained Sessions the last complete scan let pass, by path. Derived
/// and in memory only: a restart starts with none, and a scan that ends in a
/// refusal leaves it as it was.
#[derive(Default)]
pub(crate) struct SessionVerdicts {
    passed: HashMap<PathBuf, Passed>,
    /// How many Sessions the last complete scan read, and how many it did
    /// not read again.
    #[cfg(test)]
    counts: (usize, usize),
}

/// How one scan uses what the last one let pass.
#[derive(Clone, Copy)]
pub(crate) enum Reuse {
    /// Every Session is read, and what is kept stays as it was.
    Never,
    /// A Session whose files are unchanged is not read again. A file changed
    /// at or after this instant (seconds and nanoseconds since 1970) is read
    /// and never kept.
    SettledBefore((i64, i64)),
}

impl Reuse {
    fn now() -> Self {
        let settled = SystemTime::now()
            .checked_sub(SETTLE)
            .and_then(|at| at.duration_since(SystemTime::UNIX_EPOCH).ok())
            .map(|since| (since.as_secs() as i64, i64::from(since.subsec_nanos())));
        settled.map_or(Self::Never, Self::SettledBefore)
    }
}

/// The Job store whose failed publications may account for a retained
/// Session that holds its identity and no Manifest: the owner's, or the
/// state root the cutover preflight reads without any owner. Either way the
/// proof reads the same facts of it: a Job's durable record as its index row
/// keeps it, its Journal and its Manifest proposal.
#[derive(Clone, Copy)]
enum PublicationSource<'a> {
    Owner(&'a JobStore),
    /// The Job store's root and its index, each where it could be opened,
    /// the index read through the connection Swift's repository inspects
    /// with.
    Inspected {
        root: Option<&'a HostDirectory>,
        index: Option<&'a InspectedIndex>,
    },
}

impl PublicationSource<'_> {
    fn root(&self) -> Option<&HostDirectory> {
        match self {
            Self::Owner(jobs) => Some(&jobs.root),
            Self::Inspected { root, .. } => *root,
        }
    }

    /// The Job's durable record, from its index row.
    fn record(&self, job_id: &str) -> Option<JobRecord> {
        let row = match self {
            Self::Owner(jobs) => jobs.repository.rows(Some(job_id)).ok()?.into_iter().next(),
            Self::Inspected { index, .. } => index.as_ref()?.row(job_id).ok()?,
        }?;
        JobRecord::from_row(&row).ok()
    }

    /// The Job's own Journal.
    fn journal(&self, job_id: &str) -> io::Result<Vec<u8>> {
        match self {
            Self::Owner(jobs) => jobs.journal_bytes(job_id),
            Self::Inspected { root, .. } => {
                if !crate::job_repository::identifier(job_id) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "The Job identity is not a Runtime identifier",
                    ));
                }
                root.ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?
                    .child("jobs")?
                    .child(job_id)?
                    .read("journal.jsonl", JOURNAL_BOUND)
            }
        }
    }
}

/// One scan's reading of the last one's verdicts, and the verdicts it keeps.
struct Verdicts<'a> {
    /// The Job store whose failed publications may account for a retained
    /// Session that holds its identity and no Manifest.
    jobs: PublicationSource<'a>,
    reuse: Reuse,
    previous: &'a HashMap<PathBuf, Passed>,
    next: HashMap<PathBuf, Passed>,
    /// The Sessions read, and those not read again.
    #[cfg(test)]
    counts: (usize, usize),
}

impl Verdicts<'_> {
    /// The last scan's verdict for `path`, if every file it read is still
    /// the one it read.
    fn unchanged(&self, session: &HostDirectory, path: &Path) -> Result<Option<Passed>, WireError> {
        if matches!(self.reuse, Reuse::Never) {
            return Ok(None);
        }
        let Some(passed) = self.previous.get(path) else {
            return Ok(None);
        };
        let current = Passed {
            manifest: optional_identity(session, "manifest.json")?,
            journal: optional_identity(session, "journal.jsonl")?,
        };
        Ok((current == *passed).then_some(current))
    }

    /// Keeps the last scan's verdict for `path`, not read again.
    fn reused(&mut self, path: PathBuf, passed: Passed) {
        #[cfg(test)]
        {
            self.counts.1 += 1;
        }
        self.next.insert(path, passed);
    }

    /// Keeps `passed` for `path`, just read, if each file it read had
    /// settled.
    fn read(&mut self, path: PathBuf, passed: Passed) {
        #[cfg(test)]
        {
            self.counts.0 += 1;
        }
        let Reuse::SettledBefore(before) = self.reuse else {
            return;
        };
        let settled = |identity: &Option<HostFileIdentity>| {
            identity.is_none_or(|identity| identity.modified < before && identity.changed < before)
        };
        if settled(&passed.manifest) && settled(&passed.journal) {
            self.next.insert(path, passed);
        }
    }
}

const IDENTITY: &str = ".session-identity.json";

/// A retained Session holding its identity and no Manifest that no failed
/// publication of this Runtime accounts for, named by its place under its
/// Sessions root, bounded.
fn incomplete(location: &[String]) -> WireError {
    let mut named = location.join("/");
    if named.chars().count() > 200 {
        named = format!("{}...", named.chars().take(200).collect::<String>());
    }
    crate::job_record::failure(
        "recordUnreadable",
        &format!(
            "Runtime mutation state continuity cannot be proved: retained Session {named} has no Manifest and no failed publication of this Runtime accounts for it; runtime storage status and session cleanup name it; move it out of the Session root once reviewed; original state is preserved"
        ),
    )
}

/// The names from the Sessions root down to the Session at `path`, found at
/// `depth`.
fn location(path: &Path, depth: usize) -> Vec<String> {
    let names: Vec<String> = path
        .components()
        .map(|component| component.as_os_str().to_string_lossy().into_owned())
        .collect();
    names[names.len().saturating_sub(depth + 1)..].to_vec()
}

fn refused() -> WireError {
    crate::job_record::failure(
        "recordUnreadable",
        "Runtime mutation state continuity cannot be proved; original state is preserved",
    )
}

fn normalized(path: &Path) -> Result<PathBuf, WireError> {
    if !path.is_absolute() {
        return Err(refused());
    }
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => (),
            _ => result.push(component.as_os_str()),
        }
    }
    Ok(result)
}

fn exists(path: &Path) -> Result<bool, WireError> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(refused()),
    }
}

fn optional_child(parent: &HostDirectory, name: &str) -> Result<Option<HostDirectory>, WireError> {
    match parent.child(name) {
        Ok(child) => Ok(Some(child)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(refused()),
    }
}

fn optional_read(
    parent: &HostDirectory,
    name: &str,
    bound: usize,
) -> Result<Option<(Vec<u8>, HostFileIdentity)>, WireError> {
    match parent.read_identified(name, bound) {
        Ok(read) => Ok(Some(read)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(refused()),
    }
}

fn optional_identity(
    parent: &HostDirectory,
    name: &str,
) -> Result<Option<HostFileIdentity>, WireError> {
    match parent.file_identity(name) {
        Ok(identity) => Ok(Some(identity)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(refused()),
    }
}

fn read_only_history(bytes: &[u8]) -> Result<(), WireError> {
    let value = strict_json(bytes).map_err(|_| refused())?;
    let fields = value.as_object().ok_or_else(refused)?;
    let request = fields
        .get("request")
        .and_then(|v| v.as_object())
        .ok_or_else(refused)?;
    if request.contains_key("authorization")
        || !matches!(
            fields.get("actualEffect").and_then(|v| v.as_str()),
            Some("hostOnly" | "readOnly")
        )
    {
        return Err(refused());
    }
    Ok(())
}

fn check_sessions(path: &Path, verdicts: &mut Verdicts<'_>) -> Result<(), WireError> {
    if !exists(path)? {
        return Ok(());
    }
    // Resolve case spelling on case-insensitive APFS, without permitting any
    // symlink component. A configured `sessions` can also be the default
    // sibling `Sessions`; canonical spelling is not a distinct authority root.
    let physical = session_root_path(path)?;
    let root = HostDirectory::open_session_tree(&physical).map_err(|_| refused())?;
    let mut remaining = ENTRY_BOUND;
    inspect_session_children(&root, &physical, 0, &mut remaining, verdicts)?;
    if session_root_path(path)? != physical {
        return Err(refused());
    }
    root.validate_path(&physical).map_err(|_| refused())
}

fn session_root_path(path: &Path) -> Result<PathBuf, WireError> {
    for component in path.ancestors() {
        if std::fs::symlink_metadata(component)
            .map_err(|_| refused())?
            .file_type()
            .is_symlink()
        {
            return Err(refused());
        }
    }
    path.canonicalize().map_err(|_| refused())
}

fn inspect_session_children(
    root: &HostDirectory,
    path: &Path,
    depth: usize,
    remaining: &mut usize,
    verdicts: &mut Verdicts<'_>,
) -> Result<(), WireError> {
    let mut names = root.names(*remaining).map_err(|_| refused())?;
    // A publication writes its Session aside in the Sessions root's own
    // `.staging` and renames it, whole, to its published name: what staging
    // holds is a terminal Job's Journal copied in part or in full, never a
    // retained Session. Only that exact entry of the root is passed over.
    if depth == 0 {
        names.retain(|name| name != crate::session_inventory::STAGING);
    }
    inspect_named_children(root, path, depth, remaining, names, verdicts)
}

/// An entry gone since the listing is skipped, as Swift's scan skips a path
/// that no longer exists: a document's temporary name renamed into place by
/// the publication writing the retention catalog, or a Session removed. What
/// is gone retains no Journal to prove. Anything else unreadable is refused.
fn gone(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::NotFound
}

fn inspect_named_children(
    root: &HostDirectory,
    path: &Path,
    depth: usize,
    remaining: &mut usize,
    names: Vec<String>,
    verdicts: &mut Verdicts<'_>,
) -> Result<(), WireError> {
    for name in names {
        *remaining = remaining.checked_sub(1).ok_or_else(refused)?;
        let kind = match root.kind_and_size(&name) {
            Ok((kind, _)) => kind,
            Err(error) if gone(&error) => continue,
            Err(_) => return Err(refused()),
        };
        match kind {
            HostEntryKind::Regular => continue,
            HostEntryKind::Directory => (),
            HostEntryKind::Other => return Err(refused()),
        }
        let session = match root.child(&name) {
            Ok(session) => session,
            Err(error) if gone(&error) => continue,
            Err(_) => return Err(refused()),
        };
        let child_path = path.join(&name);
        // Unchanged since the last scan let it pass: not read again.
        if let Some(passed) = verdicts.unchanged(&session, &child_path)? {
            verdicts.reused(child_path.clone(), passed);
            match session.validate_path(&child_path) {
                Err(error) if gone(&error) => continue,
                result => result.map_err(|_| refused())?,
            }
            continue;
        }
        let manifest = optional_read(&session, "manifest.json", DOCUMENT_BOUND)?;
        let journal = optional_read(&session, "journal.jsonl", JOURNAL_BOUND)?;
        let verdict = (|| {
            if let Some((bytes, _)) = &manifest {
                crate::session_manifest::decode_manifest(bytes).map_err(|_| refused())?;
            }
            if let Some((bytes, _)) = &journal {
                let replay =
                    crate::job_journal_replay::ReplayState::replay(bytes).map_err(|_| refused())?;
                let facts = replay.state.facts(replay.torn);
                let mutation = |effect: &str| matches!(effect, "deviceMutation" | "destructive");
                if facts.has_torn_tail
                    || facts
                        .outstanding_intents
                        .iter()
                        .any(|intent| mutation(&intent.effect))
                    || facts
                        .unknown_outcomes
                        .iter()
                        .any(|outcome| mutation(&outcome.effect))
                {
                    return Err(refused());
                }
            }
            // Current production SessionStore is YYYY/MM/session-ID. Inspect
            // its containers as well as older flat roots, but never
            // reinterpret raw Artifact subdirectories beneath a discovered
            // Session as control state.
            if manifest.is_none() && journal.is_none() {
                if depth >= 3 {
                    return Err(refused());
                }
                inspect_session_children(&session, &child_path, depth + 1, remaining, verdicts)?;
            }
            Ok(())
        })();
        match verdict {
            Ok(()) if manifest.is_some() || journal.is_some() => verdicts.read(
                child_path.clone(),
                Passed {
                    manifest: manifest.map(|(_, identity)| identity),
                    journal: journal.map(|(_, identity)| identity),
                },
            ),
            Ok(()) => (),
            // A Session holding its identity and no Manifest is what a
            // publication that stopped short of it left. Refused as any
            // other, it passes only where a failed publication of this
            // Runtime accounts for it, and is never kept; otherwise the
            // refusal names it.
            Err(refusal) => {
                if manifest.is_some() || optional_identity(&session, IDENTITY)?.is_none() {
                    return Err(refusal);
                }
                let location = location(&child_path, depth);
                let journal = journal.as_ref().map(|(bytes, _)| bytes.as_slice());
                if verdicts
                    .jobs
                    .failed_publication(&session, &location, journal)
                    .is_none()
                {
                    return Err(incomplete(&location));
                }
            }
        }
        match session.validate_path(&child_path) {
            // Removed while it was read: gone, never replaced.
            Err(error) if gone(&error) => continue,
            result => result.map_err(|_| refused())?,
        }
    }
    Ok(())
}

impl JobStore {
    /// Called before mutation admission and again immediately before consuming
    /// authority. `default_root` and Session roots come from Runtime composition,
    /// never from an operation's inputs, transport peer or development override.
    pub fn require_mutation_state(
        &self,
        default_root: &Path,
        session_roots: &[PathBuf],
    ) -> Result<(), WireError> {
        self.require_mutation_state_reusing(default_root, session_roots, Reuse::now())
    }

    pub(crate) fn require_mutation_state_reusing(
        &self,
        default_root: &Path,
        session_roots: &[PathBuf],
        reuse: Reuse,
    ) -> Result<(), WireError> {
        let expected = normalized(default_root)?;
        if normalized(&self.path)? != expected {
            return Err(refused());
        }
        let _activity = self.activity.lock().map_err(|_| refused())?;
        self.root.validate_path(&self.path).map_err(|_| refused())?;
        let parent = expected.parent().ok_or_else(refused)?;
        if exists(&parent.join("AuthorizationUsage"))? {
            return Err(refused());
        }
        let checkpoint_exists = match optional_child(&self.root, "capabilities")? {
            Some(capabilities) => match capabilities.kind_and_size("runtime-capabilities.json") {
                Ok((HostEntryKind::Regular, _)) => true,
                Err(error) if error.kind() == io::ErrorKind::NotFound => false,
                _ => return Err(refused()),
            },
            None => false,
        };
        if !checkpoint_exists {
            if let Some(jobs) = optional_child(&self.root, "jobs")? {
                for name in jobs.names(ENTRY_BOUND).map_err(|_| refused())? {
                    let job = jobs.child(&name).map_err(|_| refused())?;
                    let bytes = job
                        .read("job-record.json", DOCUMENT_BOUND)
                        .map_err(|_| refused())?;
                    read_only_history(&bytes)?;
                    job.validate_path(&self.path.join("jobs").join(&name))
                        .map_err(|_| refused())?;
                }
                jobs.validate_path(&self.path.join("jobs"))
                    .map_err(|_| refused())?;
            }
            // The index may be the only surviving copy after an interrupted
            // admission or missing Job directory. It cannot be treated as empty.
            for row in self.repository.rows(None).map_err(|_| refused())? {
                read_only_history(&row.record)?;
            }
        }
        let mut roots = BTreeSet::from([parent.join("Sessions")]);
        for root in session_roots {
            roots.insert(normalized(root)?);
        }
        // Taken under `activity`, as every scan is.
        let mut kept = self
            .session_verdicts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut verdicts = Verdicts {
            jobs: PublicationSource::Owner(self),
            reuse,
            previous: &kept.passed,
            next: HashMap::new(),
            #[cfg(test)]
            counts: (0, 0),
        };
        for root in roots {
            check_sessions(&root, &mut verdicts)?;
        }
        self.root.validate_path(&self.path).map_err(|_| refused())?;
        // Only a scan that let every Session pass, reusing, replaces what is
        // kept: the Sessions it met, and no other.
        if matches!(reuse, Reuse::SettledBefore(_)) {
            *kept = SessionVerdicts {
                passed: verdicts.next,
                #[cfg(test)]
                counts: verdicts.counts,
            };
        }
        Ok(())
    }
}

impl JobStore {
    /// The continuity proof of the retained Sessions under `sessions_root`
    /// alone, read-only and reusing nothing: what a device mutation's proof
    /// (`require_mutation_state`) refuses there, this refuses, with the same
    /// reason, so a check made before the Runtime serves can never differ
    /// from the proof it makes later.
    pub fn require_retained_sessions(&self, sessions_root: &Path) -> Result<(), WireError> {
        let root = normalized(sessions_root)?;
        let _activity = self.activity.lock().map_err(|_| refused())?;
        retained_sessions(PublicationSource::Owner(self), &root)
    }

    /// Whether the Session at `location` (`yyyy`, `mm`, `session-<job>`)
    /// under `sessions_root`, holding its identity and no Manifest, is
    /// exactly what a failed publication of a Job this store holds leaves,
    /// which the continuity proof passes over. Read-only, and it takes no
    /// lock.
    pub fn failed_publication_accounts_for(
        &self,
        sessions_root: &Path,
        location: [&str; 3],
    ) -> bool {
        let session = HostDirectory::open_session_tree(sessions_root).and_then(|root| {
            root.child(location[0])?
                .child(location[1])?
                .child(location[2])
        });
        let Ok(session) = session else {
            return false;
        };
        if !matches!(optional_identity(&session, "manifest.json"), Ok(None)) {
            return false;
        }
        let journal = match session.read("journal.jsonl", JOURNAL_BOUND) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(_) => return false,
        };
        PublicationSource::Owner(self)
            .failed_publication(&session, &location.map(str::to_owned), journal.as_deref())
            .is_some()
    }
}

/// The retained Sessions under `root` scanned, reusing nothing, with the
/// failed publications of `jobs` passing a Session they account for.
fn retained_sessions(jobs: PublicationSource<'_>, root: &Path) -> Result<(), WireError> {
    let previous = HashMap::new();
    let mut verdicts = Verdicts {
        jobs,
        reuse: Reuse::Never,
        previous: &previous,
        next: HashMap::new(),
        #[cfg(test)]
        counts: (0, 0),
    };
    check_sessions(root, &mut verdicts)
}

/// [`JobStore::require_retained_sessions`] over a state root no owner of
/// this process holds, for the cutover preflight's read of the Runtime it
/// would replace: the same scan, which refuses what a device mutation's proof
/// will refuse there, with the same reason. The failed publications that
/// may account for a Session are read from the Job store's root `jobs` and
/// its `index` (each `None` where there is none) without any owner: no lock
/// is taken, and nothing is marked, created or written.
pub(crate) fn require_retained_sessions_without_owner(
    jobs: Option<&HostDirectory>,
    index: Option<&InspectedIndex>,
    sessions_root: &Path,
) -> Result<(), WireError> {
    let root = normalized(sessions_root)?;
    retained_sessions(PublicationSource::Inspected { root: jobs, index }, &root)
}

impl PublicationSource<'_> {
    /// The durable proof that `session`, at `location` under its Sessions
    /// root, holding `journal` (if any) and no Manifest, is what a failed
    /// publication of a Job this store holds leaves (`SessionPublisher`,
    /// `session_publication.rs`), all of it:
    /// - its identity, canonical, names that Job, and its name is that Job's
    ///   Session;
    /// - the Job's durable record keeps a publication that failed, for this
    ///   Session, which it would have published at `yyyy/mm` of its creation;
    /// - it holds nothing the publication does not create before it stops:
    ///   its directories, empty but for the outcome audit and publication
    ///   locks, a Journal that is the Job's own as far as it goes, and the
    ///   outcome audit of this Job only once the whole Journal is copied.
    fn failed_publication(
        self,
        session: &HostDirectory,
        location: &[String],
        journal: Option<&[u8]>,
    ) -> Option<()> {
        use serde_json::{Value, json};
        let [year, month, name] = location else {
            return None;
        };
        let identity = session.read(IDENTITY, 4096).ok()?;
        let job_id = strict_json(&identity).ok()?["jobId"].as_str()?.to_owned();
        let session_id = format!("session-{job_id}");
        let canonical = crate::session_json::encode(
            &json!({"jobId": job_id, "schemaVersion": "1.0.0", "sessionId": session_id}),
        )
        .ok()?;
        if identity != canonical || *name != session_id {
            return None;
        }

        let record = self.record(&job_id)?;
        let marker = record.session_publication()?;
        if crate::job_record_fields::publication_fact(Some(marker))["state"] != "failed"
            || marker["sessionID"] != session_id.as_str()
            || crate::session_publication::utc_month(record.created())?
                != (year.clone(), month.clone())
        {
            return None;
        }

        let kind = |directory: &HostDirectory, name: &str| directory.kind_and_size(name).ok();
        let empty_file = |directory: &HostDirectory, name: &str| {
            kind(directory, name) == Some((HostEntryKind::Regular, 0))
        };
        let names = session.names(8).ok()?;
        let created = [
            IDENTITY,
            "audit",
            "artifacts",
            "journal.jsonl",
            ".manifest.lock",
        ];
        if names.iter().any(|name| !created.contains(&name.as_str()))
            || kind(session, IDENTITY)?.0 != HostEntryKind::Regular
            || (journal.is_some() && kind(session, "journal.jsonl")?.0 != HostEntryKind::Regular)
            || (names.iter().any(|name| name == ".manifest.lock")
                && !empty_file(session, ".manifest.lock"))
        {
            return None;
        }
        // Every directory is created before the identity.
        let artifacts = session.child("artifacts").ok()?;
        if artifacts.names(4).ok()? != ["derived", "partial", "raw"] {
            return None;
        }
        for part in ["derived", "raw"] {
            if !artifacts.child(part).ok()?.names(1).ok()?.is_empty() {
                return None;
            }
        }
        let partial = artifacts.child("partial").ok()?;
        for lock in partial.names(17).ok()? {
            let shard = lock
                .strip_prefix(".publication-lock-")
                .and_then(|rest| rest.strip_suffix(".lock"))?;
            if shard.len() != 1
                || !shard
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                || !empty_file(&partial, &lock)
            {
                return None;
            }
        }
        let job_journal = self.journal(&job_id).ok()?;
        if journal.is_some_and(|copy| !job_journal.starts_with(copy)) {
            return None;
        }
        let audit = session.child("audit").ok()?;
        match audit.names(2).ok()?.as_slice() {
            [] => Some(()),
            // Appended only once the whole Journal is copied.
            [only] if only == "session.jsonl" && journal == Some(job_journal.as_slice()) => {
                let line = audit.read("session.jsonl", 64 * 1024).ok()?;
                let body = line.strip_suffix(b"\n")?;
                if body.contains(&b'\n') {
                    return None;
                }
                let audit = strict_json(body).ok()?;
                let proposal = self
                    .root()?
                    .child("jobs")
                    .ok()?
                    .child(&job_id)
                    .ok()?
                    .read("session-manifest.proposal.json", DOCUMENT_BOUND)
                    .ok()?;
                let expected = |timestamp: &Value| {
                    json!({"auditId": format!("session-publication-{job_id}"),
                        "category": "outcome", "correlationId": job_id,
                        "details": {"manifestSha256": arkdeck_contract::sha256_hex(&proposal),
                            "operation": record.operation(), "terminalStatus": record.state},
                        "jobId": job_id, "recordId": "session-publication-outcome",
                        "schemaVersion": "1.0.0", "sessionId": session_id,
                        "timestamp": timestamp})
                };
                (audit["timestamp"].is_string() && audit == expected(&audit["timestamp"]))
                    .then_some(())
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Fixture {
        base: PathBuf,
        root: PathBuf,
        jobs: JobStore,
    }
    impl Fixture {
        fn new() -> Self {
            let id = arkdeck_contract::sha256_hex(&arkdeck_platform::random_bytes::<16>().unwrap());
            let base = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("mutation-continuity-{id}"));
            let root = base.join("Runtime");
            std::fs::create_dir_all(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let jobs = JobStore::open_owner(&root).unwrap();
            Self { base, root, jobs }
        }
        fn check(&self) -> Result<(), WireError> {
            self.jobs.require_mutation_state(&self.root, &[])
        }
        fn scan(&self, reuse: Reuse) -> Result<(), WireError> {
            self.jobs
                .require_mutation_state_reusing(&self.root, &[], reuse)
        }
        /// The last complete reusing scan's Sessions read, and those not
        /// read again.
        fn counts(&self) -> (usize, usize) {
            self.jobs.session_verdicts.lock().unwrap().counts
        }
        fn file(&self, relative: &str, bytes: &[u8]) {
            let path = self.base.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bytes).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    #[test]
    fn override_and_retired_authority_are_refused_without_changing_source() {
        let fixture = Fixture::new();
        assert!(fixture.check().is_ok());
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.base.join("other"), &[])
                .is_err()
        );
        fixture.file("AuthorizationUsage/original", b"retained");
        assert!(fixture.check().is_err());
        assert_eq!(
            std::fs::read(fixture.base.join("AuthorizationUsage/original")).unwrap(),
            b"retained"
        );
    }

    #[test]
    fn missing_checkpoint_checks_job_directories_with_strict_json() {
        let fixture = Fixture::new();
        let relative = "Runtime/jobs/job-one/job-record.json";
        let parent = fixture.root.join("jobs");
        std::fs::create_dir_all(parent.join("job-one")).unwrap();
        for path in [&parent, &parent.join("job-one")] {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        fixture.file(relative, br#"{"request":{},"actualEffect":"readOnly"}"#);
        assert!(fixture.check().is_ok());
        for bytes in [
            br#"{"request":{},"actualEffect":"deviceMutation"}"#.as_slice(),
            br#"{"request":{"authorization":null},"actualEffect":"readOnly"}"#,
            br#"{"request":{},"actualEffect":"deviceMutation","actualEffect":"readOnly"}"#,
            br#"{"request":{}}"#,
        ] {
            fixture.file(relative, bytes);
            assert!(fixture.check().is_err());
            assert_eq!(std::fs::read(fixture.base.join(relative)).unwrap(), bytes);
        }
    }

    #[test]
    fn sqlite_only_mutation_history_cannot_reset_the_budget() {
        let fixture = Fixture::new();
        let bytes = br#"{"request":{},"actualEffect":"deviceMutation"}"#;
        fixture
            .jobs
            .repository
            .admit(
                "job-index-only",
                "intent-index-only",
                &"a".repeat(64),
                "preflight",
                "2026-09-19T00:00:00Z",
                bytes,
            )
            .unwrap();
        assert!(!fixture.root.join("jobs/job-index-only").exists());
        assert!(fixture.check().is_err());
        assert_eq!(fixture.jobs.repository.rows(None).unwrap()[0].record, bytes);
        assert!(
            !fixture
                .root
                .join("capabilities/runtime-capabilities.json")
                .exists()
        );
    }

    #[test]
    fn retained_session_mutation_and_torn_tail_block_even_with_checkpoint() {
        let fixture = Fixture::new();
        fixture.file("Runtime/capabilities/runtime-capabilities.json", b"{}");
        std::fs::set_permissions(
            fixture.root.join("capabilities"),
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let original = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-50242330d29da200cc17ae91a74808d1/journal.jsonl"
        );
        let prefix = |count| {
            original
                .split_inclusive(|byte| *byte == b'\n')
                .take(count)
                .flatten()
                .copied()
                .collect::<Vec<_>>()
        };
        // Actual Swift oracle prefix: an outstanding read-only probe is allowed.
        fixture.file("Sessions/one/journal.jsonl", &prefix(4));
        assert!(fixture.check().is_ok());
        // The next intent injects a pointer gesture and must never be hidden.
        let mutation = prefix(6);
        fixture.file("Sessions/one/journal.jsonl", &mutation);
        assert!(fixture.check().is_err());
        assert_eq!(
            std::fs::read(fixture.base.join("Sessions/one/journal.jsonl")).unwrap(),
            mutation
        );
        let unknown = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-dda3780682ad4198fc853da9011bc974/journal.jsonl"
        );
        fixture.file("Sessions/one/journal.jsonl", unknown);
        assert!(fixture.check().is_err());
        fixture.file("Sessions/one/journal.jsonl", b"{");
        assert!(fixture.check().is_err());
    }

    #[test]
    fn configured_session_roots_and_invalid_manifests_are_checked() {
        let fixture = Fixture::new();
        fixture.file("Archive/session/manifest.json", b"{}");
        assert!(fixture.check().is_ok());
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.root, &[fixture.base.join("Archive")])
                .is_err()
        );
        assert_eq!(
            std::fs::read(fixture.base.join("Archive/session/manifest.json")).unwrap(),
            b"{}"
        );
    }

    #[test]
    fn nested_production_sessions_and_case_aliases_cannot_hide_unknown_mutation() {
        let fixture = Fixture::new();
        let unknown = include_bytes!(
            "../../../tests/fixtures/pointer-input/store/jobs/job-dda3780682ad4198fc853da9011bc974/journal.jsonl"
        );
        fixture.file("sessions/2026/09/session-unknown/journal.jsonl", unknown);
        assert!(
            fixture
                .jobs
                .require_mutation_state(&fixture.root, &[fixture.base.join("sessions")])
                .is_err()
        );
        if fixture.base.join("Sessions").exists() {
            // APFS case-insensitive spelling must inspect the same real root.
            assert!(fixture.check().is_err());
            std::fs::write(
                fixture
                    .base
                    .join("sessions/2026/09/session-unknown/journal.jsonl"),
                b"",
            )
            .unwrap();
            assert!(fixture.check().is_ok());
        }
    }

    #[test]
    fn symlinked_roots_and_retired_state_are_not_followed() {
        let fixture = Fixture::new();
        symlink(
            fixture.base.join("missing"),
            fixture.base.join("AuthorizationUsage"),
        )
        .unwrap();
        assert!(fixture.check().is_err());
        std::fs::remove_file(fixture.base.join("AuthorizationUsage")).unwrap();
        symlink(
            fixture.base.join("elsewhere"),
            fixture.base.join("Sessions"),
        )
        .unwrap();
        assert!(fixture.check().is_err());
        assert!(
            std::fs::symlink_metadata(fixture.base.join("Sessions"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn an_entry_gone_since_the_listing_is_skipped() {
        // The publication writing the retention catalog lists a temporary
        // name in the Session root and renames it into place: a scan that
        // listed it finds it gone, as Swift's scan may, and skips it.
        let fixture = Fixture::new();
        let sessions = fixture.base.join("Sessions");
        std::fs::create_dir(&sessions).unwrap();
        std::fs::set_permissions(&sessions, std::fs::Permissions::from_mode(0o700)).unwrap();
        let root = HostDirectory::open_session_tree(&sessions).unwrap();
        let previous = HashMap::new();
        let mut verdicts = Verdicts {
            jobs: PublicationSource::Owner(&fixture.jobs),
            reuse: Reuse::Never,
            previous: &previous,
            next: HashMap::new(),
            #[cfg(test)]
            counts: (0, 0),
        };
        let mut remaining = ENTRY_BOUND;
        inspect_named_children(
            &root,
            &sessions,
            0,
            &mut remaining,
            vec![
                ".arkdeck-retention-catalog.json.00.part".into(),
                "2026".into(),
            ],
            &mut verdicts,
        )
        .unwrap();
        // An entry still there keeps its checks: an unresolved mutation in a
        // retained Session's Journal still refuses the state.
        fixture.file(
            "Sessions/2026/09/session-a/journal.jsonl",
            b"not a journal\n",
        );
        let mut remaining = ENTRY_BOUND;
        assert!(
            inspect_named_children(
                &root,
                &sessions,
                0,
                &mut remaining,
                vec![".gone.part".into(), "2026".into()],
                &mut verdicts,
            )
            .is_err()
        );
    }

    /// Every file has settled: whatever the scan reads it may keep.
    const SETTLED: Reuse = Reuse::SettledBefore((i64::MAX, 0));

    /// A Swift pointer oracle Journal, whole: a gesture the device refused,
    /// nine records, every intent resolved.
    const GESTURE: &[u8] = include_bytes!(
        "../../../tests/fixtures/pointer-input/store/jobs/job-50242330d29da200cc17ae91a74808d1/journal.jsonl"
    );

    fn records(bytes: &[u8]) -> Vec<&[u8]> {
        bytes.split_inclusive(|byte| *byte == b'\n').collect()
    }

    fn identity(path: &Path) -> HostFileIdentity {
        let parent = HostDirectory::open_session_tree(path.parent().unwrap()).unwrap();
        parent
            .file_identity(path.file_name().unwrap().to_str().unwrap())
            .unwrap()
    }

    /// Replaces `path`'s bytes in place, keeping its inode.
    fn rewrite(path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).unwrap();
    }

    fn append(path: &Path, bytes: &[u8]) {
        use std::io::Write;
        std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
    }

    /// A retained Session unchanged since the last scan let it pass is not
    /// read again, and every answer is the answer of a scan that reads every
    /// Session. Each difference in what identifies its files reads it again:
    /// its size, its change time alone (the same number of bytes, one of them
    /// changed, and the modification time set back), its inode, and a file
    /// that appears. A refusal keeps nothing and leaves what was kept.
    #[test]
    fn an_unchanged_session_is_not_read_again_and_answers_as_a_full_scan() {
        let fixture = Fixture::new();
        let journal = fixture
            .base
            .join("Sessions/2026/09/session-a/journal.jsonl");
        fixture.file("Sessions/2026/09/session-a/journal.jsonl", GESTURE);
        fixture.file(
            "Sessions/2026/09/session-b/journal.jsonl",
            &records(GESTURE)[..4].concat(),
        );
        let full = || fixture.scan(Reuse::Never);
        assert!(full().is_ok());
        assert_eq!(fixture.scan(SETTLED), full());
        assert_eq!(fixture.counts(), (2, 0));
        assert_eq!(fixture.scan(SETTLED), full());
        assert_eq!(fixture.counts(), (0, 2));

        // Its size: a torn tail. The refusal keeps what was kept.
        append(&journal, b"{");
        assert!(full().is_err());
        assert_eq!(fixture.scan(SETTLED), full());
        assert_eq!(fixture.counts(), (0, 2));
        rewrite(&journal, GESTURE);
        assert_eq!(fixture.scan(SETTLED), full());
        assert_eq!(fixture.counts(), (1, 1));

        // Its change time alone.
        let before = identity(&journal);
        let modified = std::fs::metadata(&journal).unwrap().modified().unwrap();
        let mut changed = GESTURE.to_vec();
        changed[0] = b'[';
        rewrite(&journal, &changed);
        std::fs::File::options()
            .write(true)
            .open(&journal)
            .unwrap()
            .set_modified(modified)
            .unwrap();
        let after = identity(&journal);
        assert_eq!(
            (after.device, after.inode, after.size, after.modified),
            (before.device, before.inode, before.size, before.modified)
        );
        assert_ne!(after.changed, before.changed);
        assert!(full().is_err());
        assert_eq!(fixture.scan(SETTLED), full());

        // Its inode: a whole Journal renamed over it.
        rewrite(&journal, GESTURE);
        assert_eq!(fixture.scan(SETTLED), full());
        let replacement = journal.with_file_name("journal.jsonl.new");
        std::fs::write(&replacement, &changed).unwrap();
        std::fs::set_permissions(&replacement, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::rename(&replacement, &journal).unwrap();
        assert_ne!(identity(&journal).inode, before.inode);
        assert!(full().is_err());
        assert_eq!(fixture.scan(SETTLED), full());

        // A file that appears: a Manifest that does not decode.
        rewrite(&journal, GESTURE);
        assert_eq!(fixture.scan(SETTLED), full());
        fixture.file("Sessions/2026/09/session-b/manifest.json", b"{}");
        assert!(full().is_err());
        assert_eq!(fixture.scan(SETTLED), full());
    }

    /// Each part of a file's identity is compared: a verdict kept for one
    /// identity is never the verdict of another that differs in any part.
    #[test]
    fn every_part_of_a_file_identity_tells_it_apart() {
        let kept = HostFileIdentity {
            device: 1,
            inode: 2,
            size: 3,
            modified: (4, 5),
            changed: (6, 7),
        };
        let changes: [fn(&mut HostFileIdentity); 7] = [
            |identity| identity.device += 1,
            |identity| identity.inode += 1,
            |identity| identity.size += 1,
            |identity| identity.modified.0 += 1,
            |identity| identity.modified.1 += 1,
            |identity| identity.changed.0 += 1,
            |identity| identity.changed.1 += 1,
        ];
        for change in changes {
            let mut other = kept;
            change(&mut other);
            let passed = |journal| Passed {
                manifest: None,
                journal: Some(journal),
            };
            assert_ne!(passed(other), passed(kept));
        }
    }

    /// A file changed at or after the settled instant is read by every scan
    /// and never kept. The daemon's instant is `SETTLE` before its clock.
    #[test]
    fn a_file_not_yet_settled_is_read_every_time_and_never_kept() {
        let fixture = Fixture::new();
        fixture.file("Sessions/2026/09/session-a/journal.jsonl", GESTURE);
        let recent = Reuse::SettledBefore((0, 0));
        for _ in 0..2 {
            assert!(fixture.scan(recent).is_ok());
            assert_eq!(fixture.counts(), (1, 0));
        }
        let Reuse::SettledBefore(settled) = Reuse::now() else {
            panic!("the clock reads before 1970");
        };
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        assert!(
            (now - 3..=now - 1).contains(&settled.0),
            "{settled:?} {now}"
        );
    }

    /// Records appended to a retained Session's Journal between scans, in
    /// turn with them, are never answered from a kept verdict: after each
    /// record the scan answers as a scan that reads every Session, as the
    /// Journal refuses and allows the state in turn. A second writer appends
    /// the whole Journal again elsewhere while scans run; once it is done,
    /// the scan answers as a full one.
    #[test]
    fn appends_between_scans_are_never_answered_from_a_kept_verdict() {
        let fixture = Fixture::new();
        let gesture = records(GESTURE);
        let journal = fixture
            .base
            .join("Sessions/2026/09/session-a/journal.jsonl");
        fixture.file("Sessions/2026/09/session-a/journal.jsonl", gesture[0]);
        let full = || fixture.scan(Reuse::Never);
        let (appended, appends) = std::sync::mpsc::channel();
        let (next, nexts) = std::sync::mpsc::channel::<()>();
        let mut answers = BTreeSet::new();
        std::thread::scope(|scope| {
            // Owned here: a failed assertion drops it, and the writer stops
            // waiting rather than holding the scope open.
            let next = next;
            let journal = &journal;
            let gesture = &gesture;
            scope.spawn(move || {
                for record in &gesture[1..] {
                    if nexts.recv().is_err() {
                        return;
                    }
                    append(journal, record);
                    appended.send(()).unwrap();
                }
            });
            for count in 1..=gesture.len() {
                let answer = fixture.scan(SETTLED);
                assert_eq!(answer, full(), "after {count} records");
                answers.insert(answer.is_ok());
                if count < gesture.len() {
                    next.send(()).unwrap();
                    appends.recv().unwrap();
                }
            }
        });
        // The Journal both refused the state and allowed it on the way.
        assert_eq!(answers, BTreeSet::from([false, true]));

        let other = fixture
            .base
            .join("Sessions/2026/09/session-b/journal.jsonl");
        fixture.file("Sessions/2026/09/session-b/journal.jsonl", gesture[0]);
        std::thread::scope(|scope| {
            let writer = scope.spawn(|| {
                for record in &gesture[1..] {
                    append(&other, record);
                }
            });
            while !writer.is_finished() {
                // Mid-append a read may refuse; it never keeps.
                let _ = fixture.scan(SETTLED);
            }
        });
        assert_eq!(fixture.scan(SETTLED), full());
        assert!(full().is_ok());
    }

    /// How long a proof over a thousand retained Sessions takes, each holding
    /// the same pointer oracle Journal: reading every Session, and reusing
    /// what the last scan let pass. A measurement, not a check:
    /// `cargo test -p arkdeck-hoststore --lib mutation_state_continuity::tests::a_proof -- --ignored --nocapture`.
    #[test]
    #[ignore = "a measurement"]
    fn a_proof_over_a_thousand_retained_sessions_takes() {
        let fixture = Fixture::new();
        for index in 0..1_000 {
            fixture.file(
                &format!("Sessions/2026/09/session-{index:04}/journal.jsonl"),
                GESTURE,
            );
        }
        let time = |reuse: Reuse| {
            let mut samples: Vec<_> = (0..5)
                .map(|_| {
                    let started = std::time::Instant::now();
                    fixture.scan(reuse).unwrap();
                    started.elapsed()
                })
                .collect();
            samples.sort();
            (samples[2], samples[4])
        };
        println!(
            "reading every Session: median and max {:?}",
            time(Reuse::Never)
        );
        fixture.scan(SETTLED).unwrap();
        println!("reusing every Session: median and max {:?}", time(SETTLED));
        assert_eq!(fixture.counts(), (0, 1_000));
    }
}
