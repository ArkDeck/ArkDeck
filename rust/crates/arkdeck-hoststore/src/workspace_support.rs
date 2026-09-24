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
//! A refusal is the detail Swift's `DeviceProviderError` describes itself by.
use arkdeck_contract::sha256_hex;
use std::collections::HashSet;
use std::fs;
use std::path::Path;

/// Swift's refusal detail.
pub(crate) type Refusal = String;

const MAXIMUM_VISITED: usize = 20_000;
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

/// Foundation's lexical standardization of an absolute path: empty and `.`
/// components dropped, `..` climbing no higher than the root.
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

/// Foundation drops a leading `/private` when what remains still exists.
fn without_private(path: String) -> String {
    match path.strip_prefix("/private") {
        Some(rest) if rest.starts_with('/') && fs::metadata(rest).is_ok() => rest.to_owned(),
        _ => path,
    }
}

/// Swift `URL(filePath:).resolvingSymlinksInPath().standardizedFileURL.path`.
pub(crate) fn foundation_resolved(path: &str) -> String {
    match fs::canonicalize(path) {
        Ok(physical) => match physical.to_str() {
            Some(physical) => without_private(physical.to_owned()),
            None => without_private(lexical(path)),
        },
        Err(_) => without_private(lexical(path)),
    }
}

/// Swift `URL(filePath:).standardizedFileURL.path` of a path without `..`.
pub(crate) fn foundation_standardized(path: &str) -> String {
    without_private(lexical(path))
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
            let path = format!("{directory}/{name}");
            let kind = fs::symlink_metadata(&path)
                .map_err(|_| Stop::EnumerationFailed)?
                .file_type();
            let presentation =
                arkdeck_platform::host_entry_presentation(Path::new(&path), kind.is_dir())
                    .map_err(|_| Stop::EnumerationFailed)?;
            if presentation.hidden {
                continue;
            }
            self.visited += 1;
            if self.visited > MAXIMUM_VISITED {
                return Err(Stop::Refused(
                    "workspace inspection enumeration exceeds 20000 entries".into(),
                ));
            }
            let relative = &path[self.root.len() + 1..];
            if kind.is_dir() {
                if !presentation.package
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
            let Some(relative) = canonical.strip_prefix(&format!("{}/", self.root)) else {
                return Err(Stop::Refused(
                    "workspace source path escapes the canonical project root".into(),
                ));
            };
            if self
                .profile_globs
                .iter()
                .any(|glob| matches(relative, glob))
                && self
                    .request_globs
                    .iter()
                    .any(|glob| matches(relative, glob))
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
            Some(anchor) => format!("{canonical_root}/{anchor}"),
            None => canonical_root.clone(),
        };
        let lexical_anchor = foundation_standardized(&anchor_path);
        if lexical_anchor != canonical_root
            && !lexical_anchor.starts_with(&format!("{canonical_root}/"))
        {
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
        let relative = path[canonical_root.len()..].trim_start_matches('/');
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
