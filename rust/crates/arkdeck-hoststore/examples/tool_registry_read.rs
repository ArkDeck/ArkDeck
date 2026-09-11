//! Local test adapter for comparing the actual Swift/Rust bootstrap owners.
#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    let mut args = std::env::args_os().skip(1);
    let root = args.next().ok_or("missing isolated registry root")?;
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    let rows =
        arkdeck_hoststore::ToolRegistryStore::open_existing(std::path::Path::new(&root))?.list()?;
    let bytes = arkdeck_contract::canonical_json(&serde_json::Value::Array(rows))?;
    std::io::stdout().write_all(&bytes)?;
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("macOS owner comparison only");
    std::process::exit(2);
}
