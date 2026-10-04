//! Bounded private keyboard payload. Only its immutable Artifact lease crosses
//! the Job boundary; neither text nor an encoded copy belongs in audit output.
use crate::ContractError;
use serde::Deserialize;

pub const KEYBOARD_PAYLOAD_MAX_BYTES: usize = 4096;
pub const KEYBOARD_TEXT_MAX_BYTES: usize = 512;
pub const KEYBOARD_MEDIA_TYPE: &str = "application/vnd.arkdeck.keyboard-input+json";

// Deliberately no Debug/Serialize: accidental diagnostic formatting must not
// turn a private input into an audit record.
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum KeyboardPayload {
    Key {
        key: KeyboardKey,
    },
    Text {
        text: String,
        #[serde(rename = "allowDeviceClipboard")]
        allow_device_clipboard: bool,
    },
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyboardKey {
    Enter,
    Backspace,
    Tab,
    Escape,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    Home,
    Back,
}

impl KeyboardKey {
    /// OpenHarmony KeyEvent constants; source pins are in the provider contract.
    pub fn code(self) -> u32 {
        match self {
            Self::Enter => 2054,
            Self::Backspace => 2055,
            Self::Tab => 2049,
            Self::Escape => 2070,
            Self::ArrowUp => 2012,
            Self::ArrowDown => 2013,
            Self::ArrowLeft => 2014,
            Self::ArrowRight => 2015,
            Self::Home => 1,
            Self::Back => 2,
        }
    }
}

impl KeyboardPayload {
    pub fn decode(bytes: &[u8]) -> Result<Self, ContractError> {
        if bytes.is_empty() || bytes.len() > KEYBOARD_PAYLOAD_MAX_BYTES {
            return Err(ContractError::Malformed);
        }
        // Struct decoding also rejects duplicate keys and unknown fields.
        let payload: Self = serde_json::from_slice(bytes).map_err(|_| ContractError::Malformed)?;
        if let Self::Text {
            text,
            allow_device_clipboard,
        } = &payload
            && (!allow_device_clipboard
                || text.is_empty()
                || text.len() > KEYBOARD_TEXT_MAX_BYTES
                || text.chars().any(char::is_control))
        {
            return Err(ContractError::Malformed);
        }
        Ok(payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_private_payload_rejects_ambiguous_or_unapproved_input() {
        for value in [
            r#"{"kind":"key","key":"Power"}"#,
            r#"{"kind":"key","key":"enter","argv":[]}"#,
            r#"{"kind":"key","key":"enter","key":"back"}"#,
            r#"{"kind":"text","text":"你好","allowDeviceClipboard":false}"#,
            r#"{"kind":"text","text":"","allowDeviceClipboard":true}"#,
            r#"{"kind":"text","text":"a\nb","allowDeviceClipboard":true}"#,
        ] {
            assert!(KeyboardPayload::decode(value.as_bytes()).is_err());
        }
        let text =
            serde_json::json!({"kind":"text","text":"字".repeat(171),"allowDeviceClipboard":true});
        assert!(KeyboardPayload::decode(text.to_string().as_bytes()).is_err());
        assert!(KeyboardPayload::decode(br#"{"kind":"key","key":"enter"}"#).is_ok());
        assert!(
            KeyboardPayload::decode(
                r#"{"kind":"text","text":"你好 ' $() ` 世界","allowDeviceClipboard":true}"#
                    .as_bytes()
            )
            .is_ok()
        );
    }
}
