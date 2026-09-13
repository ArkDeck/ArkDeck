//! Frozen Session JSONValue/JSONEncoder document domain. Unlike CLI JCS this
//! keeps 64-bit integers, sorts UTF-8 keys, and uses Foundation float spelling.
//! Readers accept canonical input only; they do not rewrite durable documents.
use crate::{DecodeError, DecodedStore, canonical_host_text};
use serde_json::{Map, Number, Value, json};
use std::collections::BTreeSet;

type Result<T> = std::result::Result<T, DecodeError>;

struct Reader<'a> {
    bytes: &'a [u8],
    position: usize,
}
impl Reader<'_> {
    fn whitespace(&mut self) {
        while self
            .bytes
            .get(self.position)
            .is_some_and(|b| b" \t\r\n".contains(b))
        {
            self.position += 1;
        }
    }
    fn consume(&mut self, byte: u8) -> Result<()> {
        if self.bytes.get(self.position) != Some(&byte) {
            return Err(DecodeError::Shape);
        }
        self.position += 1;
        Ok(())
    }
    fn string(&mut self) -> Result<String> {
        let start = self.position;
        self.consume(b'"')?;
        while let Some(b) = self.bytes.get(self.position) {
            self.position += 1;
            match b {
                b'\\' => {
                    self.position += 1;
                }
                b'"' => {
                    return serde_json::from_slice(&self.bytes[start..self.position])
                        .map_err(|_| DecodeError::Shape);
                }
                _ => (),
            }
        }
        Err(DecodeError::Shape)
    }
    fn value(&mut self, depth: usize) -> Result<Value> {
        // StrictJSONDuplicateValidator counts the root as depth zero, including
        // scalar leaves. Keep this bound independent of serde's wire reader.
        if depth > 256 {
            return Err(DecodeError::Shape);
        }
        self.whitespace();
        match self
            .bytes
            .get(self.position)
            .copied()
            .ok_or(DecodeError::Shape)?
        {
            b'"' => Ok(Value::String(self.string()?)),
            b'{' => {
                self.position += 1;
                self.whitespace();
                let mut fields = Map::new();
                let mut keys = BTreeSet::new();
                if self.bytes.get(self.position) != Some(&b'}') {
                    loop {
                        self.whitespace();
                        let key = self.string()?;
                        let canonical = if key.is_ascii() {
                            key.clone()
                        } else {
                            canonical_host_text(&key)?
                        };
                        if !keys.insert(canonical) {
                            return Err(DecodeError::Shape);
                        }
                        self.whitespace();
                        self.consume(b':')?;
                        fields.insert(key, self.value(depth + 1)?);
                        self.whitespace();
                        if self.bytes.get(self.position) == Some(&b'}') {
                            break;
                        }
                        self.consume(b',')?;
                    }
                }
                self.consume(b'}')?;
                Ok(Value::Object(fields))
            }
            b'[' => {
                self.position += 1;
                self.whitespace();
                let mut values = Vec::new();
                if self.bytes.get(self.position) != Some(&b']') {
                    loop {
                        values.push(self.value(depth + 1)?);
                        self.whitespace();
                        if self.bytes.get(self.position) == Some(&b']') {
                            break;
                        }
                        self.consume(b',')?;
                    }
                }
                self.consume(b']')?;
                Ok(Value::Array(values))
            }
            b't' | b'f' | b'n' | b'-' | b'0'..=b'9' => {
                let start = self.position;
                while self
                    .bytes
                    .get(self.position)
                    .is_some_and(|b| !b" \t\r\n,]}".contains(b))
                {
                    self.position += 1;
                }
                let token = &self.bytes[start..self.position];
                let value: Value = serde_json::from_slice(token).map_err(|_| DecodeError::Shape)?;
                if value.is_number() {
                    number(token)
                } else {
                    Ok(value)
                }
            }
            _ => Err(DecodeError::Shape),
        }
    }
}

// JSONValue tries Int64, UInt64, then Double. Plain integers retain all bits;
// decimal/exponent spellings which Foundation decodes as integers cannot be
// canonical floating-point tokens. The final byte comparison rejects them.
fn number(token: &[u8]) -> Result<Value> {
    let text = std::str::from_utf8(token).map_err(|_| DecodeError::Shape)?;
    if let Ok(value) = text.parse::<i64>() {
        return Ok(value.into());
    }
    if let Ok(value) = text.parse::<u64>() {
        return Ok(value.into());
    }
    let value: f64 = text.parse().map_err(|_| DecodeError::Shape)?;
    if !value.is_finite() {
        return Err(DecodeError::Shape);
    }
    if value.fract() == 0.0 {
        if value.abs() < 9_007_199_254_740_992.0 {
            return Ok((value as i64).into());
        }
        if (-9_223_372_036_854_775_808.0..18_446_744_073_709_551_616.0).contains(&value)
            && let Some(integer) = decimal_integer(text)
        {
            return Ok(integer);
        }
    }
    Number::from_f64(value)
        .map(Value::Number)
        .ok_or(DecodeError::Shape)
}

fn decimal_integer(text: &str) -> Option<Value> {
    let negative = text.starts_with('-');
    let text = text.strip_prefix('-').unwrap_or(text);
    let (coefficient, exponent) = text.split_once(['e', 'E']).unwrap_or((text, "0"));
    let fraction = coefficient.split_once('.').map_or(0, |(_, f)| f.len());
    let mut exponent = exponent
        .parse::<i32>()
        .ok()?
        .checked_sub(i32::try_from(fraction).ok()?)?;
    let mut digits: String = coefficient.chars().filter(|c| *c != '.').collect();
    while digits.ends_with('0') && digits.len() > 1 {
        digits.pop();
        exponent = exponent.checked_add(1)?;
    }
    let mut integer = digits.parse::<u64>().ok()?;
    if exponent >= 0 {
        integer = integer.checked_mul(10_u64.checked_pow(exponent as u32)?)?;
    } else {
        integer /= 10_u64.checked_pow(exponent.unsigned_abs())?;
    }
    if negative {
        i64::try_from(integer).ok().map(|v| Value::from(-v))
    } else {
        Some(integer.into())
    }
}

pub(super) fn float_text(number: &Number) -> Result<String> {
    // serde's audited shortest-roundtrip digit generator is reused; only the
    // Foundation presentation (fixed/scientific boundary and exponent sign/
    // minimum width) differs. No CLI integer limit is applied.
    let raw = number.to_string();
    let negative = raw.starts_with('-');
    let raw = raw.strip_prefix('-').unwrap_or(&raw);
    let (coefficient, exponent) = raw.split_once(['e', 'E']).unwrap_or((raw, "0"));
    let exp: i32 = exponent.parse().map_err(|_| DecodeError::Shape)?;
    let decimal = coefficient.find('.').unwrap_or(coefficient.len());
    let mut digits = coefficient.replace('.', "");
    let leading = digits.bytes().take_while(|b| *b == b'0').count();
    let power = exp + decimal as i32 - leading as i32 - 1;
    digits.drain(..leading);
    while digits.ends_with('0') {
        digits.pop();
    }
    if digits.is_empty() {
        return Ok(if negative { "-0" } else { "0" }.into());
    }
    let sign = if negative { "-" } else { "" };
    if !(-4..16).contains(&power) {
        let tail = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        return Ok(format!(
            "{sign}{}{tail}e{}{:02}",
            &digits[..1],
            if power < 0 { "-" } else { "+" },
            power.unsigned_abs()
        ));
    }
    let point = power + 1;
    let value = if point <= 0 {
        format!("0.{}{digits}", "0".repeat((-point) as usize))
    } else if point as usize >= digits.len() {
        format!("{digits}{}", "0".repeat(point as usize - digits.len()))
    } else {
        format!(
            "{}.{}",
            &digits[..point as usize],
            &digits[point as usize..]
        )
    };
    Ok(format!("{sign}{value}"))
}

pub(super) fn encode(value: &Value) -> Result<Vec<u8>> {
    fn write(value: &Value, output: &mut Vec<u8>) -> Result<()> {
        match value {
            Value::Array(values) => {
                output.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    write(value, output)?;
                }
                output.push(b']');
            }
            Value::Object(fields) => {
                output.push(b'{');
                for (index, (key, value)) in fields.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    output.extend(serde_json::to_vec(key).map_err(|_| DecodeError::Shape)?);
                    output.push(b':');
                    write(value, output)?;
                }
                output.push(b'}');
            }
            Value::Number(n) if !n.is_i64() && !n.is_u64() => output.extend(float_text(n)?.bytes()),
            _ => output.extend(serde_json::to_vec(value).map_err(|_| DecodeError::Shape)?),
        }
        Ok(())
    }
    let mut bytes = Vec::new();
    write(value, &mut bytes)?;
    Ok(bytes)
}

/// Foundation JSONEncoder with `[.sortedKeys, .prettyPrinted]`, the spelling of
/// Swift `RuntimeJobRecord.durableData()`: two-space indentation, `" : "`, an
/// empty container as its open bracket, a blank line and its close, an escaped
/// solidus and no trailing newline. Keys and numbers are spelled as `encode`.
#[cfg(target_os = "macos")]
pub(super) fn encode_pretty(value: &Value) -> Result<Vec<u8>> {
    fn string(text: &str, output: &mut Vec<u8>) -> Result<()> {
        // serde escapes Foundation's set (quote, backslash, C0 controls with
        // the short forms and lowercase \u00xx) except the solidus.
        for byte in serde_json::to_vec(text).map_err(|_| DecodeError::Shape)? {
            if byte == b'/' {
                output.push(b'\\');
            }
            output.push(byte);
        }
        Ok(())
    }
    fn line(output: &mut Vec<u8>, depth: usize) {
        output.push(b'\n');
        output.resize(output.len() + 2 * depth, b' ');
    }
    fn write(value: &Value, depth: usize, output: &mut Vec<u8>) -> Result<()> {
        match value {
            Value::Array(values) => {
                output.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    line(output, depth + 1);
                    write(value, depth + 1, output)?;
                }
                if values.is_empty() {
                    output.push(b'\n');
                }
                line(output, depth);
                output.push(b']');
            }
            Value::Object(fields) => {
                let mut keys: Vec<&String> = fields.keys().collect();
                keys.sort_unstable();
                output.push(b'{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    line(output, depth + 1);
                    string(key, output)?;
                    output.extend_from_slice(b" : ");
                    write(&fields[key.as_str()], depth + 1, output)?;
                }
                if fields.is_empty() {
                    output.push(b'\n');
                }
                line(output, depth);
                output.push(b'}');
            }
            Value::String(text) => string(text, output)?,
            Value::Number(n) if !n.is_i64() && !n.is_u64() => output.extend(float_text(n)?.bytes()),
            _ => output.extend(serde_json::to_vec(value).map_err(|_| DecodeError::Shape)?),
        }
        Ok(())
    }
    let mut bytes = Vec::new();
    write(value, 0, &mut bytes)?;
    Ok(bytes)
}

pub(super) fn parse(bytes: &[u8]) -> Result<Value> {
    if bytes.is_empty() || bytes.len() > 16 * 1024 * 1024 {
        return Err(DecodeError::Size);
    }
    let mut reader = Reader { bytes, position: 0 };
    let value = reader.value(0)?;
    reader.whitespace();
    if reader.position != bytes.len() || encode(&value)? != bytes {
        return Err(DecodeError::Shape);
    }
    Ok(value)
}

pub fn decode_session_json(bytes: &[u8]) -> Result<DecodedStore> {
    let value = parse(bytes)?;
    let document = encode(&value)?;
    Ok(DecodedStore {
        projection: json!({"canonicalSHA256": arkdeck_contract::sha256_hex(&document)}),
        document,
    })
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::encode_pretty;
    use serde_json::{Value, json};

    #[test]
    fn pretty_spelling_matches_foundation() {
        // Printed by Foundation JSONEncoder([.sortedKeys, .prettyPrinted]).
        let cases = [
            (json!({}), "{\n\n}"),
            (json!([]), "[\n\n]"),
            (
                json!({"b": {}, "a": [], "c": [[], {}, [1]]}),
                "{\n  \"a\" : [\n\n  ],\n  \"b\" : {\n\n  },\n  \"c\" : [\n    [\n\n    ],\n    {\n\n    },\n    [\n      1\n    ]\n  ]\n}",
            ),
            (
                json!({"a/b": ["x/y", "\u{7}\u{1f}\u{7f}", "\n\t\r\u{8}\u{c}", "\"\\", "\u{2028}"]}),
                "{\n  \"a\\/b\" : [\n    \"x\\/y\",\n    \"\\u0007\\u001f\u{7f}\",\n    \"\\n\\t\\r\\b\\f\",\n    \"\\\"\\\\\",\n    \"\u{2028}\"\n  ]\n}",
            ),
            (
                json!([1.0e-7, 1.0e21, 1.0e16, 1.0e15, 0.5, -0.0, 5e-324, 1, -1]),
                "[\n  1e-07,\n  1e+21,\n  1e+16,\n  1000000000000000,\n  0.5,\n  -0,\n  5e-324,\n  1,\n  -1\n]",
            ),
        ];
        for (value, expected) in cases {
            let bytes = encode_pretty(&value).unwrap();
            assert_eq!(String::from_utf8(bytes).unwrap(), expected);
        }
    }

    #[test]
    fn pretty_spelling_reproduces_the_swift_probe() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/fixtures/job-store-writer/format-probe.json"
        ))
        .unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(encode_pretty(&value).unwrap(), bytes);
    }
}
