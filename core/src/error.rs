use std::fmt;

/// Error returned by every core operation.
///
/// `code` is a stable, machine-readable identifier shared by all hosts (it is
/// part of the contract fixtures). `message` is for logs only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreError {
    pub code: &'static str,
    pub message: String,
}

impl CoreError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid_input(message: impl Into<String>) -> Self {
        Self::new("invalid_input", message)
    }

    pub fn io(context: &str, error: std::io::Error) -> Self {
        Self::new("io_error", format!("{context}: {error}"))
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for CoreError {}

pub type CoreResult<T> = Result<T, CoreError>;
