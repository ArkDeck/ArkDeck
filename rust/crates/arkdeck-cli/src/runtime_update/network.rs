//! Closed production update URL policy. Foundation supplies URL syntax and
//! query encoding; every permission decision stays in Rust.
use super::ProductIdentity;
use arkdeck_platform::{host_url_with_query, host_url_without_query_names, inspect_host_url};

pub const FEED_URL: &str =
    "https://github.com/ArkDeck/ArkDeck/releases/latest/download/arkdeck-update-feed-v1.json";
pub const ACCEPT: &str = "application/vnd.arkdeck.update-feed.v1+json";
pub const USER_AGENT: &str = "ArkDeck-Update/1";
const HOSTS: [&str; 3] = [
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkError {
    InvalidInitialURL,
    InvalidRequest,
    InvalidResponse,
    HttpStatus(i64),
    ResponseTooLarge,
    RedirectLimitExceeded,
    RedirectRejected,
    Transport(i64),
}

#[derive(Debug, PartialEq, Eq)]
pub enum StreamFailure<E> {
    Network(NetworkError),
    Cancelled,
    Sink(E),
}

struct Stream<C, W> {
    maximum: u64,
    received: u64,
    redirects: usize,
    cancel: C,
    write: W,
}
impl<C, W, E> arkdeck_platform::UpdateHttpEvents for Stream<C, W>
where
    C: FnMut() -> bool + Send,
    W: FnMut(&[u8]) -> Result<(), E> + Send,
    E: Send,
{
    type Error = StreamFailure<E>;
    fn response(&mut self, status: i64, expected_length: i64) -> Result<(), Self::Error> {
        if status < 0 {
            return Err(StreamFailure::Network(NetworkError::InvalidResponse));
        }
        if status != 200 {
            return Err(StreamFailure::Network(NetworkError::HttpStatus(status)));
        }
        if expected_length > 0 && expected_length as u64 > self.maximum {
            return Err(StreamFailure::Network(NetworkError::ResponseTooLarge));
        }
        Ok(())
    }
    fn data(&mut self, bytes: &[u8]) -> Result<(), Self::Error> {
        if (self.cancel)() {
            return Err(StreamFailure::Cancelled);
        }
        if bytes.len() as u64 > self.maximum.saturating_sub(self.received) {
            return Err(StreamFailure::Network(NetworkError::ResponseTooLarge));
        }
        self.received += bytes.len() as u64;
        (self.write)(bytes).map_err(StreamFailure::Sink)
    }
    fn redirect(&mut self, proposed: &str) -> Result<String, Self::Error> {
        self.redirects += 1;
        redirect_url(proposed, self.redirects).map_err(StreamFailure::Network)
    }
    fn cancelled(&mut self) -> bool {
        (self.cancel)()
    }
}

pub fn stream_url<C, W, E>(
    url: &str,
    maximum: u64,
    cancel: C,
    write: W,
) -> Result<(), StreamFailure<E>>
where
    C: FnMut() -> bool + Send,
    W: FnMut(&[u8]) -> Result<(), E> + Send,
    E: Send,
{
    validate(url).map_err(StreamFailure::Network)?;
    let mut events = Stream {
        maximum,
        received: 0,
        redirects: 0,
        cancel,
        write,
    };
    use arkdeck_platform::{UpdateHttpError, UpdateHttpRequest};
    match arkdeck_platform::stream_update_http(
        &UpdateHttpRequest {
            url,
            accept: ACCEPT,
            user_agent: USER_AGENT,
        },
        &mut events,
    ) {
        Ok(()) => Ok(()),
        Err(UpdateHttpError::Callback(error)) => Err(error),
        Err(UpdateHttpError::Cancelled) => Err(StreamFailure::Cancelled),
        Err(UpdateHttpError::Network(code)) => {
            Err(StreamFailure::Network(NetworkError::Transport(code)))
        }
        Err(UpdateHttpError::InvalidRequest) => {
            Err(StreamFailure::Network(NetworkError::InvalidRequest))
        }
        Err(UpdateHttpError::NativeException | UpdateHttpError::CallbackPanicked) => {
            Err(StreamFailure::Network(NetworkError::InvalidResponse))
        }
    }
}

fn validate(url: &str) -> Result<(), NetworkError> {
    let parts = inspect_host_url(url).ok_or(NetworkError::RedirectRejected)?;
    if parts.scheme.as_deref() != Some("https")
        || parts.user.is_some()
        || parts.password.is_some()
        || parts.port.is_some()
        || parts.fragment.is_some()
        || !parts
            .host
            .as_ref()
            .is_some_and(|host| HOSTS.contains(&host.to_ascii_lowercase().as_str()))
    {
        return Err(NetworkError::RedirectRejected);
    }
    Ok(())
}

pub fn feed_url(identity: &ProductIdentity) -> Result<String, NetworkError> {
    let url = host_url_with_query(
        FEED_URL,
        &[
            ("appVersion", Some(identity.app_version.as_str())),
            ("osVersion", Some(identity.system_version.as_str())),
            ("arch", Some(identity.architecture.as_str())),
        ],
    )
    .ok_or(NetworkError::InvalidInitialURL)?;
    validate(&url)?;
    Ok(url)
}

pub fn artifact_url(signed_url: &str) -> Result<String, NetworkError> {
    let parts = inspect_host_url(signed_url).ok_or(NetworkError::InvalidInitialURL)?;
    if parts.canonical != signed_url {
        return Err(NetworkError::InvalidInitialURL);
    }
    validate(signed_url)?;
    Ok(signed_url.to_owned())
}

pub fn redirect_url(proposed: &str, count: usize) -> Result<String, NetworkError> {
    if count > 5 {
        return Err(NetworkError::RedirectLimitExceeded);
    }
    let url = host_url_without_query_names(proposed, &["appVersion", "osVersion", "arch"])
        .ok_or(NetworkError::RedirectRejected)?;
    validate(&url)?;
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn result(value: Result<String, NetworkError>) -> (Value, Value) {
        match value {
            Ok(url) => (json!(url), Value::Null),
            Err(error) => {
                let name = match error {
                    NetworkError::InvalidInitialURL => "invalidInitialURL",
                    NetworkError::RedirectRejected => "redirectRejected",
                    NetworkError::RedirectLimitExceeded => "redirectLimitExceeded",
                    other => panic!("unexpected error: {other:?}"),
                };
                (Value::Null, json!(name))
            }
        }
    }

    #[test]
    fn actual_swift_request_and_redirect_oracle_replays() {
        let oracle: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/urls.json"
        ))
        .unwrap();
        for row in oracle["artifacts"].as_array().unwrap() {
            let input = row["input"].as_str().unwrap();
            let (url, error) = result(artifact_url(input));
            assert_eq!(
                (url, error),
                (row["url"].clone(), row["error"].clone()),
                "{input}"
            );
        }
        for row in oracle["redirects"].as_array().unwrap() {
            let proposed = row["proposed"].as_str().unwrap();
            let (url, error) = result(redirect_url(
                proposed,
                row["count"].as_u64().unwrap() as usize,
            ));
            assert_eq!(
                (url, error),
                (row["url"].clone(), row["error"].clone()),
                "{proposed}"
            );
        }
        for row in oracle["feeds"].as_array().unwrap() {
            let identity = ProductIdentity {
                app_version: row["appVersion"].as_str().unwrap().into(),
                system_version: row["osVersion"].as_str().unwrap().into(),
                architecture: row["architecture"].as_str().unwrap().into(),
            };
            assert_eq!(feed_url(&identity).unwrap(), row["url"]);
            assert_eq!(ACCEPT, row["accept"]);
            assert_eq!(USER_AGENT, row["userAgent"]);
            assert_eq!(row["method"], "GET");
            assert_eq!(row["cookies"], false);
        }
    }
}
