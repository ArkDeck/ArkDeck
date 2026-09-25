//! The isolated owner's startup admission (TASK-XPA-014): every value of its
//! development inputs and every combination of them, decided from the
//! environment alone before anything is opened or started. A start this
//! refuses has launched nothing: no managed HDC server, no `arkforged`, and
//! no HDC client.
//!
//! The environment cannot say whether the development HDC is a registered
//! one; its bytes do. [`Admission::admit_registration`] decides what that
//! answer allows, still before the managed server is launched, as the named
//! code-sign helper's bytes are verified before it (`main.rs`). Past the
//! launch only the Runtime's own state can end a start — its Job recovery,
//! above all — and the managed server is stopped when one does
//! (`managed_hdc::Launched`).
//!
//! Standalone and facade starts never get here: `main.rs` refuses every
//! development input of theirs before anything else.
use crate::{code_sign_helper, development_mutation, development_usb};
use arkdeck_provider_hdc::{EndpointSelection, SERVER_PORT_VARIABLE};
use std::ffi::OsString;
use std::path::PathBuf;

/// The development HDC the environment names.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AdmittedHdc {
    /// `ARKDECK_DEVELOPMENT_HDC_PATH`: an explicit absolute path.
    pub(crate) path: PathBuf,
    /// With `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, the endpoint the owner
    /// starts it on as its managed server, as Swift's selector picks it from
    /// the inherited `OHOS_HDC_SERVER_PORT`.
    pub(crate) managed: Option<EndpointSelection>,
}

/// The development inputs of an isolated owner, admitted.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Admission {
    pub(crate) hdc: Option<AdmittedHdc>,
    /// `ARKDECK_DEVELOPMENT_USB_RELATIONS`: an explicit absolute path.
    pub(crate) relations: Option<PathBuf>,
    /// `development_usb::REGISTERED_HDC_ACKNOWLEDGMENT`, acknowledged.
    pub(crate) relations_acknowledged: bool,
    /// `code_sign_helper::DEVELOPMENT_HELPER`: an explicit absolute path.
    pub(crate) code_sign_helper: Option<PathBuf>,
    /// `development_mutation::ACKNOWLEDGMENT`, acknowledged in the one
    /// composition it names.
    pub(crate) mutation_authority: bool,
}

impl Admission {
    /// Whether the owner starts its development HDC as its managed server.
    pub(crate) fn managed(&self) -> bool {
        self.hdc.as_ref().is_some_and(|hdc| hdc.managed.is_some())
    }

    /// What the development HDC's registration allows, once its bytes have
    /// said whether it is a registered HDC and before anything is started.
    /// On its own it must be a fixture: a registered HDC would address a real
    /// server and device, which needs the existing-server identity proof,
    /// and starting it as the managed server is that proof. Relations beside
    /// a registered HDC need that server and the acknowledgment
    /// (`development_usb::admit`), which names no other composition.
    pub(crate) fn admit_registration(&self, registered: bool) -> Result<(), String> {
        let Some(hdc) = &self.hdc else {
            return Ok(());
        };
        let managed = hdc.managed.is_some();
        if registered && !managed {
            return Err(
                "the isolated Rust development owner runs a fixture HDC only; a registered HDC \
                 needs the existing-server identity proof"
                    .into(),
            );
        }
        development_usb::admit(
            registered,
            managed,
            self.relations.is_some(),
            self.relations_acknowledged,
        )
        .map_err(str::to_owned)
    }
}

/// The isolated owner's development inputs as `variable` names them, or the
/// first refusal, in the order the owner reported them before any of them
/// moved ahead of the managed server's launch; the refusals only the HDC's
/// registration decides follow them all ([`Admission::admit_registration`]).
pub(crate) fn admit(variable: &dyn Fn(&str) -> Option<OsString>) -> Result<Admission, String> {
    let managed = match variable("ARKDECK_DEVELOPMENT_HDC_SERVER") {
        None => false,
        Some(mode) if mode == "managed" => true,
        Some(_) => return Err("ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed".into()),
    };
    let relations = variable("ARKDECK_DEVELOPMENT_USB_RELATIONS");
    let relations_acknowledged = development_usb::acknowledged(
        variable(development_usb::REGISTERED_HDC_ACKNOWLEDGMENT).as_deref(),
    )?;
    let hdc = match variable("ARKDECK_DEVELOPMENT_HDC_PATH") {
        None if managed => {
            return Err(
                "a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH".into(),
            );
        }
        None => {
            development_usb::admit(false, false, relations.is_some(), relations_acknowledged)?;
            None
        }
        Some(path) => {
            let path = PathBuf::from(path);
            if !path.is_absolute() {
                return Err(
                    "ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path".into(),
                );
            }
            let managed = if managed {
                Some(EndpointSelection::select(
                    variable(SERVER_PORT_VARIABLE)
                        .map(|port| port.to_string_lossy().into_owned())
                        .as_deref(),
                )?)
            } else {
                None
            };
            Some(AdmittedHdc { path, managed })
        }
    };
    let relations = match relations.map(PathBuf::from) {
        Some(path) if !path.is_absolute() => {
            return Err(
                "ARKDECK_DEVELOPMENT_USB_RELATIONS must be an explicit absolute path".into(),
            );
        }
        relations => relations,
    };
    let code_sign_helper =
        code_sign_helper::development(variable(code_sign_helper::DEVELOPMENT_HELPER).as_deref())?;
    // Acknowledged, and with the development HDC started as the managed
    // server, the owner proves a device mutation's state continuity against
    // its own Job state (`development_mutation`).
    let mutation_authority = development_mutation::admit(
        true,
        managed,
        development_mutation::acknowledged(
            variable(development_mutation::ACKNOWLEDGMENT).as_deref(),
        )?,
    )?;
    Ok(Admission {
        hdc,
        relations,
        relations_acknowledged,
        code_sign_helper,
        mutation_authority,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

    fn admitted(environment: &[(&str, &str)]) -> Result<Admission, String> {
        admit(&|name| {
            environment
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| OsString::from(value))
        })
    }

    const HDC: (&str, &str) = ("ARKDECK_DEVELOPMENT_HDC_PATH", "/tools/hdc");
    const MANAGED: (&str, &str) = ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed");
    const PORT: (&str, &str) = ("OHOS_HDC_SERVER_PORT", "18710");
    const RELATIONS: (&str, &str) = ("ARKDECK_DEVELOPMENT_USB_RELATIONS", "/usb.json");
    const RELATIONS_ACKNOWLEDGED: (&str, &str) = (
        "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC",
        "acknowledged",
    );
    const HELPER: (&str, &str) = ("ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER", "/helper");
    const MUTATION: (&str, &str) = ("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "acknowledged");

    fn managed_on(port: u16) -> Option<EndpointSelection> {
        Some(EndpointSelection {
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, port),
            source: "inheritedEnvironment",
        })
    }

    #[test]
    fn every_value_and_combination_the_environment_decides_is_refused_before_anything_starts() {
        let relations_only = "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC is \
                              acknowledged only with development USB relations and a \
                              registered HDC started as the managed server";
        let mutation_only = "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY is acknowledged only with \
                             an isolated development state root whose development HDC the \
                             owner starts as its managed server";
        for (environment, refusal) in [
            (
                vec![HDC, ("ARKDECK_DEVELOPMENT_HDC_SERVER", "external")],
                "ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed",
            ),
            (
                vec![
                    HDC,
                    (
                        "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC",
                        "yes",
                    ),
                ],
                "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC accepts only acknowledged",
            ),
            (
                vec![MANAGED],
                "a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH",
            ),
            (vec![RELATIONS_ACKNOWLEDGED], relations_only),
            (
                vec![("ARKDECK_DEVELOPMENT_HDC_PATH", "tools/hdc")],
                "ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path",
            ),
            (
                vec![HDC, MANAGED, ("OHOS_HDC_SERVER_PORT", "65536")],
                "OHOS_HDC_SERVER_PORT is not a port in 1...65535",
            ),
            (
                vec![
                    HDC,
                    MANAGED,
                    PORT,
                    ("ARKDECK_DEVELOPMENT_USB_RELATIONS", "usb.json"),
                ],
                "ARKDECK_DEVELOPMENT_USB_RELATIONS must be an explicit absolute path",
            ),
            (
                vec![
                    HDC,
                    MANAGED,
                    PORT,
                    (
                        "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER",
                        "arkdeck-code-sign-enable",
                    ),
                ],
                "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER must be an explicit absolute path",
            ),
            (
                vec![
                    HDC,
                    MANAGED,
                    PORT,
                    ("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "yes"),
                ],
                "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY accepts only acknowledged",
            ),
            (vec![HDC, MUTATION], mutation_only),
            (vec![MUTATION], mutation_only),
        ] {
            assert_eq!(
                admitted(&environment),
                Err(refusal.to_owned()),
                "{environment:?}"
            );
        }
    }

    #[test]
    fn the_first_refusal_is_the_one_the_owner_reported_first() {
        // A bad server mode before a bad port, relations or authority.
        assert_eq!(
            admitted(&[
                HDC,
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "external"),
                ("OHOS_HDC_SERVER_PORT", "0"),
                ("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "yes"),
            ]),
            Err("ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed".to_owned())
        );
        // The port the managed server needs before what only follows it.
        assert_eq!(
            admitted(&[
                HDC,
                MANAGED,
                ("OHOS_HDC_SERVER_PORT", "0"),
                ("ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY", "yes"),
            ]),
            Err("OHOS_HDC_SERVER_PORT is not a port in 1...65535".to_owned())
        );
    }

    #[test]
    fn what_the_environment_admits_is_what_the_owner_composes() {
        assert_eq!(
            admitted(&[]),
            Ok(Admission {
                hdc: None,
                relations: None,
                relations_acknowledged: false,
                code_sign_helper: None,
                mutation_authority: false,
            })
        );
        // A fixture the owner does not start, with its relations and a helper.
        let fixture = admitted(&[HDC, RELATIONS, HELPER]).unwrap();
        assert_eq!(
            fixture,
            Admission {
                hdc: Some(AdmittedHdc {
                    path: "/tools/hdc".into(),
                    managed: None,
                }),
                relations: Some("/usb.json".into()),
                relations_acknowledged: false,
                code_sign_helper: Some("/helper".into()),
                mutation_authority: false,
            }
        );
        assert!(!fixture.managed());
        // The managed server on the inherited port, or Swift's default.
        let managed = admitted(&[HDC, MANAGED, PORT, MUTATION]).unwrap();
        assert_eq!(
            managed.hdc,
            Some(AdmittedHdc {
                path: "/tools/hdc".into(),
                managed: managed_on(18710),
            })
        );
        assert!(managed.managed());
        assert!(managed.mutation_authority);
        assert_eq!(
            admitted(&[HDC, MANAGED]).unwrap().hdc.unwrap().managed,
            Some(EndpointSelection {
                endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
                source: "default",
            })
        );
        // Beside a fixture the owner does not start, no port is read.
        assert_eq!(
            admitted(&[HDC, ("OHOS_HDC_SERVER_PORT", "0")])
                .unwrap()
                .hdc
                .unwrap()
                .managed,
            None
        );
    }

    #[test]
    fn a_registered_hdc_is_admitted_only_as_the_managed_server() {
        let fixture_only = "the isolated Rust development owner runs a fixture HDC only; a \
                            registered HDC needs the existing-server identity proof";
        let relations_only = "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC is \
                              acknowledged only with development USB relations and a \
                              registered HDC started as the managed server";
        let beside_fixture = "development USB relations are configured only beside a fixture HDC";
        // (environment, registered) and the answer.
        for (environment, registered, answer) in [
            (vec![HDC], false, Ok(())),
            (vec![HDC], true, Err(fixture_only)),
            (vec![HDC, RELATIONS], false, Ok(())),
            (vec![HDC, MANAGED, PORT], true, Ok(())),
            (
                vec![HDC, MANAGED, PORT, RELATIONS],
                true,
                Err(beside_fixture),
            ),
            (
                vec![HDC, MANAGED, PORT, RELATIONS, RELATIONS_ACKNOWLEDGED],
                true,
                Ok(()),
            ),
            (
                vec![HDC, MANAGED, PORT, RELATIONS, RELATIONS_ACKNOWLEDGED],
                false,
                Err(relations_only),
            ),
            (
                vec![HDC, MANAGED, PORT, RELATIONS_ACKNOWLEDGED],
                true,
                Err(relations_only),
            ),
            (
                vec![HDC, RELATIONS, RELATIONS_ACKNOWLEDGED],
                true,
                Err(fixture_only),
            ),
            (vec![], true, Ok(())),
        ] {
            assert_eq!(
                admitted(&environment)
                    .unwrap()
                    .admit_registration(registered),
                answer.map_err(str::to_owned),
                "{environment:?} registered {registered}"
            );
        }
    }
}
