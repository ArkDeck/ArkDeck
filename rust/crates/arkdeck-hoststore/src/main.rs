//! Offline differential adapter. Input/output are pipes, never Runtime paths.
use std::io::{self, Read, Write};

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 1
        || ![
            "history-filter",
            "bundle-registry",
            "tool-registry",
            "display-names",
        ]
        .contains(&args[0].as_str())
    {
        eprintln!("usage: arkdeck-hoststore <store-kind> < snapshot.json");
        std::process::exit(64);
    }
    let mut input = Vec::new();
    if io::stdin()
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut input)
        .is_err()
    {
        std::process::exit(74);
    }
    let result = match args[0].as_str() {
        "history-filter" => arkdeck_hoststore::decode_history(&input),
        "bundle-registry" => arkdeck_hoststore::decode_bundles(&input),
        "tool-registry" => arkdeck_hoststore::decode_tools(&input),
        "display-names" => arkdeck_hoststore::decode_display_names(&input),
        _ => unreachable!(),
    };
    let decoded = match result {
        Ok(value) => value,
        Err(_) => {
            // Do not print document contents, paths, names or filters.
            eprintln!("host-store snapshot refused");
            std::process::exit(65);
        }
    };
    let value = serde_json::json!({
        "document": String::from_utf8(decoded.document).expect("JSON is UTF-8"),
        "projection": decoded.projection,
    });
    let mut bytes = arkdeck_contract::canonical_json(&value).expect("string-valued counters");
    bytes.push(b'\n');
    if io::stdout().write_all(&bytes).is_err() {
        std::process::exit(74);
    }
}
