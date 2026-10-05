//! The Swift signing oracle's stand-in signer (`hap-signer.sh`), as a test
//! binary of this crate (`harness = false`): the signed test daemon's
//! fixture signing preset names it as its Java launcher
//! (`tests/spawning/workspace_sign_leaf.rs`), and the daemon runs it as
//! `java.exe -jar <jar> <command> …` on a pseudo console. Run any other way
//! (as `cargo test` runs a test binary) it has nothing to check and exits.
//! It never reaches DevEco's `hap-sign-tool`, a keystore or a password that
//! unlocks anything.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
#[path = "../../arkdeck-hoststore/tests/sign_stand_in/mod.rs"]
mod sign_stand_in;

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).is_some_and(|flag| flag == "-jar") {
        // The recording's `/tmp/…` names are read below the directory the
        // copy runs from.
        let root = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        sign_stand_in::stand_in(&arguments[1..], &root);
    }
}
