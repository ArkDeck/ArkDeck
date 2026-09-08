use crate::ContractError;

/// The restricted deterministic CBOR vocabulary in the current Swift encoder.
/// Encoding bytes gives no permit, signing key, capability, or dispatch authority.
#[derive(Debug, Clone, PartialEq)]
pub enum CborValue {
    Unsigned(u64),
    Bytes(Vec<u8>),
    Text(String),
    Bool(bool),
    Array(Vec<CborValue>),
    Null,
    Map(Vec<(String, CborValue)>),
}

pub fn canonical_cbor(value: &CborValue) -> Result<Vec<u8>, ContractError> {
    fn head(major: u8, number: u64, out: &mut Vec<u8>) {
        let (width, additional) = match number {
            0..=23 => {
                out.push(major << 5 | number as u8);
                return;
            }
            24..=0xff => (1, 24),
            0x100..=0xffff => (2, 25),
            0x10000..=0xffff_ffff => (4, 26),
            _ => (8, 27),
        };
        out.push(major << 5 | additional);
        out.extend_from_slice(&number.to_be_bytes()[8 - width..]);
    }
    fn append(value: &CborValue, out: &mut Vec<u8>) -> Result<(), ContractError> {
        match value {
            CborValue::Unsigned(number) => head(0, *number, out),
            CborValue::Bytes(bytes) => {
                head(2, bytes.len() as u64, out);
                out.extend_from_slice(bytes);
            }
            CborValue::Text(text) => {
                head(3, text.len() as u64, out);
                out.extend_from_slice(text.as_bytes());
            }
            CborValue::Bool(flag) => out.push(if *flag { 0xf5 } else { 0xf4 }),
            CborValue::Null => out.push(0xf6),
            CborValue::Array(values) => {
                head(4, values.len() as u64, out);
                for item in values {
                    append(item, out)?;
                }
            }
            CborValue::Map(fields) => {
                let mut encoded = Vec::with_capacity(fields.len());
                for (key, value) in fields {
                    encoded.push((
                        canonical_cbor(&CborValue::Text(key.clone()))?,
                        canonical_cbor(value)?,
                    ));
                }
                encoded.sort_by(|a, b| a.0.cmp(&b.0));
                if encoded.windows(2).any(|pair| pair[0].0 == pair[1].0) {
                    return Err(ContractError::DuplicateKey);
                }
                head(5, fields.len() as u64, out);
                for (key, value) in encoded {
                    out.extend(key);
                    out.extend(value);
                }
            }
        }
        Ok(())
    }
    let mut result = Vec::new();
    append(value, &mut result)?;
    Ok(result)
}
