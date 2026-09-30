//! Publisher identity of a production-signed xcopy daemon (maintainer ruling
//! 17 of 2026-09-30, TASK-XPA-002).
//!
//! Azure Artifact Signing renews its leaf certificates daily and each is valid
//! for 72 hours, so a pin on one certificate's SHA-256 would break with every
//! signing. The xcopy daemon is pinned instead by who signed it: the Authenticode
//! chain that `WinVerifyTrust` already accepted must end at the Microsoft root
//! that Artifact Signing Public Trust chains to, and the leaf's subject
//! organisation (`O=`) and its certificate-profile identity EKU
//! (`1.3.6.1.4.1.311.97.<profile>`) must both equal the configured values.
//!
//! [`chain_matches`] is a pure function over the DER certificates of a chain
//! that `WinVerifyTrust` has verified; it performs no trust decision of its own.

use crate::{denied, invalid};
use sha2::{Digest, Sha256};
use std::io;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Cryptography::*;

/// SHA-256 of the DER of "Microsoft Identity Verification Root Certificate
/// Authority 2020", the root that Artifact Signing Public Trust certificates are
/// issued from. SHA-1 thumbprint `f40042e2e5f7e8ef8189fed15519aece42c3bfa2` as
/// published in the Microsoft PKI Services repository
/// (<https://www.microsoft.com/pkiops/docs/repository.htm>); valid until 2045.
///
/// Update path: when Microsoft announces a new Artifact Signing root, download
/// it from that repository, check its SHA-1 against the repository's
/// thumbprint, replace `fixtures/microsoft-identity-verification-root-2020.crt`
/// beside this file (the test `the_root_pin_is_the_official_certificate` ties
/// the constant to it), and release a new client.
pub(crate) const ARTIFACT_SIGNING_ROOT_SHA256: &str =
    "5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270";

/// The Artifact Signing identity EKU arc; a certificate-profile identity is
/// this prefix followed by more arcs unique to the profile.
const IDENTITY_EKU_PREFIX: &str = "1.3.6.1.4.1.311.97.";
/// Present in every Artifact Signing Public Trust certificate, so it names no
/// publisher and is refused as a configured identity.
const PUBLIC_TRUST_MARKER_EKU: &str = "1.3.6.1.4.1.311.97.1.0";
const CODE_SIGNING_EKU: &str = "1.3.6.1.5.5.7.3.3";

/// The configured publisher of a production-signed xcopy daemon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PublisherIdentity {
    organization: String,
    eku: String,
}

impl PublisherIdentity {
    /// Both inputs or neither: `Ok(None)` when neither is configured, an error
    /// when only one is, or when a value is not a usable identity. A partial or
    /// malformed configuration refuses the connection outright, whatever else
    /// is configured.
    pub(crate) fn from_config(
        organization: Option<&str>,
        eku: Option<&str>,
    ) -> io::Result<Option<Self>> {
        let (organization, eku) = match (organization, eku) {
            (None, None) => return Ok(None),
            (Some(organization), Some(eku)) => (organization, eku),
            _ => {
                return Err(denied(
                    "partial daemon publisher identity: both the organisation and the \
                     Artifact Signing identity EKU are required; zero frames sent",
                ));
            }
        };
        if organization.is_empty() || organization.trim() != organization {
            return Err(invalid(
                "the daemon publisher organisation must be the exact non-empty subject O= value",
            ));
        }
        let suffix = eku.strip_prefix(IDENTITY_EKU_PREFIX).unwrap_or("");
        if suffix.is_empty()
            || eku == PUBLIC_TRUST_MARKER_EKU
            || !suffix.split('.').all(|arc| {
                !arc.is_empty()
                    && arc.bytes().all(|b| b.is_ascii_digit())
                    && (arc == "0" || !arc.starts_with('0'))
            })
        {
            return Err(invalid(
                "the daemon publisher EKU must be an Artifact Signing certificate-profile \
                 identity OID (1.3.6.1.4.1.311.97.<profile>)",
            ));
        }
        Ok(Some(Self {
            organization: organization.to_owned(),
            eku: eku.to_owned(),
        }))
    }
}

/// Whether a chain `WinVerifyTrust` verified (leaf first, root last) is the
/// configured publisher's: the root's DER SHA-256 is `root_sha256`, and the
/// leaf has exactly one subject `O=` equal to the configured organisation, the
/// code-signing EKU and the configured identity EKU.
pub(crate) fn chain_matches(
    chain: &[Vec<u8>],
    root_sha256: &str,
    publisher: &PublisherIdentity,
) -> bool {
    let [leaf, .., root] = chain else {
        return false;
    };
    if format!("{:x}", Sha256::digest(root)) != root_sha256 {
        return false;
    }
    let Ok(certificate) = Certificate::decode(leaf) else {
        return false;
    };
    let organizations = certificate.subject_organizations().unwrap_or_default();
    let usages = certificate.enhanced_key_usages().unwrap_or_default();
    matches!(organizations.as_slice(), [only] if *only == publisher.organization)
        && usages.iter().any(|usage| usage == CODE_SIGNING_EKU)
        && usages.contains(&publisher.eku)
}

/// The name a signer is known by in a tool registration (TASK-XPA-011): the
/// leaf's single subject `O=`, or, with no `O=`, its single `CN=`. Anything
/// else is not one name and is an error.
pub(crate) fn signer_name(der: &[u8]) -> io::Result<String> {
    let certificate = Certificate::decode(der)?;
    let organizations = certificate.subject_organizations()?;
    match organizations.as_slice() {
        [only] => Ok(only.clone()),
        [] => match certificate.subject_values(b"2.5.4.3")?.as_slice() {
            [only] => Ok(only.clone()),
            _ => Err(invalid("the signer certificate names no single subject")),
        },
        _ => Err(invalid(
            "the signer certificate names more than one organisation",
        )),
    }
}

struct Certificate(*const CERT_CONTEXT);

impl Drop for Certificate {
    fn drop(&mut self) {
        // SAFETY: exclusively owned context from CertCreateCertificateContext.
        unsafe {
            CertFreeCertificateContext(self.0);
        }
    }
}

struct Decoded(*mut std::ffi::c_void);

impl Drop for Decoded {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: allocated by CryptDecodeObjectEx with CRYPT_DECODE_ALLOC_FLAG.
            unsafe {
                LocalFree(self.0);
            }
        }
    }
}

impl Certificate {
    fn decode(der: &[u8]) -> io::Result<Self> {
        let length = u32::try_from(der.len()).map_err(|_| invalid("certificate too large"))?;
        // SAFETY: the DER slice outlives the call; the context copies it.
        let context = unsafe {
            CertCreateCertificateContext(
                X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                der.as_ptr(),
                length,
            )
        };
        if context.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(context))
    }

    fn subject_organizations(&self) -> io::Result<Vec<String>> {
        self.subject_values(b"2.5.4.10")
    }

    /// Every value of the subject attribute `oid` (dotted, as ASCII bytes).
    fn subject_values(&self, oid: &[u8]) -> io::Result<Vec<String>> {
        // SAFETY: live context; its CERT_INFO and subject blob belong to it.
        let subject = unsafe { (*(*self.0).pCertInfo).Subject };
        let mut decoded = Decoded(null_mut());
        let mut length = 0u32;
        // SAFETY: the subject blob is live; the API allocates the output,
        // which `decoded` releases.
        super::bool_result(unsafe {
            CryptDecodeObjectEx(
                X509_ASN_ENCODING,
                X509_NAME,
                subject.pbData,
                subject.cbData,
                CRYPT_DECODE_ALLOC_FLAG,
                std::ptr::null(),
                std::ptr::from_mut(&mut decoded.0).cast(),
                &mut length,
            )
        })?;
        let mut organizations = Vec::new();
        // SAFETY: a successful decode yields a CERT_NAME_INFO whose arrays
        // have the stated counts and live in the same allocation.
        unsafe {
            let name = &*decoded.0.cast::<CERT_NAME_INFO>();
            for rdn in slice(name.rgRDN, name.cRDN) {
                for attribute in slice(rdn.rgRDNAttr, rdn.cRDNAttr) {
                    if attribute.pszObjId.is_null()
                        || std::ffi::CStr::from_ptr(attribute.pszObjId.cast()).to_bytes() != oid
                    {
                        continue;
                    }
                    let size =
                        CertRDNValueToStrW(attribute.dwValueType, &attribute.Value, null_mut(), 0);
                    let mut text = vec![0u16; size.max(1) as usize];
                    let written = CertRDNValueToStrW(
                        attribute.dwValueType,
                        &attribute.Value,
                        text.as_mut_ptr(),
                        text.len() as u32,
                    );
                    let end = (written as usize).saturating_sub(1).min(text.len());
                    organizations.push(
                        String::from_utf16(&text[..end])
                            .map_err(|_| invalid("certificate subject is not valid UTF-16"))?,
                    );
                }
            }
        }
        Ok(organizations)
    }

    /// The EKUs of the leaf's own extension (not merged with properties).
    fn enhanced_key_usages(&self) -> io::Result<Vec<String>> {
        let mut length = 0u32;
        // SAFETY: documented size query on a live context.
        super::bool_result(unsafe {
            CertGetEnhancedKeyUsage(
                self.0,
                CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG,
                null_mut(),
                &mut length,
            )
        })?;
        let mut storage = vec![0usize; (length as usize).div_ceil(size_of::<usize>())];
        // SAFETY: pointer-aligned storage of at least `length` bytes.
        super::bool_result(unsafe {
            CertGetEnhancedKeyUsage(
                self.0,
                CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG,
                storage.as_mut_ptr().cast(),
                &mut length,
            )
        })?;
        // SAFETY: a successful call wrote a CTL_USAGE whose identifiers are
        // NUL-terminated strings inside `storage`.
        unsafe {
            let usage = &*storage.as_ptr().cast::<CTL_USAGE>();
            slice(usage.rgpszUsageIdentifier, usage.cUsageIdentifier)
                .iter()
                .map(|identifier| {
                    std::ffi::CStr::from_ptr(identifier.cast())
                        .to_str()
                        .map(str::to_owned)
                        .map_err(|_| invalid("certificate EKU is not ASCII"))
                })
                .collect()
        }
    }
}

/// # Safety
/// `pointer` must address `count` initialised elements, or `count` be zero.
unsafe fn slice<'a, T>(pointer: *const T, count: u32) -> &'a [T] {
    if count == 0 || pointer.is_null() {
        &[]
    } else {
        // SAFETY: guaranteed by the caller.
        unsafe { std::slice::from_raw_parts(pointer, count as usize) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::windows::wide;
    use windows_sys::Win32::Foundation::SYSTEMTIME;

    const OFFICIAL_ROOT: &[u8] =
        include_bytes!("fixtures/microsoft-identity-verification-root-2020.crt");
    const PROFILE_EKU: &str = "1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583";
    const OTHER_PROFILE_EKU: &str = "1.3.6.1.4.1.311.97.123456789.1.2.3";

    /// An ephemeral CNG key: never persisted, so nothing reaches a key or
    /// certificate store.
    struct EphemeralKey(NCRYPT_PROV_HANDLE, NCRYPT_KEY_HANDLE);
    impl Drop for EphemeralKey {
        fn drop(&mut self) {
            // SAFETY: handles exclusively owned by this guard.
            unsafe {
                NCryptFreeObject(self.1);
                NCryptFreeObject(self.0);
            }
        }
    }

    /// A self-signed in-memory certificate with `subject` and `usages`. The
    /// matcher runs after `WinVerifyTrust`, so only the fields matter here.
    fn certificate(subject: &str, usages: &[&str]) -> Vec<u8> {
        // SAFETY: every handle, buffer and context below is owned by this
        // function and released before it returns.
        unsafe {
            let mut key = EphemeralKey(0, 0);
            assert_eq!(
                NCryptOpenStorageProvider(&mut key.0, MS_KEY_STORAGE_PROVIDER, 0),
                0
            );
            assert_eq!(
                NCryptCreatePersistedKey(
                    key.0,
                    &mut key.1,
                    BCRYPT_ECDSA_P256_ALGORITHM,
                    std::ptr::null(),
                    0,
                    0
                ),
                0
            );
            assert_eq!(NCryptFinalizeKey(key.1, 0), 0);
            let subject = wide(std::ffi::OsStr::new(subject)).unwrap();
            let mut length = 0u32;
            super::super::bool_result(CertStrToNameW(
                X509_ASN_ENCODING,
                subject.as_ptr(),
                CERT_X500_NAME_STR,
                std::ptr::null(),
                null_mut(),
                &mut length,
                null_mut(),
            ))
            .unwrap();
            let mut name = vec![0u8; length as usize];
            super::super::bool_result(CertStrToNameW(
                X509_ASN_ENCODING,
                subject.as_ptr(),
                CERT_X500_NAME_STR,
                std::ptr::null(),
                name.as_mut_ptr(),
                &mut length,
                null_mut(),
            ))
            .unwrap();
            let name_blob = CRYPT_INTEGER_BLOB {
                cbData: length,
                pbData: name.as_mut_ptr(),
            };
            let identifiers: Vec<std::ffi::CString> = usages
                .iter()
                .map(|usage| std::ffi::CString::new(*usage).unwrap())
                .collect();
            let mut pointers: Vec<windows_sys::core::PSTR> = identifiers
                .iter()
                .map(|identifier| identifier.as_ptr().cast_mut().cast())
                .collect();
            let usage = CTL_USAGE {
                cUsageIdentifier: pointers.len() as u32,
                rgpszUsageIdentifier: pointers.as_mut_ptr(),
            };
            let mut encoded = Decoded(null_mut());
            let mut encoded_length = 0u32;
            let mut extensions = Vec::new();
            if !usages.is_empty() {
                super::super::bool_result(CryptEncodeObjectEx(
                    X509_ASN_ENCODING,
                    X509_ENHANCED_KEY_USAGE,
                    std::ptr::from_ref(&usage).cast(),
                    CRYPT_ENCODE_ALLOC_FLAG,
                    std::ptr::null(),
                    std::ptr::from_mut(&mut encoded.0).cast(),
                    &mut encoded_length,
                ))
                .unwrap();
                extensions.push(CERT_EXTENSION {
                    pszObjId: szOID_ENHANCED_KEY_USAGE.cast_mut(),
                    fCritical: 0,
                    Value: CRYPT_INTEGER_BLOB {
                        cbData: encoded_length,
                        pbData: encoded.0.cast(),
                    },
                });
            }
            let extensions = CERT_EXTENSIONS {
                cExtension: extensions.len() as u32,
                rgExtension: extensions.as_mut_ptr(),
            };
            let algorithm = CRYPT_ALGORITHM_IDENTIFIER {
                pszObjId: szOID_ECDSA_SHA256.cast_mut(),
                Parameters: CRYPT_INTEGER_BLOB::default(),
            };
            let context = CertCreateSelfSignCertificate(
                key.1,
                &name_blob,
                CERT_CREATE_SELFSIGN_NO_KEY_INFO,
                std::ptr::null(),
                &algorithm,
                std::ptr::null::<SYSTEMTIME>(),
                std::ptr::null::<SYSTEMTIME>(),
                &extensions,
            );
            assert!(!context.is_null(), "{}", io::Error::last_os_error());
            let owned = Certificate(context);
            std::slice::from_raw_parts((*owned.0).pbCertEncoded, (*owned.0).cbCertEncoded as usize)
                .to_vec()
        }
    }

    fn publisher() -> PublisherIdentity {
        PublisherIdentity::from_config(Some("Contoso Ltd"), Some(PROFILE_EKU))
            .unwrap()
            .unwrap()
    }

    fn leaf(subject: &str, usages: &[&str]) -> Vec<Vec<u8>> {
        vec![certificate(subject, usages), OFFICIAL_ROOT.to_vec()]
    }

    #[test]
    fn the_root_pin_is_the_official_certificate() {
        let sha1 = {
            use windows_sys::Win32::Security::Cryptography::CryptHashCertificate2;
            let mut out = [0u8; 20];
            let mut length = out.len() as u32;
            // SAFETY: input slice and output buffer live across the call.
            unsafe {
                assert_ne!(
                    CryptHashCertificate2(
                        windows_sys::core::w!("SHA1"),
                        0,
                        std::ptr::null(),
                        OFFICIAL_ROOT.as_ptr(),
                        OFFICIAL_ROOT.len() as u32,
                        out.as_mut_ptr(),
                        &mut length,
                    ),
                    0
                );
            }
            out.iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>()
        };
        assert_eq!(sha1, "f40042e2e5f7e8ef8189fed15519aece42c3bfa2");
        assert_eq!(
            format!("{:x}", Sha256::digest(OFFICIAL_ROOT)),
            ARTIFACT_SIGNING_ROOT_SHA256
        );
    }

    #[test]
    fn the_configured_publisher_matches() {
        let chain = leaf(
            "CN=Contoso Ltd, O=Contoso Ltd, L=Redmond, C=US",
            &[CODE_SIGNING_EKU, PUBLIC_TRUST_MARKER_EKU, PROFILE_EKU],
        );
        assert!(chain_matches(
            &chain,
            ARTIFACT_SIGNING_ROOT_SHA256,
            &publisher()
        ));
        // Intermediates between leaf and root do not change the answer.
        let with_intermediate = vec![
            chain[0].clone(),
            certificate("CN=Intermediate", &[]),
            chain[1].clone(),
        ];
        assert!(chain_matches(
            &with_intermediate,
            ARTIFACT_SIGNING_ROOT_SHA256,
            &publisher()
        ));
    }

    #[test]
    fn a_different_organisation_is_refused() {
        let expected = publisher();
        for subject in [
            "CN=Contoso Ltd, O=Fabrikam Inc, C=US",
            "CN=Contoso Ltd, O=contoso ltd, C=US",
            "CN=Contoso Ltd, O=Contoso Ltd., C=US",
            "CN=Contoso Ltd, C=US",
            // Two O= values are ambiguous, even when one matches.
            "CN=Contoso Ltd, O=Contoso Ltd, O=Fabrikam Inc, C=US",
        ] {
            let chain = leaf(subject, &[CODE_SIGNING_EKU, PROFILE_EKU]);
            assert!(
                !chain_matches(&chain, ARTIFACT_SIGNING_ROOT_SHA256, &expected),
                "{subject}"
            );
        }
    }

    #[test]
    fn a_missing_or_different_identity_eku_is_refused() {
        let expected = publisher();
        let subject = "CN=Contoso Ltd, O=Contoso Ltd, C=US";
        for usages in [
            &[][..],
            &[CODE_SIGNING_EKU][..],
            &[CODE_SIGNING_EKU, PUBLIC_TRUST_MARKER_EKU][..],
            &[CODE_SIGNING_EKU, OTHER_PROFILE_EKU][..],
            // The profile EKU without code signing is not a code-signing leaf.
            &[PROFILE_EKU][..],
        ] {
            let chain = leaf(subject, usages);
            assert!(
                !chain_matches(&chain, ARTIFACT_SIGNING_ROOT_SHA256, &expected),
                "{usages:?}"
            );
        }
    }

    #[test]
    fn a_different_root_is_refused() {
        let expected = publisher();
        let leaf = certificate(
            "CN=Contoso Ltd, O=Contoso Ltd, C=US",
            &[CODE_SIGNING_EKU, PROFILE_EKU],
        );
        let other_root = certificate("CN=Contoso Test Root, O=Contoso Ltd", &[]);
        assert!(!chain_matches(
            &[leaf.clone(), other_root],
            ARTIFACT_SIGNING_ROOT_SHA256,
            &expected
        ));
        // A leaf alone (its own root) and an empty chain never match.
        assert!(!chain_matches(
            std::slice::from_ref(&leaf),
            ARTIFACT_SIGNING_ROOT_SHA256,
            &expected
        ));
        assert!(!chain_matches(&[], ARTIFACT_SIGNING_ROOT_SHA256, &expected));
        // The official root in the leaf position is not a chain ending there.
        assert!(!chain_matches(
            &[OFFICIAL_ROOT.to_vec()],
            ARTIFACT_SIGNING_ROOT_SHA256,
            &expected
        ));
    }

    #[test]
    fn partial_or_malformed_configuration_is_refused() {
        assert_eq!(PublisherIdentity::from_config(None, None).unwrap(), None);
        for (organization, eku) in [
            (Some("Contoso Ltd"), None),
            (None, Some(PROFILE_EKU)),
            (Some(""), Some(PROFILE_EKU)),
            (Some(" Contoso Ltd"), Some(PROFILE_EKU)),
            (Some("Contoso Ltd"), Some("")),
            (Some("Contoso Ltd"), Some(CODE_SIGNING_EKU)),
            (Some("Contoso Ltd"), Some(PUBLIC_TRUST_MARKER_EKU)),
            (Some("Contoso Ltd"), Some("1.3.6.1.4.1.311.97.")),
            (Some("Contoso Ltd"), Some("1.3.6.1.4.1.311.97.1..2")),
            (Some("Contoso Ltd"), Some("1.3.6.1.4.1.311.97.01.2")),
            (Some("Contoso Ltd"), Some("1.3.6.1.4.1.311.97.1.x")),
        ] {
            assert!(
                PublisherIdentity::from_config(organization, eku).is_err(),
                "{organization:?} {eku:?}"
            );
        }
    }
}
