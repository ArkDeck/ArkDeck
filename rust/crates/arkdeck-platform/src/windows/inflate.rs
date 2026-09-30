//! Raw DEFLATE decoding (RFC 1951, no zlib or gzip framing) on Windows, in
//! place of Apple's Compression library that `host_inflate.rs` drives on
//! macOS (TASK-XPA-010). Windows ships no raw DEFLATE decoder, so this is a
//! decoder of its own: the same `RawInflate` surface, fed in any split and
//! handing its output on in windows of at most 1 MiB, with the answers the
//! macOS decoder gives. A malformed stream, and a stream finalized before its
//! final block, are `DecompressionFailed`, as the library refuses both; input
//! after the final block is ignored, as Swift ignores the gzip trailer.
//!
//! The decoder keeps the input it has not consumed and resumes at the last
//! whole unit (a block header with its code tables, one literal, one
//! length/distance pair, or a run of stored bytes), so no unit ever depends
//! on input that has not arrived. It keeps the last 32 KiB of output as the
//! history back-references read. Code sets are judged as zlib judges them:
//! over-subscribed sets and incomplete ones (other than a single one-bit
//! code) are refused.

/// Swift `GzipTarArchiveReader.chunkSizeBytes`: the output window.
pub const INFLATE_WINDOW_BYTES: usize = 1 << 20;

/// The furthest back a distance may reach.
const HISTORY_BYTES: usize = 32 * 1024;

/// Why decoding stopped: the stream is malformed or was finalized before its
/// final block (`decompressionFailed`), input ran out before the final block
/// (`truncatedArchive`, which this decoder, like the library, reports as a
/// refused stream), or the caller's sink refused a window.
#[derive(Debug, PartialEq, Eq)]
pub enum InflateError<E> {
    DecompressionFailed,
    Truncated,
    Sink(E),
}

/// A canonical Huffman code as one lookup table indexed by the next
/// `bits` input bits (least significant first): each entry is the symbol and
/// its code length, or length 0 where no code leads.
struct Code {
    bits: u32,
    table: Vec<(u16, u8)>,
}

impl Code {
    /// The code of `lengths` (0 for an unused symbol), or `None` when the set
    /// is over-subscribed, or incomplete — which zlib lets pass only for a
    /// literal or distance code whose longest code is one bit.
    fn new(lengths: &[u8], single_allowed: bool) -> Option<Self> {
        let mut counts = [0u16; 16];
        for &length in lengths {
            counts[usize::from(length)] += 1;
        }
        counts[0] = 0;
        let bits = (1..16)
            .rev()
            .find(|&length| counts[length] > 0)
            .unwrap_or(0) as u32;
        // Kraft's inequality: what is left of the code space at each length.
        let mut left: i32 = 1;
        for &count in &counts[1..] {
            left = left * 2 - i32::from(count);
            if left < 0 {
                return None;
            }
        }
        let used: u16 = counts[1..].iter().sum();
        if left > 0 && used != 0 && !(single_allowed && bits == 1) {
            return None;
        }
        let mut next = [0u32; 16];
        let mut code = 0u32;
        for length in 1..16 {
            code = (code + u32::from(counts[length - 1])) << 1;
            next[length] = code;
        }
        let size = 1usize << bits;
        let mut table = vec![(0u16, 0u8); size.max(1)];
        for (symbol, &length) in lengths.iter().enumerate() {
            if length == 0 {
                continue;
            }
            let length_bits = u32::from(length);
            let canonical = next[usize::from(length)];
            next[usize::from(length)] += 1;
            let reversed = canonical.reverse_bits() >> (32 - length_bits);
            let mut index = reversed as usize;
            while index < size {
                table[index] = (symbol as u16, length);
                index += 1 << length_bits;
            }
        }
        Some(Self { bits, table })
    }
}

enum State {
    Header,
    Stored { remaining: usize },
    Codes { literals: Code, distances: Code },
}

/// A unit that could not be decoded yet.
enum Stop {
    NeedInput,
    Malformed,
}

const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LENGTH_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DISTANCE_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DISTANCE_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];
/// The order the code-length code's lengths are sent in.
const CODE_LENGTH_ORDER: [usize; 19] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

/// One raw DEFLATE stream being decoded. Once its final block has been
/// decoded, further input is ignored, as Swift ignores the gzip trailer.
pub struct RawInflate {
    /// Input not yet consumed, from the byte holding `bit`.
    input: Vec<u8>,
    bit: usize,
    state: State,
    last_block: bool,
    /// The history (the last output, at most 32 KiB of it before `fresh`)
    /// and the output not yet handed on (from `fresh`).
    output: Vec<u8>,
    fresh: usize,
    ended: bool,
}

impl RawInflate {
    /// A decoder; `Option` as the macOS decoder's, which the library may
    /// refuse to start.
    pub fn new() -> Option<Self> {
        Some(Self {
            input: Vec::new(),
            bit: 0,
            state: State::Header,
            last_block: false,
            output: Vec::new(),
            fresh: 0,
            ended: false,
        })
    }

    /// Swift `RawDeflateDecompressor.feed(_:finalize:emit:)`: decodes `input`,
    /// handing each full window to `emit` as it fills and what is left once
    /// the input is consumed; with `finalize`, the stream must end within
    /// what it was given.
    pub fn feed<E>(
        &mut self,
        input: &[u8],
        finalize: bool,
        mut emit: impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), InflateError<E>> {
        if self.ended {
            return Ok(());
        }
        self.input.extend_from_slice(input);
        let result = loop {
            match self.unit() {
                Ok(true) => break Ok(()),
                Ok(false) => {}
                Err(Stop::NeedInput) if finalize => break Err(InflateError::DecompressionFailed),
                Err(Stop::NeedInput) => break Ok(()),
                Err(Stop::Malformed) => break Err(InflateError::DecompressionFailed),
            }
            while self.output.len() - self.fresh >= INFLATE_WINDOW_BYTES {
                let end = self.fresh + INFLATE_WINDOW_BYTES;
                emit(&self.output[self.fresh..end]).map_err(InflateError::Sink)?;
                self.fresh = end;
                self.keep_history();
            }
        };
        // What was decoded is handed on whether or not the stream then
        // failed, as the library hands on what it produced before refusing.
        if self.output.len() > self.fresh {
            emit(&self.output[self.fresh..]).map_err(InflateError::Sink)?;
            self.fresh = self.output.len();
            self.keep_history();
        }
        let consumed = self.bit / 8;
        self.input.drain(..consumed);
        self.bit -= consumed * 8;
        result
    }

    fn keep_history(&mut self) {
        let keep_from = self.fresh.saturating_sub(HISTORY_BYTES);
        if keep_from > 0 {
            self.output.drain(..keep_from);
            self.fresh -= keep_from;
        }
    }

    /// `n` (at most 32) bits at `at`, least significant first.
    fn peek(&self, at: usize, n: u32) -> Option<u32> {
        if n == 0 {
            return Some(0);
        }
        if at + n as usize > self.input.len() * 8 {
            return None;
        }
        let mut value: u64 = 0;
        let first = at / 8;
        let last = (at + n as usize - 1) / 8;
        for (shift, byte) in self.input[first..=last].iter().enumerate() {
            value |= u64::from(*byte) << (8 * shift);
        }
        Some(((value >> (at % 8)) & ((1u64 << n) - 1)) as u32)
    }

    fn take(&self, at: &mut usize, n: u32) -> Result<u32, Stop> {
        let value = self.peek(*at, n).ok_or(Stop::NeedInput)?;
        *at += n as usize;
        Ok(value)
    }

    /// The next symbol of `code` at `at`.
    fn symbol(&self, code: &Code, at: &mut usize) -> Result<u16, Stop> {
        let available = (self.input.len() * 8).saturating_sub(*at);
        let bits = code.bits.min(available.min(32) as u32);
        let index = self.peek(*at, bits).ok_or(Stop::NeedInput)? as usize;
        let (symbol, length) = code.table[index];
        if length == 0 {
            return Err(if bits < code.bits {
                Stop::NeedInput
            } else {
                Stop::Malformed
            });
        }
        if u32::from(length) > bits {
            return Err(Stop::NeedInput);
        }
        *at += usize::from(length);
        Ok(symbol)
    }

    /// Decodes one whole unit, or nothing: `true` once the final block ended.
    fn unit(&mut self) -> Result<bool, Stop> {
        let mut at = self.bit;
        match std::mem::replace(&mut self.state, State::Header) {
            // Nothing of a unit is kept until all of it has been read: an
            // unfinished unit leaves `bit` where it began.
            State::Header => {
                let header = self.take(&mut at, 3)?;
                let last = header & 1 == 1;
                self.state = match header >> 1 {
                    0 => {
                        at = at.div_ceil(8) * 8;
                        let length = self.take(&mut at, 16)?;
                        let complement = self.take(&mut at, 16)?;
                        if length != !complement & 0xffff {
                            return Err(Stop::Malformed);
                        }
                        State::Stored {
                            remaining: length as usize,
                        }
                    }
                    1 => fixed(),
                    2 => self.dynamic(&mut at)?,
                    _ => return Err(Stop::Malformed),
                };
                self.last_block = last;
                self.bit = at;
                Ok(false)
            }
            State::Stored { remaining } => {
                if remaining == 0 {
                    return Ok(self.block_ended());
                }
                let start = self.bit / 8;
                let available = self.input.len() - start;
                if available == 0 {
                    self.state = State::Stored { remaining };
                    return Err(Stop::NeedInput);
                }
                let count = remaining.min(available).min(INFLATE_WINDOW_BYTES);
                self.output
                    .extend_from_slice(&self.input[start..start + count]);
                self.bit += count * 8;
                self.state = State::Stored {
                    remaining: remaining - count,
                };
                Ok(false)
            }
            State::Codes {
                literals,
                distances,
            } => {
                let result = self.pair(&literals, &distances, &mut at);
                self.state = State::Codes {
                    literals,
                    distances,
                };
                match result? {
                    None => {
                        self.bit = at;
                        Ok(self.block_ended())
                    }
                    Some(()) => {
                        self.bit = at;
                        Ok(false)
                    }
                }
            }
        }
    }

    /// After a block's end: the stream's end, or the next block's header.
    fn block_ended(&mut self) -> bool {
        self.state = State::Header;
        if self.last_block {
            self.ended = true;
        }
        self.last_block
    }

    /// One literal or one length/distance pair; `None` at the block's end.
    fn pair(
        &mut self,
        literals: &Code,
        distances: &Code,
        at: &mut usize,
    ) -> Result<Option<()>, Stop> {
        let symbol = self.symbol(literals, at)?;
        match symbol {
            0..=255 => {
                self.output.push(symbol as u8);
                Ok(Some(()))
            }
            256 => Ok(None),
            257..=285 => {
                let index = usize::from(symbol - 257);
                let length = usize::from(LENGTH_BASE[index])
                    + self.take(at, u32::from(LENGTH_EXTRA[index]))? as usize;
                let symbol = usize::from(self.symbol(distances, at)?);
                if symbol >= 30 {
                    return Err(Stop::Malformed);
                }
                let distance = usize::from(DISTANCE_BASE[symbol])
                    + self.take(at, u32::from(DISTANCE_EXTRA[symbol]))? as usize;
                if distance > self.output.len() {
                    return Err(Stop::Malformed);
                }
                let from = self.output.len() - distance;
                for offset in 0..length {
                    let byte = self.output[from + offset];
                    self.output.push(byte);
                }
                Ok(Some(()))
            }
            _ => Err(Stop::Malformed),
        }
    }

    /// A dynamic block's code tables, read whole.
    fn dynamic(&self, at: &mut usize) -> Result<State, Stop> {
        let literal_count = self.take(at, 5)? as usize + 257;
        let distance_count = self.take(at, 5)? as usize + 1;
        let length_code_count = self.take(at, 4)? as usize + 4;
        if literal_count > 286 || distance_count > 30 {
            return Err(Stop::Malformed);
        }
        let mut code_lengths = [0u8; 19];
        for &position in &CODE_LENGTH_ORDER[..length_code_count] {
            code_lengths[position] = self.take(at, 3)? as u8;
        }
        let length_code = Code::new(&code_lengths, false).ok_or(Stop::Malformed)?;
        if length_code.bits == 0 {
            return Err(Stop::Malformed);
        }
        let total = literal_count + distance_count;
        let mut lengths = Vec::with_capacity(total);
        while lengths.len() < total {
            let symbol = self.symbol(&length_code, at)?;
            let (value, repeat) = match symbol {
                0..=15 => (symbol as u8, 1),
                16 => {
                    let previous = *lengths.last().ok_or(Stop::Malformed)?;
                    (previous, 3 + self.take(at, 2)? as usize)
                }
                17 => (0, 3 + self.take(at, 3)? as usize),
                _ => (0, 11 + self.take(at, 7)? as usize),
            };
            if lengths.len() + repeat > total {
                return Err(Stop::Malformed);
            }
            lengths.extend(std::iter::repeat_n(value, repeat));
        }
        if lengths[256] == 0 {
            return Err(Stop::Malformed);
        }
        let literals = Code::new(&lengths[..literal_count], true).ok_or(Stop::Malformed)?;
        let distances = Code::new(&lengths[literal_count..], true).ok_or(Stop::Malformed)?;
        Ok(State::Codes {
            literals,
            distances,
        })
    }
}

/// The fixed codes of a type 1 block.
fn fixed() -> State {
    let mut literals = [0u8; 288];
    literals[..144].fill(8);
    literals[144..256].fill(9);
    literals[256..280].fill(7);
    literals[280..].fill(8);
    State::Codes {
        literals: Code::new(&literals, false).expect("the fixed literal code is complete"),
        // All 32 five-bit codes; 30 and 31 are refused where they are read.
        distances: Code::new(&[5; 32], false).expect("the fixed distance code is complete"),
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
                assert!(window.len() <= INFLATE_WINDOW_BYTES);
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
        let bytes: Vec<&[u8]> = HELLO.chunks(1).collect();
        assert_eq!(decode(&bytes).unwrap(), expected);
        // A gzip trailer after the final block is not decoded.
        assert_eq!(decode(&[HELLO, b"trailer!"]).unwrap(), expected);
    }

    #[test]
    fn a_stream_cut_short_or_malformed_is_refused() {
        assert_eq!(
            decode(&[&HELLO[..HELLO.len() - 3]]),
            Err(InflateError::DecompressionFailed)
        );
        assert_eq!(
            decode(&[&[0xff; 32]]),
            Err(InflateError::DecompressionFailed)
        );
        // A stored block whose length's complement is wrong.
        assert_eq!(
            decode(&[&[0x01, 0x02, 0x00, 0x00, 0x00, b'a', b'b']]),
            Err(InflateError::DecompressionFailed)
        );
        // A distance before the start of the output.
        assert_eq!(
            decode(&[&[0x03, 0x02]]),
            Err(InflateError::DecompressionFailed)
        );
        let mut inflate = RawInflate::new().unwrap();
        assert_eq!(
            inflate.feed(HELLO, true, |_| Err("full")),
            Err(InflateError::Sink("full"))
        );
    }

    #[test]
    fn stored_blocks_and_output_past_a_window_leave_in_windows() {
        // Two stored blocks: 1 MiB + 1 byte of `x`, then `yz`, in one stream.
        let mut stream = Vec::new();
        let first = INFLATE_WINDOW_BYTES + 1;
        let mut left = first;
        while left > 0 {
            let count = left.min(0xffff);
            left -= count;
            stream.push(0x00);
            stream.extend_from_slice(&(count as u16).to_le_bytes());
            stream.extend_from_slice(&(!(count as u16)).to_le_bytes());
            stream.extend(std::iter::repeat_n(b'x', count));
        }
        stream.extend_from_slice(&[0x01, 0x02, 0x00, 0xfd, 0xff, b'y', b'z']);
        let mut inflate = RawInflate::new().unwrap();
        let mut windows = Vec::new();
        for chunk in stream.chunks(4099) {
            inflate
                .feed(chunk, false, |window| {
                    windows.push(window.to_vec());
                    Ok::<(), ()>(())
                })
                .unwrap();
        }
        inflate
            .feed(&[], true, |window| {
                windows.push(window.to_vec());
                Ok::<(), ()>(())
            })
            .unwrap();
        assert!(
            windows
                .iter()
                .all(|window| window.len() <= INFLATE_WINDOW_BYTES)
        );
        let all: Vec<u8> = windows.concat();
        assert_eq!(all.len(), first + 2);
        assert!(all[..first].iter().all(|byte| *byte == b'x'));
        assert_eq!(&all[first..], b"yz");
    }
}
