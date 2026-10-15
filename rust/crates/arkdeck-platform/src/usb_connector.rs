//! The Windows hub driver's physical connector, independent of USB speed.
//!
//! ArkForge's Windows transport names a connector by its reciprocal hub/port
//! endpoints. This observer uses the same published byte rule, while the
//! Runtime's existing attachment topology and stored bindings stay unchanged.

use std::io;

const MAX_BYTES: usize = 65_536;
const HUB_SUFFIX: &str = "#{F18A0E88-C30C-11D0-8815-00A0C906BED8}";

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Endpoint {
    pub(crate) hub: String,
    pub(crate) port: u32,
}

fn invalid(detail: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, detail)
}

impl Endpoint {
    pub(crate) fn new(hub: &str, port: u32) -> io::Result<Self> {
        let upper = hub.to_ascii_uppercase();
        let key = [r"\\?\", r"\\.\", r"\??\"]
            .into_iter()
            .find_map(|prefix| upper.strip_prefix(prefix))
            .unwrap_or(&upper);
        if !(1..=255).contains(&port)
            || !key.starts_with("USB#")
            || !key.ends_with(HUB_SUFFIX)
            || key.contains(['\\', '/', '\0'])
            || key.encode_utf16().count() > MAX_BYTES / 2
        {
            return Err(invalid("invalid USB connector endpoint"));
        }
        Ok(Self {
            hub: key.into(),
            port,
        })
    }
}

/// Resolve twice in both directions before publishing the connector. A
/// similar location path, matching serial or caller alias cannot join ports.
pub(crate) fn location(
    endpoint: &Endpoint,
    mut query: impl FnMut(&Endpoint) -> io::Result<Option<Endpoint>>,
) -> io::Result<u32> {
    let companion = query(endpoint)?;
    let mut ports = vec![endpoint.clone()];
    if let Some(other) = &companion {
        if other == endpoint || query(other)?.as_ref() != Some(endpoint) {
            return Err(invalid("USB connector relationship is not reciprocal"));
        }
        ports.push(other.clone());
    }
    if query(endpoint)? != companion {
        return Err(invalid("USB connector relationship changed"));
    }
    if let Some(other) = &companion
        && query(other)?.as_ref() != Some(endpoint)
    {
        return Err(invalid("USB connector relationship changed"));
    }
    ports.sort();
    // arkforge-usb/windows_topology.rs, windows-usb-connector/v1.
    let mut hash = 0x811c_9dc5u32;
    let mut feed = |unit: u16| {
        hash ^= u32::from(unit);
        hash = hash.wrapping_mul(0x0100_0193);
    };
    for unit in "arkforge/windows-usb-connector/v1\0".encode_utf16() {
        feed(unit);
    }
    for endpoint in ports {
        for unit in endpoint.hub.encode_utf16().chain(std::iter::once(0)) {
            feed(unit);
        }
        feed(endpoint.port as u16);
        feed(0);
    }
    Ok(hash)
}

/// USB_PORT_CONNECTOR_PROPERTIES is packed; decode bounded byte slices.
pub(crate) fn companion(bytes: &[u8], port: u32) -> io::Result<Option<Endpoint>> {
    let word = |offset| -> io::Result<u16> {
        let pair = bytes
            .get(offset..offset + 2)
            .ok_or_else(|| invalid("short USB connector response"))?;
        Ok(u16::from_le_bytes([pair[0], pair[1]]))
    };
    let dword = |offset| -> io::Result<u32> {
        let part = bytes
            .get(offset..offset + 4)
            .ok_or_else(|| invalid("short USB connector response"))?;
        Ok(u32::from_le_bytes(part.try_into().unwrap()))
    };
    if bytes.len() < 18 || dword(0)? != port || word(12)? != 0 {
        return Err(invalid("mismatched USB connector response"));
    }
    let flags = dword(8)?;
    if flags & !0x0f != 0 || flags & 4 != 0 {
        return Err(invalid("multiple or unknown USB companions"));
    }
    let length = dword(4)? as usize;
    if !(18..=MAX_BYTES).contains(&length)
        || length > bytes.len()
        || !length.is_multiple_of(2)
        || bytes[length..].iter().any(|byte| *byte != 0)
    {
        return Err(invalid("invalid USB connector response length"));
    }
    let units: Vec<u16> = bytes[16..length]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_le_bytes(*pair))
        .collect();
    let end = units
        .iter()
        .position(|unit| *unit == 0)
        .ok_or_else(|| invalid("unterminated USB companion"))?;
    if units[end..].iter().any(|unit| *unit != 0) {
        return Err(invalid("data follows USB companion terminator"));
    }
    let other_port = word(14)?;
    if other_port == 0 && end == 0 {
        return Ok(None);
    }
    let name =
        String::from_utf16(&units[..end]).map_err(|_| invalid("invalid USB companion name"))?;
    Endpoint::new(&name, u32::from(other_port)).map(Some)
}

#[cfg(test)]
#[path = "usb_connector_tests.rs"]
mod tests;
