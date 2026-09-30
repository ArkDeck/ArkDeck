//! Swift's hexadecimal predicates over Characters, which the ArkTrace
//! profile and the Rockchip host records both read digests with.
use crate::session_graphemes::graphemes;

/// `Character.isHexDigit`: one scalar with the Hex_Digit property, and
/// whether it is uppercase or lowercase.
pub(crate) fn hex_case(character: &str) -> Option<(bool, bool)> {
    let mut scalars = character.chars();
    let scalar = scalars.next()?;
    if scalars.next().is_some() {
        return None;
    }
    match scalar {
        '0'..='9' | '\u{FF10}'..='\u{FF19}' => Some((false, false)),
        'a'..='f' | '\u{FF41}'..='\u{FF46}' => Some((false, true)),
        'A'..='F' | '\u{FF21}'..='\u{FF26}' => Some((true, false)),
        _ => None,
    }
}

/// Swift `isSHA256`: 64 Characters, each a hexadecimal digit that is not
/// uppercase.
pub(crate) fn swift_sha256(value: &str) -> bool {
    graphemes(value).count() == 64
        && graphemes(value).all(|character| hex_case(character).is_some_and(|(upper, _)| !upper))
}
