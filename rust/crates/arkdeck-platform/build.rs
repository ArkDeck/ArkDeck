use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=src/macos_control.c");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let object = output.join("macos_control.o");
    let arch = if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
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
                "src/macos_control.c",
                "-o"
            ])
            .arg(&object)
            .status()
            .expect("clang")
            .success()
    );
    assert!(
        Command::new("ar")
            .arg("crs")
            .arg(output.join("libarkdeck_macos_control.a"))
            .arg(object)
            .status()
            .expect("ar")
            .success()
    );
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=arkdeck_macos_control");
}
