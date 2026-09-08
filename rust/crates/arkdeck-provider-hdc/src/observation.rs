use std::fmt;

/// Raw candidate transport facts, not a physical identity or a trust receipt.
/// The Runtime mints its own observation ID and determines continuity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceCandidate {
    pub connect_key: String,
    pub transport: String,
    pub state: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerCheck {
    pub client_version: String,
    pub server_version: String,
}

impl ServerCheck {
    pub fn versions_agree(&self) -> bool {
        self.client_version == self.server_version
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ParseError {
    UnsupportedVersion(String),
    InvalidEncoding,
    Truncated,
    Empty,
    Malformed(&'static str),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedVersion(_) => f.write_str("unregistered HDC observation version"),
            Self::InvalidEncoding => f.write_str("HDC observation is not valid UTF-8"),
            Self::Truncated => f.write_str("HDC observation exceeded its byte budget"),
            Self::Empty => f.write_str("HDC observation output is empty"),
            Self::Malformed(reason) => f.write_str(reason),
        }
    }
}

impl std::error::Error for ParseError {}

fn supports(version: &str) -> bool {
    matches!(version, "3.2.0d" | "3.2.0f")
}

fn require_version(version: &str) -> Result<(), ParseError> {
    if supports(version) {
        Ok(())
    } else {
        Err(ParseError::UnsupportedVersion(version.to_owned()))
    }
}

/// Diagnostic noise the daemon may interleave with observation output, in the
/// same closed prefix order as Swift `ignorableDiagnosticPrefixes`.
const IGNORABLE_DIAGNOSTIC_PREFIXES: [&str; 5] =
    ["[I]", "[W]", "[D]", "* daemon", "Connect server failed"];

// Foundation CharacterSet.whitespaces: horizontal whitespace, excluding line
// terminators. Keeping this set explicit prevents a CRLF/double-CR extension
// from silently changing the current Swift compatibility parser's grammar.
fn is_swift_whitespace(character: char) -> bool {
    matches!(
        character,
        '\t' | ' ' | '\u{00a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

// Foundation CharacterSet.newlines: U+000A-U+000D, U+0085, U+2028, U+2029.
// Only the registered LF and CRLF terminators end a target line; every other
// member stays inside the line and marks it unregistered.
fn is_foundation_newline(character: char) -> bool {
    matches!(
        character,
        '\u{000a}'..='\u{000d}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
    )
}

/// Swift `HDCObservationSemanticParser.normalizedLines` parity, used only by
/// the version probes. Those split `Character("\n")`, which does not split the
/// single CRLF grapheme; the target-list family below and the registered
/// presence parser each have their own, different CRLF handling.
fn normalized_lines(stdout: &[u8], truncated: bool) -> Result<Vec<&str>, ParseError> {
    if truncated {
        return Err(ParseError::Truncated);
    }
    let text = std::str::from_utf8(stdout).map_err(|_| ParseError::InvalidEncoding)?;
    let mut previous = '\0';
    let lines: Vec<_> = text
        .split(|character| {
            let separator = character == '\n' && previous != '\r';
            previous = character;
            separator
        })
        .map(|line| line.trim_matches(is_swift_whitespace))
        .filter(|line| {
            !line.is_empty()
                && !IGNORABLE_DIAGNOSTIC_PREFIXES
                    .iter()
                    .any(|prefix| line.starts_with(prefix))
        })
        .collect();
    if lines.is_empty() {
        Err(ParseError::Empty)
    } else {
        Ok(lines)
    }
}

/// A segment between two registered target-line terminators, normalized the
/// way Swift `targetOutputLines.appendLine` does it.
fn push_target_line<'a>(lines: &mut Vec<&'a str>, content: &'a str) {
    // Swift keeps a segment that still holds an unregistered newline exactly
    // as it arrived, and admits it even when it looks empty or diagnostic, so
    // the row grammar rejects it instead of the filter silently dropping it.
    if content.chars().any(is_foundation_newline) {
        lines.push(content);
        return;
    }
    let normalized = content.trim_matches(is_swift_whitespace);
    if normalized.is_empty()
        || IGNORABLE_DIAGNOSTIC_PREFIXES
            .iter()
            .any(|prefix| normalized.starts_with(prefix))
    {
        return;
    }
    lines.push(normalized);
}

/// Swift `HDCObservationSemanticParser.targetOutputLines` parity. Swift walks
/// `Character` values, so a lone LF and the single CRLF grapheme both end a
/// line while a bare CR stays inside one; the target-list family registers
/// both terminators (TASK-AIN-021). LF and CR never occur as UTF-8
/// continuation bytes, so scanning bytes stays on char boundaries.
fn target_output_lines(text: &str) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        let terminator_len = match bytes[index] {
            b'\r' if bytes.get(index + 1) == Some(&b'\n') => 2,
            b'\n' => 1,
            _ => {
                index += 1;
                continue;
            }
        };
        push_target_line(&mut lines, &text[start..index]);
        index += terminator_len;
        start = index;
    }
    push_target_line(&mut lines, &text[start..]);
    lines
}

/// Swift `HDCObservationSemanticParser.parseClientVersion` parity. This pure
/// parser recognizes an output family; it does not register the executable.
pub fn parse_client_version(stdout: &[u8], truncated: bool) -> Result<String, ParseError> {
    let lines = normalized_lines(stdout, truncated)?;
    let mut versions = lines.iter().filter_map(|line| line.strip_prefix("Ver:"));
    let token = versions.next().ok_or(ParseError::Malformed(
        "expected exactly one Ver: line in HDC version output",
    ))?;
    if versions.next().is_some() {
        return Err(ParseError::Malformed(
            "expected exactly one Ver: line in HDC version output",
        ));
    }
    let version = token.trim_matches(is_swift_whitespace);
    if version.is_empty() {
        return Err(ParseError::Malformed("empty version token"));
    }
    require_version(version)?;
    Ok(version.to_owned())
}

/// A parsed mismatch remains a mismatch. Callers must never treat the presence
/// of two registered version tokens as proof that client and server agree.
pub fn parse_server_check(stdout: &[u8], truncated: bool) -> Result<ServerCheck, ParseError> {
    let lines = normalized_lines(stdout, truncated)?;
    let line = lines
        .iter()
        .find(|line| line.starts_with("Client version:") && line.contains("server version:"))
        .ok_or(ParseError::Malformed(
            "no client/server version line in checkserver output",
        ))?;
    let (client, server) = line.split_once(',').ok_or(ParseError::Malformed(
        "checkserver line is missing its server segment",
    ))?;
    fn version(segment: &str) -> Result<String, ParseError> {
        let (_, token) = segment.split_once("Ver:").ok_or(ParseError::Malformed(
            "checkserver versions could not be read",
        ))?;
        let token = token.trim_matches(is_swift_whitespace);
        if token.is_empty() {
            return Err(ParseError::Malformed(
                "checkserver versions could not be read",
            ));
        }
        require_version(token)?;
        Ok(token.to_owned())
    }
    Ok(ServerCheck {
        client_version: version(client)?,
        server_version: version(server)?,
    })
}

/// The current Swift candidate-list grammar, distinct from the stricter
/// registered presence-feed grammar. Offline and Unauthorized are rows, not
/// successful authorization. Repeated connect keys remain separate rows; the
/// Runtime may not derive identity continuity from any such key.
pub fn parse_target_list(
    stdout: &[u8],
    tool_version: &str,
    truncated: bool,
) -> Result<Vec<DeviceCandidate>, ParseError> {
    if truncated {
        return Err(ParseError::Truncated);
    }
    require_version(tool_version)?;
    let text = std::str::from_utf8(stdout).map_err(|_| ParseError::InvalidEncoding)?;
    let lines = target_output_lines(text);
    if lines.is_empty() {
        return Err(ParseError::Empty);
    }
    if lines == ["[Empty]"] {
        return Ok(Vec::new());
    }
    lines
        .into_iter()
        .map(|line| {
            let columns: Vec<_> = line.split('\t').collect();
            if columns.len() != 5 || !columns[1].is_empty() || columns[4] != "localhost" {
                return Err(ParseError::Malformed(
                    "target line is not the registered 5-column family",
                ));
            }
            let key = columns[0];
            if key.is_empty()
                || key.len() > 128
                || !key.chars().all(|c| c.is_ascii() && !c.is_whitespace())
            {
                return Err(ParseError::Malformed("connect key length out of bounds"));
            }
            if !matches!(columns[2], "USB" | "TCP" | "UART") {
                return Err(ParseError::Malformed("unregistered target transport"));
            }
            if !matches!(columns[3], "Connected" | "Unauthorized" | "Offline") {
                return Err(ParseError::Malformed("unregistered target state"));
            }
            Ok(DeviceCandidate {
                connect_key: key.to_owned(),
                transport: columns[2].to_ascii_lowercase(),
                state: columns[3].to_owned(),
            })
        })
        .collect()
}
