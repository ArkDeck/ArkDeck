//! The native code signature of a registered DevEco tool on Windows
//! (TASK-XPA-011, gate G12): the Authenticode counterpart of the macOS
//! `inspect_native_code_signature` / `inspect_deveco_publisher_signature`
//! (`host_signature.rs`), with the same answer type.
//!
//! macOS answers `verified`, `adHoc` or `unsigned` with the code signing
//! identifier, the team identifier and the code directory's SHA-256. Windows
//! has no ad-hoc signature and no team; it answers:
//!
//! * `verified`: `WinVerifyTrust` accepts the image with the pipe client's
//!   policy (generic Authenticode, whole-chain revocation from cache only);
//!   `identifier` is the signer's name (its leaf's single subject `O=`, else
//!   its `CN=`) and `code_directory_sha256` the SHA-256 of that leaf
//!   certificate, which changes when the publisher re-signs;
//! * `unsigned`: the image carries no signature (`TRUST_E_NOSIGNATURE`);
//! * anything else — a signature that does not verify, an untrusted chain,
//!   a revoked or expired certificate — is refused (`PermissionDenied`),
//!   never reported as unsigned.
//!
//! The file is opened without following a reparse point and held while it
//! is checked.
use super::identity::authenticode_chain;
use super::publisher::{chain_publisher, signer_name};
use super::reject_reparse_file;
use sha2::{Digest, Sha256};
use std::io;
use std::path::Path;
use windows_sys::Win32::Foundation::TRUST_E_NOSIGNATURE;

/// What a native signature check established (the macOS type's shape).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeCodeSignature {
    pub signature: &'static str,
    pub identifier: Option<String>,
    pub team_identifier: Option<String>,
    pub code_directory_sha256: Option<String>,
}

/// The publisher DevEco Studio's Windows launcher must be signed by, as the
/// macOS check pins the DevEco bundle's identifier and team.
pub const DEVECO_PUBLISHER: &str = "Huawei Technologies Co., Ltd.";

fn refused(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

/// The Authenticode signature of the image at `path`.
pub fn inspect_native_code_signature(path: &Path) -> io::Result<NativeCodeSignature> {
    let file = crate::process::open_locked_file(path)?;
    reject_reparse_file(&file)?;
    match authenticode_chain(&file, path)? {
        Ok(chain) => {
            let leaf = chain
                .first()
                .ok_or_else(|| refused("the signer chain is empty"))?;
            Ok(NativeCodeSignature {
                signature: "verified",
                identifier: Some(signer_name(leaf)?),
                team_identifier: None,
                code_directory_sha256: Some(format!("{:x}", Sha256::digest(leaf))),
            })
        }
        Err(status) if status == TRUST_E_NOSIGNATURE => Ok(NativeCodeSignature {
            signature: "unsigned",
            identifier: None,
            team_identifier: None,
            code_directory_sha256: None,
        }),
        Err(_) => Err(refused(
            "the image's Authenticode signature does not verify under the trust policy",
        )),
    }
}

/// The verified chain of the image at `path`, held while it is checked.
fn verified_chain(path: &Path) -> io::Result<Vec<Vec<u8>>> {
    let file = crate::process::open_locked_file(path)?;
    reject_reparse_file(&file)?;
    match authenticode_chain(&file, path)? {
        Ok(chain) if !chain.is_empty() => Ok(chain),
        _ => Err(refused(
            "the image carries no Authenticode signature that verifies under the trust policy",
        )),
    }
}

/// Whether the image at `path` is signed as `reference` is (maintainer
/// ruling 17's two pins): both verify under the trust policy, and either
/// their leaf certificates are the same (the development signer) or both are
/// Artifact Signing chains of one publisher (the same subject `O=` and
/// certificate-profile EKU; the leaf itself renews daily). The answer is the
/// signer's name. Anything else is refused (`PermissionDenied`), including an
/// unsigned `reference`: nothing can be pinned to it.
pub fn same_signer(path: &Path, reference: &Path) -> io::Result<String> {
    let expected = verified_chain(reference)?;
    let chain = verified_chain(path)?;
    let same_leaf = chain.first() == expected.first();
    let same_publisher = matches!(
        (chain_publisher(&chain), chain_publisher(&expected)),
        (Some(a), Some(b)) if a == b
    );
    if !same_leaf && !same_publisher {
        return Err(refused(
            "the image is not signed by this Runtime's signer or publisher",
        ));
    }
    signer_name(&chain[0])
}

/// The DevEco Studio installation at `root`: its Windows launcher
/// `bin\devecostudio64.exe` must be `verified` and signed by
/// [`DEVECO_PUBLISHER`]. Anything else is refused.
pub fn inspect_deveco_publisher_signature(root: &Path) -> io::Result<NativeCodeSignature> {
    inspect_publisher(root, DEVECO_PUBLISHER)
}

/// [`inspect_deveco_publisher_signature`] with another expected publisher, for
/// fixtures signed by a host-trusted development certificate.
#[doc(hidden)]
pub fn inspect_publisher(root: &Path, publisher: &str) -> io::Result<NativeCodeSignature> {
    let trust = inspect_native_code_signature(&root.join("bin").join("devecostudio64.exe"))?;
    if trust.signature != "verified" || trust.identifier.as_deref() != Some(publisher) {
        return Err(refused(
            "the DevEco launcher is not signed by the DevEco publisher",
        ));
    }
    Ok(trust)
}
