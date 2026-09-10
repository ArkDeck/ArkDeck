use std::{env, fs, path::PathBuf};
fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let path = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR")).join("facade-info.plist");
    // Product release metadata matches the same-release Swift helper and App.
    let version = env::var("CARGO_PKG_VERSION").expect("package version");
    fs::write(&path, format!(r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.arkdeck.agentd.facade</string><key>CFBundleShortVersionString</key><string>{version}</string><key>CFBundleVersion</key><string>1</string></dict></plist>"#)).expect("transport release metadata");
    println!(
        "cargo:rustc-link-arg=-Wl,-sectcreate,__TEXT,__info_plist,{}",
        path.display()
    );
}
