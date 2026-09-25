//! Swift `ArkDeckCore.StrictJSONDuplicateValidator`: the byte-level check a
//! durable reader runs before it decodes a document. It refuses a member name
//! repeated in one object at any depth and malformed input, in Swift's words
//! and at Swift's byte offsets, and says nothing about the document's shape.
use unicode_segmentation::UnicodeSegmentation;

/// Swift `StrictJSONError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum StrictJsonError {
    DuplicateMemberName(String),
    Malformed(String),
}

impl StrictJsonError {
    /// Swift's interpolation of the error: the case with its payload.
    pub(crate) fn swift(&self) -> String {
        match self {
            Self::DuplicateMemberName(path) => {
                format!("duplicateMemberName(path: {})", swift_quoted(path))
            }
            Self::Malformed(reason) => format!("malformed({})", swift_quoted(reason)),
        }
    }
}

/// Swift's `debugDescription` of a `String`, which interpolating an error
/// case uses for its payload (Swift 6.4's `String.debugDescription`, recorded
/// for every scalar). Each scalar is spelled as
/// `Unicode.Scalar.escaped(asASCII: false)` spells it — `\0`, `\t`, `\n`,
/// `\r`, `\"`, `\'` and `\\`, any other ASCII control as `\u{XX}` with two
/// upper-case digits, anything else as itself — except that a scalar left as
/// itself may not make one grapheme with the opening quote or an escape
/// before it, nor with the closing quote (or an escape) after it: such a
/// scalar is spelled `\u{XXXX}` instead, eight digits beyond the Basic
/// Multilingual Plane. That is a mark or joiner the text begins with or that
/// follows an escape, and a prepended mark the text ends with.
pub(crate) fn swift_quoted(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    // Whether what was written last is the opening quote or an escape.
    let mut after_escape = true;
    for scalar in text.chars() {
        if let Some(escape) = ascii_escape(scalar) {
            quoted.push_str(&escape);
            after_escape = true;
        } else if after_escape && joins(quoted.chars().next_back(), scalar) {
            quoted.push_str(&unicode_escape(scalar));
        } else {
            quoted.push(scalar);
            after_escape = false;
        }
    }
    // Nor may the last scalar left as itself join what follows it: the
    // closing quote, then the escape that took its successor's place.
    let mut tail = String::new();
    let mut next = '"';
    while let Some(last) = quoted.chars().next_back()
        && joins(Some(last), next)
    {
        quoted.pop();
        tail.insert_str(0, &unicode_escape(last));
        next = '\\';
    }
    quoted.push_str(&tail);
    quoted.push('"');
    quoted
}

/// `Unicode.Scalar.escaped(asASCII: false)` where it escapes, which is ASCII
/// only.
fn ascii_escape(scalar: char) -> Option<String> {
    Some(match scalar {
        '\\' => "\\\\".into(),
        '\'' => "\\'".into(),
        '"' => "\\\"".into(),
        ' '..='~' => return None,
        '\0' => "\\0".into(),
        '\n' => "\\n".into(),
        '\r' => "\\r".into(),
        '\t' => "\\t".into(),
        control if control.is_ascii() => format!("\\u{{{:02X}}}", u32::from(control)),
        _ => return None,
    })
}

/// `Unicode.Scalar.escaped(asASCII: true)` of a scalar beyond ASCII.
fn unicode_escape(scalar: char) -> String {
    let value = u32::from(scalar);
    if value <= 0xFFFF {
        format!("\\u{{{value:04X}}}")
    } else {
        format!("\\u{{{value:08X}}}")
    }
}

/// Whether the two scalars side by side make one extended grapheme cluster:
/// Swift's `_GraphemeBreakingState().shouldBreak(between:and:)` answering
/// no. Two scalars never meet the Indic conjunct rule, the one place Swift's
/// runtime and the segmenter part (`session_graphemes`).
fn joins(left: Option<char>, right: char) -> bool {
    let Some(left) = left else {
        return false;
    };
    let mut pair = String::with_capacity(8);
    pair.push(left);
    pair.push(right);
    pair.graphemes(true).nth(1).is_none()
}

/// Validates `bytes` as one JSON value without duplicate member names.
pub(crate) fn validate(bytes: &[u8]) -> Result<(), StrictJsonError> {
    let mut parser = Parser { bytes, index: 0 };
    parser.skip_whitespace();
    parser.value("$", 0)?;
    parser.skip_whitespace();
    if parser.index != bytes.len() {
        return Err(malformed(format!(
            "unexpected trailing data at byte offset {}",
            parser.index
        )));
    }
    Ok(())
}

fn malformed(reason: impl Into<String>) -> StrictJsonError {
    StrictJsonError::Malformed(reason.into())
}

struct Parser<'a> {
    bytes: &'a [u8],
    index: usize,
}

impl Parser<'_> {
    fn value(&mut self, path: &str, depth: usize) -> Result<(), StrictJsonError> {
        let byte = match self.current() {
            Some(byte) if depth <= 256 => byte,
            _ if depth > 256 => return Err(malformed("JSON nesting exceeds 256 levels")),
            _ => return Err(malformed("missing JSON value")),
        };
        match byte {
            b'{' => self.object(path, depth),
            b'[' => self.array(path, depth),
            b'"' => self.string().map(drop),
            b'-' | b'0'..=b'9' => self.number(),
            b't' => self.literal(b"true"),
            b'f' => self.literal(b"false"),
            b'n' => self.literal(b"null"),
            _ => Err(malformed(format!(
                "unexpected byte at byte offset {}",
                self.index
            ))),
        }
    }

    fn object(&mut self, path: &str, depth: usize) -> Result<(), StrictJsonError> {
        self.consume(b'{', "object start")?;
        self.skip_whitespace();
        if self.consume_if(b'}') {
            return Ok(());
        }
        let mut names = std::collections::HashSet::new();
        loop {
            if self.current() != Some(b'"') {
                return Err(malformed("object member name must be a string"));
            }
            let name = self.string()?;
            let member = format!("{path}.{name}");
            // Swift's `Set<String>` compares names by canonical equivalence.
            if !names.insert(canonical(&name)?) {
                return Err(StrictJsonError::DuplicateMemberName(member));
            }
            self.skip_whitespace();
            self.consume(b':', "colon after member name")?;
            self.skip_whitespace();
            self.value(&member, depth + 1)?;
            self.skip_whitespace();
            if self.consume_if(b'}') {
                return Ok(());
            }
            self.consume(b',', "comma between object members")?;
            self.skip_whitespace();
        }
    }

    fn array(&mut self, path: &str, depth: usize) -> Result<(), StrictJsonError> {
        self.consume(b'[', "array start")?;
        self.skip_whitespace();
        if self.consume_if(b']') {
            return Ok(());
        }
        let mut element = 0;
        loop {
            self.value(&format!("{path}[{element}]"), depth + 1)?;
            element += 1;
            self.skip_whitespace();
            if self.consume_if(b']') {
                return Ok(());
            }
            self.consume(b',', "comma between array elements")?;
            self.skip_whitespace();
        }
    }

    /// A string token, decoded as Swift's `JSONDecoder` decodes it.
    fn string(&mut self) -> Result<String, StrictJsonError> {
        let start = self.index;
        self.consume(b'"', "string opening quote")?;
        while let Some(byte) = self.current() {
            match byte {
                b'"' => {
                    self.index += 1;
                    return serde_json::from_slice(&self.bytes[start..self.index])
                        .map_err(|_| malformed("invalid JSON string"));
                }
                b'\\' => {
                    self.index += 1;
                    let Some(escaped) = self.current() else {
                        return Err(malformed("unterminated JSON escape"));
                    };
                    if escaped == b'u' {
                        self.index += 1;
                        for _ in 0..4 {
                            if !self.current().is_some_and(|hex| hex.is_ascii_hexdigit()) {
                                return Err(malformed("invalid Unicode escape"));
                            }
                            self.index += 1;
                        }
                    } else {
                        if !matches!(
                            escaped,
                            b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't'
                        ) {
                            return Err(malformed("invalid JSON escape"));
                        }
                        self.index += 1;
                    }
                }
                0x00..=0x1f => {
                    return Err(malformed("unescaped control character in JSON string"));
                }
                _ => self.index += 1,
            }
        }
        Err(malformed("unterminated JSON string"))
    }

    fn literal(&mut self, literal: &[u8]) -> Result<(), StrictJsonError> {
        let end = self.index + literal.len();
        if end > self.bytes.len() || &self.bytes[self.index..end] != literal {
            return Err(malformed("invalid JSON literal"));
        }
        self.index = end;
        Ok(())
    }

    fn number(&mut self) -> Result<(), StrictJsonError> {
        if self.consume_if(b'-') && self.current().is_none() {
            return Err(malformed("minus must be followed by a number"));
        }
        if self.consume_if(b'0') {
            if self.current().is_some_and(|byte| byte.is_ascii_digit()) {
                return Err(malformed("leading zero in JSON number"));
            }
        } else {
            if !self
                .current()
                .is_some_and(|byte| (b'1'..=b'9').contains(&byte))
            {
                return Err(malformed("invalid JSON integer"));
            }
            self.digits();
        }
        if self.consume_if(b'.') {
            if !self.current().is_some_and(|byte| byte.is_ascii_digit()) {
                return Err(malformed("fraction requires a digit"));
            }
            self.digits();
        }
        if matches!(self.current(), Some(b'e' | b'E')) {
            self.index += 1;
            if matches!(self.current(), Some(b'+' | b'-')) {
                self.index += 1;
            }
            if !self.current().is_some_and(|byte| byte.is_ascii_digit()) {
                return Err(malformed("exponent requires a digit"));
            }
            self.digits();
        }
        Ok(())
    }

    fn digits(&mut self) {
        while self.current().is_some_and(|byte| byte.is_ascii_digit()) {
            self.index += 1;
        }
    }

    fn consume(&mut self, expected: u8, expectation: &str) -> Result<(), StrictJsonError> {
        if self.consume_if(expected) {
            Ok(())
        } else {
            Err(malformed(format!(
                "expected {expectation} at byte offset {}",
                self.index
            )))
        }
    }

    fn consume_if(&mut self, expected: u8) -> bool {
        if self.current() == Some(expected) {
            self.index += 1;
            true
        } else {
            false
        }
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.current(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.index += 1;
        }
    }

    fn current(&self) -> Option<u8> {
        self.bytes.get(self.index).copied()
    }
}

/// The key Swift's `String` equality compares: an ASCII name is its own; any
/// other is compared by canonical equivalence, which only the macOS host's
/// Unicode tables answer as Foundation does, so elsewhere it is refused.
fn canonical(name: &str) -> Result<String, StrictJsonError> {
    if name.is_ascii() {
        return Ok(name.to_owned());
    }
    crate::canonical_host_text(name)
        .map_err(|_| malformed("member name cannot be compared as Swift compares it"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refusal(text: &str) -> String {
        validate(text.as_bytes()).unwrap_err().swift()
    }

    #[test]
    fn swift_messages_and_offsets() {
        assert!(
            validate(" {\"a\": [1, -0.5e+3, true, null, \"x\\u00e9\u{e9}\"]} ".as_bytes()).is_ok()
        );
        for (text, expected) in [
            ("", r#"malformed("missing JSON value")"#),
            (
                "{} x",
                r#"malformed("unexpected trailing data at byte offset 3")"#,
            ),
            (r#"{"a":1,"a":2}"#, r#"duplicateMemberName(path: "$.a")"#),
            (
                r#"{"r":[{"b":1},{"b":1,"b":2}]}"#,
                r#"duplicateMemberName(path: "$.r[1].b")"#,
            ),
            (
                r#"{"a" 1}"#,
                r#"malformed("expected colon after member name at byte offset 5")"#,
            ),
            (
                "[1 2]",
                r#"malformed("expected comma between array elements at byte offset 3")"#,
            ),
            (
                "{1:2}",
                r#"malformed("object member name must be a string")"#,
            ),
            (r#"{"a":01}"#, r#"malformed("leading zero in JSON number")"#),
            ("[1.]", r#"malformed("fraction requires a digit")"#),
            ("[1e]", r#"malformed("exponent requires a digit")"#),
            ("-", r#"malformed("minus must be followed by a number")"#),
            ("[-x]", r#"malformed("invalid JSON integer")"#),
            ("[tru]", r#"malformed("invalid JSON literal")"#),
            (r#"["\x"]"#, r#"malformed("invalid JSON escape")"#),
            (r#"["\u00g0"]"#, r#"malformed("invalid Unicode escape")"#),
            (
                "[\"a\u{1}\"]",
                r#"malformed("unescaped control character in JSON string")"#,
            ),
            (r#"["abc"#, r#"malformed("unterminated JSON string")"#),
            ("[?]", r#"malformed("unexpected byte at byte offset 1")"#),
        ] {
            assert_eq!(refusal(text), expected, "{text:?}");
        }
        let deep = "[".repeat(258);
        assert_eq!(
            refusal(&deep),
            r#"malformed("JSON nesting exceeds 256 levels")"#
        );
    }

    #[test]
    fn escaped_names_are_the_names_they_decode_to() {
        assert_eq!(
            refusal(r#"{"a":1,"a":2}"#),
            r#"duplicateMemberName(path: "$.a")"#
        );
    }

    /// Recorded from Swift 6.4, `String(reflecting:)` (what interpolating an
    /// error case's payload prints); every scalar alone, before and after
    /// ASCII, and twice agreed with Swift once, exhaustively
    /// (`evidence/runs/TASK-XPA-014/swift-quoting-and-record-upkeep-run.md`).
    #[test]
    fn swift_quoting_escapes_what_swift_escapes() {
        for (text, swift) in [
            ("a\"b\\c'd\te\u{1b}", r#""a\"b\\c\'d\te\u{1B}""#),
            // Any other ASCII control: two upper-case digits.
            (
                "\u{1}\u{b}\u{10}\u{1f}\u{7f}\0\r\n",
                r#""\u{01}\u{0B}\u{10}\u{1F}\u{7F}\0\r\n""#,
            ),
            // Beyond ASCII, as itself, controls and marks after a base included.
            (
                "x\u{85}y\u{2028}z\u{feff}\u{e9}e\u{301}",
                "\"x\u{85}y\u{2028}z\u{feff}\u{e9}e\u{301}\"",
            ),
            // Nothing may join the opening quote or an escape before it...
            ("\u{301}x", r#""\u{0301}x""#),
            ("\u{1b}\u{301}\u{301}", r#""\u{1B}\u{0301}\u{0301}""#),
            ("\u{200d}\u{903}", r#""\u{200D}\u{0903}""#),
            ("\u{1f3fb}x", r#""\u{0001F3FB}x""#),
            // ...nor the closing quote, or an escape, after it.
            ("a\u{600}\u{600}", r#""a\u{0600}\u{0600}""#),
            ("\u{600}a\u{600}", "\"\u{600}a\\u{0600}\""),
            ("a\u{110bd}", r#""a\u{000110BD}""#),
            ("a\u{110bd}b", "\"a\u{110bd}b\""),
        ] {
            assert_eq!(swift_quoted(text), swift, "{text:?}");
        }
    }
}
