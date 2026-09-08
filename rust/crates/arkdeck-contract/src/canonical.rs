use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::ContractError;

pub fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// arkdeck.cli.canonical-json/1. Catalog and CBOR retain their own encodings.
pub fn canonical_json(value: &Value) -> Result<Vec<u8>, ContractError> {
    fn append(value: &Value, out: &mut String) -> Result<(), ContractError> {
        match value {
            Value::Null => out.push_str("null"),
            Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
            Value::Number(number) => {
                const EXACT: u64 = 9_007_199_254_740_991;
                if let Some(integer) = number.as_i64() {
                    if integer.unsigned_abs() > EXACT {
                        return Err(ContractError::IntegerBeyondExactRange);
                    }
                    out.push_str(&integer.to_string());
                } else if let Some(integer) = number.as_u64() {
                    if integer > EXACT {
                        return Err(ContractError::IntegerBeyondExactRange);
                    }
                    out.push_str(&integer.to_string());
                } else {
                    let number = number.as_f64().ok_or(ContractError::Malformed)?;
                    // Match the Swift oracle's integral-binary64 restriction too.
                    if number.fract() == 0.0
                        && number.abs() < 1e21
                        && number >= i64::MIN as f64
                        && number < i64::MAX as f64
                        && number.abs() > EXACT as f64
                    {
                        return Err(ContractError::IntegerBeyondExactRange);
                    }
                    out.push_str(&swift_number(number));
                }
            }
            Value::String(string) => {
                out.push_str(&serde_json::to_string(string).map_err(|_| ContractError::Malformed)?)
            }
            Value::Array(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index != 0 {
                        out.push(',');
                    }
                    append(item, out)?;
                }
                out.push(']');
            }
            Value::Object(fields) => {
                let mut keys: Vec<_> = fields.keys().collect();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                out.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index != 0 {
                        out.push(',');
                    }
                    out.push_str(
                        &serde_json::to_string(key).map_err(|_| ContractError::Malformed)?,
                    );
                    out.push(':');
                    append(&fields[*key], out)?;
                }
                out.push('}');
            }
        }
        Ok(())
    }
    let mut out = String::new();
    append(value, &mut out)?;
    Ok(out.into_bytes())
}

// Preserve the current Swift oracle, including its scientific notation below
// 1e-4 and above the integral-Int64 fast path. Swift currently emits 1e-6 and
// 1e+20 where RFC 8785 would use decimal notation. Changing only Rust would
// split the contract. Native Swift boundary vectors pin that known difference.
fn swift_number(number: f64) -> String {
    if number == 0.0 {
        return "0".into();
    }
    let rendered = number.abs().to_string();
    let (mantissa, exponent) = rendered
        .split_once(['e', 'E'])
        .map_or((rendered.as_str(), 0_i32), |(m, e)| {
            (m, e.parse().expect("float exponent"))
        });
    let mut position = mantissa.find('.').unwrap_or(mantissa.len()) as i32 + exponent;
    let all_digits = mantissa.replace('.', "");
    let leading = all_digits.len() - all_digits.trim_start_matches('0').len();
    position -= leading as i32;
    let digits = all_digits[leading..].trim_end_matches('0');
    let mut result = if number.is_sign_negative() {
        "-".to_owned()
    } else {
        String::new()
    };
    if position > 0 && position <= 16 {
        let position = position as usize;
        if position >= digits.len() {
            result.push_str(digits);
            result.push_str(&"0".repeat(position - digits.len()));
        } else {
            result.push_str(&digits[..position]);
            result.push('.');
            result.push_str(&digits[position..]);
        }
    } else if position <= 0 && position > -4 {
        result.push_str("0.");
        result.push_str(&"0".repeat((-position) as usize));
        result.push_str(digits);
    } else {
        result.push_str(&digits[..1]);
        if digits.len() > 1 {
            result.push('.');
            result.push_str(&digits[1..]);
        }
        result.push('e');
        let exponent = position - 1;
        if exponent >= 0 {
            result.push('+');
        }
        result.push_str(&exponent.to_string());
    }
    result
}
