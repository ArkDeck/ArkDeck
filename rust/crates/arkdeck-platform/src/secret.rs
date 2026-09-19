//! Secret bytes that are wiped when they go out of scope, as Swift clears its
//! `Data` copies of a signing password with `resetBytes` (SPK-10,
//! TASK-XPA-015). The type never prints its content: `Debug` shows only the
//! length, and there is no `Display`.
use std::fmt;

/// Owned secret bytes, overwritten with zeros when dropped.
pub struct Secret(Vec<u8>);

impl Secret {
    pub fn new(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    pub fn from_slice(bytes: &[u8]) -> Self {
        Self(bytes.to_vec())
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Clone for Secret {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        wipe(&mut self.0);
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "Secret({} bytes)", self.0.len())
    }
}

/// Overwrites `bytes` with zeros through volatile writes, so that the wipe of
/// a buffer about to be freed is not optimised away.
pub fn wipe(bytes: &mut [u8]) {
    for byte in bytes.iter_mut() {
        // SAFETY: `byte` is a valid, exclusive reference for this write.
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::{Secret, wipe};

    #[test]
    fn debug_shows_the_length_and_never_the_bytes() {
        let secret = Secret::from_slice(b"do-not-print");
        assert_eq!(format!("{secret:?}"), "Secret(12 bytes)");
        assert_eq!(secret.as_bytes(), b"do-not-print");
    }

    #[test]
    fn wipe_zeroes_every_byte() {
        let mut bytes = b"password".to_vec();
        wipe(&mut bytes);
        assert_eq!(bytes, vec![0; 8]);
    }
}
