//! Swift's catalog `pattern` check, `text.range(of: pattern, options:
//! .regularExpression)`: an ICU search for the pattern anywhere in the text,
//! for the syntax the published catalog's patterns use.
//!
//! That syntax is literal characters, escaped punctuation, bracketed classes
//! of characters and ranges (negated or not), capturing and non-capturing
//! groups, the greedy quantifiers `*`, `+`, `?`, `{n}`, `{n,}` and `{n,m}`,
//! and the anchors `^` (the start of the text) and `$` (its end: measured
//! against Foundation, a text with a final line terminator does not match a
//! pattern ending in `$`). Characters are Unicode scalars, compared exactly. A
//! pattern outside this syntax is not evaluated: [`matches`] answers `None`,
//! and the validator refuses the input rather than guessing.

/// One element of a pattern: what it matches, how many times.
#[derive(Debug)]
struct Piece {
    node: Node,
    minimum: u32,
    maximum: Option<u32>,
}

#[derive(Debug)]
enum Node {
    Start,
    End,
    Character(char),
    Class {
        negated: bool,
        ranges: Vec<(char, char)>,
    },
    Group(Vec<Piece>),
}

/// Whether `pattern` is found in `text` as Swift finds it, or `None` for a
/// pattern this evaluator does not read.
pub(crate) fn matches(pattern: &str, text: &str) -> Option<bool> {
    let pieces = parse(pattern)?;
    let text: Vec<char> = text.chars().collect();
    Some((0..=text.len()).any(|start| sequence(&pieces, &text, start, &mut |_| true)))
}

fn parse(pattern: &str) -> Option<Vec<Piece>> {
    let characters: Vec<char> = pattern.chars().collect();
    let mut position = 0;
    let pieces = parse_sequence(&characters, &mut position)?;
    (position == characters.len()).then_some(pieces)
}

/// A sequence up to the end of the pattern or the `)` closing its group.
fn parse_sequence(pattern: &[char], position: &mut usize) -> Option<Vec<Piece>> {
    let mut pieces = Vec::new();
    while let Some(&character) = pattern.get(*position) {
        let node = match character {
            ')' => break,
            '^' => {
                *position += 1;
                Node::Start
            }
            '$' => {
                *position += 1;
                Node::End
            }
            '(' => {
                *position += 1;
                // A non-capturing group; any other `(?` construct is not read.
                if pattern.get(*position) == Some(&'?') {
                    if pattern.get(*position + 1) != Some(&':') {
                        return None;
                    }
                    *position += 2;
                }
                let inner = parse_sequence(pattern, position)?;
                if pattern.get(*position) != Some(&')') {
                    return None;
                }
                *position += 1;
                Node::Group(inner)
            }
            '[' => parse_class(pattern, position)?,
            '\\' => {
                let literal = escaped(*pattern.get(*position + 1)?)?;
                *position += 2;
                Node::Character(literal)
            }
            // Alternation, the wildcard, a stray quantifier or a stray bracket.
            '|' | '.' | '*' | '+' | '?' | '{' | '}' | ']' => return None,
            literal => {
                *position += 1;
                Node::Character(literal)
            }
        };
        let (minimum, maximum) = parse_quantifier(pattern, position)?;
        pieces.push(Piece {
            node,
            minimum,
            maximum,
        });
    }
    Some(pieces)
}

/// An escaped character: punctuation stands for itself. A letter or digit
/// names a class or a reference, which this evaluator does not read.
fn escaped(character: char) -> Option<char> {
    (character.is_ascii() && !character.is_ascii_alphanumeric()).then_some(character)
}

/// `[...]` of characters and ranges, `^` first to negate it; a `-` first or
/// last stands for itself.
fn parse_class(pattern: &[char], position: &mut usize) -> Option<Node> {
    *position += 1;
    let negated = pattern.get(*position) == Some(&'^');
    if negated {
        *position += 1;
    }
    let mut ranges = Vec::new();
    let mut first = true;
    loop {
        let character = *pattern.get(*position)?;
        if character == ']' && !first {
            *position += 1;
            return Some(Node::Class { negated, ranges });
        }
        let low = class_character(pattern, position)?;
        let is_range = pattern.get(*position) == Some(&'-')
            && pattern.get(*position + 1).is_some_and(|next| *next != ']');
        if is_range {
            *position += 1;
            let high = class_character(pattern, position)?;
            if high < low {
                return None;
            }
            ranges.push((low, high));
        } else {
            ranges.push((low, low));
        }
        first = false;
    }
}

/// One character inside a class. Nested classes, set operations and named
/// classes are not read.
fn class_character(pattern: &[char], position: &mut usize) -> Option<char> {
    let character = *pattern.get(*position)?;
    *position += 1;
    match character {
        '\\' => {
            let escaped_character = escaped(*pattern.get(*position)?)?;
            *position += 1;
            Some(escaped_character)
        }
        '[' | '&' => None,
        other => Some(other),
    }
}

/// The greedy quantifier after a piece, if any. Lazy and possessive forms
/// are not read.
fn parse_quantifier(pattern: &[char], position: &mut usize) -> Option<(u32, Option<u32>)> {
    let bounds = match pattern.get(*position) {
        Some('*') => {
            *position += 1;
            (0, None)
        }
        Some('+') => {
            *position += 1;
            (1, None)
        }
        Some('?') => {
            *position += 1;
            (0, Some(1))
        }
        Some('{') => {
            *position += 1;
            let minimum = number(pattern, position)?;
            let maximum = if pattern.get(*position) == Some(&',') {
                *position += 1;
                if pattern.get(*position) == Some(&'}') {
                    None
                } else {
                    Some(number(pattern, position)?)
                }
            } else {
                Some(minimum)
            };
            if pattern.get(*position) != Some(&'}') || maximum.is_some_and(|max| max < minimum) {
                return None;
            }
            *position += 1;
            (minimum, maximum)
        }
        _ => return Some((1, Some(1))),
    };
    if matches!(pattern.get(*position), Some('?' | '+')) {
        return None;
    }
    Some(bounds)
}

fn number(pattern: &[char], position: &mut usize) -> Option<u32> {
    let start = *position;
    while pattern.get(*position).is_some_and(char::is_ascii_digit) {
        *position += 1;
    }
    if *position == start {
        return None;
    }
    pattern[start..*position]
        .iter()
        .collect::<String>()
        .parse()
        .ok()
}

/// Whether `pieces` match from `position`, handing each end they can reach
/// to `rest` until it accepts one: a backtracking search, greedy first.
fn sequence(
    pieces: &[Piece],
    text: &[char],
    position: usize,
    rest: &mut dyn FnMut(usize) -> bool,
) -> bool {
    match pieces.split_first() {
        None => rest(position),
        Some((piece, later)) => repeat(piece, 0, text, position, &mut |next| {
            sequence(later, text, next, rest)
        }),
    }
}

fn repeat(
    piece: &Piece,
    count: u32,
    text: &[char],
    position: usize,
    rest: &mut dyn FnMut(usize) -> bool,
) -> bool {
    if piece.maximum.is_none_or(|maximum| count < maximum)
        && node(&piece.node, text, position, &mut |next| {
            // An empty repetition past the minimum adds nothing and would
            // never end.
            !(next == position && count >= piece.minimum)
                && repeat(piece, count + 1, text, next, rest)
        })
    {
        return true;
    }
    count >= piece.minimum && rest(position)
}

fn node(node: &Node, text: &[char], position: usize, rest: &mut dyn FnMut(usize) -> bool) -> bool {
    match node {
        Node::Start => position == 0 && rest(position),
        Node::End => position == text.len() && rest(position),
        Node::Character(expected) => text.get(position) == Some(expected) && rest(position + 1),
        Node::Class { negated, ranges } => {
            text.get(position).is_some_and(|character| {
                ranges
                    .iter()
                    .any(|(low, high)| (low..=high).contains(&character))
                    != *negated
            }) && rest(position + 1)
        }
        Node::Group(pieces) => sequence(pieces, text, position, rest),
    }
}

#[cfg(test)]
mod tests {
    use super::matches;

    const EPOCH: &str = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$";
    const BUNDLE: &str = r"^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$";

    /// What Foundation answered for each (`String.range(of:options:
    /// .regularExpression)`, macOS 26, 2026-09-15).
    #[test]
    fn patterns_match_as_foundation_matched_them() {
        let cases = [
            (EPOCH, "2026-09-14T00:00:00Z", true),
            (EPOCH, "2026-09-14T00:00:00.000Z", true),
            (EPOCH, "2026-09-14T00:00:00Z\n", false),
            (EPOCH, "2026-09-14T00:00:00Z\r\n", false),
            (EPOCH, "2026-09-14T00:00:00Z\r", false),
            (EPOCH, "2026-09-14T00:00:00Z\u{2028}", false),
            (EPOCH, "2026-09-14T00:00:00Z\u{85}", false),
            (EPOCH, "2026-09-14T00:00:00Z\n\n", false),
            (EPOCH, "\n2026-09-14T00:00:00Z", false),
            (EPOCH, "2026-09-14T00:00:00.1234567Z", false),
            (EPOCH, "\u{ff12}026-09-14T00:00:00Z", false),
            (EPOCH, "\u{662}026-09-14T00:00:00Z", false),
            (BUNDLE, "com.example.app", true),
            (BUNDLE, "com", false),
            (BUNDLE, "com.\u{e9}", false),
            (BUNDLE, "com.example\n", false),
            (BUNDLE, "Com.a_b.C9", true),
            ("[0-9]{3}", "ab123cd", true),
            (r"^lib[a-zA-Z0-9_.-]+\.so$", "libfoo.so", true),
            (r"^lib[a-zA-Z0-9_.-]+\.so$", "libfoo-1.2.so\n", false),
            (r"^[a-z]+-[A-Za-z0-9._-]{1,180}$", "lease-ab.c_d-e", true),
        ];
        for (pattern, text, expected) in cases {
            assert_eq!(matches(pattern, text), Some(expected), "{pattern} {text:?}");
        }
        let digest = "a".repeat(64);
        assert_eq!(matches("^[0-9a-f]{64}$", &digest), Some(true));
        assert_eq!(
            matches("^[0-9a-f]{64}$", &format!("{digest}\n")),
            Some(false)
        );
        assert_eq!(matches("^[0-9a-f]{64}$", &digest[1..]), Some(false));
    }

    #[test]
    fn quantifiers_classes_and_groups_backtrack() {
        assert_eq!(matches("^a{2,3}b$", "aab"), Some(true));
        assert_eq!(matches("^a{2,3}b$", "aaaab"), Some(false));
        assert_eq!(matches("^a{2,}$", "aaaaa"), Some(true));
        assert_eq!(matches("^(ab)+c$", "ababc"), Some(true));
        assert_eq!(matches("^(ab)+c$", "abac"), Some(false));
        assert_eq!(matches("^[^0-9]+$", "abc"), Some(true));
        assert_eq!(matches("^[^0-9]+$", "ab1"), Some(false));
        assert_eq!(matches(r"^[a\-z]$", "-"), Some(true));
        assert_eq!(matches("^[-a]$", "-"), Some(true));
        assert_eq!(matches("^(a*)*b$", "aaab"), Some(true));
        assert_eq!(matches("^(a*)*b$", "aaac"), Some(false));
        assert_eq!(matches("x?", ""), Some(true));
        assert_eq!(matches(r"^\$\.$", "$."), Some(true));
    }

    #[test]
    fn syntax_outside_the_catalog_s_is_not_evaluated() {
        for pattern in [
            "a|b",
            "a.b",
            r"\d+",
            "(?=a)",
            "a*?",
            "a++",
            "[[:alpha:]]",
            "[a&&b]",
            "(a",
            "a)",
            "a{2",
            "a{3,2}",
            "*a",
            "[b-a]",
            "[]",
            "é{",
        ] {
            assert_eq!(matches(pattern, "a"), None, "{pattern}");
        }
    }

    /// Every pattern the published catalog declares is one this evaluator
    /// reads, so no catalog input is refused as unevaluated.
    #[test]
    fn every_catalog_pattern_is_evaluated() {
        let catalog: Vec<serde_json::Value> =
            serde_json::from_str(crate::CATALOG_CANONICAL_JSON).unwrap();
        let mut patterns = 0;
        for operation in &catalog {
            for field in operation["inputs"]["fields"]
                .as_object()
                .into_iter()
                .flat_map(|fields| fields.values())
            {
                if let Some(pattern) = field["pattern"].as_str() {
                    patterns += 1;
                    assert!(matches(pattern, "").is_some(), "{pattern}");
                }
            }
        }
        assert!(patterns >= 16, "{patterns} catalog patterns");
    }
}
