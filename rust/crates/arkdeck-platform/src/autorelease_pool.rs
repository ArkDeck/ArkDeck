//! One call's Objective-C autorelease pool. A Rust thread has no pool of its
//! own, so whatever a framework call autoreleases on it stays allocated until
//! the thread exits — and a Runtime owner's thread, or the soak's, lives as
//! long as the process (TASK-XPA-025, #2129). Every platform call that reaches
//! a framework which may autorelease opens one of these for its own duration.
use std::ffi::c_void;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

/// Declare the guard before any other local so that it drops last.
pub(crate) struct AutoreleasePool(*mut c_void);

impl AutoreleasePool {
    pub(crate) fn push() -> Self {
        // SAFETY: opens a pool boundary on this thread's pool stack. The raw
        // pointer keeps the guard on this thread, and it pops in LIFO order.
        Self(unsafe { objc_autoreleasePoolPush() })
    }
}

impl Drop for AutoreleasePool {
    fn drop(&mut self) {
        // SAFETY: the token of this thread's matching push; pools pushed
        // after it have already been popped by their own guards.
        unsafe { objc_autoreleasePoolPop(self.0) };
    }
}
