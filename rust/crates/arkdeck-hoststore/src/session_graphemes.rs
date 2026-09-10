//! Match the pinned macOS Swift reader's Character boundaries. Unicode 17
//! supplies the properties; the installed Swift runtime still recognizes only
//! six Indic linkers in GB9c. Keep that historical rule while using the audited
//! segmenter's Unicode 17 behavior for every other boundary.
// Swift rule source: swiftlang/swift, stdlib/public/core/StringGraphemeBreaking.swift,
// Unicode.Scalar._isInCBLinker. Both Unicode 16/17 corpora are compared with the
// actual Swift executable; a newer runtime must not silently change this rule.
use unicode_segmentation::UnicodeSegmentation;
#[path = "session_grapheme_tables.rs"]
mod tables;

fn property(c: char, ranges: &[(u32, u32)]) -> bool {
    let c = c as u32;
    let index = ranges.partition_point(|(_, end)| *end < c);
    ranges.get(index).is_some_and(|(start, _)| *start <= c)
}
fn swift_linker(c: char) -> bool {
    matches!(
        c,
        '\u{94d}' | '\u{9cd}' | '\u{acd}' | '\u{b4d}' | '\u{c4d}' | '\u{d4d}'
    )
}
struct Parts<'a> {
    one: Option<&'a str>,
    many: std::vec::IntoIter<&'a str>,
}
impl<'a> Iterator for Parts<'a> {
    type Item = &'a str;
    fn next(&mut self) -> Option<Self::Item> {
        self.one.take().or_else(|| self.many.next())
    }
}
impl DoubleEndedIterator for Parts<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        self.one.take().or_else(|| self.many.next_back())
    }
}
fn parts(cluster: &str) -> Parts<'_> {
    let mut result = Vec::new();
    if cluster
        .chars()
        .any(|c| property(c, tables::LINKER) && !swift_linker(c))
    {
        let (mut consonant, mut linker, mut swift) = (false, false, false);
        let mut start = 0;
        for (index, c) in cluster.char_indices() {
            if property(c, tables::CONSONANT) {
                if consonant && linker && !swift {
                    result.push(&cluster[start..index]);
                    start = index;
                }
                (consonant, linker, swift) = (true, false, false);
            } else if property(c, tables::LINKER) {
                linker = true;
                swift |= swift_linker(c);
            } else if !property(c, tables::EXTEND) {
                (consonant, linker, swift) = (false, false, false);
            }
        }
        if !result.is_empty() {
            result.push(&cluster[start..]);
        }
    }
    Parts {
        one: if result.is_empty() {
            Some(cluster)
        } else {
            None
        },
        many: result.into_iter(),
    }
}

pub(super) fn graphemes(value: &str) -> impl DoubleEndedIterator<Item = &str> {
    value.graphemes(true).flat_map(parts)
}

pub(super) fn indices(value: &str) -> impl Iterator<Item = (usize, &str)> {
    let mut offset = 0;
    graphemes(value).map(move |part| {
        let start = offset;
        offset += part.len();
        (start, part)
    })
}

pub fn decode_graphemes(bytes: &[u8]) -> Result<crate::DecodedStore, crate::DecodeError> {
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(crate::DecodeError::Size);
    }
    let texts: Vec<String> =
        serde_json::from_slice(bytes).map_err(|_| crate::DecodeError::Shape)?;
    if texts.len() > 100_000 {
        return Err(crate::DecodeError::Size);
    }
    let lengths: Vec<Vec<usize>> = texts
        .iter()
        .map(|s| graphemes(s).map(str::len).collect())
        .collect();
    Ok(crate::DecodedStore {
        document: serde_json::to_vec(&texts).map_err(|_| crate::DecodeError::Shape)?,
        projection: serde_json::json!({"utf8GraphemeLengths": lengths}),
    })
}
