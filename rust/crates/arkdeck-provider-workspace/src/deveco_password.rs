//! Swift `OpenHarmonyDevEcoPasswordDecoder`: DevEco Studio writes each signing
//! password as hexadecimal ciphertext and keeps the key material beside the
//! keystore (`material/fd/<slot>/<file>` ×3, `material/ac/<salt>`,
//! `material/ce/<work key>`). The three `fd` parts and a fixed component are
//! XORed; the result becomes a password the way Node's `Buffer.toString()`
//! reads it (UTF-8 with U+FFFD for each maximal ill-formed subsequence);
//! PBKDF2-HMAC-SHA256 (10 000 rounds, 16 bytes) of it with the salt opens the
//! work key; the work key opens the password. Both envelopes are
//! `[u32 big-endian ciphertext+tag length][12-byte nonce][ciphertext][16-byte tag]`
//! under AES-128-GCM.
//!
//! Only the interactive install and re-key boundaries decode; a Runtime Job
//! never depends on DevEco's mutable material. A candidate that is not shaped
//! as DevEco ciphertext is an ordinary password and comes back unchanged.
use crate::SigningError;
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use arkdeck_platform::{Secret, wipe};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::path::Path;

const COMPONENT: [u8; 16] = [
    49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119,
];
const ITERATIONS: u32 = 10_000;
const MAX_CIPHERTEXT_HEX: usize = 2_048;

/// Swift `decodeIfNeeded(_:keystore:)`: the decoded password when `candidate`
/// is DevEco ciphertext whose material lives beside `keystore`, otherwise the
/// candidate itself.
pub fn decode_if_needed(candidate: &[u8], keystore: &Path) -> Result<Secret, SigningError> {
    let Ok(text) = std::str::from_utf8(candidate) else {
        return Ok(Secret::from_slice(candidate));
    };
    if text.len() < 32
        || !text.len().is_multiple_of(2)
        || !text.bytes().all(|b| nibble(b).is_some())
    {
        return Ok(Secret::from_slice(candidate));
    }
    if text.len() > MAX_CIPHERTEXT_HEX {
        return Err(SigningError::invalid(
            "DevEco password ciphertext is malformed",
        ));
    }
    let encrypted_password = Secret::new(
        text.as_bytes()
            .chunks(2)
            .map(|pair| (nibble(pair[0]).unwrap_or(0) << 4) | nibble(pair[1]).unwrap_or(0))
            .collect(),
    );
    // A long hexadecimal plaintext password is valid: only the authenticated
    // envelope shape makes it DevEco material.
    if !looks_like_envelope(encrypted_password.as_bytes()) {
        return Ok(Secret::from_slice(candidate));
    }
    let material = keystore
        .parent()
        .ok_or_else(|| {
            SigningError::invalid("DevEco signing material directory is absent or unsafe")
        })?
        .join("material");
    let parts = material_layout::fd_parts(&material.join("fd"))?;
    let salt = material_layout::only_file(&material.join("ac"), Some(16))?;
    let encrypted_work_key = material_layout::only_file(&material.join("ce"), None)?;
    decode_with_material(
        encrypted_password.as_bytes(),
        [
            parts[0].as_bytes(),
            parts[1].as_bytes(),
            parts[2].as_bytes(),
        ],
        salt.as_bytes(),
        encrypted_work_key.as_bytes(),
    )
}

/// The derivation and both decryptions over material already read.
pub fn decode_with_material(
    encrypted_password: &[u8],
    parts: [&[u8]; 3],
    salt: &[u8],
    encrypted_work_key: &[u8],
) -> Result<Secret, SigningError> {
    if parts.iter().any(|part| part.len() != COMPONENT.len()) || salt.len() != 16 {
        return Err(SigningError::invalid(
            "DevEco signing material layout is incomplete",
        ));
    }
    let mut combined = Secret::from_slice(&COMPONENT);
    let mut bytes = combined.as_bytes().to_vec();
    for part in parts {
        for (byte, other) in bytes.iter_mut().zip(part) {
            *byte ^= other;
        }
    }
    combined = Secret::new(bytes);
    // Node's `Buffer.toString()` then `pbkdf2Sync` re-encoding: UTF-8 with
    // replacement characters, not the bytes themselves.
    let password_material = Secret::new(
        String::from_utf8_lossy(combined.as_bytes())
            .into_owned()
            .into_bytes(),
    );
    drop(combined);
    let root_key = pbkdf2_sha256(password_material.as_bytes(), salt, ITERATIONS, 16)?;
    drop(password_material);
    let work_key = open(encrypted_work_key, root_key.as_bytes())?;
    if work_key.len() != 16 {
        return Err(SigningError::invalid(
            "DevEco signing material produced an invalid work key",
        ));
    }
    let decoded = open(encrypted_password, work_key.as_bytes())?;
    let bytes = decoded.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 1_024
        || std::str::from_utf8(bytes).is_err()
        || bytes.iter().any(|byte| matches!(byte, 0 | b'\n' | b'\r'))
    {
        return Err(SigningError::invalid(
            "DevEco signing password plaintext is invalid",
        ));
    }
    Ok(decoded)
}

fn looks_like_envelope(envelope: &[u8]) -> bool {
    if envelope.len() < 4 + 12 + 1 + 16 {
        return false;
    }
    let sealed = sealed_count(envelope);
    sealed > 16 && envelope.len() as u64 == 4 + 12 + sealed
}

fn sealed_count(envelope: &[u8]) -> u64 {
    envelope[..4]
        .iter()
        .fold(0u64, |value, byte| (value << 8) | u64::from(*byte))
}

/// Swift `decrypt(_:key:)`: one AES-128-GCM envelope.
fn open(envelope: &[u8], key: &[u8]) -> Result<Secret, SigningError> {
    if envelope.len() < 4 + 12 + 16 {
        return Err(SigningError::invalid(
            "DevEco encrypted material is truncated",
        ));
    }
    // The prefix counts the ciphertext and its tag; what remains is the nonce.
    let sealed = sealed_count(envelope);
    let nonce_count = envelope.len() as i128 - 4 - i128::from(sealed);
    if nonce_count != 12 || sealed <= 16 {
        return Err(SigningError::invalid(
            "DevEco encrypted material envelope is malformed",
        ));
    }
    let cipher = Aes128Gcm::new_from_slice(key).map_err(|_| {
        SigningError::invalid("DevEco encrypted password could not be authenticated")
    })?;
    cipher
        .decrypt(Nonce::from_slice(&envelope[4..16]), &envelope[16..])
        .map(Secret::new)
        .map_err(|_| SigningError::invalid("DevEco encrypted password could not be authenticated"))
}

/// Swift `pbkdf2SHA256(password:salt:iterations:outputByteCount:)`.
pub fn pbkdf2_sha256(
    password: &[u8],
    salt: &[u8],
    iterations: u32,
    output_byte_count: usize,
) -> Result<Secret, SigningError> {
    if iterations == 0 || output_byte_count == 0 {
        return Err(SigningError::invalid(
            "DevEco password derivation parameters are invalid",
        ));
    }
    let key = <Hmac<Sha256> as Mac>::new_from_slice(password)
        .map_err(|_| SigningError::invalid("DevEco password derivation parameters are invalid"))?;
    let mut derived = Vec::with_capacity(output_byte_count + 32);
    let mut block: u32 = 1;
    while derived.len() < output_byte_count {
        let mut mac = key.clone();
        mac.update(salt);
        mac.update(&block.to_be_bytes());
        let mut u: [u8; 32] = mac.finalize().into_bytes().into();
        let mut accumulated = u;
        for _ in 1..iterations {
            let mut mac = key.clone();
            mac.update(&u);
            u = mac.finalize().into_bytes().into();
            for (byte, other) in accumulated.iter_mut().zip(u) {
                *byte ^= other;
            }
        }
        derived.extend_from_slice(&accumulated);
        wipe(&mut u);
        wipe(&mut accumulated);
        block += 1;
    }
    let result = Secret::from_slice(&derived[..output_byte_count]);
    wipe(&mut derived);
    Ok(result)
}

fn nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

#[cfg(unix)]
mod material_layout {
    //! The bounded DevEco material layout, so that no unrelated file can ever
    //! become key-derivation input.
    const MAX_MATERIAL_FILE: u64 = 4_096;
    use crate::SigningError;
    use arkdeck_platform::Secret;
    use std::os::unix::fs::MetadataExt;
    use std::path::{Path, PathBuf};

    fn unsafe_directory() -> SigningError {
        SigningError::invalid("DevEco signing material directory is absent or unsafe")
    }

    fn incomplete() -> SigningError {
        SigningError::invalid("DevEco signing material layout is incomplete")
    }

    /// Swift `validateDirectory`: a real directory, not writable by group or
    /// others.
    fn validate_directory(directory: &Path) -> Result<(), SigningError> {
        let metadata = std::fs::symlink_metadata(directory).map_err(|_| unsafe_directory())?;
        if !metadata.file_type().is_dir() || metadata.mode() & 0o022 != 0 {
            return Err(unsafe_directory());
        }
        Ok(())
    }

    /// The entries of a validated directory except `.DS_Store`, in name order.
    fn entries(directory: &Path) -> Result<Vec<PathBuf>, SigningError> {
        validate_directory(directory)?;
        let mut entries = std::fs::read_dir(directory)
            .map_err(|_| unsafe_directory())?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| unsafe_directory())?;
        entries.retain(|path| path.file_name().is_some_and(|name| name != ".DS_Store"));
        entries.sort_by(|left, right| left.file_name().cmp(&right.file_name()));
        Ok(entries)
    }

    /// Swift `readFDParts`: three slots, each holding one 16-byte file.
    pub(super) fn fd_parts(directory: &Path) -> Result<Vec<Secret>, SigningError> {
        let slots = entries(directory)?;
        if slots.len() != 3 {
            return Err(incomplete());
        }
        slots.iter().map(|slot| only_file(slot, Some(16))).collect()
    }

    /// Swift `onlyFile(in:expectedByteCount:)`: exactly one bounded regular
    /// file in a validated directory.
    pub(super) fn only_file(
        directory: &Path,
        expected: Option<u64>,
    ) -> Result<Secret, SigningError> {
        let files = entries(directory)?;
        if files.len() != 1 {
            return Err(incomplete());
        }
        let path = &files[0];
        let metadata = std::fs::symlink_metadata(path).map_err(|_| unsafe_file())?;
        if !metadata.file_type().is_file()
            || metadata.len() == 0
            || metadata.len() > MAX_MATERIAL_FILE
            || expected.is_some_and(|expected| metadata.len() != expected)
        {
            return Err(unsafe_file());
        }
        let bytes = Secret::new(std::fs::read(path).map_err(|_| unsafe_file())?);
        if bytes.len() as u64 != metadata.len() {
            return Err(SigningError::drift("DevEco signing material"));
        }
        Ok(bytes)
    }

    fn unsafe_file() -> SigningError {
        SigningError::invalid("DevEco signing material file is absent or unsafe")
    }
}

#[cfg(not(unix))]
mod material_layout {
    //! DevEco's material layout on this platform has not been measured yet;
    //! nothing is read until it is.
    use crate::SigningError;
    use arkdeck_platform::Secret;
    use std::path::Path;

    pub(super) fn fd_parts(_: &Path) -> Result<Vec<Secret>, SigningError> {
        Err(SigningError::invalid(
            "DevEco signing material is not supported on this platform",
        ))
    }

    pub(super) fn only_file(_: &Path, _: Option<u64>) -> Result<Secret, SigningError> {
        Err(SigningError::invalid(
            "DevEco signing material is not supported on this platform",
        ))
    }
}
