//! Acceptance predicate for the pinned macOS ISO8601Timestamps.parse reader.
//! This is Date.ISO8601FormatStyle (Swift 6.2), not ISO8601DateFormatter or the
//! stricter Session timestamp validator. Dates are retained in their original
//! spelling; the History/display-name projections do not convert them to time.
//!
//! Upstream reference: swiftlang/swift-foundation, swift-6.2-RELEASE,
//! DateComponents+ISO8601FormatStyle.swift and Calendar_Gregorian.swift.
//! Actual Swift store comparisons pin platform behavior, including permissive
//! component normalization and trailing text. Newer upstream parsing differs.

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl Reader<'_> {
    fn take(&mut self, byte: u8) -> bool {
        if self.bytes.get(self.offset) != Some(&byte) {
            return false;
        }
        self.offset += 1;
        true
    }

    fn expect(&mut self, byte: u8) -> Option<()> {
        self.take(byte).then_some(())
    }

    fn digits(&mut self, maximum: usize) -> Option<u64> {
        let start = self.offset;
        let mut value = 0;
        while self.offset - start < maximum {
            let Some(digit) = self.bytes.get(self.offset).filter(|d| d.is_ascii_digit()) else {
                break;
            };
            value = value * 10 + u64::from(digit - b'0');
            self.offset += 1;
        }
        (self.offset != start).then_some(value)
    }

    fn timezone(&mut self) -> Option<()> {
        if self.take(b'Z') || self.take(b'z') {
            return Some(());
        }
        if self
            .bytes
            .get(self.offset..self.offset + 3)
            .is_some_and(|v| v.eq_ignore_ascii_case(b"GMT") || v.eq_ignore_ascii_case(b"UTC"))
        {
            self.offset += 3;
            if !matches!(self.bytes.get(self.offset), Some(b'+' | b'-')) {
                return Some(());
            }
        }
        if !self.take(b'+') && !self.take(b'-') {
            return None;
        }
        let hours = self.digits(2)?;
        let mut seconds = hours * 3600;
        if self.take(b':') || self.bytes.get(self.offset).is_some_and(u8::is_ascii_digit) {
            seconds += self.digits(2)? * 60;
            self.take(b':');
            if self.bytes.get(self.offset).is_some_and(u8::is_ascii_digit) {
                seconds += self.digits(2)?;
            }
        }
        // TimeZone(secondsFromGMT:) accepts both endpoints. Individual offset
        // minutes/seconds are not range-checked by the pinned FormatStyle.
        (seconds <= 18 * 3600).then_some(())
    }

    fn parse(&mut self) -> Option<()> {
        let year = self.digits(10)?;
        self.expect(b'-')?;
        let month = self.digits(10)?;
        self.expect(b'-')?;
        let day = self.digits(10)?;
        self.expect(b'T')?;
        let hour = self.digits(10)?;
        self.expect(b':')?;
        let minute = self.digits(10)?;
        self.expect(b':')?;
        let second = self.digits(10)?;
        if self.take(b'.') {
            let start = self.offset;
            self.digits(10)?;
            if self.offset - start > 9 {
                return None;
            }
        }
        // FormatStyle checks the calendar's maximum month/day ranges, then
        // CalendarGregorian checks supported component sizes. It normalizes
        // dates such as February 31 and times such as 24:00:01 or second 61.
        if year > 506_714
            || !(1..=12).contains(&month)
            || !(1..=31).contains(&day)
            || [hour, minute, second].iter().any(|v| *v > i32::MAX as u64)
        {
            return None;
        }
        // The public parse method discards the consumed end index.
        self.timezone()
    }
}

pub(crate) fn valid_format_timestamp(value: &str) -> bool {
    Reader {
        bytes: value.as_bytes(),
        offset: 0,
    }
    .parse()
    .is_some()
}
