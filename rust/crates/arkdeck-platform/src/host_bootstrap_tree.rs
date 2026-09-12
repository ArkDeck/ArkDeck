//! Bounded descriptor-relative bootstrap content inspection. Never executes or
//! mutates inspected content; quarantine contributes to content identity.
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::{CStr, CString},
    fs::{File, Metadata, OpenOptions},
    io,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{FileExt, MetadataExt, OpenOptionsExt},
        },
    },
    path::Path,
};
const MAX_ENTRIES: usize = 4096;
const MAX_BYTES: u64 = 1_073_741_824;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapEntry {
    pub path: String,
    pub directory: bool,
    pub executable: bool,
    pub quarantine_sha256: Option<String>,
    pub byte_count: u64,
    pub sha256: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Identity {
    dev: u64,
    ino: u64,
    size: u64,
    mode: u32,
    uid: u32,
    links: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl From<Metadata> for Identity {
    fn from(m: Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            size: m.len(),
            mode: m.mode(),
            uid: m.uid(),
            links: m.nlink(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapTree {
    pub entries: Vec<BootstrapEntry>,
    pub byte_count: u64,
    identities: BTreeMap<String, Identity>,
}
impl BootstrapTree {
    /// Reopen a bounded relative file, checking each held component against
    /// this snapshot. No pathname from the input can traverse outside the tree.
    pub fn open_relative_file(&self, root: &Path, relative: &str) -> io::Result<File> {
        // At most 24 macOS directory components (255 bytes plus separator).
        if relative.len() > 24 * 256 {
            return Err(refusal());
        }
        let components: Vec<_> = relative.split('/').collect();
        if components.len() > 24
            || components
                .iter()
                .any(|part| part.is_empty() || *part == "." || *part == "..")
        {
            return Err(refusal());
        }
        let mut held = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root)?;
        if Some(&Identity::from(held.metadata()?)) != self.identities.get("") {
            return Err(refusal());
        }
        let mut prefix = String::new();
        for component in components {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            held = child(&held, component)?;
            if Some(&Identity::from(held.metadata()?)) != self.identities.get(&prefix) {
                return Err(refusal());
            }
        }
        if !held.metadata()?.is_file() {
            return Err(refusal());
        }
        Ok(held)
    }

    /// Reopen one inspected immediate regular child and retain its descriptor
    /// through load-command inspection. The caller compares a second full tree.
    pub fn open_immediate_file(&self, root: &Path, name: &str) -> io::Result<File> {
        if name.is_empty() || name.contains('/') || name == "." || name == ".." {
            return Err(refusal());
        }
        let expected = self.identities.get(name).ok_or_else(refusal)?;
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root)?;
        if Some(&Identity::from(parent.metadata()?)) != self.identities.get("") {
            return Err(refusal());
        }
        let file = child(&parent, name)?;
        if !file.metadata()?.is_file() || &Identity::from(file.metadata()?) != expected {
            return Err(refusal());
        }
        Ok(file)
    }
}
/// Resolve the current account's bootstrap owner exactly as the Swift CLI does.
/// HOME and the App Sandbox container path are intentionally not consulted.
pub fn default_bootstrap_registry_root() -> io::Result<std::path::PathBuf> {
    let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    // SAFETY: output storage and the backing passwd strings remain alive until
    // the home path is copied. No pointer escapes this function.
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            record.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return Err(refusal());
    }
    let record = unsafe { record.assume_init() };
    if record.pw_dir.is_null() {
        return Err(refusal());
    }
    let home = unsafe { CStr::from_ptr(record.pw_dir) }
        .to_str()
        .map_err(|_| refusal())?;
    if !home.starts_with('/') {
        return Err(refusal());
    }
    Ok(Path::new(home).join("Library/Application Support/ArkDeck/Bootstrap/v1"))
}
fn refusal() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "bootstrap content identity is unsafe, changed or unbounded",
    )
}
pub(super) fn quarantine(file: &File) -> io::Result<Option<Vec<u8>>> {
    // SAFETY: descriptor is held; attribute name and bounded buffers live through each call.
    let size = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            c"com.apple.quarantine".as_ptr(),
            std::ptr::null_mut(),
            0,
            0,
            0,
        )
    };
    if size < 0 {
        return if io::Error::last_os_error().raw_os_error() == Some(libc::ENOATTR) {
            Ok(None)
        } else {
            Err(io::Error::last_os_error())
        };
    }
    if size > 16 * 1024 {
        return Err(refusal());
    }
    let mut bytes = vec![0; size as usize];
    let count = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            c"com.apple.quarantine".as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            0,
            0,
        )
    };
    if count != size {
        return Err(refusal());
    }
    Ok(Some(bytes))
}
// BootstrapBundleFiles.names uses ASCII byte validation and Swift String
// equality. Canonical keys detect ambiguous names; original bytes remain in
// the returned inventory and retain their UTF-8 ordering.
fn insert_name(
    name: &str,
    result: &mut Vec<String>,
    canonical_names: &mut BTreeSet<String>,
) -> io::Result<()> {
    if name.is_empty()
        || name.contains('/')
        || name.bytes().any(|byte| byte < 32 || byte == 127)
        || result.len() >= MAX_ENTRIES
        || !canonical_names.insert(crate::host_canonical_text(name).ok_or_else(refusal)?)
    {
        return Err(refusal());
    }
    result.push(name.to_owned());
    Ok(())
}
pub(super) fn names(file: &File) -> io::Result<Vec<String>> {
    // SAFETY: a fresh open description avoids sharing directory enumeration offsets.
    let fd = unsafe {
        libc::openat(
            file.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let dir = unsafe { libc::fdopendir(fd) };
    if dir.is_null() {
        let e = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(e);
    }
    struct Close(*mut libc::DIR);
    impl Drop for Close {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let _close = Close(dir);
    let mut result = Vec::new();
    let mut canonical_names = BTreeSet::new();
    loop {
        unsafe {
            *libc::__error() = 0;
        }
        let entry = unsafe { libc::readdir(dir) };
        if entry.is_null() {
            if unsafe { *libc::__error() } != 0 {
                return Err(io::Error::last_os_error());
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
            .to_str()
            .map_err(|_| refusal())?;
        if name == "." || name == ".." {
            continue;
        }
        insert_name(name, &mut result, &mut canonical_names)?;
    }
    result.sort();
    Ok(result)
}
fn child(parent: &File, name: &str) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| refusal())?;
    // SAFETY: descriptor and nul-terminated component remain live; owned fd transferred once.
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn visit(file: &File, path: String, depth: usize, tree: &mut BootstrapTree) -> io::Result<()> {
    if depth > 24 || tree.entries.len() >= MAX_ENTRIES {
        return Err(refusal());
    }
    let m = file.metadata()?;
    if (m.uid() != unsafe { libc::geteuid() } && m.uid() != 0)
        || m.mode() & 0o6022 != 0
        || !(m.is_dir() || (m.is_file() && m.nlink() == 1))
    {
        return Err(refusal());
    }
    let identity = Identity::from(m.clone());
    let attr = quarantine(file)?;
    let mut entry = BootstrapEntry {
        path: path.clone(),
        directory: m.is_dir(),
        executable: m.is_file() && m.mode() & 0o111 != 0,
        quarantine_sha256: attr.as_ref().map(|v| format!("{:x}", Sha256::digest(v))),
        byte_count: 0,
        sha256: None,
    };
    let position = tree.entries.len();
    tree.entries.push(entry.clone());
    if m.is_dir() {
        let before = names(file)?;
        for name in &before {
            let held = child(file, name)?;
            let child_identity = Identity::from(held.metadata()?);
            visit(
                &held,
                if path.is_empty() {
                    name.clone()
                } else {
                    format!("{path}/{name}")
                },
                depth + 1,
                tree,
            )?;
            if Identity::from(child(file, name)?.metadata()?) != child_identity {
                return Err(refusal());
            }
        }
        if names(file)? != before {
            return Err(refusal());
        }
    } else {
        if m.len() > MAX_BYTES - tree.byte_count {
            return Err(refusal());
        }
        let mut hash = Sha256::new();
        let mut offset = 0;
        let mut buffer = [0; 65536];
        loop {
            let count = match file.read_at(&mut buffer, offset) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                v => v?,
            };
            if count == 0 {
                break;
            }
            offset += count as u64;
            if offset > m.len() {
                return Err(refusal());
            }
            hash.update(&buffer[..count]);
        }
        if offset != m.len() {
            return Err(refusal());
        }
        tree.byte_count += offset;
        entry.byte_count = offset;
        entry.sha256 = Some(format!("{:x}", hash.finalize()));
    }
    if Identity::from(file.metadata()?) != identity || quarantine(file)? != attr {
        return Err(refusal());
    }
    tree.identities.insert(path, identity);
    tree.entries[position] = entry;
    Ok(())
}
/// The returned tree includes held-file identities so two scans around native
/// signature inspection reject replacement even when replacement bytes match.
pub fn inspect_bootstrap_tree(path: &Path) -> io::Result<BootstrapTree> {
    if !path.is_absolute()
        || path.as_os_str().as_bytes().contains(&0)
        || path.canonicalize()? != path
    {
        return Err(refusal());
    }
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let mut tree = BootstrapTree {
        entries: Vec::new(),
        byte_count: 0,
        identities: BTreeMap::new(),
    };
    visit(&root, String::new(), 0, &mut tree)?;
    if Identity::from(std::fs::symlink_metadata(path)?) != Identity::from(root.metadata()?)
        || path.canonicalize()? != path
    {
        return Err(refusal());
    }
    Ok(tree)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };
    fn fixture() -> std::path::PathBuf {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("bootstrap-tree-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        root
    }
    fn put(root: &Path, name: &str, bytes: &[u8], mode: u32) {
        fs::write(root.join(name), bytes).unwrap();
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(mode)).unwrap();
    }
    #[test]
    fn nested_file_reopen_stays_bound_to_every_inspected_component() {
        let root = fixture();
        std::fs::create_dir(root.join("Contents")).unwrap();
        put(&root, "Contents/Info.plist", b"original", 0o600);
        let tree = inspect_bootstrap_tree(&root).unwrap();
        assert_eq!(
            tree.open_relative_file(&root, "Contents/Info.plist")
                .unwrap()
                .metadata()
                .unwrap()
                .len(),
            8
        );
        for relative in [
            "",
            "/Contents/Info.plist",
            "Contents//Info.plist",
            "Contents/../Contents/Info.plist",
            "Contents/./Info.plist",
            "Contents",
        ] {
            assert!(tree.open_relative_file(&root, relative).is_err());
        }
        std::fs::rename(root.join("Contents/Info.plist"), root.join("Contents/old")).unwrap();
        put(&root, "Contents/Info.plist", b"original", 0o600);
        assert!(
            tree.open_relative_file(&root, "Contents/Info.plist")
                .is_err()
        );
    }

    #[test]
    fn captures_content_metadata_and_detects_same_bytes_replacement() {
        let root = fixture();
        put(&root, "hdc", b"bounded native fixture", 0o700);
        let before = inspect_bootstrap_tree(&root).unwrap();
        assert_eq!(before.entries.len(), 2);
        assert_eq!(before.entries[0].path, "");
        assert_eq!(before.entries[1].path, "hdc");
        assert!(before.entries[1].executable);
        assert_eq!(before.byte_count, 22);
        assert_eq!(before, inspect_bootstrap_tree(&root).unwrap());
        put(&root, "replacement", b"bounded native fixture", 0o700);
        fs::rename(root.join("replacement"), root.join("hdc")).unwrap();
        let after = inspect_bootstrap_tree(&root).unwrap();
        assert_eq!(before.entries, after.entries);
        assert_ne!(before, after);
    }
    #[test]
    fn refuses_links_unsafe_mode_and_depth_without_mutation() {
        let root = fixture();
        put(&root, "hdc", b"original", 0o600);
        symlink("hdc", root.join("link")).unwrap();
        assert!(inspect_bootstrap_tree(&root).is_err());
        assert_eq!(fs::read(root.join("hdc")).unwrap(), b"original");
        let hard = fixture();
        put(&hard, "a", b"hard", 0o600);
        fs::hard_link(hard.join("a"), hard.join("b")).unwrap();
        assert!(inspect_bootstrap_tree(&hard).is_err());
        let writable = fixture();
        put(&writable, "a", b"unsafe", 0o622);
        assert!(inspect_bootstrap_tree(&writable).is_err());
        let deep = fixture();
        let mut child = deep.clone();
        for _ in 0..25 {
            child = child.join("a");
            fs::DirBuilder::new().mode(0o700).create(&child).unwrap();
        }
        assert!(inspect_bootstrap_tree(&deep).is_err());
        assert!(inspect_bootstrap_tree(Path::new("relative")).is_err());
    }
    #[test]
    fn quarantine_is_hashed_and_preserved() {
        let root = fixture();
        put(&root, "hdc", b"file", 0o600);
        let file = File::open(root.join("hdc")).unwrap();
        let attribute = b"0081;fixture;ArkDeck;";
        // SAFETY: test-owned descriptor and bytes remain live. Only new fixture metadata is set.
        assert_eq!(
            unsafe {
                libc::fsetxattr(
                    file.as_raw_fd(),
                    c"com.apple.quarantine".as_ptr(),
                    attribute.as_ptr().cast(),
                    attribute.len(),
                    0,
                    0,
                )
            },
            0
        );
        let tree = inspect_bootstrap_tree(&root).unwrap();
        assert_eq!(
            tree.entries[1].quarantine_sha256,
            Some(format!("{:x}", Sha256::digest(attribute)))
        );
        assert_eq!(
            quarantine(&file).unwrap().as_deref(),
            Some(attribute.as_slice())
        );
    }
    #[test]
    fn directory_names_refuse_ascii_control_bytes_without_touching_fixture_content() {
        for name in [
            "line\nfeed",
            "tab\tname",
            "carriage\rreturn",
            "delete\u{7f}name",
            "control\u{1}name",
        ] {
            let root = fixture();
            put(&root, name, b"unchanged fixture", 0o600);
            let directory = File::open(&root).unwrap();
            assert!(names(&directory).is_err());
            assert!(inspect_bootstrap_tree(&root).is_err());
            assert_eq!(fs::read(root.join(name)).unwrap(), b"unchanged fixture");
        }
    }

    #[test]
    fn directory_names_match_swift_canonical_equality_without_normalizing_output() {
        // APFS may prohibit these pairs from coexisting. Exercise the exact
        // insertion path used by readdir to cover both distinct byte spellings.
        for (first, equivalent) in [
            ("é", "e\u{301}"),
            ("Å", "A\u{30a}"),
            ("가", "\u{1100}\u{1161}"),
        ] {
            let mut result = Vec::new();
            let mut canonical = BTreeSet::new();
            insert_name(first, &mut result, &mut canonical).unwrap();
            assert!(insert_name(equivalent, &mut result, &mut canonical).is_err());
            assert_eq!(result, [first]);
        }
        let mut result = Vec::new();
        let mut canonical = BTreeSet::new();
        // C1 control and format scalars are accepted by the Swift byte rule;
        // CharacterSet.controlCharacters or case-folding would be too strict.
        for name in [
            "e\u{301}",
            "A",
            "a",
            "space name",
            "c1\u{85}",
            "format\u{200b}",
        ] {
            insert_name(name, &mut result, &mut canonical).unwrap();
        }
        assert_eq!(result[0].as_bytes(), "e\u{301}".as_bytes());
        assert!(insert_name("A", &mut result, &mut canonical).is_err());
        for byte in (0_u8..32).chain(std::iter::once(127)) {
            let name = format!("invalid{}name", char::from(byte));
            assert!(insert_name(&name, &mut result, &mut canonical).is_err());
        }
        for name in ["", "path/component"] {
            assert!(insert_name(name, &mut result, &mut canonical).is_err());
        }
    }

    #[test]
    fn directory_names_keep_utf8_order_and_allow_non_ascii_control_scalars() {
        let root = fixture();
        for name in ["é", "z", "space name", "c1\u{85}", "format\u{200b}"] {
            put(&root, name, b"fixture", 0o600);
        }
        let directory = File::open(&root).unwrap();
        assert_eq!(
            names(&directory).unwrap(),
            ["c1\u{85}", "format\u{200b}", "space name", "z", "é"]
        );
        assert_eq!(inspect_bootstrap_tree(&root).unwrap().entries.len(), 6);
    }
}
