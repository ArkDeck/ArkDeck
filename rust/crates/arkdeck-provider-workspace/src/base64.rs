//! The standard Base64 alphabet as Foundation's `Data.base64EncodedString()`
//! writes it and `Data(base64Encoded:)` reads it: padded to a multiple of four,
//! no line breaks and no characters outside the alphabet. Like Foundation, the
//! decoder ignores unused bits in the last quantum.
use arkdeck_platform::Secret;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(crate) fn encode(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                output.push(char::from(
                    ALPHABET[((value >> (18 - 6 * index)) & 0x3f) as usize],
                ));
            } else {
                output.push('=');
            }
        }
    }
    output
}

pub(crate) fn decode(text: &[u8]) -> Option<Secret> {
    if !text.len().is_multiple_of(4) {
        return None;
    }
    let mut output = Vec::with_capacity(text.len() / 4 * 3);
    for (index, quantum) in text.chunks(4).enumerate() {
        let last = index + 1 == text.len() / 4;
        let padding = quantum
            .iter()
            .rev()
            .take_while(|byte| **byte == b'=')
            .count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut value = 0u32;
        for (position, byte) in quantum.iter().enumerate() {
            let digit = if position >= 4 - padding {
                0
            } else {
                u32::from(ALPHABET.iter().position(|symbol| symbol == byte)? as u8)
            };
            value = (value << 6) | digit;
        }
        let bytes = [(value >> 16) as u8, (value >> 8) as u8, value as u8];
        output.extend_from_slice(&bytes[..3 - padding]);
    }
    Some(Secret::new(output))
}

#[cfg(test)]
mod tests {
    use super::{decode, encode};

    #[test]
    fn round_trips_every_length_and_matches_known_vectors() {
        for (plain, encoded) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"fooba", "Zm9vYmE="),
            (b"foobar", "Zm9vYmFy"),
            // Foundation's own spelling of these bytes (`/++/Pj8=`).
            (&[0xff, 0xef, 0xbf, 0x3e, 0x3f][..], "/++/Pj8="),
        ] {
            assert_eq!(encode(plain), encoded);
            assert_eq!(decode(encoded.as_bytes()).unwrap().as_bytes(), plain);
        }
    }

    #[test]
    fn refuses_what_foundation_refuses() {
        for text in ["QQ", "Q===", "QQ==QQ==", "Zm9v\n", "Zm9 ", "Zm9-"] {
            assert!(decode(text.as_bytes()).is_none(), "{text:?}");
        }
        // Foundation accepts unused non-zero bits in the last quantum.
        assert_eq!(decode(b"QR==").unwrap().as_bytes(), b"A");
    }
}
