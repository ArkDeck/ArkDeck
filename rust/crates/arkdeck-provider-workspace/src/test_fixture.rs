//! Scratch trees of the maintenance unit tests on macOS and Windows: a
//! private directory under `/private/tmp` (macOS) or the account's local
//! application data (Windows — never the temporary directory, which on some
//! hosts grants other principals write through inheritance), and private
//! fixture files in it. No real signing material is involved.
#[cfg(target_os = "macos")]
use std::fs;
use std::path::{Path, PathBuf};

fn token() -> String {
    format!(
        "{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    )
}

/// A new private directory `arkdeck-<label>-<random>`, as the host spells
/// it before any link is resolved (`/private/tmp/…` on macOS).
#[cfg(target_os = "macos")]
pub(crate) fn directory(label: &str) -> PathBuf {
    use std::os::unix::fs::DirBuilderExt;
    let path = PathBuf::from(format!("/private/tmp/arkdeck-{label}-{}", token()));
    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
    path
}

/// A new private directory `arkdeck-test-<label>-<random>` in its plain
/// canonical `X:\…` spelling.
#[cfg(windows)]
pub(crate) fn directory(label: &str) -> PathBuf {
    let base = arkdeck_platform::application_support_directory()
        .unwrap()
        .canonicalize()
        .unwrap();
    let base = base.to_str().unwrap();
    let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base))
        .join(format!("arkdeck-test-{label}-{}", token()));
    arkdeck_platform::create_private_directory(&path).unwrap();
    arkdeck_platform::host_resolved_path(&path).unwrap()
}

/// `path` and every missing ancestor, private.
pub(crate) fn directories(path: &Path) {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .unwrap();
    }
    #[cfg(windows)]
    {
        if !path.exists() {
            directories(path.parent().unwrap());
            arkdeck_platform::create_private_directory(path).unwrap();
        }
    }
}

/// A private fixture file (`0600`, or `0700` when `executable`; on Windows
/// the private descriptor, whose owner grant includes execute).
pub(crate) fn file(path: &Path, bytes: &[u8], executable: bool) {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::write(path, bytes).unwrap();
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if executable { 0o700 } else { 0o600 }),
        )
        .unwrap();
    }
    #[cfg(windows)]
    {
        let _ = executable;
        let mut file = arkdeck_platform::create_private_file(path).unwrap();
        std::io::Write::write_all(&mut file, bytes).unwrap();
    }
}

/// The file name of an executable called `stem` on this host.
pub(crate) fn executable(stem: &str) -> String {
    if cfg!(windows) {
        format!("{stem}.exe")
    } else {
        stem.to_owned()
    }
}
