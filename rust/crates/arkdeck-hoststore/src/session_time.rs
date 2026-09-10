//! Current SessionStorageValidation.timestamp + lockedTimestampDate semantics.
//! This is distinct from the narrower History/Trace formatter domains.
use crate::{DecodeError, DecodedStore};
#[cfg(target_os = "macos")]
use serde_json::json;

#[cfg(target_os = "macos")]
fn number(bytes: &[u8]) -> Option<i32> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    bytes.iter().try_fold(0_i32, |n, b| {
        n.checked_mul(10)?.checked_add(i32::from(b - b'0'))
    })
}

#[cfg(target_os = "macos")]
pub fn session_timestamp(text: &str) -> Option<f64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 {
        return None;
    }
    let (local, offset) = if matches!(bytes.last(), Some(b'Z' | b'z')) {
        (&bytes[..bytes.len() - 1], 0)
    } else {
        if bytes.len() < 25 {
            return None;
        }
        let at = bytes.len() - 6;
        let zone = &bytes[at..];
        if !matches!(zone[0], b'+' | b'-') || zone[3] != b':' {
            return None;
        }
        let hour = number(&zone[1..3])?;
        let minute = number(&zone[4..6])?;
        if hour > 23 || minute > 59 {
            return None;
        }
        (
            &bytes[..at],
            (hour * 3600 + minute * 60) * if zone[0] == b'-' { -1 } else { 1 },
        )
    };
    if local.len() < 19
        || local[4] != b'-'
        || local[7] != b'-'
        || !matches!(local[10], b'T' | b't')
        || local[13] != b':'
        || local[16] != b':'
    {
        return None;
    }
    let year = number(&local[0..4])?;
    let month = number(&local[5..7])?;
    let day = number(&local[8..10])?;
    let hour = number(&local[11..13])?;
    let minute = number(&local[14..16])?;
    let second = number(&local[17..19])?;
    if !(1..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let nanos = if local.len() == 19 {
        0
    } else {
        if local.len() < 21 || local[19] != b'.' || !local[20..].iter().all(u8::is_ascii_digit) {
            return None;
        }
        let fraction = &local[20..local.len().min(29)];
        number(fraction)? * 10_i32.pow(9 - fraction.len() as u32)
    };
    let mut date =
        arkdeck_platform::host_gregorian_seconds(year, month, day, hour, minute, second.min(59))?;
    if second == 60 {
        date += 1.0;
    }
    if local.len() != 19 {
        date += f64::from(nanos) / 1_000_000_000.0;
    }
    date -= f64::from(offset);
    Some(date)
}

#[cfg(target_os = "macos")]
pub fn decode_session_timestamp(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    if bytes.is_empty() || bytes.len() > 64 * 1024 {
        return Err(DecodeError::Size);
    }
    let text: String = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    let date = session_timestamp(&text).ok_or(DecodeError::Shape)?;
    Ok(DecodedStore {
        document: serde_json::to_vec(&text).map_err(|_| DecodeError::Shape)?,
        projection: json!({"referenceSecondsBits": date.to_bits().to_string()}),
    })
}

#[cfg(not(target_os = "macos"))]
pub fn decode_session_timestamp(_: &[u8]) -> Result<DecodedStore, DecodeError> {
    Err(DecodeError::Shape)
}
