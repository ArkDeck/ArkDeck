use std::io::{self, BufRead};

/// LF counts toward the byte limit, as it does in the Swift framing contract.
/// Unterminated EOF is a lost reply; it is never interpreted as a complete frame.
pub fn read_frame(reader: &mut impl BufRead, limit: usize) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete control frame",
            ));
        }
        let end = buffer.iter().position(|b| *b == b'\n');
        let consumed = end.map_or(buffer.len(), |index| index + 1);
        if output.len().saturating_add(consumed) > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame exceeds its limit",
            ));
        }
        output.extend_from_slice(&buffer[..consumed]);
        reader.consume(consumed);
        if end.is_some() {
            output.pop();
            return Ok(output);
        }
        if output.len() == limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame lacks its bounded delimiter",
            ));
        }
    }
}
