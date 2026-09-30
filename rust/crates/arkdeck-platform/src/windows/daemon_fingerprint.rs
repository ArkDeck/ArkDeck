//! The installed daemon's code identity that a signing receipt is bound to
//! (TASK-XPA-011): the Windows counterpart of the macOS
//! `trusted_daemon_fingerprint`.
//!
//! macOS binds a receipt to `SHA-256(domain ‖ kSecCodeInfoUnique ‖
//! SHA-256(bytes))` of a daemon that satisfies the ArkDeck code requirement.
//! Windows binds it to `SHA-256(domain ‖ SHA-256(signer leaf) ‖
//! SHA-256(bytes))` of a daemon image `WinVerifyTrust` accepts, with the same
//! policy the pipe client uses: the leaf is the first signer's certificate in
//! the chain `WinVerifyTrust` verified, so a different signer or a different
//! byte of the image is a different identity. Which signer is ArkDeck's (the
//! development certificate pin or the Artifact Signing publisher identity,
//! maintainer ruling 17) is the maintenance client's check before it records
//! the identity ([`crate::verify_daemon_image`]); the daemon itself only has
//! to prove it is still the image that was recorded.
//!
//! The image must be a canonical local path (the spelling on disk, no link
//! or junction), a regular `.exe` the caller may execute, owned by the user
//! or a trusted principal, and writable by nobody else — the Windows reading
//! of the macOS "a private, executable regular file of this user" for an
//! xcopy daemon that may live under `Program Files`. It is held (file and
//! namespace) from the measurement to the signature check, and hashed from
//! that handle.
use super::identity::trusted_signer_chain;
use super::pinned_file::measure_host_file;
use super::{lock_namespace, reject_reparse_file};
use sha2::{Digest, Sha256};
use std::io;
use std::path::Path;

const FINGERPRINT_DOMAIN: &[u8] = b"arkdeck-keychain-trusted-application-windows-v1\0";
const MAX_DAEMON_BYTES: u64 = 512 * 1024 * 1024;

/// The fingerprint of the installed daemon at `executable`. An absent or
/// unsafe file is `PermissionDenied`; a signature `WinVerifyTrust` does not
/// accept, or an image that changed while it was checked, is `Other`.
pub fn trusted_daemon_fingerprint(executable: &Path) -> io::Result<String> {
    let unsafe_file = || {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "installed arkdeck-agentd is absent or unsafe",
        )
    };
    // The plain spelling only, as the receipt and the client name it: the
    // verbatim `\\?\` form is refused rather than normalised.
    if executable
        .to_str()
        .is_none_or(|text| text.starts_with(r"\\"))
    {
        return Err(unsafe_file());
    }
    let measured = measure_host_file(executable, MAX_DAEMON_BYTES).map_err(|_| unsafe_file())?;
    if !measured.executable || !measured.trusted_write_only || measured.links != 1 {
        return Err(unsafe_file());
    }
    let _namespace = lock_namespace(executable).map_err(|_| unsafe_file())?;
    let file = crate::process::open_locked_file(executable).map_err(|_| unsafe_file())?;
    reject_reparse_file(&file).map_err(|_| unsafe_file())?;
    let chain = trusted_signer_chain(&file, executable)
        .map_err(|_| io::Error::other("arkdeck-agentd Authenticode signature is not trusted"))?;
    let leaf = chain
        .first()
        .ok_or_else(|| io::Error::other("arkdeck-agentd Authenticode signature is not trusted"))?;
    let length = file.metadata()?.len();
    let image = crate::process::hash_file(&file, length)?;
    if length != measured.identity.size || image != hex(&measured.sha256) {
        return Err(io::Error::other(
            "arkdeck-agentd changed while it was checked",
        ));
    }
    let mut fingerprint = Sha256::new();
    fingerprint.update(FINGERPRINT_DOMAIN);
    fingerprint.update(Sha256::digest(leaf));
    fingerprint.update(measured.sha256);
    Ok(hex(&fingerprint.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
