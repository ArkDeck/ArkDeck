//! The Windows daemon's HDC tuple gate (TASK-XPA-005, CHG-2026-078): the one
//! place a Windows development root admits an HDC, decided before its state
//! root is opened or anything is started.
//!
//! A Windows daemon composes an HDC only for an executable whose bytes'
//! SHA-256 is a registered entry of `OPENHARMONY-HDC-WINDOWS-PROBES`
//! ([`arkdeck_provider_hdc::WINDOWS_HDC_TUPLES`]), and only as its managed
//! server: unlike the macOS owner, it runs no unregistered fixture HDC, and a
//! macOS tool's hash registers nothing here. While the registry is a draft
//! the table is empty, and every development HDC is refused here, naming the
//! digest the registry would have to hold.
//!
//! What it admits, `windows_lifecycle` starts as the root's managed server
//! (`managed_hdc::ManagedHdc`) on the endpoint Swift's selector picks, which
//! must be the tuple's own.
use arkdeck_provider_hdc::{EndpointSelection, WindowsHdcTuple, tuple_in};
use std::ffi::OsString;
use std::path::PathBuf;

/// The development HDC this gate admits: its path, the digest of the bytes
/// it was admitted by, the registered tuple that digest selects, and the
/// endpoint its managed server starts on (Swift's selection, the tuple's).
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AdmittedHdc {
    pub(crate) path: PathBuf,
    pub(crate) sha256: String,
    pub(crate) tuple: &'static WindowsHdcTuple,
    pub(crate) selection: EndpointSelection,
}

/// The development HDC `variable` names, admitted against `table`; `None`
/// when none is named, or the refusal. Only an explicit absolute path to an
/// executable whose digest `table` registers, started as the managed server
/// on the tuple's own endpoint, is admitted.
pub(crate) fn admit(
    variable: &dyn Fn(&str) -> Option<OsString>,
    table: &'static [WindowsHdcTuple],
) -> Result<Option<AdmittedHdc>, String> {
    let managed = match variable("ARKDECK_DEVELOPMENT_HDC_SERVER") {
        None => false,
        Some(mode) if mode == "managed" => true,
        Some(_) => return Err("ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed".into()),
    };
    let path = match variable("ARKDECK_DEVELOPMENT_HDC_PATH") {
        None if managed => {
            return Err(
                "a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH".into(),
            );
        }
        None => return Ok(None),
        Some(path) => PathBuf::from(path),
    };
    if !path.is_absolute() {
        return Err("ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path".into());
    }
    if !managed {
        return Err(
            "the Windows development root runs no fixture HDC: a registered HDC is composed only \
             as its managed server (ARKDECK_DEVELOPMENT_HDC_SERVER=managed); nothing was started"
                .into(),
        );
    }
    let bytes = std::fs::read(&path).map_err(|error| {
        format!(
            "the development HDC {} cannot be read: {error}; nothing was started",
            path.display()
        )
    })?;
    let sha256 = arkdeck_contract::sha256_hex(&bytes);
    let Some(tuple) = tuple_in(table, &sha256) else {
        return Err(format!(
            "the development HDC {} (SHA-256 {sha256}) is not a registered Windows HDC: \
             OPENHARMONY-HDC-WINDOWS-PROBES (CHG-2026-078) registers no tuple with that digest; \
             nothing was started",
            path.display()
        ));
    };
    // Swift's selector over the inherited port, as the macOS isolated owner
    // selects its managed server's endpoint; it must pick the tuple's.
    let inherited = variable(arkdeck_provider_hdc::SERVER_PORT_VARIABLE);
    let selection = match &inherited {
        Some(port) => port
            .to_str()
            .and_then(|port| EndpointSelection::select(Some(port)).ok()),
        None => EndpointSelection::select(None).ok(),
    }
    .filter(|selection| selection.endpoint == tuple.endpoint);
    let Some(selection) = selection else {
        return Err(match inherited {
            Some(_) => format!(
                "{} names another endpoint than the registered HDC {}'s {}; nothing was started",
                arkdeck_provider_hdc::SERVER_PORT_VARIABLE,
                tuple.candidate,
                tuple.endpoint
            ),
            None => format!(
                "the registered HDC {}'s endpoint {} is not the default one: {} must name its \
                 port; nothing was started",
                tuple.candidate,
                tuple.endpoint,
                arkdeck_provider_hdc::SERVER_PORT_VARIABLE
            ),
        });
    };
    Ok(Some(AdmittedHdc {
        path,
        sha256,
        tuple,
        selection,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_provider_hdc::WINDOWS_HDC_TUPLES;
    use std::net::{Ipv4Addr, SocketAddrV4};

    /// The bytes of the test's stand-in executable, which is never run.
    const BYTES: &[u8] = b"a Windows HDC stand-in; never executed";
    /// Another executable's digest.
    const OTHER: &str = "1111111111111111111111111111111111111111111111111111111111111111";

    fn entry(sha256: &'static str) -> WindowsHdcTuple {
        WindowsHdcTuple {
            candidate: "c1",
            executable_sha256: sha256,
            reported_version: "3.2.0x",
            version_stdout: b"Ver: 3.2.0x\r\n",
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
        }
    }

    struct Tool(PathBuf);
    impl Tool {
        fn new() -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let path = std::env::temp_dir().join(format!("ad-hdcgate-{nonce:016x}.exe"));
            std::fs::write(&path, BYTES).unwrap();
            Self(path)
        }
    }
    impl Drop for Tool {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn admitted(
        environment: &[(&str, &str)],
        table: &'static [WindowsHdcTuple],
    ) -> Result<Option<AdmittedHdc>, String> {
        admit(
            &|name| {
                environment
                    .iter()
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| OsString::from(value))
            },
            table,
        )
    }

    fn leak(tuple: WindowsHdcTuple) -> &'static [WindowsHdcTuple] {
        Box::leak(Box::new([tuple]))
    }

    /// Exactly the entry whose digest the executable's bytes have enables the
    /// composition; the real (draft) registry enables none.
    #[test]
    fn only_the_registry_entry_of_the_executable_s_digest_admits_it() {
        let tool = Tool::new();
        let path = tool.0.to_str().unwrap();
        let sha256: &'static str = Box::leak(arkdeck_contract::sha256_hex(BYTES).into_boxed_str());
        let registered = leak(entry(sha256));
        let environment = [
            ("ARKDECK_DEVELOPMENT_HDC_PATH", path),
            ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ];
        assert_eq!(
            admitted(&environment, registered),
            Ok(Some(AdmittedHdc {
                path: tool.0.clone(),
                sha256: sha256.to_owned(),
                tuple: &registered[0],
                selection: EndpointSelection {
                    endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
                    source: "default",
                },
            }))
        );
        // Another entry, a macOS tool's digest, and today's registry: refused.
        for table in [
            leak(entry(OTHER)),
            leak(entry(
                "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83",
            )),
            WINDOWS_HDC_TUPLES,
        ] {
            assert_eq!(
                admitted(&environment, table),
                Err(format!(
                    "the development HDC {path} (SHA-256 {sha256}) is not a registered Windows \
                     HDC: OPENHARMONY-HDC-WINDOWS-PROBES (CHG-2026-078) registers no tuple with \
                     that digest; nothing was started"
                ))
            );
        }
    }

    #[test]
    fn every_other_input_is_refused_before_the_executable_is_read() {
        let fixture = "the Windows development root runs no fixture HDC: a registered HDC is \
                       composed only as its managed server (ARKDECK_DEVELOPMENT_HDC_SERVER=\
                       managed); nothing was started";
        // A path that does not exist: none of these reads it.
        let missing = r"C:\ArkDeck-absent\hdc.exe";
        for (environment, refusal) in [
            (
                vec![
                    ("ARKDECK_DEVELOPMENT_HDC_PATH", missing),
                    ("ARKDECK_DEVELOPMENT_HDC_SERVER", "external"),
                ],
                "ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed",
            ),
            (
                vec![("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")],
                "a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH",
            ),
            (
                vec![
                    ("ARKDECK_DEVELOPMENT_HDC_PATH", r"tools\hdc.exe"),
                    ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ],
                "ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path",
            ),
            (vec![("ARKDECK_DEVELOPMENT_HDC_PATH", missing)], fixture),
        ] {
            assert_eq!(
                admitted(&environment, WINDOWS_HDC_TUPLES),
                Err(refusal.to_owned()),
                "{environment:?}"
            );
        }
        assert_eq!(admitted(&[], WINDOWS_HDC_TUPLES), Ok(None));
    }

    #[test]
    fn the_managed_server_runs_on_the_registered_endpoint_only() {
        let tool = Tool::new();
        let path = tool.0.to_str().unwrap();
        let sha256: &'static str = Box::leak(arkdeck_contract::sha256_hex(BYTES).into_boxed_str());
        let registered = leak(entry(sha256));
        let base = [
            ("ARKDECK_DEVELOPMENT_HDC_PATH", path),
            ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ];
        let with_port = |port| {
            let mut environment = base.to_vec();
            environment.push(("OHOS_HDC_SERVER_PORT", port));
            admitted(&environment, registered)
        };
        assert!(matches!(
            with_port("8710"),
            Ok(Some(AdmittedHdc {
                selection: EndpointSelection {
                    source: "inheritedEnvironment",
                    ..
                },
                ..
            }))
        ));
        for port in ["18710", "0", "port"] {
            assert_eq!(
                with_port(port),
                Err(
                    "OHOS_HDC_SERVER_PORT names another endpoint than the registered HDC c1's \
                     127.0.0.1:8710; nothing was started"
                        .to_owned()
                )
            );
        }
        // A tuple on another endpoint than Swift's default is started there
        // only when the inherited port names it.
        let elsewhere = leak(WindowsHdcTuple {
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 18710),
            ..entry(sha256)
        });
        assert_eq!(
            admitted(&base, elsewhere),
            Err(
                "the registered HDC c1's endpoint 127.0.0.1:18710 is not the default one: \
                 OHOS_HDC_SERVER_PORT must name its port; nothing was started"
                    .to_owned()
            )
        );
        let mut environment = base.to_vec();
        environment.push(("OHOS_HDC_SERVER_PORT", "18710"));
        assert_eq!(
            admitted(&environment, elsewhere).map(|hdc| hdc.map(|hdc| hdc.selection)),
            Ok(Some(EndpointSelection {
                endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 18710),
                source: "inheritedEnvironment",
            }))
        );
    }
}
