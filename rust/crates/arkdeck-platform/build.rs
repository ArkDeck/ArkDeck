use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=src/macos_control.c");
    println!("cargo:rerun-if-changed=src/macos_procscan.c");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let arch = if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let mut objects = Vec::new();
    for source in ["macos_control", "macos_procscan"] {
        let object = output.join(format!("{source}.o"));
        assert!(
            Command::new("xcrun")
                .args([
                    "clang",
                    "-arch",
                    arch,
                    "-mmacosx-version-min=14.0",
                    "-fblocks",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-c",
                    &format!("src/{source}.c"),
                    "-o"
                ])
                .arg(&object)
                .status()
                .expect("clang")
                .success()
        );
        objects.push(object);
    }
    assert!(
        Command::new("ar")
            .arg("crs")
            .arg(output.join("libarkdeck_macos_control.a"))
            .args(&objects)
            .status()
            .expect("ar")
            .success()
    );
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=arkdeck_macos_control");
}
