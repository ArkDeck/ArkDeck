//! The primitives with which a Windows client starts the daemon it needs
//! (CHG-2026-074 r12 decision 11: the Windows daemon is started by its
//! client and is single-instance). The composition — when to start, how long
//! to wait, and the identity check that always follows — is the client's
//! (`arkdeck-client`); these only answer, launch and exclude.
//!
//! * [`pipe_present`]: whether a daemon's pipe exists now, without connecting
//!   to it or waiting for it.
//! * [`StarterLock`]: a named mutex beside the daemon's own guard that
//!   clients take in turn, so that concurrent starters launch one daemon. It
//!   never stands in for the daemon's single-instance guard, which stays the
//!   only authority on which daemon runs.
//! * [`DetachedDaemon::launch`]: the pinned daemon image, checked as a file
//!   first ([`ImagePin`]) and held unchanged until the process exists,
//!   started as a fixed argument array (the image alone), detached, with no
//!   console window, no inherited handle and no standard streams, in the
//!   image's own directory.
use super::identity::{ImagePin, Token, owned_by_current_user, verify_installed_image};
use super::state::InstanceScope;
use super::{Handle, SecurityDescriptor, bool_result, endpoint_name, wide};
use crate::{LocalEndpoint, ServerIdentity, denied};
use std::ffi::{OsStr, OsString};
use std::io;
use std::marker::PhantomData;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::null;
use std::time::Duration;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::SE_KERNEL_OBJECT;
use windows_sys::Win32::System::Pipes::WaitNamedPipeW;
use windows_sys::Win32::System::Threading::*;

/// Checks the pinned daemon image as [`DetachedDaemon::launch`] checks it
/// before starting it, and starts nothing: what vouches for it, or why it is
/// refused.
pub fn verify_daemon_image(identity: &ServerIdentity) -> io::Result<ImagePin> {
    verify_installed_image(identity).map(|image| image.pin)
}

/// Whether the pipe `endpoint` names exists now. Nothing connects to it and
/// nothing waits for it to appear: a pipe whose every instance is busy
/// exists.
pub fn pipe_present(endpoint: &LocalEndpoint) -> io::Result<bool> {
    let name = endpoint_name(endpoint)?;
    // SAFETY: a NUL-terminated local pipe name; the shortest wait, which
    // answers at once for an absent name or a free instance.
    if unsafe { WaitNamedPipeW(name.as_ptr(), 1) } != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error().map(|code| code as u32) {
        Some(ERROR_FILE_NOT_FOUND) => Ok(false),
        Some(ERROR_SEM_TIMEOUT) => Ok(true),
        _ => Err(error),
    }
}

/// Waits at most `timeout` for an instance of the existing pipe `endpoint`
/// to be free for a client (every instance was busy: the server has not yet
/// offered its next one); `false` if none was. A pipe that does not exist
/// is an error. Nothing connects.
pub fn await_pipe_instance(endpoint: &LocalEndpoint, timeout: Duration) -> io::Result<bool> {
    let name = endpoint_name(endpoint)?;
    let millis = timeout.as_millis().clamp(1, u128::from(u32::MAX - 1)) as u32;
    // SAFETY: a NUL-terminated local pipe name and a bounded wait.
    if unsafe { WaitNamedPipeW(name.as_ptr(), millis) } != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_SEM_TIMEOUT as i32) {
        Ok(false)
    } else {
        Err(error)
    }
}

/// The starters' turn for one scope: held by one client thread at a time.
/// Thread-affine like every mutex, so neither sent nor shared; released when
/// dropped, and a starter that died holding it leaves it to the next.
pub struct StarterLock {
    mutex: Handle,
    _thread: PhantomData<*const ()>,
}

impl StarterLock {
    /// Takes the starters' turn for `scope`, waiting at most `wait`; `None`
    /// if another starter still holds it then. An existing object that is
    /// not this user's refuses.
    pub fn acquire(scope: &InstanceScope, wait: Duration) -> io::Result<Option<Self>> {
        let user = Token::current()?.user()?.text()?;
        let security =
            SecurityDescriptor::from_sddl(&format!("O:{user}D:P(A;;GA;;;{user})(A;;GA;;;SY)"))?;
        let attributes = security.attributes();
        let name = wide(OsStr::new(&scope.starter_name()))?;
        // SAFETY: NUL-terminated name and security attributes alive for the
        // call; the handle is owned at once.
        let mutex = Handle::new(unsafe { CreateMutexW(&attributes, 0, name.as_ptr()) })?;
        if !owned_by_current_user(mutex.raw(), SE_KERNEL_OBJECT)? {
            return Err(denied(
                "the daemon starters' lock is owned by another account; nothing was started",
            ));
        }
        let millis = wait.as_millis().min(u128::from(INFINITE - 1)) as u32;
        // SAFETY: live mutex handle with SYNCHRONIZE access.
        match unsafe { WaitForSingleObject(mutex.raw(), millis) } {
            // A starter that died holding the turn started nothing this one
            // relies on: the pipe is looked at again under the turn.
            WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Some(Self {
                mutex,
                _thread: PhantomData,
            })),
            WAIT_TIMEOUT => Ok(None),
            _ => Err(io::Error::last_os_error()),
        }
    }
}

impl Drop for StarterLock {
    fn drop(&mut self) {
        // SAFETY: this thread owns the mutex (the lock cannot leave it).
        unsafe {
            ReleaseMutex(self.mutex.raw());
        }
    }
}

/// A daemon process this client launched. Dropping it closes the handle
/// only: the daemon runs on.
pub struct DetachedDaemon {
    process: Handle,
    pid: u32,
    pin: ImagePin,
}

impl DetachedDaemon {
    /// Launches the daemon image `identity` pins, after checking it as a
    /// file (see [`ImagePin`]); an image that fails the check, or no
    /// configured identity, is refused and nothing runs. `environment`
    /// replaces the inherited environment when given; otherwise the child
    /// inherits this process's, with `ARKDECK_ENDPOINT` removed (the daemon
    /// derives its pipe from its state root) and
    /// `ARKDECK_DEVELOPMENT_STATE_ROOT` set to `development_root` or removed.
    pub fn launch(
        identity: &ServerIdentity,
        development_root: Option<&Path>,
        environment: Option<&[(OsString, OsString)]>,
    ) -> io::Result<Self> {
        let image = verify_installed_image(identity)?;
        let variables: Vec<(OsString, OsString)> = match environment {
            Some(variables) => variables.to_vec(),
            None => std::env::vars_os()
                .filter(|(name, _)| {
                    !name.eq_ignore_ascii_case("ARKDECK_ENDPOINT")
                        && !name.eq_ignore_ascii_case("ARKDECK_DEVELOPMENT_STATE_ROOT")
                })
                .chain(development_root.map(|root| {
                    (
                        OsString::from("ARKDECK_DEVELOPMENT_STATE_ROOT"),
                        root.as_os_str().to_owned(),
                    )
                }))
                .collect(),
        };
        let block = environment_block(&variables)?;
        let application = wide(image.path.as_os_str())?;
        // The command line is the image alone, quoted: a Windows path holds
        // no quotation mark, so nothing in it can become a second argument.
        let mut command_line = wide(&{
            let mut line = OsString::from("\"");
            line.push(image.path.as_os_str());
            line.push("\"");
            line
        })?;
        let directory = image
            .path
            .parent()
            .map(|parent| wide(parent.as_os_str()))
            .transpose()?;
        let startup = STARTUPINFOW {
            cb: size_of::<STARTUPINFOW>() as u32,
            ..Default::default()
        };
        let mut information = PROCESS_INFORMATION::default();
        // SAFETY: NUL-terminated application name, a writable command line,
        // a double-NUL-terminated UTF-16 environment block and directory, all
        // alive for the call; no handle is inherited. Both returned handles
        // are owned at once.
        bool_result(unsafe {
            CreateProcessW(
                application.as_ptr(),
                command_line.as_mut_ptr(),
                null(),
                null(),
                0,
                DETACHED_PROCESS
                    | CREATE_NEW_PROCESS_GROUP
                    | CREATE_NO_WINDOW
                    | CREATE_UNICODE_ENVIRONMENT,
                block.as_ptr().cast(),
                directory
                    .as_ref()
                    .map_or(null(), |directory| directory.as_ptr()),
                &startup,
                &mut information,
            )
        })?;
        let process = Handle::new(information.hProcess)?;
        drop(Handle::new(information.hThread)?);
        Ok(Self {
            process,
            pid: information.dwProcessId,
            pin: image.pin,
        })
    }

    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// What vouched for the image before it ran.
    pub fn pin(&self) -> ImagePin {
        self.pin
    }

    /// The daemon's exit code if it has exited within `timeout`; `None` while
    /// it runs.
    pub fn wait_exit(&self, timeout: Duration) -> io::Result<Option<u32>> {
        let millis = timeout.as_millis().min(u128::from(INFINITE - 1)) as u32;
        // SAFETY: a live process handle with SYNCHRONIZE access.
        match unsafe { WaitForSingleObject(self.process.raw(), millis) } {
            WAIT_TIMEOUT => Ok(None),
            WAIT_OBJECT_0 => {
                let mut code = 0;
                // SAFETY: a live process handle and valid output storage.
                bool_result(unsafe { GetExitCodeProcess(self.process.raw(), &mut code) })?;
                Ok(Some(code))
            }
            _ => Err(io::Error::last_os_error()),
        }
    }
}

/// `CreateProcessW`'s Unicode environment block: `name=value` entries sorted
/// by name without regard to case, each NUL-terminated, and a final NUL.
fn environment_block(variables: &[(OsString, OsString)]) -> io::Result<Vec<u16>> {
    let mut entries: Vec<(Vec<u16>, Vec<u16>)> = variables
        .iter()
        .map(|(name, value)| {
            let name: Vec<u16> = name.encode_wide().collect();
            let value: Vec<u16> = value.encode_wide().collect();
            if name.is_empty()
                || name.contains(&0)
                || name[1..].contains(&u16::from(b'='))
                || value.contains(&0)
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "an environment variable cannot be passed to the daemon",
                ));
            }
            Ok((name, value))
        })
        .collect::<io::Result<_>>()?;
    let upper = |name: &[u16]| -> Vec<u16> {
        String::from_utf16_lossy(name)
            .to_uppercase()
            .encode_utf16()
            .collect()
    };
    entries.sort_by_key(|(name, _)| upper(name));
    let mut block = Vec::new();
    for (name, value) in entries {
        block.extend(name);
        block.push(u16::from(b'='));
        block.extend(value);
        block.push(0);
    }
    if block.is_empty() {
        block.push(0);
    }
    block.push(0);
    Ok(block)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> InstanceScope {
        let nonce = u64::from_le_bytes(crate::random_bytes().unwrap());
        let root = std::env::temp_dir().join(format!("ad-start-{nonce:016x}"));
        std::fs::create_dir(&root).unwrap();
        let scope = super::super::StateRoot::development(&root)
            .unwrap()
            .scope()
            .unwrap();
        std::fs::remove_dir(&root).unwrap();
        scope
    }

    #[test]
    fn a_pipe_is_present_only_while_it_is_served() {
        let nonce = u64::from_le_bytes(crate::random_bytes().unwrap());
        let endpoint = LocalEndpoint::new(format!(r"\\.\pipe\arkdeck-start-probe-{nonce:016x}"));
        assert!(!pipe_present(&endpoint).unwrap());
        let listener = super::super::LocalListener::bind(&endpoint).unwrap();
        assert!(pipe_present(&endpoint).unwrap());
        drop(listener);
        assert!(!pipe_present(&endpoint).unwrap());
        assert!(pipe_present(&LocalEndpoint::new(r"\\.\pipe\not-arkdeck")).is_err());
    }

    #[test]
    fn one_starter_holds_the_turn_at_a_time() {
        let scope = scope();
        let (taken, release) = (
            std::sync::mpsc::channel::<()>(),
            std::sync::mpsc::channel::<()>(),
        );
        let holder = {
            let scope = scope.clone();
            let (taken, release) = (taken.0, release.1);
            std::thread::spawn(move || {
                let turn = StarterLock::acquire(&scope, Duration::ZERO)
                    .unwrap()
                    .expect("the first starter's turn");
                taken.send(()).unwrap();
                release.recv().unwrap();
                drop(turn);
            })
        };
        taken.1.recv().unwrap();
        assert!(
            StarterLock::acquire(&scope, Duration::ZERO)
                .unwrap()
                .is_none()
        );
        release.0.send(()).unwrap();
        holder.join().unwrap();
        assert!(
            StarterLock::acquire(&scope, Duration::ZERO)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn nothing_is_launched_without_a_configured_identity() {
        let image = std::env::current_exe().unwrap();
        let refused = DetachedDaemon::launch(&ServerIdentity::new(&image), None, Some(&[]))
            .err()
            .expect("an image without a pin is never launched");
        assert_eq!(refused.kind(), io::ErrorKind::PermissionDenied);
        let unsigned = ServerIdentity {
            authenticode_sha256: Some("0".repeat(64)),
            ..ServerIdentity::new(&image)
        };
        assert!(DetachedDaemon::launch(&unsigned, None, Some(&[])).is_err());
        assert!(
            DetachedDaemon::launch(&ServerIdentity::new("relative.exe"), None, Some(&[])).is_err()
        );
    }

    /// Maintainer ruling 17 before the start: a partial publisher identity
    /// refuses whatever else is configured, and a complete one the image
    /// cannot prove launches nothing (the test image is unsigned), unless a
    /// package family is left to be proved on the running server.
    #[test]
    fn the_pre_launch_check_honours_the_publisher_identity() {
        let image = std::env::current_exe().unwrap();
        const EKU: &str = "1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583";
        let family = Some("Contoso.ArkDeck_8wekyb3d8bbwe".to_owned());
        for (organization, eku) in [(Some("Contoso Ltd"), None), (None, Some(EKU))] {
            let partial = ServerIdentity {
                authenticode_sha256: Some("0".repeat(64)),
                package_family: family.clone(),
                publisher_organization: organization.map(str::to_owned),
                publisher_eku: eku.map(str::to_owned),
                ..ServerIdentity::new(&image)
            };
            let refused = verify_daemon_image(&partial).expect_err("partial publisher identity");
            assert_eq!(refused.kind(), io::ErrorKind::PermissionDenied);
            assert!(
                refused
                    .to_string()
                    .contains("partial daemon publisher identity")
            );
            assert!(DetachedDaemon::launch(&partial, None, Some(&[])).is_err());
        }
        let malformed = ServerIdentity {
            publisher_organization: Some("Contoso Ltd".into()),
            publisher_eku: Some("1.3.6.1.4.1.311.97.1.0".into()),
            ..ServerIdentity::new(&image)
        };
        assert!(verify_daemon_image(&malformed).is_err());
        let publisher = ServerIdentity {
            publisher_organization: Some("Contoso Ltd".into()),
            publisher_eku: Some(EKU.into()),
            ..ServerIdentity::new(&image)
        };
        assert_eq!(
            verify_daemon_image(&publisher).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert!(DetachedDaemon::launch(&publisher, None, Some(&[])).is_err());
        let with_family = ServerIdentity {
            package_family: family,
            ..publisher
        };
        assert_eq!(
            verify_daemon_image(&with_family).unwrap(),
            ImagePin::PackageFamily
        );
    }

    #[test]
    fn the_environment_block_is_sorted_and_double_terminated() {
        let block = environment_block(&[
            ("b".into(), "2".into()),
            ("A".into(), "1".into()),
            ("=C:".into(), r"C:\".into()),
        ])
        .unwrap();
        assert_eq!(String::from_utf16_lossy(&block), "=C:=C:\\\0A=1\0b=2\0\0");
        assert_eq!(environment_block(&[]).unwrap(), vec![0, 0]);
        assert!(environment_block(&[("A=B".into(), "1".into())]).is_err());
    }
}
