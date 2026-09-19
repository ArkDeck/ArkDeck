//! The isolated owner's development USB relations: what the Target
//! observation owner reads in place of the ArkForge lane's reader, named by
//! `ARKDECK_DEVELOPMENT_USB_RELATIONS` and allowed only beside the
//! development HDC's fixture. A harness rewrites the file for each exchange:
//! `{"relations": [...]}`, or with `"after": {"reads": n, "relations": [...]}`
//! the relations it changes to once the file has been read `n` times since
//! it last changed, as an oracle times a replug by its reads. A missing file
//! reads no relations.
use arkdeck_provider_hdc::{UsbRelation, UsbRelations};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Mutex;

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
}
