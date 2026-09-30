//! The wire failures a Job snapshot read answers with, shared by the Job
//! record reader and the Job events reader.
use arkdeck_contract::WireError;

pub(crate) fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}
pub(crate) fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "The Runtime Job snapshot is unreadable or unsupported",
    )
}
