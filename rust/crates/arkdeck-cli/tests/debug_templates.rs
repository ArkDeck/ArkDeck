use arkdeck_contract::{CATALOG_DIGEST, DEBUG_TEMPLATES};
use serde_json::{Value, json};
use std::process::Command;

#[test]
fn actual_cli_discloses_the_complete_provider_vocabulary_without_a_runtime() {
    for machine in [false, true] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
        command
            .args(["debug", "template", "list"])
            .env("ARKDECK_ENDPOINT", "deliberately-invalid-relative-endpoint")
            .env("ARKDECK_DAEMON_PATH", "deliberately-missing-daemon");
        if machine {
            command.args(["--output", "json"]);
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let answer: Value = serde_json::from_slice(&output.stdout).unwrap();
        let result = if machine {
            assert_eq!(answer["ok"], true);
            assert_eq!(answer["command"], "debug.template.list");
            &answer["result"]
        } else {
            &answer
        };
        assert_eq!(result["catalogDigest"], CATALOG_DIGEST);
        assert_eq!(result["schemaVersion"], "arkdeck.debug-template-list/1");
        assert_eq!(result["operation"], "debug.template@1");
        assert_eq!(result["effect"], "readOnly");
        let rows = result["templates"].as_array().unwrap();
        assert_eq!(rows.len(), 4);
        for (row, source) in rows.iter().zip(DEBUG_TEMPLATES) {
            assert_eq!(
                *row,
                json!({"templateId":source.id, "title":source.title,
                "remoteCommand":source.command,"outputByteBudget":source.output_byte_budget,
                "effect":"readOnly","inputs":{"templateId":source.id}})
            );
        }
    }
}
