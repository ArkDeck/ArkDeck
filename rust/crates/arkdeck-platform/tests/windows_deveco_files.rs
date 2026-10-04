//! The DevEco child-role reader and the pinned-file measurement on Windows
//! (TASK-XPA-011, G15), against fixture trees in the Windows DevEco layout.
//! The manifests are synthetic documents in the recorded key set, never
//! copies of an installation. One ignored probe reads this host's own
//! installation read-only and asserts its shape only.
#![cfg(windows)]

use arkdeck_platform::{
    DevEcoRole, DevEcoRoot, HostFileMeasureError, application_support_directory,
    host_resolved_path, measure_host_file, random_bytes,
};
use sha2::{Digest, Sha256};
use std::ffi::OsStr;
use std::io::ErrorKind;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};

const PRODUCT: &str = r#"{"name":"DevEco Studio","version":"9.8.7.6","buildNumber":"DS-999.1.2","productCode":"DS","productVendor":"Huawei","launch":[{"os":"Windows","arch":"amd64","launcherPath":"bin/devecostudio64.exe"}]}"#;
const SDK: &str = r#"{"meta":{"version":"1.0.0"},"data":{"apiVersion":"99","platformVersion":"9.9.9","version":"9.9.9.1"}}"#;

/// A scratch base under the account's local application data directory,
/// whose chain from the drive root is owned and written by the user and the
/// system alone (the temporary directory may grant other principals write,
/// which the reader rightly refuses).
struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> Self {
        let base = application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let path = base.join(format!(
            "arkdeck-test-{label}-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn deveco(&self, name: &str) -> PathBuf {
        deveco(&self.0, name)
    }
}

/// A DevEco root in the Windows layout below `base`.
fn deveco(base: &Path, name: &str) -> PathBuf {
    {
        let root = base.join(name);
        for directory in [
            "bin",
            "sdk/default/openharmony",
            "tools/node",
            "tools/hvigor/bin",
        ] {
            std::fs::create_dir_all(root.join(directory)).unwrap();
        }
        std::fs::write(root.join("bin/devecostudio64.exe"), b"MZ launcher").unwrap();
        std::fs::write(root.join("product-info.json"), PRODUCT).unwrap();
        std::fs::write(root.join("sdk/default/sdk-pkg.json"), SDK).unwrap();
        std::fs::write(root.join("tools/node/node.exe"), b"MZ node").unwrap();
        std::fs::create_dir_all(root.join("jbr/bin")).unwrap();
        std::fs::write(root.join("jbr/bin/java.exe"), b"MZ java").unwrap();
        std::fs::write(root.join("tools/hvigor/bin/hvigorw.js"), b"// hvigor").unwrap();
        root
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A path without its verbatim `\\?\` prefix, as a caller spells it.
fn plain(path: &Path) -> PathBuf {
    let text = path.to_str().unwrap();
    PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(text))
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain([0]).collect()
}

/// Rewrite an entry's DACL through SDDL: `edit` receives the current SDDL.
fn edit_dacl(path: &Path, edit: impl FnOnce(String) -> String) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::*;
    use windows_sys::Win32::Security::*;
    use windows_sys::Win32::Storage::FileSystem::*;
    let file = std::fs::OpenOptions::new()
        .access_mode(READ_CONTROL | WRITE_DAC)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .unwrap();
    let mut descriptor = std::ptr::null_mut();
    // SAFETY: live handle; the descriptor is freed below.
    let status = unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut descriptor,
        )
    };
    assert_eq!(status, 0);
    let mut text = std::ptr::null_mut();
    // SAFETY: a valid descriptor; the string is freed below.
    assert_ne!(
        unsafe {
            ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor,
                SDDL_REVISION_1,
                DACL_SECURITY_INFORMATION,
                &mut text,
                std::ptr::null_mut(),
            )
        },
        0
    );
    let mut length = 0;
    // SAFETY: a NUL-terminated string from the call above.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    // SAFETY: `length` characters precede the terminator.
    let sddl = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).unwrap();
    // SAFETY: allocations returned by the two calls above.
    unsafe {
        LocalFree(text.cast());
        LocalFree(descriptor);
    }
    let sddl = wide(OsStr::new(&edit(sddl)));
    let mut replacement = std::ptr::null_mut();
    // SAFETY: NUL-terminated SDDL; freed below.
    assert_ne!(
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut replacement,
                std::ptr::null_mut(),
            )
        },
        0
    );
    let (mut present, mut dacl, mut defaulted) = (0, std::ptr::null_mut(), 0);
    // SAFETY: a valid descriptor from the call above.
    assert_ne!(
        unsafe { GetSecurityDescriptorDacl(replacement, &mut present, &mut dacl, &mut defaulted) },
        0
    );
    // SAFETY: a live handle with WRITE_DAC and a valid ACL.
    let status = unsafe {
        SetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            dacl,
            std::ptr::null(),
        )
    };
    // SAFETY: the allocation from ConvertStringSecurityDescriptor….
    unsafe { LocalFree(replacement) };
    assert_eq!(status, 0);
}

/// Grant Everyone (`WD`) full control of the entry: the Unix `chmod o+w`.
fn grant_everyone_write(path: &Path) {
    edit_dacl(path, |sddl| format!("{sddl}(A;;FA;;;WD)"));
}

/// The token user's SID in its string form.
fn user_sid() -> String {
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    let mut token = std::ptr::null_mut();
    // SAFETY: the current-process pseudo handle and an output handle.
    assert_ne!(
        unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
        0
    );
    let mut buffer = vec![0u64; 64];
    let mut length = 0;
    // SAFETY: a live token and a buffer of the stated, aligned length.
    let queried = unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            (buffer.len() * 8) as u32,
            &mut length,
        )
    };
    // SAFETY: the handle opened above.
    unsafe { CloseHandle(token) };
    assert_ne!(queried, 0);
    // SAFETY: a successful TokenUser query starts with a TOKEN_USER.
    let sid = unsafe { (*buffer.as_ptr().cast::<TOKEN_USER>()).User.Sid };
    let mut text = std::ptr::null_mut();
    // SAFETY: a valid SID inside `buffer`; the string is freed below.
    assert_ne!(unsafe { ConvertSidToStringSidW(sid, &mut text) }, 0);
    let mut count = 0;
    // SAFETY: a NUL-terminated string from the call above.
    while unsafe { *text.add(count) } != 0 {
        count += 1;
    }
    // SAFETY: `count` characters precede the terminator.
    let value = String::from_utf16(unsafe { std::slice::from_raw_parts(text, count) }).unwrap();
    // SAFETY: the allocation from ConvertSidToStringSidW.
    unsafe { LocalFree(text.cast()) };
    value
}

/// The entry's DACL granting the token user read only: no execute right
/// for anyone.
fn owner_read_only(path: &Path) {
    let user = user_sid();
    edit_dacl(path, |_| format!("D:P(A;;FR;;;{user})"));
}

/// The entry owned by the token user, its DACL granting the user, `SYSTEM`
/// and `Administrators` full control and nobody else anything: the Unix
/// `0600` where root still reads everything. The owner is set explicitly,
/// since an elevated administrator's default owner is `Administrators`.
fn private(path: &Path) {
    let user = user_sid();
    let status = std::process::Command::new("icacls")
        .arg(path)
        .args(["/setowner", &format!("*{user}")])
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    edit_dacl(path, |_| {
        format!("D:P(A;;FA;;;{user})(A;;FA;;;SY)(A;;FA;;;BA)")
    });
}

/// A directory junction (a mount-point reparse point, which needs no
/// privilege) at `link`, naming `target`.
fn junction(link: &Path, target: &Path) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::IO::DeviceIoControl;
    const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
    std::fs::create_dir(link).unwrap();
    let target = target.to_str().unwrap();
    let target = target.strip_prefix(r"\\?\").unwrap_or(target);
    let substitute: Vec<u16> = format!(r"\??\{target}").encode_utf16().collect();
    let substitute_bytes = (substitute.len() * 2) as u16;
    let mut path_buffer = substitute.clone();
    path_buffer.extend([0, 0]);
    let data_length = 8 + path_buffer.len() * 2;
    let mut buffer = Vec::with_capacity(8 + data_length);
    buffer.extend(IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buffer.extend((data_length as u16).to_le_bytes());
    buffer.extend(0u16.to_le_bytes());
    buffer.extend(0u16.to_le_bytes()); // substitute name offset
    buffer.extend(substitute_bytes.to_le_bytes());
    buffer.extend((substitute_bytes + 2).to_le_bytes()); // print name offset
    buffer.extend(0u16.to_le_bytes()); // empty print name
    for unit in path_buffer {
        buffer.extend(unit.to_le_bytes());
    }
    let directory = std::fs::OpenOptions::new()
        .access_mode(FILE_WRITE_ATTRIBUTES | FILE_WRITE_DATA)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(link)
        .unwrap();
    let mut returned = 0;
    // SAFETY: a live directory handle and a complete mount-point buffer.
    let set = unsafe {
        DeviceIoControl(
            directory.as_raw_handle(),
            FSCTL_SET_REPARSE_POINT,
            buffer.as_ptr().cast(),
            buffer.len() as u32,
            std::ptr::null_mut(),
            0,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    assert_ne!(set, 0, "{}", std::io::Error::last_os_error());
}

#[test]
fn the_five_windows_roles_read_with_pinned_identities() {
    let scratch = Scratch::new("deveco-roles");
    let path = scratch.deveco("DevEco Studio");
    let root = DevEcoRoot::open(&path).unwrap();
    assert_eq!(root.path(), path);
    root.verify_sdk_directory().unwrap();
    root.require_linked().unwrap();
    let expected: [(DevEcoRole, &[u8], bool); 5] = [
        (DevEcoRole::ProductManifest, PRODUCT.as_bytes(), false),
        (DevEcoRole::SdkManifest, SDK.as_bytes(), false),
        (DevEcoRole::Node, b"MZ node", true),
        (DevEcoRole::Hvigor, b"// hvigor", false),
        (DevEcoRole::Java, b"MZ java", true),
    ];
    assert_eq!(
        DevEcoRole::ALL.map(DevEcoRole::name),
        ["productManifest", "sdkManifest", "node", "hvigor", "java"]
    );
    for (role, bytes, executable) in expected {
        let read = root.read_role(role).unwrap();
        assert_eq!(read.bytes, bytes, "{}", role.name());
        assert_eq!(read.facts.executable, executable, "{}", role.name());
        assert_eq!(read.facts.links, 1);
        assert_eq!(read.facts.identity.size, bytes.len() as u64);
        assert_eq!(read.facts.identity.device, root.identity.device);
        // A second read pins the same identity: nothing moved.
        assert_eq!(root.read_role(role).unwrap().facts, read.facts);
    }
    // A write moves the child's identity (size and times).
    let before = root.read_role(DevEcoRole::Hvigor).unwrap().facts;
    std::fs::write(path.join("tools/hvigor/bin/hvigorw.js"), b"// hvigor 2").unwrap();
    let after = root.read_role(DevEcoRole::Hvigor).unwrap().facts;
    assert_eq!(after.identity.inode, before.identity.inode);
    assert_ne!(after.identity, before.identity);
}

#[test]
fn unknown_layouts_links_and_foreign_rights_are_refused() {
    let scratch = Scratch::new("deveco-refusals");

    // The macOS layout on a Windows disk: no Windows launcher.
    let mac = scratch.0.join("DevEco-Studio.app").join("Contents");
    std::fs::create_dir_all(mac.join("Resources")).unwrap();
    std::fs::write(mac.join("Resources/product-info.json"), PRODUCT).unwrap();
    assert!(DevEcoRoot::open(&mac).is_err());

    // Relative, UNC and non-canonical spellings.
    let path = scratch.deveco("DevEco Studio");
    for spelling in [
        PathBuf::from(r"DevEco Studio"),
        PathBuf::from(r"\\localhost\c$\DevEco Studio"),
        PathBuf::from(plain(&path).to_str().unwrap().to_uppercase()),
        PathBuf::from(format!(r"{}\bin\..", plain(&path).display())),
        PathBuf::from(format!(r"{}\.", plain(&path).display())),
    ] {
        assert!(DevEcoRoot::open(&spelling).is_err(), "{spelling:?}");
    }

    // A root reached through a junction, and a junction inside the root.
    junction(&scratch.0.join("via-junction"), &path);
    assert!(DevEcoRoot::open(&scratch.0.join("via-junction")).is_err());
    let linked = scratch.deveco("linked");
    let elsewhere = scratch.0.join("elsewhere");
    std::fs::create_dir_all(elsewhere.join("bin")).unwrap();
    std::fs::write(elsewhere.join("bin/hvigorw.js"), b"// other").unwrap();
    std::fs::remove_dir_all(linked.join("tools/hvigor")).unwrap();
    junction(&linked.join("tools/hvigor"), &elsewhere);
    let root = DevEcoRoot::open(&linked).unwrap();
    assert!(root.read_role(DevEcoRole::Hvigor).is_err());
    assert!(root.read_role(DevEcoRole::ProductManifest).is_ok());

    // A second hard link to a child.
    let root = DevEcoRoot::open(&path).unwrap();
    std::fs::hard_link(
        path.join("sdk/default/sdk-pkg.json"),
        scratch.0.join("sdk-pkg-link.json"),
    )
    .unwrap();
    assert_eq!(
        root.read_role(DevEcoRole::SdkManifest)
            .err()
            .unwrap()
            .kind(),
        ErrorKind::PermissionDenied
    );

    // Node the caller may not execute.
    owner_read_only(&path.join("tools/node/node.exe"));
    assert_eq!(
        root.read_role(DevEcoRole::Node).err().unwrap().kind(),
        ErrorKind::PermissionDenied
    );
    // Nor the bundled JDK's launcher.
    owner_read_only(&path.join("jbr/bin/java.exe"));
    assert_eq!(
        root.read_role(DevEcoRole::Java).err().unwrap().kind(),
        ErrorKind::PermissionDenied
    );

    // Others granted write on a child, on a directory of the role, on the
    // SDK directory and on an ancestor of the root.
    grant_everyone_write(&path.join("product-info.json"));
    assert_eq!(
        root.read_role(DevEcoRole::ProductManifest)
            .err()
            .unwrap()
            .kind(),
        ErrorKind::PermissionDenied
    );
    grant_everyone_write(&path.join("tools/hvigor/bin"));
    assert!(root.read_role(DevEcoRole::Hvigor).is_err());
    grant_everyone_write(&path.join("sdk/default/openharmony"));
    assert!(root.verify_sdk_directory().is_err());
    let shared = scratch.0.join("shared");
    std::fs::create_dir(&shared).unwrap();
    let nested = deveco(&shared, "DevEco Studio");
    assert!(DevEcoRoot::open(&nested).is_ok());
    grant_everyone_write(&shared);
    assert!(DevEcoRoot::open(&nested).is_err());

    // A manifest beyond its bound.
    let large = scratch.deveco("large");
    std::fs::write(large.join("product-info.json"), vec![b' '; 64 * 1024 + 1]).unwrap();
    assert!(
        DevEcoRoot::open(&large)
            .unwrap()
            .read_role(DevEcoRole::ProductManifest)
            .is_err()
    );

    // The root replaced after it was opened.
    let replaced = scratch.deveco("replaced");
    let held = DevEcoRoot::open(&replaced).unwrap();
    std::fs::rename(&replaced, scratch.0.join("replaced-old")).unwrap();
    scratch.deveco("replaced");
    assert!(held.require_linked().is_err());
}

#[test]
fn a_pinned_file_is_measured_through_one_no_follow_handle() {
    let scratch = Scratch::new("pinned");
    let file = scratch.0.join("hap-sign-tool.jar");
    std::fs::write(&file, b"jar bytes").unwrap();
    // The account's directories may grant other principals read (this
    // host's sandbox group does); a private DACL is what a keystore has.
    private(&file);
    let measured = measure_host_file(&file, 1024).unwrap();
    assert_eq!(
        measured.sha256.as_slice(),
        Sha256::digest(b"jar bytes").as_slice()
    );
    assert_eq!(measured.identity.size, 9);
    assert_eq!(measured.links, 1);
    assert!(measured.owner_is_user && measured.trusted_write_only && measured.owner_private);
    assert!(!measured.executable, "only a PE image name is executable");

    let java = scratch.0.join("java.exe");
    std::fs::write(&java, b"MZ java").unwrap();
    private(&java);
    assert!(measure_host_file(&java, 1024).unwrap().executable);
    owner_read_only(&java);
    let read_only = measure_host_file(&java, 1024).unwrap();
    assert!(!read_only.executable);
    assert!(read_only.owner_private);

    // Readable by others: not private, still not writable by them.
    edit_dacl(&file, |sddl| format!("{sddl}(A;;FR;;;BU)"));
    let shared = measure_host_file(&file, 1024).unwrap();
    assert!(shared.trusted_write_only && !shared.owner_private);
    grant_everyone_write(&file);
    let writable = measure_host_file(&file, 1024).unwrap();
    assert!(!writable.trusted_write_only && !writable.owner_private);

    // Empty, over the bound, a directory, relative, not canonical, through
    // a junction: not a bounded regular file at its own path.
    let empty = scratch.0.join("empty.p12");
    std::fs::write(&empty, b"").unwrap();
    let directory = scratch.0.join("directory");
    std::fs::create_dir(&directory).unwrap();
    std::fs::write(directory.join("inner.pem"), b"pem").unwrap();
    junction(&scratch.0.join("via"), &directory);
    for (path, maximum) in [
        (empty.clone(), 1024),
        (java.clone(), 3),
        (directory.clone(), 1024),
        (PathBuf::from("java.exe"), 1024),
        (
            PathBuf::from(plain(&java).to_str().unwrap().to_uppercase()),
            1024,
        ),
        (
            PathBuf::from(format!(r"{}\..\java.exe", plain(&directory).display())),
            1024,
        ),
        (scratch.0.join("via").join("inner.pem"), 1024),
        (scratch.0.join("absent.pem"), 1024),
    ] {
        assert_eq!(
            measure_host_file(&path, maximum),
            Err(HostFileMeasureError::Unreadable),
            "{path:?}"
        );
    }
    assert!(measure_host_file(&directory.join("inner.pem"), 1024).is_ok());

    // Foundation's link resolution: the target's own spelling.
    assert_eq!(
        host_resolved_path(&scratch.0.join("via").join("inner.pem")),
        Some(plain(&directory.join("inner.pem")))
    );
    assert_eq!(host_resolved_path(&plain(&file)), Some(plain(&file)));
    assert_eq!(host_resolved_path(&scratch.0.join("absent.pem")), None);
}

/// This host's own DevEco installation, read-only: every role reads within
/// its bound and the manifests have the recorded shape. Nothing about the
/// installation (path, versions, identities) is printed. Run with
/// `ARKDECK_LIVE_DEVECO_ROOT=<root> cargo test -- --ignored live_deveco`.
#[test]
#[ignore = "reads a local DevEco installation"]
fn live_deveco_installation_has_the_windows_shape() {
    let Some(path) = std::env::var_os("ARKDECK_LIVE_DEVECO_ROOT") else {
        panic!("ARKDECK_LIVE_DEVECO_ROOT is not set");
    };
    let root = DevEcoRoot::open(Path::new(&path)).expect("root opens");
    root.verify_sdk_directory().expect("SDK directory is safe");
    for role in DevEcoRole::ALL {
        let read = root
            .read_role(role)
            .unwrap_or_else(|_| panic!("{}", role.name()));
        assert!(!read.bytes.is_empty());
        assert_eq!(read.facts.executable, role == DevEcoRole::Node);
    }
    let product: serde_json::Value =
        serde_json::from_slice(&root.read_role(DevEcoRole::ProductManifest).unwrap().bytes)
            .unwrap();
    for key in [
        "name",
        "version",
        "buildNumber",
        "productCode",
        "productVendor",
    ] {
        assert!(product[key].is_string(), "{key}");
    }
    assert!(
        product["launch"]
            .as_array()
            .unwrap()
            .iter()
            .any(|launch| launch["os"] == "Windows" && launch["arch"] == "amd64")
    );
    let sdk: serde_json::Value =
        serde_json::from_slice(&root.read_role(DevEcoRole::SdkManifest).unwrap().bytes).unwrap();
    for key in ["apiVersion", "platformVersion", "version"] {
        assert!(sdk["data"][key].is_string(), "{key}");
    }
    root.require_linked().unwrap();
}
