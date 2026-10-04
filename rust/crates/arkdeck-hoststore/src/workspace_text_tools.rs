//! The code-owned source tools a Windows workspace profile pins in place of
//! macOS's `/usr/bin/grep`, `/usr/bin/sed` and `/usr/bin/patch` (TASK-XPA-011,
//! maintainer ruling of 2026-10-04): the three, reimplemented in Rust for
//! exactly the argv the workspace provider builds, answering as the macOS
//! (FreeBSD-derived) tools answer — the same exit status, stdout, stderr and
//! tree — for the inputs the profiles use. No external binary is trusted for
//! them: the daemon runs its own image as each tool
//! (`arkdeck-agentd --workspace-tool <grep|sed|patch> <argv>`), so a plan pins
//! the daemon's digest and the dispatch keeps its process bound, timeout and
//! receipt.
//!
//! - `grep -r -n --include <glob> -- <pattern> <root>`: every line of every
//!   regular file below `root` whose name `glob` matches (`fnmatch`) that the
//!   basic regular expression `pattern` matches, as `<path>:<n>:<line>`;
//!   `Binary file <path> matches` once for a file with a NUL byte in its
//!   first 32 KiB. Directories are walked in byte order of their names (the
//!   macOS walk's order is the file system's, so a multi-file answer is
//!   compared as a set there); links are not followed.
//! - `sed -n <a>,<b>p <file>`: lines `a` through `b` (only `a` when `b < a`),
//!   each with its newline, a missing final newline supplied.
//! - `patch -f [-R] -p1 -d <root> -i <file>`: BSD patch's unified-diff apply
//!   (Plan A): each file's hunks located at their line, then at growing
//!   offsets, then with up to two lines of fuzz, written in place; BSD's
//!   "Hmm..." narration, "Patching file … using Plan A...", per-hunk lines,
//!   "done", and for a hunk that does not apply its rejects beside the file
//!   and exit status 1.
//!
//! Any other argv is refused with exit status 2 (grep, patch) or 1 (sed)
//! before anything is read, as the tools refuse an argv they do not accept.
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// What one run of a tool answered.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TextToolOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// The daemon's child mode that runs one of these tools:
/// `arkdeck-agentd --workspace-tool <tool> <argv>`.
pub const WORKSPACE_TOOL_FLAG: &str = "--workspace-tool";

/// The tools this module implements, by the name the daemon's child mode
/// takes.
pub const TEXT_TOOLS: [&str; 3] = ["grep", "sed", "patch"];

/// Runs `tool` over `arguments` (the argv after the tool's own name).
pub fn run_text_tool(tool: &str, arguments: &[String]) -> TextToolOutput {
    match tool {
        "grep" => grep(arguments),
        "sed" => sed(arguments),
        "patch" => patch(arguments),
        _ => TextToolOutput {
            status: 2,
            stdout: Vec::new(),
            stderr: format!("arkdeck-agentd: {tool}: no such workspace tool\n").into_bytes(),
        },
    }
}

/// The daemon's child mode: the tool's answer on the process's own streams,
/// its status as the exit status.
pub fn workspace_tool_main(arguments: &[String]) -> i32 {
    let Some((tool, rest)) = arguments.split_first() else {
        let _ = std::io::stderr().write_all(b"usage: arkdeck-agentd --workspace-tool <tool> ...\n");
        return 2;
    };
    let output = run_text_tool(tool, rest);
    let _ = std::io::stdout().write_all(&output.stdout);
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().write_all(&output.stderr);
    output.status
}

fn lines_of(bytes: &[u8]) -> Vec<&[u8]> {
    let mut lines: Vec<&[u8]> = bytes.split(|&byte| byte == b'\n').collect();
    if bytes.is_empty() || bytes.ends_with(b"\n") {
        lines.pop();
    }
    lines
}

fn os_error_text(error: &std::io::Error) -> &'static str {
    match error.kind() {
        std::io::ErrorKind::NotFound => "No such file or directory",
        std::io::ErrorKind::PermissionDenied => "Permission denied",
        _ if error.raw_os_error().is_some() => "Input/output error",
        _ => "Is a directory",
    }
}

// MARK: - sed

fn sed(arguments: &[String]) -> TextToolOutput {
    let usage = || {
        TextToolOutput {
        status: 1,
        stdout: Vec::new(),
        stderr: b"usage: sed script [-Ealn] [-i extension] [file ...]\n       sed [-Ealn] [-i extension] [-e script] ... [-f script_file] ... [file ...]\n".to_vec(),
    }
    };
    let [flag, script, file] = arguments else {
        return usage();
    };
    if flag != "-n" {
        return usage();
    }
    let Some((first, last)) = script
        .strip_suffix('p')
        .and_then(|range| range.split_once(','))
        .and_then(|(first, last)| Some((line_number(first)?, line_number(last)?)))
    else {
        return TextToolOutput {
            status: 1,
            stdout: Vec::new(),
            stderr: format!("sed: 1: \"{script}\": unsupported workspace sed script\n")
                .into_bytes(),
        };
    };
    if first == 0 || last == 0 {
        return TextToolOutput {
            status: 1,
            stdout: Vec::new(),
            stderr: format!("sed: 1: \"{script}\": invalid usage of line address 0\n").into_bytes(),
        };
    }
    let bytes = match fs::read(file) {
        Ok(bytes) => bytes,
        Err(error) => {
            return TextToolOutput {
                status: 1,
                stdout: Vec::new(),
                stderr: format!("sed: {file}: {}\n", os_error_text(&error)).into_bytes(),
            };
        }
    };
    let mut stdout = Vec::new();
    for (index, line) in lines_of(&bytes).iter().enumerate() {
        let number = index as u64 + 1;
        if number == first || (number > first && number <= last) {
            stdout.extend_from_slice(line);
            stdout.push(b'\n');
        }
    }
    TextToolOutput {
        status: 0,
        stdout,
        stderr: Vec::new(),
    }
}

fn line_number(text: &str) -> Option<u64> {
    (!text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

// MARK: - grep

fn grep(arguments: &[String]) -> TextToolOutput {
    let usage = || TextToolOutput {
        status: 2,
        stdout: Vec::new(),
        stderr: b"grep: unsupported workspace grep arguments\n".to_vec(),
    };
    let [recursive, numbered, include, glob, separator, pattern, root] = arguments else {
        return usage();
    };
    if (
        recursive.as_str(),
        numbered.as_str(),
        include.as_str(),
        separator.as_str(),
    ) != ("-r", "-n", "--include", "--")
    {
        return usage();
    }
    let Some(expression) = Regex::compile(pattern.as_bytes()) else {
        return TextToolOutput {
            status: 2,
            stdout: Vec::new(),
            stderr: b"grep: unsupported workspace grep pattern\n".to_vec(),
        };
    };
    let mut output = TextToolOutput::default();
    let mut matched = false;
    let mut failed = false;
    let root_path = Path::new(root);
    match fs::symlink_metadata(root_path) {
        Ok(metadata) if metadata.is_dir() => walk(
            root,
            glob,
            &expression,
            &mut output,
            &mut matched,
            &mut failed,
        ),
        Ok(metadata) if metadata.is_file() => {
            if fnmatch(glob.as_bytes(), file_name(root).as_bytes()) {
                search(root, &expression, &mut output, &mut matched, &mut failed);
            }
        }
        Ok(_) => {}
        Err(error) => {
            output
                .stderr
                .extend(format!("grep: {root}: {}\n", os_error_text(&error)).bytes());
            failed = true;
        }
    }
    output.status = match (matched, failed) {
        (_, true) => 2,
        (true, false) => 0,
        (false, false) => 1,
    };
    output
}

fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

fn child(directory: &str, name: &str) -> String {
    if directory.ends_with('/') || directory.ends_with('\\') {
        format!("{directory}{name}")
    } else if cfg!(windows) && !directory.contains('/') {
        format!("{directory}\\{name}")
    } else {
        format!("{directory}/{name}")
    }
}

fn walk(
    directory: &str,
    glob: &str,
    expression: &Regex,
    output: &mut TextToolOutput,
    matched: &mut bool,
    failed: &mut bool,
) {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) => {
            output
                .stderr
                .extend(format!("grep: {directory}: {}\n", os_error_text(&error)).bytes());
            *failed = true;
            return;
        }
    };
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .collect();
    names.sort();
    for name in names {
        let path = child(directory, &name);
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.is_dir() {
            walk(&path, glob, expression, output, matched, failed);
        } else if metadata.is_file() && fnmatch(glob.as_bytes(), name.as_bytes()) {
            search(&path, expression, output, matched, failed);
        }
    }
}

fn search(
    path: &str,
    expression: &Regex,
    output: &mut TextToolOutput,
    matched: &mut bool,
    failed: &mut bool,
) {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            output
                .stderr
                .extend(format!("grep: {path}: {}\n", os_error_text(&error)).bytes());
            *failed = true;
            return;
        }
    };
    let binary = bytes[..bytes.len().min(32 * 1024)].contains(&0);
    for (index, line) in lines_of(&bytes).iter().enumerate() {
        if expression.matches(line) {
            *matched = true;
            if binary {
                output
                    .stdout
                    .extend(format!("Binary file {path} matches\n").bytes());
                return;
            }
            output
                .stdout
                .extend(format!("{path}:{}:", index + 1).bytes());
            output.stdout.extend_from_slice(line);
            output.stdout.push(b'\n');
        }
    }
}

/// `fnmatch(3)` without flags: `*`, `?`, bracket expressions and `\`
/// escapes over bytes.
fn fnmatch(pattern: &[u8], text: &[u8]) -> bool {
    match pattern.split_first() {
        None => text.is_empty(),
        Some((b'*', rest)) => (0..=text.len()).any(|skip| fnmatch(rest, &text[skip..])),
        Some((b'?', rest)) => !text.is_empty() && fnmatch(rest, &text[1..]),
        Some((b'[', rest)) => match bracket(rest) {
            Some((set, after)) => {
                !text.is_empty() && set.matches(text[0]) && fnmatch(after, &text[1..])
            }
            None => text.first() == Some(&b'[') && fnmatch(rest, &text[1..]),
        },
        Some((b'\\', rest)) if !rest.is_empty() => {
            text.first() == Some(&rest[0]) && fnmatch(&rest[1..], &text[1..])
        }
        Some((&byte, rest)) => text.first() == Some(&byte) && fnmatch(rest, &text[1..]),
    }
}

/// A bracket expression's members.
#[derive(Clone, Debug)]
struct ByteSet {
    negated: bool,
    ranges: Vec<(u8, u8)>,
}

impl ByteSet {
    fn matches(&self, byte: u8) -> bool {
        self.ranges
            .iter()
            .any(|&(low, high)| low <= byte && byte <= high)
            != self.negated
    }
}

/// The bracket expression after its `[`: its members and what follows `]`.
fn bracket(pattern: &[u8]) -> Option<(ByteSet, &[u8])> {
    let mut index = 0;
    let negated = matches!(pattern.first(), Some(b'!' | b'^'));
    if negated {
        index += 1;
    }
    let mut ranges = Vec::new();
    let mut first = true;
    while index < pattern.len() {
        let byte = pattern[index];
        if byte == b']' && !first {
            return Some((ByteSet { negated, ranges }, &pattern[index + 1..]));
        }
        if byte == b'[' && pattern.get(index + 1) == Some(&b':') {
            let end = pattern[index + 2..]
                .windows(2)
                .position(|window| window == b":]")?;
            let class = &pattern[index + 2..index + 2 + end];
            ranges.extend(class_ranges(class)?);
            index += end + 4;
            first = false;
            continue;
        }
        if pattern.get(index + 1) == Some(&b'-')
            && pattern.get(index + 2).is_some_and(|&high| high != b']')
        {
            ranges.push((byte, pattern[index + 2]));
            index += 3;
        } else {
            ranges.push((byte, byte));
            index += 1;
        }
        first = false;
    }
    None
}

fn class_ranges(class: &[u8]) -> Option<Vec<(u8, u8)>> {
    Some(match class {
        b"alpha" => vec![(b'a', b'z'), (b'A', b'Z')],
        b"digit" => vec![(b'0', b'9')],
        b"alnum" => vec![(b'a', b'z'), (b'A', b'Z'), (b'0', b'9')],
        b"upper" => vec![(b'A', b'Z')],
        b"lower" => vec![(b'a', b'z')],
        b"space" => vec![(b' ', b' '), (b'\t', b'\r')],
        b"blank" => vec![(b' ', b' '), (b'\t', b'\t')],
        b"punct" => vec![(b'!', b'/'), (b':', b'@'), (b'[', b'`'), (b'{', b'~')],
        b"xdigit" => vec![(b'0', b'9'), (b'a', b'f'), (b'A', b'F')],
        _ => return None,
    })
}

/// One basic-regular-expression atom.
#[derive(Clone, Debug)]
enum Atom {
    Byte(u8),
    Any,
    Set(ByteSet),
}

impl Atom {
    fn matches(&self, byte: u8) -> bool {
        match self {
            Self::Byte(expected) => *expected == byte,
            Self::Any => true,
            Self::Set(set) => set.matches(byte),
        }
    }
}

/// A basic regular expression of literal bytes, `.`, bracket expressions,
/// `*` and the `^`/`$` anchors (POSIX BRE without groups, intervals or back
/// references, which the workspace inspection refuses).
#[derive(Clone, Debug)]
struct Regex {
    anchored_start: bool,
    anchored_end: bool,
    pieces: Vec<(Atom, bool)>,
}

impl Regex {
    fn compile(pattern: &[u8]) -> Option<Self> {
        let mut index = 0;
        let anchored_start = pattern.first() == Some(&b'^');
        if anchored_start {
            index = 1;
        }
        let mut end = pattern.len();
        let anchored_end = end > index
            && pattern[end - 1] == b'$'
            && !(end >= 2 + index && pattern[end - 2] == b'\\');
        if anchored_end {
            end -= 1;
        }
        let mut pieces: Vec<(Atom, bool)> = Vec::new();
        while index < end {
            let byte = pattern[index];
            let atom = match byte {
                b'.' => {
                    index += 1;
                    Atom::Any
                }
                b'[' => {
                    let (set, rest) = bracket(&pattern[index + 1..end])?;
                    index = end - rest.len();
                    Atom::Set(set)
                }
                b'\\' => {
                    let escaped = *pattern.get(index + 1).filter(|_| index + 1 < end)?;
                    if escaped.is_ascii_alphanumeric()
                        || matches!(escaped, b'(' | b')' | b'{' | b'}' | b'<' | b'>')
                    {
                        return None;
                    }
                    index += 2;
                    Atom::Byte(escaped)
                }
                b'*' if pieces.is_empty() => {
                    // A leading `*` is literal in a BRE.
                    index += 1;
                    Atom::Byte(b'*')
                }
                b'*' => {
                    let last = pieces.last_mut()?;
                    if last.1 {
                        // `**` repeats the starred atom: the same language.
                        index += 1;
                        continue;
                    }
                    last.1 = true;
                    index += 1;
                    continue;
                }
                other => {
                    index += 1;
                    Atom::Byte(other)
                }
            };
            pieces.push((atom, false));
        }
        Some(Self {
            anchored_start,
            anchored_end,
            pieces,
        })
    }

    fn matches(&self, line: &[u8]) -> bool {
        if self.anchored_start {
            return self.here(0, line, 0);
        }
        (0..=line.len()).any(|start| self.here(0, line, start))
    }

    fn here(&self, piece: usize, line: &[u8], at: usize) -> bool {
        let Some((atom, starred)) = self.pieces.get(piece) else {
            return !self.anchored_end || at == line.len();
        };
        if *starred {
            let mut end = at;
            while end < line.len() && atom.matches(line[end]) {
                end += 1;
            }
            (at..=end)
                .rev()
                .any(|next| self.here(piece + 1, line, next))
        } else {
            at < line.len() && atom.matches(line[at]) && self.here(piece + 1, line, at + 1)
        }
    }
}

// MARK: - patch

/// One line of a hunk: context (both sides), removed (old side) or added
/// (new side), with whether it ends with a newline.
#[derive(Clone, Debug, PartialEq, Eq)]
enum HunkLine {
    Context(Vec<u8>, bool),
    Removed(Vec<u8>, bool),
    Added(Vec<u8>, bool),
}

#[derive(Clone, Debug)]
struct Hunk {
    old_first: usize,
    new_first: usize,
    lines: Vec<HunkLine>,
}

impl Hunk {
    fn reversed(&self) -> Self {
        Self {
            old_first: self.new_first,
            new_first: self.old_first,
            lines: self
                .lines
                .iter()
                .map(|line| match line {
                    HunkLine::Removed(text, newline) => HunkLine::Added(text.clone(), *newline),
                    HunkLine::Added(text, newline) => HunkLine::Removed(text.clone(), *newline),
                    context => context.clone(),
                })
                .collect(),
        }
    }

    /// The old side: (text, ends with a newline).
    fn old(&self) -> Vec<(&[u8], bool)> {
        self.lines
            .iter()
            .filter_map(|line| match line {
                HunkLine::Context(text, newline) | HunkLine::Removed(text, newline) => {
                    Some((text.as_slice(), *newline))
                }
                HunkLine::Added(..) => None,
            })
            .collect()
    }

    fn new_side(&self) -> Vec<(Vec<u8>, bool)> {
        self.lines
            .iter()
            .filter_map(|line| match line {
                HunkLine::Context(text, newline) | HunkLine::Added(text, newline) => {
                    Some((text.clone(), *newline))
                }
                HunkLine::Removed(..) => None,
            })
            .collect()
    }

    fn leading_context(&self) -> usize {
        self.lines
            .iter()
            .take_while(|line| matches!(line, HunkLine::Context(..)))
            .count()
    }

    fn trailing_context(&self) -> usize {
        self.lines
            .iter()
            .rev()
            .take_while(|line| matches!(line, HunkLine::Context(..)))
            .count()
    }
}

/// One file's patch: the text leading up to it, its two names and hunks.
#[derive(Clone, Debug)]
struct FilePatch {
    leading: Vec<Vec<u8>>,
    old_name: Option<String>,
    new_name: Option<String>,
    hunks: Vec<Hunk>,
}

fn header_name(line: &[u8]) -> Option<String> {
    let rest = &line[4..];
    let end = rest
        .iter()
        .position(|&byte| byte == b'\t')
        .unwrap_or(rest.len());
    let name = String::from_utf8(rest[..end].to_vec()).ok()?;
    let name = name.trim_end_matches(['\r', ' ']).to_owned();
    (name != "/dev/null" && !name.is_empty()).then_some(name)
}

fn range(text: &[u8]) -> Option<(usize, usize)> {
    let text = std::str::from_utf8(text).ok()?;
    match text.split_once(',') {
        Some((first, count)) => Some((first.parse().ok()?, count.parse().ok()?)),
        None => Some((text.parse().ok()?, 1)),
    }
}

/// `@@ -a[,b] +c[,d] @@`: the old and new first lines and counts.
fn hunk_header(line: &[u8]) -> Option<(usize, usize, usize, usize)> {
    let rest = line.strip_prefix(b"@@ -")?;
    let space = rest.iter().position(|&byte| byte == b' ')?;
    let (old_first, old_count) = range(&rest[..space])?;
    let rest = rest[space + 1..].strip_prefix(b"+")?;
    let end = rest.windows(3).position(|window| window == b" @@")?;
    let (new_first, new_count) = range(&rest[..end])?;
    Some((old_first, old_count, new_first, new_count))
}

/// The unified diffs in `bytes`, each with the text leading up to it.
fn parse_patches(bytes: &[u8]) -> Result<Vec<FilePatch>, String> {
    let mut raw: Vec<&[u8]> = bytes.split_inclusive(|&byte| byte == b'\n').collect();
    if raw.last().is_some_and(|line| line.is_empty()) {
        raw.pop();
    }
    let mut patches = Vec::new();
    let mut leading: Vec<Vec<u8>> = Vec::new();
    let mut index = 0;
    while index < raw.len() {
        let line = raw[index];
        let starts = line.starts_with(b"--- ")
            && raw
                .get(index + 1)
                .is_some_and(|next| next.starts_with(b"+++ "))
            && raw
                .get(index + 2)
                .is_some_and(|next| next.starts_with(b"@@ -"));
        if !starts {
            leading.push(line.to_vec());
            index += 1;
            continue;
        }
        leading.push(line.to_vec());
        leading.push(raw[index + 1].to_vec());
        let old_name = header_name(trim_newline(line));
        let new_name = header_name(trim_newline(raw[index + 1]));
        index += 2;
        let mut hunks = Vec::new();
        while index < raw.len() && raw[index].starts_with(b"@@ -") {
            let header = trim_newline(raw[index]);
            let (old_first, old_count, new_first, new_count) =
                hunk_header(header).ok_or_else(|| "malformed hunk header".to_owned())?;
            index += 1;
            let (mut old_left, mut new_left) = (old_count, new_count);
            let mut lines: Vec<HunkLine> = Vec::new();
            while old_left > 0 || new_left > 0 {
                let Some(&line) = raw.get(index) else {
                    return Err("unexpected end of patch".into());
                };
                index += 1;
                let body = trim_newline(line);
                let (kind, content) = match body.split_first() {
                    Some((b' ', content)) => (b' ', content),
                    Some((b'-', content)) => (b'-', content),
                    Some((b'+', content)) => (b'+', content),
                    // An empty line is an empty context line.
                    None => (b' ', &body[..0]),
                    Some(_) => return Err("malformed hunk line".into()),
                };
                let content = content.to_vec();
                match kind {
                    b' ' => {
                        old_left = old_left.checked_sub(1).ok_or("hunk overflow")?;
                        new_left = new_left.checked_sub(1).ok_or("hunk overflow")?;
                        lines.push(HunkLine::Context(content, true));
                    }
                    b'-' => {
                        old_left = old_left.checked_sub(1).ok_or("hunk overflow")?;
                        lines.push(HunkLine::Removed(content, true));
                    }
                    _ => {
                        new_left = new_left.checked_sub(1).ok_or("hunk overflow")?;
                        lines.push(HunkLine::Added(content, true));
                    }
                }
                if raw
                    .get(index)
                    .is_some_and(|next| next.starts_with(b"\\ No newline"))
                {
                    index += 1;
                    match lines.last_mut() {
                        Some(
                            HunkLine::Context(_, newline)
                            | HunkLine::Removed(_, newline)
                            | HunkLine::Added(_, newline),
                        ) => *newline = false,
                        None => {}
                    }
                }
            }
            // A "\ No newline" after the last line of a hunk whose counts are
            // already exhausted belongs to it too.
            if raw
                .get(index)
                .is_some_and(|next| next.starts_with(b"\\ No newline"))
            {
                index += 1;
                if let Some(
                    HunkLine::Context(_, newline)
                    | HunkLine::Removed(_, newline)
                    | HunkLine::Added(_, newline),
                ) = lines.last_mut()
                {
                    *newline = false;
                }
            }
            hunks.push(Hunk {
                old_first,
                new_first,
                lines,
            });
        }
        patches.push(FilePatch {
            leading: std::mem::take(&mut leading),
            old_name,
            new_name,
            hunks,
        });
    }
    Ok(patches)
}

fn trim_newline(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\n").unwrap_or(line)
}

fn strip_components(name: &str, count: usize) -> Option<String> {
    let mut rest = name;
    for _ in 0..count {
        let slash = rest.find('/')?;
        rest = rest[slash + 1..].trim_start_matches('/');
    }
    (!rest.is_empty()).then(|| rest.to_owned())
}

/// The file's lines, each with whether it ends with a newline.
fn file_lines(bytes: &[u8]) -> Vec<(Vec<u8>, bool)> {
    let mut lines: Vec<(Vec<u8>, bool)> = bytes
        .split_inclusive(|&byte| byte == b'\n')
        .map(|line| match line.strip_suffix(b"\n") {
            Some(text) => (text.to_vec(), true),
            None => (line.to_vec(), false),
        })
        .collect();
    if lines
        .last()
        .is_some_and(|(text, newline)| text.is_empty() && !newline)
    {
        lines.pop();
    }
    lines
}

/// Whether the hunk's old side, less `fuzz` lines of leading and trailing
/// context, stands at `at` (0-based, the first old line's position) in
/// `lines`.
fn hunk_matches(lines: &[(Vec<u8>, bool)], hunk: &Hunk, at: isize, fuzz: usize) -> bool {
    let old = hunk.old();
    let skip_front = fuzz.min(hunk.leading_context());
    let skip_back = fuzz.min(hunk.trailing_context());
    if at < 0 {
        return false;
    }
    let at = at as usize;
    if at + old.len() > lines.len() + skip_back {
        return false;
    }
    old.iter()
        .enumerate()
        .skip(skip_front)
        .take(old.len().saturating_sub(skip_front + skip_back))
        .all(|(offset, (text, _))| {
            lines
                .get(at + offset)
                .is_some_and(|(line, _)| line.as_slice() == *text)
        })
}

/// BSD `locate_hunk`: the 0-based position the hunk applies at and the fuzz
/// it needed, searching outward from its expected line.
fn locate(lines: &[(Vec<u8>, bool)], hunk: &Hunk, offset: isize) -> Option<(usize, usize)> {
    let old_len = hunk.old().len();
    let first_guess = if hunk.old_first == 0 {
        0
    } else {
        hunk.old_first as isize - 1 + offset
    };
    let max_fuzz = 2usize.min(hunk.leading_context().max(hunk.trailing_context()));
    for fuzz in 0..=max_fuzz {
        if old_len == 0 {
            // A pure insertion goes where it is asked.
            let at = first_guess.clamp(0, lines.len() as isize) as usize;
            return Some((at, 0));
        }
        let span = lines.len() as isize;
        for distance in 0..=span {
            for candidate in [first_guess + distance, first_guess - distance] {
                if (distance == 0 && candidate != first_guess + distance)
                    || candidate < 0
                    || candidate > span
                {
                    continue;
                }
                if hunk_matches(lines, hunk, candidate, fuzz) {
                    return Some((candidate as usize, fuzz));
                }
            }
        }
    }
    None
}

/// BSD patch's reject of one unified hunk: its header with both counts
/// spelled out, then its lines as it was tried.
fn reject_text(hunk: &Hunk) -> Vec<u8> {
    let old_count = hunk.old().len();
    let new_count = hunk.new_side().len();
    let mut text = format!(
        "@@ -{},{old_count} +{},{new_count} @@\n",
        hunk.old_first, hunk.new_first
    )
    .into_bytes();
    for line in &hunk.lines {
        let (prefix, content, newline) = match line {
            HunkLine::Context(content, newline) => (b' ', content, newline),
            HunkLine::Removed(content, newline) => (b'-', content, newline),
            HunkLine::Added(content, newline) => (b'+', content, newline),
        };
        text.push(prefix);
        text.extend_from_slice(content);
        text.push(b'\n');
        if !newline {
            text.extend_from_slice(b"\\ No newline at end of file\n");
        }
    }
    text
}

fn patch(arguments: &[String]) -> TextToolOutput {
    let usage = || TextToolOutput {
        status: 2,
        stdout: Vec::new(),
        stderr: b"patch: unsupported workspace patch arguments\n".to_vec(),
    };
    let (reverse, rest) = match arguments {
        [force, reverse, rest @ ..] if force == "-f" && reverse == "-R" => (true, rest),
        [force, rest @ ..] if force == "-f" => (false, rest),
        _ => return usage(),
    };
    let [strip, directory_flag, directory, input_flag, input] = rest else {
        return usage();
    };
    if strip != "-p1" || directory_flag != "-d" || input_flag != "-i" {
        return usage();
    }
    let bytes = match fs::read(input) {
        Ok(bytes) => bytes,
        Err(error) => {
            return TextToolOutput {
                status: 2,
                stdout: Vec::new(),
                stderr: format!("patch: {input}: {}\n", os_error_text(&error)).into_bytes(),
            };
        }
    };
    let patches = match parse_patches(&bytes) {
        Ok(patches) => patches,
        Err(_) => {
            return TextToolOutput {
                status: 2,
                stdout: Vec::new(),
                stderr: b"patch: **** malformed patch\n".to_vec(),
            };
        }
    };
    let mut output = TextToolOutput::default();
    if patches.is_empty() {
        output
            .stdout
            .extend_from_slice(b"Hmm...  I can't seem to find a patch in there anywhere.\n");
        output.status = 1;
        return output;
    }
    let directory = PathBuf::from(directory);
    let mut failed_any = false;
    for (number, file) in patches.iter().enumerate() {
        output.stdout.extend_from_slice(if number == 0 {
            b"Hmm...  Looks like a unified diff to me...\n".as_slice()
        } else {
            b"Hmm...  The next patch looks like a unified diff to me...\n".as_slice()
        });
        if !file.leading.is_empty() {
            output.stdout.extend_from_slice(
                b"The text leading up to this was:\n--------------------------\n",
            );
            for line in &file.leading {
                output.stdout.push(b'|');
                output.stdout.extend_from_slice(line);
                if !line.ends_with(b"\n") {
                    output.stdout.push(b'\n');
                }
            }
            output
                .stdout
                .extend_from_slice(b"--------------------------\n");
        }
        let name = match (&file.old_name, &file.new_name) {
            (Some(old), _) if file.new_name.is_none() || !reverse => strip_components(old, 1)
                .or_else(|| {
                    file.new_name
                        .as_deref()
                        .and_then(|new| strip_components(new, 1))
                }),
            (_, Some(new)) => strip_components(new, 1),
            (Some(old), None) => strip_components(old, 1),
            (None, None) => None,
        };
        let creating = if reverse {
            file.new_name.is_none()
        } else {
            file.old_name.is_none()
        };
        let Some(name) = name else {
            output
                .stdout
                .extend_from_slice(b"No file to patch.  Skipping patch.\n");
            failed_any = true;
            continue;
        };
        let target = directory.join(&name);
        let original = match fs::read(&target) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => {
                output
                    .stderr
                    .extend(format!("patch: {name}: {}\n", os_error_text(&error)).bytes());
                failed_any = true;
                continue;
            }
        };
        if original.is_none() && !creating {
            output
                .stdout
                .extend_from_slice(b"No file to patch.  Skipping patch.\n");
            output.stdout.extend(
                format!(
                    "{} out of {} hunks ignored\n",
                    file.hunks.len(),
                    file.hunks.len()
                )
                .bytes(),
            );
            failed_any = true;
            continue;
        }
        output
            .stdout
            .extend(format!("Patching file {name} using Plan A...\n").bytes());
        let mut lines = file_lines(original.as_deref().unwrap_or_default());
        let mut offset: isize = 0;
        let mut rejected: Vec<usize> = Vec::new();
        let hunks: Vec<Hunk> = if reverse {
            file.hunks.iter().map(Hunk::reversed).collect()
        } else {
            file.hunks.clone()
        };
        for (index, hunk) in hunks.iter().enumerate() {
            let number = index + 1;
            match locate(&lines, hunk, offset) {
                Some((at, fuzz)) => {
                    let expected = if hunk.old_first == 0 {
                        0
                    } else {
                        hunk.old_first - 1
                    };
                    offset = at as isize - expected as isize;
                    let old_len = hunk.old().len();
                    let replacement = hunk.new_side();
                    let end = (at + old_len).min(lines.len());
                    lines.splice(at..end, replacement);
                    let reported = hunk.new_first as isize + offset;
                    let mut message = format!("Hunk #{number} succeeded at {reported}");
                    if fuzz > 0 {
                        message.push_str(&format!(" with fuzz {fuzz}"));
                    }
                    if offset != 0 {
                        message.push_str(&format!(
                            " (offset {offset} line{})",
                            if offset.abs() == 1 { "" } else { "s" }
                        ));
                    }
                    message.push_str(".\n");
                    output.stdout.extend(message.bytes());
                }
                None => {
                    let at = hunk.new_first as isize + offset;
                    output
                        .stdout
                        .extend(format!("Hunk #{number} failed at {at}.\n").bytes());
                    rejected.push(index);
                }
            }
        }
        let mut written = Vec::new();
        for (text, newline) in &lines {
            written.extend_from_slice(text);
            if *newline {
                written.push(b'\n');
            }
        }
        if let Some(parent) = target.parent()
            && !parent.as_os_str().is_empty()
        {
            let _ = fs::create_dir_all(parent);
        }
        if let Err(error) = fs::write(&target, &written) {
            output
                .stderr
                .extend(format!("patch: {name}: {}\n", os_error_text(&error)).bytes());
            failed_any = true;
            continue;
        }
        if !rejected.is_empty() {
            failed_any = true;
            let reject_name = format!("{name}.rej");
            let mut reject = Vec::new();
            for &index in &rejected {
                reject.extend(reject_text(&hunks[index]));
            }
            let _ = fs::write(directory.join(&reject_name), reject);
            // The original beside it, as BSD patch keeps it when a hunk
            // does not apply.
            if let Some(original) = &original {
                let _ = fs::write(directory.join(format!("{name}.orig")), original);
            }
            output.stdout.extend(
                format!(
                    "{} out of {} hunks failed--saving rejects to {reject_name}\n",
                    rejected.len(),
                    hunks.len()
                )
                .bytes(),
            );
        }
    }
    output.stdout.extend_from_slice(b"done\n");
    output.status = i32::from(failed_any);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(tool: &str, arguments: &[&str]) -> TextToolOutput {
        run_text_tool(
            tool,
            &arguments.iter().map(|&a| a.to_owned()).collect::<Vec<_>>(),
        )
    }

    struct Scratch(PathBuf);
    impl Scratch {
        fn new(tag: &str) -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let path = std::env::temp_dir().join(format!("ad-texttools-{tag}-{nonce:016x}"));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn write(&self, relative: &str, bytes: &[u8]) -> String {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, bytes).unwrap();
            path.to_str().unwrap().to_owned()
        }
        fn read(&self, relative: &str) -> Vec<u8> {
            fs::read(self.0.join(relative)).unwrap()
        }
        fn root(&self) -> String {
            self.0.to_str().unwrap().to_owned()
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn sed_prints_a_line_range_with_bsd_s_newline_and_refusals() {
        let scratch = Scratch::new("sed");
        let file = scratch.write("a.txt", b"one\ntwo\nthree\nfour");
        let printed = run("sed", &["-n", "2,4p", &file]);
        assert_eq!(printed.stdout, b"two\nthree\nfour\n");
        assert_eq!(printed.status, 0);
        assert_eq!(run("sed", &["-n", "3,2p", &file]).stdout, b"three\n");
        assert_eq!(run("sed", &["-n", "9,12p", &file]).stdout, b"");
        let missing = run("sed", &["-n", "1,2p", "/no/such/file"]);
        assert_eq!(missing.status, 1);
        assert_eq!(
            missing.stderr,
            b"sed: /no/such/file: No such file or directory\n"
        );
        assert_eq!(run("sed", &["-n", "0,2p", &file]).status, 1);
        assert_eq!(run("sed", &["-e", "1p", &file]).status, 1);
    }

    #[test]
    fn grep_walks_in_name_order_with_its_include_glob() {
        let scratch = Scratch::new("grep");
        scratch.write("b/Index.ets", b"@Entry\n  build() {}\n");
        scratch.write("a/Other.ets", b"build\nnothing\n");
        scratch.write("a/Skip.txt", b"build\n");
        scratch.write("c/Bin.ets", b"build\0\n");
        let root = scratch.root();
        let found = run(
            "grep",
            &["-r", "-n", "--include", "*.ets", "--", "build", &root],
        );
        assert_eq!(found.status, 0);
        let join = |parts: &[&str]| {
            let mut path = PathBuf::from(&root);
            for part in parts {
                path.push(part);
            }
            path.to_str().unwrap().to_owned()
        };
        assert_eq!(
            String::from_utf8(found.stdout).unwrap(),
            format!(
                "{}:1:build\n{}:2:  build() {{}}\nBinary file {} matches\n",
                join(&["a", "Other.ets"]),
                join(&["b", "Index.ets"]),
                join(&["c", "Bin.ets"]),
            )
        );
        let none = run(
            "grep",
            &["-r", "-n", "--include", "*.ets", "--", "absent", &root],
        );
        assert_eq!((none.status, none.stdout.is_empty()), (1, true));
    }

    #[test]
    fn basic_regular_expressions_match_as_posix_bre() {
        let matches = |pattern: &str, text: &str| {
            Regex::compile(pattern.as_bytes())
                .unwrap()
                .matches(text.as_bytes())
        };
        assert!(matches("b.ild", "build"));
        assert!(matches("^bu", "build") && !matches("^ui", "build"));
        assert!(matches("ld$", "build") && !matches("bu$", "build"));
        assert!(matches("bu*ild", "bild") && matches("bu*ild", "buuuild"));
        assert!(matches("[a-c]uild", "build") && !matches("[^b]uild", "build"));
        assert!(matches("a\\.b", "a.b") && !matches("a\\.b", "axb"));
        assert!(matches("*x", "a*x"), "a leading star is literal");
        assert!(matches("x$y", "x$y"), "an inner dollar is literal");
        assert!(Regex::compile(b"\\(a\\)").is_none());
        assert!(Regex::compile(b"a\\{2\\}").is_none());
    }

    #[test]
    fn patch_applies_reverts_and_rejects_as_bsd_patch_narrates() {
        let scratch = Scratch::new("patch");
        scratch.write("Sources/App.txt", b"zero\nold\nkeep\n");
        let diff = b"diff --git a/Sources/App.txt b/Sources/App.txt\nindex 1..2 100644\n--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1,2 +1,2 @@\n zero\n-old\n+new\n";
        let input = scratch.write("change.patch", diff);
        let root = scratch.root();
        let applied = run("patch", &["-f", "-p1", "-d", &root, "-i", &input]);
        assert_eq!(applied.status, 0, "{applied:?}");
        assert_eq!(
            String::from_utf8(applied.stdout).unwrap(),
            "Hmm...  Looks like a unified diff to me...\n\
             The text leading up to this was:\n\
             --------------------------\n\
             |diff --git a/Sources/App.txt b/Sources/App.txt\n\
             |index 1..2 100644\n\
             |--- a/Sources/App.txt\n\
             |+++ b/Sources/App.txt\n\
             --------------------------\n\
             Patching file Sources/App.txt using Plan A...\n\
             Hunk #1 succeeded at 1.\n\
             done\n"
        );
        assert_eq!(scratch.read("Sources/App.txt"), b"zero\nnew\nkeep\n");
        let reverted = run("patch", &["-f", "-R", "-p1", "-d", &root, "-i", &input]);
        assert_eq!(reverted.status, 0);
        assert_eq!(scratch.read("Sources/App.txt"), b"zero\nold\nkeep\n");
        // Offset by two lines.
        scratch.write("Sources/App.txt", b"a\nb\nzero\nold\nkeep\n");
        let offset = run("patch", &["-f", "-p1", "-d", &root, "-i", &input]);
        assert!(
            String::from_utf8_lossy(&offset.stdout)
                .contains("Hunk #1 succeeded at 3 (offset 2 lines).\n"),
            "{offset:?}"
        );
        assert_eq!(scratch.read("Sources/App.txt"), b"a\nb\nzero\nnew\nkeep\n");
        // Already applied: the hunk fails and is rejected.
        let failed = run("patch", &["-f", "-p1", "-d", &root, "-i", &input]);
        assert_eq!(failed.status, 1);
        let narration = String::from_utf8(failed.stdout).unwrap();
        assert!(
            narration.contains("Hunk #1 failed at 1.\n")
                && narration
                    .contains("1 out of 1 hunks failed--saving rejects to Sources/App.txt.rej\n"),
            "{narration}"
        );
        assert!(scratch.0.join("Sources/App.txt.rej").exists());
        // A missing final newline is kept as the patch says.
        scratch.write("Sources/Tail.txt", b"x");
        let tail = scratch.write(
            "tail.patch",
            b"--- a/Sources/Tail.txt\n+++ b/Sources/Tail.txt\n@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+y\n\\ No newline at end of file\n",
        );
        assert_eq!(
            run("patch", &["-f", "-p1", "-d", &root, "-i", &tail]).status,
            0
        );
        assert_eq!(scratch.read("Sources/Tail.txt"), b"y");
        assert_eq!(run("patch", &["-p1", "-d", &root, "-i", &tail]).status, 2);
    }
}
