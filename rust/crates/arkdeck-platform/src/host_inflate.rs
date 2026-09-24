//! Raw DEFLATE decoding (RFC 1951, no zlib or gzip framing) through Apple's
//! Compression library, the decoder Swift's `GzipTarArchiveReader` streams a
//! flash bundle's payload through (`COMPRESSION_ZLIB`). Output leaves in the
//! windows the library fills, at most 1 MiB each, exactly as Swift's
//! `RawDeflateDecompressor.feed(_:finalize:emit:)` hands them on.
use std::ffi::c_void;
use std::ptr::{null, null_mut};

/// Swift `GzipTarArchiveReader.chunkSizeBytes`: the output window.
pub const INFLATE_WINDOW_BYTES: usize = 1 << 20;

#[repr(C)]
struct Stream {
    dst_ptr: *mut u8,
    dst_size: usize,
    src_ptr: *const u8,
    src_size: usize,
    state: *mut c_void,
}

const STREAM_DECODE: u32 = 1;
const ALGORITHM_ZLIB: u32 = 0x205;
const STREAM_FINALIZE: i32 = 0x0001;
const STATUS_OK: i32 = 0;
const STATUS_END: i32 = 1;

#[link(name = "compression")]
unsafe extern "C" {
    fn compression_stream_init(stream: *mut Stream, operation: u32, algorithm: u32) -> i32;
    fn compression_stream_process(stream: *mut Stream, flags: i32) -> i32;
    fn compression_stream_destroy(stream: *mut Stream) -> i32;
}

/// Why decoding stopped: the library refused the stream
/// (`decompressionFailed`), input ran out before the final block
/// (`truncatedArchive`), or the caller's sink refused a window.
#[derive(Debug, PartialEq, Eq)]
pub enum InflateError<E> {
    DecompressionFailed,
    Truncated,
    Sink(E),
}

/// One raw DEFLATE stream being decoded. Once its final block has been
/// decoded, further input is ignored, as Swift ignores the gzip trailer.
pub struct RawInflate {
    stream: Box<Stream>,
    window: Vec<u8>,
    ended: bool,
}

impl RawInflate {
    /// A decoder, or none when the library cannot start one.
    pub fn new() -> Option<Self> {
        let mut stream = Box::new(Stream {
            dst_ptr: null_mut(),
            dst_size: 0,
            src_ptr: null(),
            src_size: 0,
            state: null_mut(),
        });
        // SAFETY: an exclusively owned, zeroed `compression_stream`.
        if unsafe { compression_stream_init(&mut *stream, STREAM_DECODE, ALGORITHM_ZLIB) }
            != STATUS_OK
        {
            return None;
        }
        Some(Self {
            stream,
            window: vec![0; INFLATE_WINDOW_BYTES],
            ended: false,
        })
    }

    /// Swift `RawDeflateDecompressor.feed(_:finalize:emit:)`: decodes `input`,
    /// handing each produced window to `emit`, until the input is consumed
    /// and a window is left partly empty; with `finalize`, until the stream
    /// ends, a third window in a row comes back empty (`Truncated`), or the
    /// library refuses.
    pub fn feed<E>(
        &mut self,
        input: &[u8],
        finalize: bool,
        mut emit: impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), InflateError<E>> {
        if self.ended {
            return Ok(());
        }
        let scratch = 0u8;
        self.stream.src_ptr = if input.is_empty() {
            &scratch
        } else {
            input.as_ptr()
        };
        self.stream.src_size = input.len();
        let flags = if finalize { STREAM_FINALIZE } else { 0 };
        let mut stalled = 0;
        loop {
            self.stream.dst_ptr = self.window.as_mut_ptr();
            self.stream.dst_size = self.window.len();
            // SAFETY: the source describes `input` (or no byte of `scratch`)
            // and the destination this decoder's own window; both outlive
            // the call, and the stream was initialized in `new`.
            let status = unsafe { compression_stream_process(&mut *self.stream, flags) };
            let produced = self.window.len() - self.stream.dst_size;
            if produced > 0 {
                emit(&self.window[..produced]).map_err(InflateError::Sink)?;
            }
            match status {
                STATUS_END => {
                    self.ended = true;
                    return Ok(());
                }
                STATUS_OK => {
                    if self.stream.src_size == 0 {
                        if !finalize && produced < self.window.len() {
                            return Ok(());
                        }
                        stalled = if produced == 0 { stalled + 1 } else { 0 };
                        if stalled > 2 {
                            return Err(InflateError::Truncated);
                        }
                    }
                }
                _ => return Err(InflateError::DecompressionFailed),
            }
        }
    }
}

impl Drop for RawInflate {
    fn drop(&mut self) {
        // SAFETY: initialized in `new` and destroyed exactly once, here.
        unsafe { compression_stream_destroy(&mut *self.stream) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `zlib.compressobj(9, zlib.DEFLATED, -15)` of 3 × "hello, flash bundle\n".
    const HELLO: &[u8] = &[
        0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x48, 0xcb, 0x49, 0x2c, 0xce, 0x50, 0x48, 0x2a,
        0xcd, 0x4b, 0xc9, 0x49, 0xe5, 0xca, 0x20, 0x52, 0x0c, 0x00,
    ];

    fn decode(chunks: &[&[u8]]) -> Result<Vec<u8>, InflateError<()>> {
        let mut inflate = RawInflate::new().unwrap();
        let mut out = Vec::new();
        for chunk in chunks {
            inflate.feed(chunk, false, |window| {
                out.extend_from_slice(window);
                Ok(())
            })?;
        }
        inflate.feed(&[], true, |window| {
            out.extend_from_slice(window);
            Ok(())
        })?;
        Ok(out)
    }

    #[test]
    fn decodes_a_raw_stream_in_any_input_split_and_ignores_what_follows_its_end() {
        let expected = "hello, flash bundle\n".repeat(3).into_bytes();
        assert_eq!(decode(&[HELLO]).unwrap(), expected);
        for split in 1..HELLO.len() {
            assert_eq!(
                decode(&[&HELLO[..split], &HELLO[split..]]).unwrap(),
                expected
            );
        }
        // A gzip trailer after the final block is not decoded.
        assert_eq!(decode(&[HELLO, b"trailer!"]).unwrap(), expected);
    }

    #[test]
    fn a_stream_cut_short_or_malformed_is_refused() {
        // Finalized before its last block, the library refuses the stream
        // itself, as Swift's decoder sees it refuse.
        assert_eq!(
            decode(&[&HELLO[..HELLO.len() - 3]]),
            Err(InflateError::DecompressionFailed)
        );
        assert_eq!(
            decode(&[&[0xff; 32]]),
            Err(InflateError::DecompressionFailed)
        );
        // The sink's refusal ends decoding with the sink's own error.
        let mut inflate = RawInflate::new().unwrap();
        assert_eq!(
            inflate.feed(HELLO, true, |_| Err("full")),
            Err(InflateError::Sink("full"))
        );
    }
}
