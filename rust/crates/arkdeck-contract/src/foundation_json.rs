//! Foundation `JSONEncoder`'s spelling of a JSON value: the one Swift's
//! durable documents are written in, and its CLI's legacy `--json` output
//! (`CanonicalJSONEncoders.canonicalPretty()`). Keys sort by Unicode scalar,
//! integers keep all 64 bits, and a non-integral number is spelled as
//! Foundation spells a `Double`. Unlike `canonical_json`
//! (`arkdeck.cli.canonical-json/1`), it applies no integer limit.
use crate::ContractError;
use serde_json::{Number, Value};

/// Foundation's spelling of a non-integral number.
pub fn float_text(number: &Number) -> Result<String, ContractError> {
    // serde's audited shortest-roundtrip digit generator is reused; only the
    // Foundation presentation (fixed/scientific boundary and exponent sign/
    // minimum width) differs. No CLI integer limit is applied.
    let raw = number.to_string();
    let negative = raw.starts_with('-');
    let raw = raw.strip_prefix('-').unwrap_or(&raw);
    let (coefficient, exponent) = raw.split_once(['e', 'E']).unwrap_or((raw, "0"));
    let exp: i32 = exponent.parse().map_err(|_| ContractError::Malformed)?;
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
    // Swift spells a `Double` exponentially below 1e-4 and above 2^53
    // (`CLILegacyJSONOracleContractTests`' boundaries).
    if power < -4
        || number
            .as_f64()
            .is_some_and(|x| x.abs() > 9_007_199_254_740_992.0)
    {
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

/// Foundation `JSONEncoder` with `[.sortedKeys, .prettyPrinted]`: two-space
/// indentation, `" : "`, an empty container as its open bracket, a blank line
/// and its close, and no trailing newline. The solidus is escaped unless the
/// encoder has `.withoutEscapingSlashes` (`escape_solidus` false), as
/// `CanonicalJSONEncoders.canonicalPretty()` does.
pub fn pretty(value: &Value, escape_solidus: bool) -> Result<Vec<u8>, ContractError> {
    fn string(text: &str, escape_solidus: bool, output: &mut Vec<u8>) -> Result<(), ContractError> {
        // serde escapes Foundation's set (quote, backslash, C0 controls with
        // the short forms and lowercase \u00xx) except the solidus.
        for byte in serde_json::to_vec(text).map_err(|_| ContractError::Malformed)? {
            if byte == b'/' && escape_solidus {
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
    fn write(
        value: &Value,
        depth: usize,
        escape_solidus: bool,
        output: &mut Vec<u8>,
    ) -> Result<(), ContractError> {
        match value {
            Value::Array(values) => {
                output.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    line(output, depth + 1);
                    write(value, depth + 1, escape_solidus, output)?;
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
                    string(key, escape_solidus, output)?;
                    output.extend_from_slice(b" : ");
                    write(&fields[key.as_str()], depth + 1, escape_solidus, output)?;
                }
                if fields.is_empty() {
                    output.push(b'\n');
                }
                line(output, depth);
                output.push(b'}');
            }
            Value::String(text) => string(text, escape_solidus, output)?,
            Value::Number(n) if !n.is_i64() && !n.is_u64() => output.extend(float_text(n)?.bytes()),
            _ => output.extend(serde_json::to_vec(value).map_err(|_| ContractError::Malformed)?),
        }
        Ok(())
    }
    let mut bytes = Vec::new();
    write(value, 0, escape_solidus, &mut bytes)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spelled(value: f64) -> String {
        float_text(&Number::from_f64(value).unwrap()).unwrap()
    }

    #[test]
    fn a_double_turns_exponential_above_two_to_the_53_and_below_1e_minus_4() {
        // Swift's spellings (`CLILegacyJSONOracleContractTests`' boundaries).
        for (value, text) in [
            (9_007_199_254_740_992.0, "9007199254740992"),
            (9_007_199_254_740_994.0, "9.007199254740994e+15"),
            (-9_007_199_254_740_994.0, "-9.007199254740994e+15"),
            (9.876_543_21e15, "9.87654321e+15"),
            (1_234_567_890_123_456.8, "1234567890123456.8"),
            (1e16, "1e+16"),
            (1e15, "1000000000000000"),
            (0.0001, "0.0001"),
            (-0.0001, "-0.0001"),
            (0.000_099_99, "9.999e-05"),
            (5e-324, "5e-324"),
            (1.5, "1.5"),
        ] {
            assert_eq!(spelled(value), text, "{value}");
        }
    }
}
