/// Conservative failure vocabulary shared with Swift's
/// `HDCSemanticOutputParser`. Exit zero alone is never success.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandFailure {
    NonZeroExit(i32),
    ExplicitFailureMarker,
    Unauthorized,
    Offline,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandOutcome {
    Success,
    Failure(CommandFailure),
    UnknownOutput,
}

/// Bounded streaming classifier for the existing command-result vocabulary.
///
/// Call `consume` in actual stream-delivery order. The rolling window survives
/// both chunk and stream boundaries, as in the Swift oracle. This parser does
/// not grant a command a registered success binding and does not execute it.
#[derive(Default)]
pub struct SemanticOutputParser {
    tail: [u8; 16],
    used: usize,
    saw_success: bool,
    failure: Option<CommandFailure>,
}

impl SemanticOutputParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn consume(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.tail.rotate_left(1);
            self.tail[15] = byte.to_ascii_lowercase();
            self.used = (self.used + 1).min(16);
            let tail = &self.tail[16 - self.used..];
            if [b"unauthorized".as_slice(), b"e000002", b"e000003"]
                .iter()
                .any(|marker| tail.ends_with(marker))
            {
                self.failure = Some(CommandFailure::Unauthorized);
            } else if tail.ends_with(b"offline") {
                if !matches!(self.failure, Some(CommandFailure::Unauthorized)) {
                    self.failure = Some(CommandFailure::Offline);
                }
            } else if [b"[fail]".as_slice(), b"fail!", b"errorcode"]
                .iter()
                .any(|marker| tail.ends_with(marker))
            {
                if self.failure.is_none() {
                    self.failure = Some(CommandFailure::ExplicitFailureMarker);
                }
            } else if tail.ends_with(b"[success]") {
                self.saw_success = true;
            }
        }
    }

    pub fn finish(&self, exit_code: i32) -> CommandOutcome {
        if exit_code != 0 {
            return CommandOutcome::Failure(CommandFailure::NonZeroExit(exit_code));
        }
        if let Some(failure) = &self.failure {
            return CommandOutcome::Failure(failure.clone());
        }
        if self.saw_success {
            CommandOutcome::Success
        } else {
            CommandOutcome::UnknownOutput
        }
    }
}
