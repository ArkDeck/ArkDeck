//! Same-connection health verification; no reconnect or replay of lost replies.

use arkdeck_contract::{
    ContractError, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, Request, Response, WireError,
    decode_request, decode_response, encode_frame, validate_health,
};
use arkdeck_platform::{LocalConnection, LocalEndpoint, ServerIdentity};
use serde_json::{Map, Value};
use std::fmt;
use std::io::{self, BufReader, Read, Write};
use std::time::Duration;

#[derive(Debug)]
pub enum ClientError {
    Transport(io::Error),
    Contract(ContractError),
    Remote(WireError),
    ConnectionUnusable,
}
impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(error) => write!(f, "local Runtime transport failed: {error}"),
            Self::Contract(error) => write!(f, "local Runtime contract validation failed: {error}"),
            Self::Remote(error) => write!(f, "{}: {}", error.code, error.message),
            Self::ConnectionUnusable => f.write_str(
                "the connection is unusable after an incomplete exchange; no request was replayed",
            ),
        }
    }
}
impl std::error::Error for ClientError {}
impl From<io::Error> for ClientError {
    fn from(error: io::Error) -> Self {
        Self::Transport(error)
    }
}
impl From<ContractError> for ClientError {
    fn from(error: ContractError) -> Self {
        Self::Contract(error)
    }
}

pub struct Client<S: Read + Write> {
    stream: BufReader<S>,
    verified: bool,
    unusable: bool,
}

impl Client<LocalConnection> {
    pub fn connect(
        endpoint: &LocalEndpoint,
        identity: &ServerIdentity,
        timeout: Duration,
    ) -> Result<Self, ClientError> {
        let connection = LocalConnection::connect(endpoint, identity)?;
        connection.set_read_timeout(Some(timeout))?;
        connection.set_write_timeout(Some(timeout))?;
        Ok(Self::new(connection))
    }
}

impl<S: Read + Write> Client<S> {
    /// The transport must already have authenticated its peer. The public
    /// LocalConnection constructor completes OS identity checks before this.
    pub fn new(stream: S) -> Self {
        Self {
            stream: BufReader::new(stream),
            verified: false,
            unusable: false,
        }
    }

    pub fn request(
        &mut self,
        id: &str,
        method: &str,
        params: Option<Map<String, Value>>,
    ) -> Result<Value, ClientError> {
        if self.unusable {
            return Err(ClientError::ConnectionUnusable);
        }
        let request = Request::new(id, method, params);
        // Refuse malformed local input before even the health frame is sent.
        let frame = encode_frame(&request, MAX_REQUEST_BYTES)?;
        decode_request(&frame[..frame.len() - 1])?;
        let result = self.request_inner(request);
        if matches!(
            result,
            Err(ClientError::Transport(_) | ClientError::Contract(_))
        ) {
            self.unusable = true;
        }
        result
    }

    fn request_inner(&mut self, request: Request) -> Result<Value, ClientError> {
        if !self.verified {
            let health = self.exchange(&Request::new("health", "health", None))?;
            validate_health(&health)?;
            self.verified = true;
        }
        self.exchange(&request)?
            .outcome
            .map_err(ClientError::Remote)
    }

    fn exchange(&mut self, request: &Request) -> Result<Response, ClientError> {
        let frame = encode_frame(request, MAX_REQUEST_BYTES)?;
        self.stream.get_mut().write_all(&frame)?;
        self.stream.get_mut().flush()?;
        let payload = read_frame(&mut self.stream, MAX_RESPONSE_BYTES)?;
        Ok(decode_response(&payload, &request.id, &request.method)?)
    }
}

pub use arkdeck_platform::read_frame;
