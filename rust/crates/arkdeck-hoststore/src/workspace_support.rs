//! Swift `WorkspaceProviderSupport` (`WorkspaceOperationsProvider.swift`) for
//! the Runtime-owned isolation lane (TASK-XPA-015, M3): the closed glob
//! grammar, the scope-narrowing rule, Foundation's view of a project tree and
//! the workspace revision, which is computed from files alone so admission
//! has it before any process runs.
//!
//! Foundation is reproduced where it decides an answer, each rule measured on
//! this host with the Swift toolchain:
//! - `resolvingSymlinksInPath` is `realpath(3)`; when that fails the path is
//!   standardized lexically instead, symbolic links left as written. Either
//!   way a leading `/private` is dropped when what remains exists.
//! - the enumerator skips exactly the entries whose hidden key is true and
//!   descends no directory whose package key is true
//!   (`arkdeck_platform::host_entry_presentation`).
//! - paths sort as Swift strings do: by their NFC scalars.
//! - `**` is ICU's `.*`, which crosses no line terminator; `*` and `?` cross
//!   anything but `/`.
//!
//! On Windows (TASK-XPA-011) an absolute path is spelled as the host spells
//! a standard local one, `X:\a\b`, which is what the project registration
//! pins and what the platform's verified handles require; a path relative to
//! a project root keeps Swift's `/` separators. Foundation's `/private`
//! rule has no Windows meaning, and a symbolic link or junction is resolved
//! by the handle's final path. An entry is hidden when its name starts with
//! `.` or it carries the hidden attribute; no directory is a package.
//!
//! A refusal is the detail Swift's `DeviceProviderError` describes itself by.
use arkdeck_contract::sha256_hex;
use std::collections::HashSet;
use std::fs::{self, File};
use std::io;
use std::path::Path;

/// Swift's refusal detail.
pub(crate) type Refusal = String;

const MAXIMUM_VISITED: usize = 20_000;
/// The largest executable a workspace tool or inspector is measured up to
/// on Windows, as an analyzer's.
#[cfg(windows)]
pub(crate) const MAXIMUM_EXECUTABLE_BYTES: u64 = 128 * 1024 * 1024;
const MAXIMUM_MATCHED: usize = 2_000;

/// Swift `WorkspaceProviderSupport.sha256`.
pub(crate) fn sha256(bytes: &[u8]) -> String {
    sha256_hex(bytes)
}

/// Swift `isIdentifier`: 1...128 ASCII letters, digits or `._:@-`.
pub(crate) fn is_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:@-".contains(&byte))
}

/// A lowercase SHA-256, as every digest here is spelled.
pub(crate) fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `isNarrower(_:than:)`: equal, or inside a `/**` scope, or a direct
/// child of a `/*` scope. No other wildcard narrows.
pub(crate) fn is_narrower(requested: &str, profile_scope: &str) -> bool {
    if requested == profile_scope {
        return true;
    }
    if let Some(prefix) = profile_scope.strip_suffix("/**") {
        return requested == prefix || requested.starts_with(&format!("{prefix}/"));
    }
    if let Some(prefix) = profile_scope.strip_suffix("/*") {
        let Some(child) = requested.strip_prefix(&format!("{prefix}/")) else {
            return false;
        };
        return !child.contains('/');
    }
    false
}

/// Swift `isSafeGlob`.
pub(crate) fn is_safe_glob(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && !value.starts_with('/')
        && !value.contains('\\')
        && !(cfg!(windows) && value.contains(':'))
        && !value
            .split('/')
            .any(|component| component == ".." || component.is_empty())
        && !value.starts_with(".git")
        && !value.contains("/.git/")
}

/// Swift `isSafeRelativePath`.
pub(crate) fn is_safe_relative_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && !value.starts_with('/')
        && !value.contains('\\')
        && !value.chars().any(|c| "*?[]".contains(c))
        && !value.chars().any(arkdeck_platform::host_control_character)
        // A colon names a drive or an alternate data stream on Windows.
        && !(cfg!(windows) && value.contains(':'))
        && !value
            .split('/')
            .any(|component| component == "." || component == ".." || component.is_empty())
        && value != ".git"
        && !value.starts_with(".git/")
        && !value.contains("/.git/")
}

/// One compiled glob token.
#[derive(Clone, Copy)]
enum Token {
    Literal(char),
    /// `*`: ICU `[^/]*`.
    Segment,
    /// `**`: ICU `.*`, which stops at a line terminator.
    Deep,
    /// `?`: ICU `[^/]`.
    One,
}

/// ICU's line terminators, which `.` does not match.
fn line_terminator(c: char) -> bool {
    matches!(
        c,
        '\u{a}' | '\u{b}' | '\u{c}' | '\u{d}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Swift `matches(_:glob:)`: the whole path against the glob's regular
/// expression, scalar by scalar.
pub(crate) fn matches(path: &str, glob: &str) -> bool {
    if !is_safe_glob(glob) {
        return false;
    }
    let characters: Vec<char> = glob.chars().collect();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < characters.len() {
        match characters[index] {
            '*' if characters.get(index + 1) == Some(&'*') => {
                tokens.push(Token::Deep);
                index += 2;
                continue;
            }
            '*' => tokens.push(Token::Segment),
            '?' => tokens.push(Token::One),
            literal => tokens.push(Token::Literal(literal)),
        }
        index += 1;
    }
    let text: Vec<char> = path.chars().collect();
    // Row `next[j]`: the tokens after the current one match text[j..].
    let mut next = vec![false; text.len() + 1];
    next[text.len()] = true;
    for token in tokens.iter().rev() {
        let mut row = vec![false; text.len() + 1];
        for j in (0..=text.len()).rev() {
            row[j] = match token {
                Token::Literal(c) => j < text.len() && text[j] == *c && next[j + 1],
                Token::One => j < text.len() && text[j] != '/' && next[j + 1],
                Token::Segment => next[j] || (j < text.len() && text[j] != '/' && row[j + 1]),
                Token::Deep => {
                    next[j] || (j < text.len() && !line_terminator(text[j]) && row[j + 1])
                }
            };
        }
        next = row;
    }
    next[0]
}

/// Swift `globMayMatchDescendant(directory:glob:)`: only the literal prefix
/// before the first wildcard prunes.
pub(crate) fn glob_may_match_descendant(directory: &str, glob: &str) -> bool {
    if !is_safe_glob(glob) || !is_safe_relative_path(directory) {
        return false;
    }
    let wildcard = glob.find(['*', '?', '[']).unwrap_or(glob.len());
    let prefix = glob[..wildcard].trim_matches('/');
    if prefix.is_empty() {
        return true;
    }
    prefix == directory
        || prefix.starts_with(&format!("{directory}/"))
        || directory.starts_with(prefix)
}

/// Swift `globEnumerationAnchor`: the narrowest directory without a
/// wildcard; none is the project root.
pub(crate) fn glob_enumeration_anchor(glob: &str) -> Option<String> {
    if !is_safe_glob(glob) {
        return None;
    }
    let Some(wildcard) = glob.find(['*', '?', '[']) else {
        let components: Vec<&str> = glob.split('/').filter(|c| !c.is_empty()).collect();
        if components.len() <= 1 {
            return None;
        }
        return Some(components[..components.len() - 1].join("/"));
    };
    let literal = &glob[..wildcard];
    if let Some(directory) = literal.strip_suffix('/') {
        return (!directory.is_empty()).then(|| directory.to_owned());
    }
    let separator = literal.rfind('/')?;
    let directory = &literal[..separator];
    (!directory.is_empty()).then(|| directory.to_owned())
}

/// The separator of an absolute path on this host.
#[cfg(not(windows))]
pub(crate) const SEPARATOR: char = '/';
#[cfg(windows)]
pub(crate) const SEPARATOR: char = '\\';

/// Whether `path` is an explicit absolute path as this host spells one:
/// `/…`, or on Windows a drive and its root (`X:\…`; `X:/…` is read the
/// same way and standardized to the former).
pub(crate) fn is_absolute(path: &str) -> bool {
    #[cfg(not(windows))]
    return path.starts_with('/');
    #[cfg(windows)]
    {
        let bytes = path.as_bytes();
        bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/')
    }
}

/// `relative` (Swift's `/`-separated spelling) under the absolute `root`.
pub(crate) fn join(root: &str, relative: &str) -> String {
    #[cfg(not(windows))]
    return format!("{root}/{relative}");
    #[cfg(windows)]
    return format!(
        "{}\\{}",
        root.trim_end_matches('\\'),
        relative.replace('/', "\\")
    );
}

/// The `/`-separated path of `path` strictly below `root`, if it is one.
pub(crate) fn relative_to(path: &str, root: &str) -> Option<String> {
    let rest = path.strip_prefix(root)?.strip_prefix(SEPARATOR)?;
    (!rest.is_empty()).then(|| rest.replace(SEPARATOR, "/"))
}

/// Whether `path` is `root` or lies below it.
pub(crate) fn is_within(path: &str, root: &str) -> bool {
    path == root
        || path
            .strip_prefix(root)
            .is_some_and(|rest| rest.starts_with(SEPARATOR))
}

/// Foundation's lexical standardization of an absolute path: empty and `.`
/// components dropped, `..` climbing no higher than the root.
#[cfg(not(windows))]
fn lexical(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

/// On Windows: the drive kept (its letter as written), `/` read as `\`,
/// empty and `.` components dropped, `..` climbing no higher than the
/// drive's root. A path without a drive is standardized as relative text.
#[cfg(windows)]
fn lexical(path: &str) -> String {
    let (drive, rest) = if is_absolute(path) {
        (&path[..2], &path[2..])
    } else {
        ("", path)
    };
    let mut parts: Vec<&str> = Vec::new();
    for component in rest.split(['/', '\\']) {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("{drive}\\{}", parts.join("\\"))
}

/// Foundation drops a leading `/private` when what remains still exists.
#[cfg(not(windows))]
fn without_private(path: String) -> String {
    match path.strip_prefix("/private") {
        Some(rest) if rest.starts_with('/') && fs::metadata(rest).is_ok() => rest.to_owned(),
        _ => path,
    }
}

/// No `/private` firmlink exists on Windows.
#[cfg(windows)]
fn without_private(path: String) -> String {
    path
}

/// Swift `URL(filePath:).resolvingSymlinksInPath().standardizedFileURL.path`.
#[cfg(not(windows))]
pub(crate) fn foundation_resolved(path: &str) -> String {
    match fs::canonicalize(path) {
        Ok(physical) => match physical.to_str() {
            Some(physical) => without_private(physical.to_owned()),
            None => without_private(lexical(path)),
        },
        Err(_) => without_private(lexical(path)),
    }
}

/// On Windows: the handle's final path (links and junctions resolved, the
/// spelling on disk) when the entry opens, otherwise the lexical form.
#[cfg(windows)]
pub(crate) fn foundation_resolved(path: &str) -> String {
    let lexical = lexical(path);
    if !is_absolute(path) {
        return lexical;
    }
    arkdeck_platform::host_resolved_path(Path::new(&lexical))
        .and_then(|resolved| resolved.to_str().map(str::to_owned))
        .unwrap_or(lexical)
}

/// Swift `URL(filePath:).standardizedFileURL.path` of a path without `..`.
pub(crate) fn foundation_standardized(path: &str) -> String {
    without_private(lexical(path))
}

/// `path` and every missing ancestor created owner-only
/// (`DirBuilder::new().recursive(true).mode(0o700)`; on Windows the private
/// descriptor). Existing levels are left as they are.
pub(crate) fn create_private_directories(path: &Path) -> io::Result<()> {
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
    }
    #[cfg(windows)]
    arkdeck_platform::create_private_directories(path)
}

/// The existing entry at `path` opened for reading (or writing), never
/// through a link: `O_NOFOLLOW`, or on Windows the entry itself opened and
/// refused when it is a reparse point.
pub(crate) fn open_no_follow(path: &Path, write: bool) -> io::Result<File> {
    let mut options = fs::OpenOptions::new();
    options.read(!write).write(write);
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
        options.open(path)
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
        let file = options.open(path)?;
        if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a link is not followed",
            ));
        }
        Ok(file)
    }
}

/// A staged file at `path` opened for writing owner-only and never through a
/// link, replacing a stale one (`create`, `truncate`, `0o600`,
/// `O_NOFOLLOW`; on Windows a stale entry is removed and the file created
/// new with the private descriptor).
pub(crate) fn create_private_staged(path: &Path) -> io::Result<File> {
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
    }
    #[cfg(windows)]
    {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_dir() => return Err(io::ErrorKind::AlreadyExists.into()),
            Ok(_) => fs::remove_file(path)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        arkdeck_platform::create_private_file(path)
    }
}

/// Swift's `String` order: NFC scalars, which is UTF-8 byte order of the NFC
/// spelling.
pub(crate) fn swift_sort(values: &mut [String]) {
    values.sort_by_cached_key(|value| {
        arkdeck_platform::host_canonical_text(value).unwrap_or_else(|| value.clone())
    });
}

/// One enumeration of a scope anchor, as Swift's `files` loop runs it.
struct Walk<'a> {
    root: &'a str,
    profile_globs: &'a [String],
    request_globs: &'a [String],
    visited: usize,
    found: HashSet<String>,
}

/// Why a walk stopped early.
enum Stop {
    /// Swift's enumerator error handler, which ends the enumeration.
    EnumerationFailed,
    Refused(Refusal),
}

impl Walk<'_> {
    fn directory(&mut self, directory: &str) -> Result<(), Stop> {
        let mut names: Vec<String> = Vec::new();
        for entry in fs::read_dir(directory).map_err(|_| Stop::EnumerationFailed)? {
            let entry = entry.map_err(|_| Stop::EnumerationFailed)?;
            names.push(
                entry
                    .file_name()
                    .into_string()
                    .map_err(|_| Stop::EnumerationFailed)?,
            );
        }
        names.sort();
        for name in names {
            let path = join(directory, &name);
            let metadata = fs::symlink_metadata(&path).map_err(|_| Stop::EnumerationFailed)?;
            let kind = metadata.file_type();
            let (hidden, package) = presentation(&path, &name, &metadata)?;
            if hidden {
                continue;
            }
            self.visited += 1;
            if self.visited > MAXIMUM_VISITED {
                return Err(Stop::Refused(
                    "workspace inspection enumeration exceeds 20000 entries".into(),
                ));
            }
            let relative = &relative_to(&path, self.root).ok_or(Stop::EnumerationFailed)?;
            if kind.is_dir() {
                if !package
                    && self
                        .profile_globs
                        .iter()
                        .any(|glob| glob_may_match_descendant(relative, glob))
                    && self
                        .request_globs
                        .iter()
                        .any(|glob| glob_may_match_descendant(relative, glob))
                {
                    self.directory(&path)?;
                }
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let canonical = foundation_resolved(&path);
            let Some(relative) = relative_to(&canonical, self.root) else {
                return Err(Stop::Refused(
                    "workspace source path escapes the canonical project root".into(),
                ));
            };
            if self
                .profile_globs
                .iter()
                .any(|glob| matches(&relative, glob))
                && self
                    .request_globs
                    .iter()
                    .any(|glob| matches(&relative, glob))
            {
                self.found.insert(canonical.clone());
                if self.found.len() > MAXIMUM_MATCHED {
                    return Err(Stop::Refused(
                        "workspace inspection scope exceeds 2000 files".into(),
                    ));
                }
            }
        }
        Ok(())
    }
}

/// Foundation's hidden and package keys of one enumerated entry.
#[cfg(not(windows))]
fn presentation(path: &str, _name: &str, metadata: &fs::Metadata) -> Result<(bool, bool), Stop> {
    arkdeck_platform::host_entry_presentation(Path::new(path), metadata.is_dir())
        .map(|presentation| (presentation.hidden, presentation.package))
        .map_err(|_| Stop::EnumerationFailed)
}

/// On Windows: hidden by a leading `.` or the hidden attribute; no
/// directory is a package.
#[cfg(windows)]
fn presentation(_path: &str, name: &str, metadata: &fs::Metadata) -> Result<(bool, bool), Stop> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    Ok((
        name.starts_with('.') || metadata.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0,
        false,
    ))
}

/// Swift `files(root:profileGlobs:requestGlobs:)`: every regular file under
/// the canonical root that both glob sets match, as canonical paths in Swift
/// order.
pub(crate) fn files(
    root: &str,
    profile_globs: &[String],
    request_globs: &[String],
) -> Result<Vec<String>, Refusal> {
    if request_globs.is_empty()
        || request_globs.len() > 64
        || !request_globs.iter().all(|glob| is_safe_glob(glob))
    {
        return Err("workspace file scope globs are empty or unsafe".into());
    }
    let canonical_root = foundation_resolved(root);
    let mut anchors: Vec<Option<String>> = request_globs
        .iter()
        .map(|glob| glob_enumeration_anchor(glob))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    anchors.sort_by(|left, right| {
        left.as_deref()
            .unwrap_or("")
            .cmp(right.as_deref().unwrap_or(""))
    });
    let mut walk = Walk {
        root: &canonical_root,
        profile_globs,
        request_globs,
        visited: 0,
        found: HashSet::new(),
    };
    for anchor in anchors {
        let anchor_path = match &anchor {
            Some(anchor) => join(&canonical_root, anchor),
            None => canonical_root.clone(),
        };
        let lexical_anchor = foundation_standardized(&anchor_path);
        if !is_within(&lexical_anchor, &canonical_root) {
            return Err("workspace enumeration anchor escapes the canonical project root".into());
        }
        if fs::metadata(&lexical_anchor).is_err() {
            continue;
        }
        let Ok(kind) = fs::symlink_metadata(&anchor_path).map(|m| m.file_type()) else {
            return Err("workspace source scope cannot be enumerated".into());
        };
        if !kind.is_dir() || kind.is_symlink() {
            continue;
        }
        // Swift standardizes every enumerated path before it reads the
        // relative one, so the walk runs from the standardized anchor.
        match walk.directory(&lexical_anchor) {
            Ok(()) => {}
            Err(Stop::Refused(refusal)) => return Err(refusal),
            Err(Stop::EnumerationFailed) => {
                return Err("workspace source scope enumeration failed".into());
            }
        }
    }
    let mut found: Vec<String> = walk.found.into_iter().collect();
    swift_sort(&mut found);
    Ok(found)
}

/// Foundation's `.whitespacesAndNewlines` trimmed from both ends.
fn trimmed(text: &str) -> &str {
    text.trim_matches(arkdeck_platform::host_whitespace_or_newline)
}

/// A file's UTF-8 text, as Swift's `String(contentsOf:encoding: .utf8)`.
fn text(path: &Path) -> Option<String> {
    String::from_utf8(fs::read(path).ok()?).ok()
}

/// Swift `headOID(gitDirectory:)`: a detached HEAD holds the id; a symbolic
/// one names a loose ref, or a packed one.
fn head_oid(git: &Path) -> Option<String> {
    let head = text(&git.join("HEAD"))?;
    let head = trimmed(&head);
    let Some(reference) = head.strip_prefix("ref: ") else {
        return (!head.is_empty()).then(|| head.to_owned());
    };
    if let Some(loose) = text(&git.join(reference)) {
        let value = trimmed(&loose);
        if !value.is_empty() {
            return Some(value.to_owned());
        }
    }
    let packed = text(&git.join("packed-refs"))?;
    let suffix = format!(" {reference}");
    packed
        .split('\n')
        .filter(|line| !line.is_empty())
        .find(|line| line.ends_with(&suffix))
        .map(|line| line.split(' ').next().unwrap_or_default().to_owned())
}

/// Swift `workspaceRevision(root:profileVersion:globs:)`: what the tree is,
/// from HEAD, the index file and every scoped file's digest.
pub(crate) fn workspace_revision(
    root: &str,
    profile_version: &str,
    globs: &[String],
) -> Result<String, Refusal> {
    let canonical_root = foundation_resolved(root);
    let git = Path::new(&canonical_root).join(".git");
    let mut material = format!("profileVersion\t{profile_version}\n");
    material.push_str(&format!(
        "head\t{}\n",
        head_oid(&git).unwrap_or_else(|| "absent".into())
    ));
    let index = fs::read(git.join("index"))
        .map(|bytes| sha256(&bytes))
        .unwrap_or_else(|_| "absent".into());
    material.push_str(&format!("index\t{index}\n"));
    for path in files(&canonical_root, globs, globs)? {
        let relative = relative_to(&path, &canonical_root).unwrap_or_default();
        let digest = fs::read(&path)
            .map(|bytes| sha256(&bytes))
            .unwrap_or_else(|_| "absent".into());
        material.push_str(&format!("file\t{relative}\t{digest}\n"));
    }
    Ok(sha256(material.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn narrowing_follows_swifts_three_rules() {
        assert!(is_narrower("Sources/App.txt", "Sources/**"));
        assert!(is_narrower("Sources", "Sources/**"));
        assert!(is_narrower("Sources/a/b", "Sources/**"));
        assert!(!is_narrower("Other/App.txt", "Sources/**"));
        assert!(is_narrower("Sources/App.txt", "Sources/*"));
        assert!(!is_narrower("Sources/a/b", "Sources/*"));
        assert!(is_narrower("exact", "exact"));
        assert!(!is_narrower("Sources/App.txt", "Sources/*.txt"));
    }

    #[test]
    fn globs_compile_as_swifts_regular_expression() {
        assert!(matches("Sources/App.txt", "Sources/**"));
        assert!(matches("Sources/a/b.txt", "Sources/**"));
        assert!(!matches("Sources/a/b.txt", "Sources/*"));
        assert!(matches("Sources/App.txt", "Sources/*.txt"));
        assert!(matches("Sources/A.txt", "Sources/?.txt"));
        assert!(!matches("Sources/AB.txt", "Sources/?.txt"));
        assert!(matches("a.b", "a.b"));
        assert!(!matches("axb", "a.b"), "a dot is literal");
        assert!(
            !matches("Sources/x\ny", "Sources/**"),
            "** stops at a line end"
        );
        assert!(matches("Sources/x\ny", "Sources/*"), "* crosses a line end");
        assert!(!matches("x", "../x"), "an unsafe glob matches nothing");
        assert!(!matches(".git/config", ".git/**"));
        assert!(
            !matches(".github/x", ".github/**"),
            "Swift refuses a .git prefix"
        );
    }

    #[test]
    fn anchors_and_descendant_pruning_match_swift() {
        assert_eq!(
            glob_enumeration_anchor("Sources/**").as_deref(),
            Some("Sources")
        );
        assert_eq!(
            glob_enumeration_anchor("Sources/App.txt").as_deref(),
            Some("Sources")
        );
        assert_eq!(glob_enumeration_anchor("App.txt"), None);
        assert_eq!(glob_enumeration_anchor("*.txt"), None);
        assert_eq!(
            glob_enumeration_anchor("entry/src/main/ets/**").as_deref(),
            Some("entry/src/main/ets")
        );
        assert_eq!(
            glob_enumeration_anchor("a/b*/c").as_deref(),
            Some("a"),
            "the literal before the wildcard ends at its last slash"
        );
        assert!(glob_may_match_descendant("entry", "entry/src/**"));
        assert!(glob_may_match_descendant("entry/src/main", "entry/src/**"));
        assert!(!glob_may_match_descendant("build", "entry/src/**"));
        assert!(glob_may_match_descendant("anything", "**"));
        assert!(!glob_may_match_descendant(".git", "**"));
    }

    #[cfg(not(windows))]
    #[test]
    fn foundation_paths_drop_private_only_when_the_rest_exists() {
        let temporary = fs::canonicalize("/tmp").unwrap();
        assert_eq!(temporary.to_str().unwrap(), "/private/tmp");
        assert_eq!(foundation_resolved("/private/tmp"), "/tmp");
        assert_eq!(foundation_resolved("/tmp/./x/../"), "/tmp");
        assert_eq!(
            foundation_resolved("/private/tmp/arkdeck-no-such-entry/x"),
            "/private/tmp/arkdeck-no-such-entry/x"
        );
        assert_eq!(foundation_standardized("/private/etc/hosts"), "/etc/hosts");
    }

    #[cfg(windows)]
    #[test]
    fn windows_paths_keep_the_drive_and_join_relative_paths_with_backslashes() {
        assert!(is_absolute(r"D:\p") && is_absolute("D:/p"));
        assert!(!is_absolute(r"\p") && !is_absolute("p") && !is_absolute("D:p"));
        assert_eq!(foundation_standardized(r"D:\a\.\b\..\c\"), r"D:\a\c");
        assert_eq!(foundation_standardized("D:/a//b"), r"D:\a\b");
        assert_eq!(foundation_standardized(r"D:\..\.."), r"D:\");
        assert_eq!(join(r"D:\p", "entry/src/a.ets"), r"D:\p\entry\src\a.ets");
        assert_eq!(
            relative_to(r"D:\p\entry\a.ets", r"D:\p").as_deref(),
            Some("entry/a.ets")
        );
        assert_eq!(relative_to(r"D:\p", r"D:\p"), None);
        assert_eq!(relative_to(r"D:\pq\a", r"D:\p"), None);
        assert!(is_within(r"D:\p\a", r"D:\p") && is_within(r"D:\p", r"D:\p"));
        assert!(!is_within(r"D:\pq", r"D:\p"));
        // A drive or stream colon is never a relative path.
        assert!(!is_safe_relative_path("a:b") && !is_safe_glob("a:*"));
    }

    #[test]
    fn swift_order_is_nfc_scalar_order() {
        let mut values = vec![
            "f.txt".to_owned(),
            "e\u{301}.txt".to_owned(),
            "Z.txt".to_owned(),
            "z.txt".to_owned(),
        ];
        swift_sort(&mut values);
        assert_eq!(values, ["Z.txt", "f.txt", "z.txt", "e\u{301}.txt"]);
    }
}
