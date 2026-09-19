//! The isolated owner's development USB relations: what the Target
//! observation owner reads in place of the ArkForge lane's reader, named by
//! `ARKDECK_DEVELOPMENT_USB_RELATIONS`. A harness rewrites the file for each
//! exchange: `{"relations": [...]}`, or with
//! `"after": {"reads": n, "relations": [...]}` the relations it changes to
//! once the file has been read `n` times since it last changed, as an oracle
//! times a replug by its reads. A missing file reads no relations.
//!
//! The file is allowed beside the development HDC's fixture. Beside a
//! registered HDC it would be a trusted fact about a real device that no
//! physical relation proved, so it is refused there unless the isolated owner
//! starts that HDC as its managed server and the caller acknowledges the file
//! as its relation source ([`REGISTERED_HDC_ACKNOWLEDGMENT`]). That opt-in is
//! the maintainer's decision of 2026-09-19 (option A of the GJ-1 preflight's
//! second and third blockers): what the owner then proves about the real
//! device is development-root evidence, never `REAL_DEVICE_PASS`.
use arkdeck_provider_hdc::{UsbRelation, UsbRelations};
use serde_json::Value;
use std::ffi::OsStr;
use std::path::PathBuf;
use std::sync::Mutex;

/// Names the caller's acknowledgment that its development USB relations
/// stand in for the trusted reader beside a registered HDC; its one value is
/// `acknowledged`.
pub(crate) const REGISTERED_HDC_ACKNOWLEDGMENT: &str =
    "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC";

/// Without the acknowledgment, as before it existed.
const FIXTURE_ONLY: &str = "development USB relations are configured only beside a fixture HDC";

/// The acknowledgment names exactly one composition.
const ACKNOWLEDGED_ONLY: &str = "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC is \
                                 acknowledged only with development USB relations and a \
                                 registered HDC started as the managed server";

/// Whether the acknowledgment's value, if one is set, acknowledges.
pub(crate) fn acknowledged(value: Option<&OsStr>) -> Result<bool, String> {
    match value {
        None => Ok(false),
        Some(value) if value == "acknowledged" => Ok(true),
        Some(_) => Err(format!(
            "{REGISTERED_HDC_ACKNOWLEDGMENT} accepts only acknowledged"
        )),
    }
}

/// Whether the isolated owner may read development USB relations beside its
/// development HDC: `registered` when the HDC's digest is a registered one,
/// `managed` when the owner starts it as its managed server, `relations` when
/// a relation file is named. Beside a fixture nothing changes; beside a
/// registered HDC the file needs the acknowledgment and the managed server,
/// and the acknowledgment is refused in every other composition, so that it
/// never stands unused in a configuration.
pub(crate) fn admit(
    registered: bool,
    managed: bool,
    relations: bool,
    acknowledged: bool,
) -> Result<(), &'static str> {
    if acknowledged {
        return if registered && managed && relations {
            Ok(())
        } else {
            Err(ACKNOWLEDGED_ONLY)
        };
    }
    if registered && relations {
        return Err(FIXTURE_ONLY);
    }
    Ok(())
}

pub(crate) struct DevelopmentUsbRelations {
    path: PathBuf,
    /// The bytes last read, and how many reads they have had.
    reads: Mutex<(Vec<u8>, u64)>,
}

impl DevelopmentUsbRelations {
    /// The source `ARKDECK_DEVELOPMENT_USB_RELATIONS` names, if it names
    /// one: an explicit absolute path.
    pub(crate) fn from_environment() -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(path) = std::env::var_os("ARKDECK_DEVELOPMENT_USB_RELATIONS") else {
            return Ok(None);
        };
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err(
                "ARKDECK_DEVELOPMENT_USB_RELATIONS must be an explicit absolute path".into(),
            );
        }
        Ok(Some(Self::at(path)))
    }

    pub(crate) fn at(path: PathBuf) -> Self {
        Self {
            path,
            reads: Mutex::new((Vec::new(), 0)),
        }
    }
}

impl UsbRelations for DevelopmentUsbRelations {
    fn relations(&self) -> Result<Vec<UsbRelation>, String> {
        let bytes = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(format!("development USB relations are unreadable: {error}")),
        };
        let read = {
            let mut reads = self
                .reads
                .lock()
                .map_err(|_| "development USB relations are unavailable".to_owned())?;
            if reads.0 != bytes {
                *reads = (bytes.clone(), 0);
            }
            reads.1 += 1;
            reads.1
        };
        let document: Value = serde_json::from_slice(&bytes)
            .map_err(|_| "development USB relations are not JSON".to_owned())?;
        let relations = match document.get("after") {
            Some(after) if after["reads"].as_u64().is_some_and(|count| read > count) => {
                &after["relations"]
            }
            _ => &document["relations"],
        };
        relations
            .as_array()
            .ok_or_else(|| "development USB relations name no relations".to_owned())?
            .iter()
            .map(|relation| {
                UsbRelation::from_value(relation)
                    .ok_or_else(|| "a development USB relation is malformed".to_owned())
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn relation(attachment: u64) -> Value {
        json!({"serial": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "location": "100",
            "attachmentId": attachment, "vendorId": 8711, "productId": 20480})
    }

    fn attachments(source: &DevelopmentUsbRelations) -> Vec<u64> {
        source
            .relations()
            .unwrap()
            .iter()
            .map(|relation| relation.attachment_id)
            .collect()
    }

    #[test]
    fn relations_change_after_the_reads_the_file_names_and_restart_with_it() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("development-usb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir(&root).unwrap();
        let path = root.join("usb-relations.json");
        let source = DevelopmentUsbRelations::at(path.clone());
        assert!(attachments(&source).is_empty(), "a missing file reads none");
        std::fs::write(
            &path,
            json!({"relations": [relation(30)], "after": {"reads": 2, "relations": [relation(31)]}})
                .to_string(),
        )
        .unwrap();
        assert_eq!(attachments(&source), [30]);
        assert_eq!(attachments(&source), [30]);
        assert_eq!(attachments(&source), [31]);
        std::fs::write(&path, json!({"relations": [relation(32)]}).to_string()).unwrap();
        assert_eq!(attachments(&source), [32]);
        std::fs::write(&path, b"not json").unwrap();
        assert!(source.relations().is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn relations_beside_a_registered_hdc_need_the_acknowledgment_and_the_managed_server() {
        // (registered, managed, relations, acknowledged) and the answer.
        for (composition, expected) in [
            // Beside the fixture, with or without its managed server, as before.
            ((false, false, true, false), Ok(())),
            ((false, true, true, false), Ok(())),
            ((false, false, false, false), Ok(())),
            // A registered HDC started as the managed server reads none...
            ((true, true, false, false), Ok(())),
            // ...and without the acknowledgment its relations stay refused.
            ((true, true, true, false), Err(FIXTURE_ONLY)),
            // The one composition the acknowledgment names.
            ((true, true, true, true), Ok(())),
            // Every other composition refuses the acknowledgment: no file,
            // a fixture, a registered HDC the owner did not start, nothing.
            ((true, true, false, true), Err(ACKNOWLEDGED_ONLY)),
            ((false, true, true, true), Err(ACKNOWLEDGED_ONLY)),
            ((false, false, true, true), Err(ACKNOWLEDGED_ONLY)),
            ((true, false, true, true), Err(ACKNOWLEDGED_ONLY)),
            ((false, false, false, true), Err(ACKNOWLEDGED_ONLY)),
        ] {
            let (registered, managed, relations, acknowledged) = composition;
            assert_eq!(
                admit(registered, managed, relations, acknowledged),
                expected,
                "{composition:?}"
            );
        }
    }

    #[test]
    fn the_acknowledgment_has_one_value() {
        assert_eq!(acknowledged(None), Ok(false));
        assert_eq!(acknowledged(Some(OsStr::new("acknowledged"))), Ok(true));
        for value in ["", "yes", "true", "1", "Acknowledged", "acknowledged "] {
            assert_eq!(
                acknowledged(Some(OsStr::new(value))),
                Err(
                    "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC accepts only \
                     acknowledged"
                        .to_owned()
                ),
                "{value:?}"
            );
        }
    }
}
