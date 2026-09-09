//! Kernel origin evidence and raw libxpc framing. The callbacks own no authority.
use crate::LocalConnection;
use std::{
    ffi::{CString, c_char, c_void},
    io,
    os::fd::AsRawFd,
};
#[derive(Clone, Copy, Debug)]
pub struct PeerOrigin {
    pub euid: u32,
    pub pid: i32,
    pub foreground_console: bool,
}
unsafe extern "C" {
    fn arkdeck_origin(fd: i32, uid: *mut u32, pid: *mut i32) -> i32;
    fn arkdeck_mach_listen(
        name: *const c_char,
        requirement: *const c_char,
        handler: unsafe extern "C" fn(
            *mut c_void,
            *const c_void,
            usize,
            u32,
            i32,
            *mut c_void,
            unsafe extern "C" fn(*mut c_void, *const c_void, usize),
        ),
        context: *mut c_void,
    ) -> i32;
}
impl LocalConnection {
    pub fn origin(&self) -> io::Result<PeerOrigin> {
        let (mut euid, mut pid) = (0, 0);
        // SAFETY: the owned descriptor is live and both output pointers are valid.
        let result = unsafe { arkdeck_origin(self.as_raw_fd(), &mut euid, &mut pid) };
        if result < 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "peer identity unavailable",
            ));
        }
        Ok(PeerOrigin {
            euid,
            pid,
            foreground_console: result == 1,
        })
    }
}
type Handler = Box<dyn Fn(&[u8], PeerOrigin) -> Vec<u8> + Send + Sync>;
struct Context {
    handler: Handler,
    _requirement: CString,
}
unsafe extern "C" fn receive(
    context: *mut c_void,
    bytes: *const c_void,
    length: usize,
    euid: u32,
    pid: i32,
    reply: *mut c_void,
    send: unsafe extern "C" fn(*mut c_void, *const c_void, usize),
) {
    // SAFETY: C invokes synchronously with live bounded buffers; Context is retained
    // for process lifetime and the closure is Send + Sync.
    let context = unsafe { &*context.cast::<Context>() };
    let bytes = unsafe { std::slice::from_raw_parts(bytes.cast::<u8>(), length) };
    let response = (context.handler)(
        bytes,
        PeerOrigin {
            euid,
            pid,
            foreground_console: false,
        },
    );
    unsafe {
        send(reply, response.as_ptr().cast(), response.len());
    }
}
pub fn listen_mach(name: &str, requirement: &str, handler: Handler) -> io::Result<()> {
    let name = CString::new(name).map_err(io::Error::other)?;
    let requirement = CString::new(requirement).map_err(io::Error::other)?;
    let context = Box::new(Context {
        handler,
        _requirement: requirement,
    });
    let context = Box::into_raw(context);
    // SAFETY: listener copies the service name. Context and requirement stay live
    // until process exit; peers call the callback on their serial libxpc queues.
    let result = unsafe {
        arkdeck_mach_listen(
            name.as_ptr(),
            (*context)._requirement.as_ptr(),
            receive,
            context.cast(),
        )
    };
    if result != 0 {
        unsafe {
            drop(Box::from_raw(context));
        }
        return Err(io::Error::other("Mach service listener unavailable"));
    }
    Ok(())
}
