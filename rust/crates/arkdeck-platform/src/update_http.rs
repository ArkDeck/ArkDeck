//! A bounded, synchronous lifetime around the macOS URLSession SDK delegate.
//! Callers own URL policy, budgets and durable effects. No Swift runtime or
//! caller-selected executable is involved.
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

pub struct UpdateHttpRequest<'a> {
    pub url: &'a str,
    pub accept: &'a str,
    pub user_agent: &'a str,
}

#[derive(Debug, PartialEq, Eq)]
pub enum UpdateHttpError<E> {
    InvalidRequest,
    Network(i64),
    Cancelled,
    NativeException,
    CallbackPanicked,
    Callback(E),
}

pub trait UpdateHttpEvents: Send {
    type Error: Send;
    fn response(&mut self, status: i64, expected_length: i64) -> Result<(), Self::Error>;
    fn data(&mut self, bytes: &[u8]) -> Result<(), Self::Error>;
    fn redirect(&mut self, proposed: &str) -> Result<String, Self::Error>;
    fn cancelled(&mut self) -> bool;
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {
    fn arkdeck_update_http(
        url: *const c_char,
        accept: *const c_char,
        user_agent: *const c_char,
        context: *mut c_void,
        response: unsafe extern "C" fn(*mut c_void, i64, i64) -> c_int,
        data: unsafe extern "C" fn(*mut c_void, *const c_void, usize) -> c_int,
        redirect: unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, usize) -> usize,
        cancelled: unsafe extern "C" fn(*mut c_void) -> c_int,
        network_code: *mut i64,
    ) -> c_int;
}

struct Context<'a, T: UpdateHttpEvents> {
    events: &'a mut T,
    failure: Option<UpdateHttpError<T::Error>>,
}

// The native function waits for session invalidation and drains the serial
// delegate queue before returning. This stack pointer cannot escape that call.
// The mutex also serializes the waiting thread's cancellation polls with data.
unsafe fn callback<T: UpdateHttpEvents, R>(
    raw: *mut c_void,
    rejected: R,
    body: impl FnOnce(&mut Context<'_, T>) -> R,
) -> R {
    // SAFETY: every trampoline receives the same live stack Mutex<Context<T>>
    // installed by stream_update_http; the C shim does not reinterpret it.
    let lock = unsafe { &*raw.cast::<Mutex<Context<'_, T>>>() };
    let Ok(mut context) = lock.lock() else {
        return rejected;
    };
    if context.failure.is_some() {
        return rejected;
    }
    // Unwind-enabled tests convert a callback panic. Production's panic=abort
    // terminates instead; neither mode unwinds across the native ABI.
    match catch_unwind(AssertUnwindSafe(|| body(&mut context))) {
        Ok(value) => value,
        Err(_) => {
            context.failure = Some(UpdateHttpError::CallbackPanicked);
            rejected
        }
    }
}

unsafe extern "C" fn response<T: UpdateHttpEvents>(
    raw: *mut c_void,
    status: i64,
    expected: i64,
) -> c_int {
    // SAFETY: the native callback lifetime and pointer are described above.
    unsafe {
        callback::<T, _>(raw, 0, |context| {
            match context.events.response(status, expected) {
                Ok(()) => 1,
                Err(error) => {
                    context.failure = Some(UpdateHttpError::Callback(error));
                    0
                }
            }
        })
    }
}

unsafe extern "C" fn data<T: UpdateHttpEvents>(
    raw: *mut c_void,
    bytes: *const c_void,
    length: usize,
) -> c_int {
    // SAFETY: the shim lends a live NSData slice for this call only and splits
    // it into at most 64 KiB. Refuse invalid shape before constructing a slice.
    unsafe {
        callback::<T, _>(raw, 0, |context| {
            if bytes.is_null() || length > 65536 {
                context.failure = Some(UpdateHttpError::NativeException);
                return 0;
            }
            let bytes = std::slice::from_raw_parts(bytes.cast::<u8>(), length);
            match context.events.data(bytes) {
                Ok(()) => 1,
                Err(error) => {
                    context.failure = Some(UpdateHttpError::Callback(error));
                    0
                }
            }
        })
    }
}

unsafe extern "C" fn redirect<T: UpdateHttpEvents>(
    raw: *mut c_void,
    proposed: *const c_char,
    output: *mut c_char,
    capacity: usize,
) -> usize {
    // SAFETY: the shim supplies a NUL-terminated NSString UTF-8 view and a
    // writable bounded buffer, neither retained by this callback.
    unsafe {
        callback::<T, _>(raw, 0, |context| {
            if proposed.is_null() || output.is_null() || capacity == 0 {
                context.failure = Some(UpdateHttpError::NativeException);
                return 0;
            }
            let Ok(proposed) = CStr::from_ptr(proposed).to_str() else {
                context.failure = Some(UpdateHttpError::NativeException);
                return 0;
            };
            match context.events.redirect(proposed) {
                Ok(url) if !url.is_empty() && url.len() < capacity && !url.contains('\0') => {
                    std::ptr::copy_nonoverlapping(url.as_ptr(), output.cast::<u8>(), url.len());
                    url.len()
                }
                Ok(_) => {
                    context.failure = Some(UpdateHttpError::InvalidRequest);
                    0
                }
                Err(error) => {
                    context.failure = Some(UpdateHttpError::Callback(error));
                    0
                }
            }
        })
    }
}

unsafe extern "C" fn cancelled<T: UpdateHttpEvents>(raw: *mut c_void) -> c_int {
    // SAFETY: same synchronous context as the delegate callbacks.
    unsafe {
        callback::<T, _>(raw, 1, |context| {
            if context.events.cancelled() {
                context.failure = Some(UpdateHttpError::Cancelled);
                1
            } else {
                0
            }
        })
    }
}

pub fn stream_update_http<T: UpdateHttpEvents>(
    request: &UpdateHttpRequest<'_>,
    events: &mut T,
) -> Result<(), UpdateHttpError<T::Error>> {
    if request.url.is_empty()
        || request.url.len() >= 128 * 1024
        || [request.accept, request.user_agent]
            .iter()
            .any(|value| value.len() > 1024 || value.chars().any(char::is_control))
    {
        return Err(UpdateHttpError::InvalidRequest);
    }
    let url = CString::new(request.url).map_err(|_| UpdateHttpError::InvalidRequest)?;
    let accept = CString::new(request.accept).map_err(|_| UpdateHttpError::InvalidRequest)?;
    let agent = CString::new(request.user_agent).map_err(|_| UpdateHttpError::InvalidRequest)?;
    let context = Mutex::new(Context {
        events,
        failure: None,
    });
    // SAFETY: strings and the mutex remain alive until the native function
    // drains every callback; T: Send permits the serial SDK queue to call it.
    let mut network_code = 0_i64;
    let result = unsafe {
        arkdeck_update_http(
            url.as_ptr(),
            accept.as_ptr(),
            agent.as_ptr(),
            (&context as *const Mutex<Context<'_, T>>).cast_mut().cast(),
            response::<T>,
            data::<T>,
            redirect::<T>,
            cancelled::<T>,
            &mut network_code,
        )
    };
    let context = context
        .into_inner()
        .map_err(|_| UpdateHttpError::CallbackPanicked)?;
    if let Some(error) = context.failure {
        return Err(error);
    }
    match result {
        0 => Ok(()),
        1 => Err(UpdateHttpError::Network(network_code)),
        2 => Err(UpdateHttpError::Cancelled),
        _ => Err(UpdateHttpError::NativeException),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::time::{Duration, Instant};

    unsafe extern "C" {
        fn arkdeck_update_http_closed_delegate_probe(
            context: *mut c_void,
            response: unsafe extern "C" fn(*mut c_void, i64, i64) -> c_int,
            data: unsafe extern "C" fn(*mut c_void, *const c_void, usize) -> c_int,
            redirect: unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, usize) -> usize,
        ) -> c_int;
    }

    #[test]
    fn exception_close_prevents_callbacks_even_when_enqueued_after_the_drain() {
        let mut events = Events::new(1024);
        let context = Mutex::new(Context {
            events: &mut events,
            failure: None,
        });
        // SAFETY: the probe uses the same delegate close barrier as production,
        // drains its synthetic callback queue before returning, and never resumes
        // its SDK task. The actual terminal guard must avoid the cleared pointer.
        let rejected = unsafe {
            arkdeck_update_http_closed_delegate_probe(
                (&context as *const Mutex<Context<'_, Events>>)
                    .cast_mut()
                    .cast(),
                response::<Events>,
                data::<Events>,
                redirect::<Events>,
            )
        };
        assert_eq!(rejected, 2);
        assert!(context.into_inner().unwrap().failure.is_none());
        assert!(events.bytes.is_empty());
        assert!(events.statuses.is_empty());
        assert_eq!(events.redirects, 0);
    }

    // Local transport fixtures only. Product URL allowlists are deliberately
    // not part of this OS port; the consumer will reject these HTTP URLs.
    struct Server {
        url: String,
        address: std::net::SocketAddr,
        worker: Option<std::thread::JoinHandle<Vec<u8>>>,
    }
    impl Server {
        fn new(response: Vec<u8>, wait_for_cancel: bool) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            listener.set_nonblocking(true).unwrap();
            let worker = std::thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(5);
                let mut socket = loop {
                    match listener.accept() {
                        Ok((socket, _)) => break socket,
                        Err(error)
                            if error.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            std::thread::yield_now()
                        }
                        Err(error) => panic!("local fixture accept: {error}"),
                    }
                };
                // Darwin inherits O_NONBLOCK on accepted sockets. The
                // bounded fixture reader must wait for the actual headers.
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") && request.len() < 16384 {
                    let mut byte = [0_u8; 1];
                    if socket.read(&mut byte).unwrap_or(0) == 0 {
                        return request;
                    }
                    request.push(byte[0]);
                }
                let _ = socket.write_all(&response);
                if wait_for_cancel {
                    let mut byte = [0_u8; 1];
                    assert_eq!(socket.read(&mut byte).unwrap_or(0), 0);
                }
                request
            });
            Self {
                url: format!("http://{address}/fixture"),
                address,
                worker: Some(worker),
            }
        }
        fn finish(mut self) -> Vec<u8> {
            self.worker.take().unwrap().join().unwrap()
        }
    }
    impl Drop for Server {
        fn drop(&mut self) {
            if let Some(worker) = self.worker.take() {
                // Wake an unused fixture listener on an early native refusal;
                // this never sends an update request or connects off-host.
                let _ = TcpStream::connect_timeout(&self.address, Duration::from_millis(100));
                let _ = worker.join();
            }
        }
    }

    struct Events {
        maximum: usize,
        bytes: Vec<u8>,
        chunks: Vec<usize>,
        statuses: Vec<i64>,
        redirects: usize,
        redirect_target: Option<String>,
        cancel_after_data: bool,
        panic_on_data: bool,
    }
    impl Events {
        fn new(maximum: usize) -> Self {
            Self {
                maximum,
                bytes: Vec::new(),
                chunks: Vec::new(),
                statuses: Vec::new(),
                redirects: 0,
                redirect_target: None,
                cancel_after_data: false,
                panic_on_data: false,
            }
        }
    }
    impl UpdateHttpEvents for Events {
        type Error = &'static str;
        fn response(&mut self, status: i64, expected: i64) -> Result<(), Self::Error> {
            self.statuses.push(status);
            if status != 200 {
                return Err("status");
            }
            if expected > self.maximum as i64 {
                return Err("length");
            }
            Ok(())
        }
        fn data(&mut self, bytes: &[u8]) -> Result<(), Self::Error> {
            assert!(!self.panic_on_data, "fixture callback panic");
            if bytes.len() > self.maximum.saturating_sub(self.bytes.len()) {
                return Err("budget");
            }
            self.chunks.push(bytes.len());
            self.bytes.extend_from_slice(bytes);
            Ok(())
        }
        fn redirect(&mut self, _proposed: &str) -> Result<String, Self::Error> {
            self.redirects += 1;
            self.redirect_target.clone().ok_or("redirect")
        }
        fn cancelled(&mut self) -> bool {
            self.cancel_after_data && !self.bytes.is_empty()
        }
    }
    fn request(url: &str) -> UpdateHttpRequest<'_> {
        UpdateHttpRequest {
            url,
            accept: "application/vnd.arkdeck.update-feed.v1+json",
            user_agent: "ArkDeck-Update/1",
        }
    }

    #[test]
    fn sdk_streams_bounded_chunks_with_only_explicit_product_headers() {
        let body = vec![b'x'; 200_000];
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(&body);
        let server = Server::new(response, false);
        let mut events = Events::new(body.len());
        assert_eq!(
            stream_update_http(&request(&server.url), &mut events),
            Ok(())
        );
        assert_eq!(events.bytes, body);
        assert!(events.chunks.iter().all(|length| *length <= 65536));
        let headers = String::from_utf8(server.finish())
            .unwrap()
            .to_ascii_lowercase();
        assert!(headers.contains("accept: application/vnd.arkdeck.update-feed.v1+json\r\n"));
        assert!(headers.contains("user-agent: arkdeck-update/1\r\n"));
        assert!(!headers.contains("\r\ncookie:"));
        assert!(!headers.contains("\r\nauthorization:"));
    }

    #[test]
    fn caller_status_length_and_incremental_budget_refusals_survive_native_cancellation() {
        for (response, expected) in [
            (
                b"HTTP/1.1 404 Missing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .as_slice(),
                "status",
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n0123456789abcdef".as_slice(),
                "length",
            ),
            (
                b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n0123456789abcdef".as_slice(),
                "budget",
            ),
        ] {
            let server = Server::new(response.to_vec(), false);
            let mut events = Events::new(8);
            assert_eq!(
                stream_update_http(&request(&server.url), &mut events),
                Err(UpdateHttpError::Callback(expected))
            );
            assert!(events.bytes.is_empty());
            server.finish();
        }
    }

    #[test]
    fn rejected_redirect_never_connects_to_the_proposed_destination() {
        let destination = TcpListener::bind("127.0.0.1:0").unwrap();
        destination.set_nonblocking(true).unwrap();
        let response = format!(
            "HTTP/1.1 302 Found\r\nLocation: http://{}/must-not-run\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            destination.local_addr().unwrap()
        );
        let server = Server::new(response.into_bytes(), false);
        let mut events = Events::new(8);
        assert_eq!(
            stream_update_http(&request(&server.url), &mut events),
            Err(UpdateHttpError::Callback("redirect"))
        );
        assert_eq!(events.redirects, 1);
        assert_eq!(
            destination.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        server.finish();
    }

    #[test]
    fn accepted_redirect_uses_callers_url_and_rebuilds_cookie_free_headers() {
        let destination = Server::new(
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_vec(),
            false,
        );
        let proposed = format!("{}?appVersion=must-strip", destination.url);
        let response = format!(
            "HTTP/1.1 302 Found\r\nLocation: {proposed}\r\nSet-Cookie: fixture=must-not-forward\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let origin = Server::new(response.into_bytes(), false);
        let mut events = Events::new(2);
        events.redirect_target = Some(destination.url.replace("/fixture", "/sanitized"));
        assert_eq!(
            stream_update_http(&request(&origin.url), &mut events),
            Ok(())
        );
        assert_eq!(events.redirects, 1);
        assert_eq!(events.bytes, b"ok");
        origin.finish();
        let headers = String::from_utf8(destination.finish())
            .unwrap()
            .to_ascii_lowercase();
        assert!(headers.starts_with("get /sanitized http/1.1\r\n"));
        assert!(!headers.contains("must-strip"));
        assert!(!headers.contains("\r\ncookie:"));
        assert!(headers.contains("user-agent: arkdeck-update/1\r\n"));
    }

    #[test]
    fn cancellation_and_callback_panics_finish_before_context_returns() {
        for panic in [false, true] {
            let mut response =
                b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n".to_vec();
            response.extend_from_slice(&vec![b'x'; 65536]);
            let server = Server::new(response, true);
            let mut events = Events::new(1_000_000);
            events.panic_on_data = panic;
            events.cancel_after_data = !panic;
            let started = Instant::now();
            let result = stream_update_http(&request(&server.url), &mut events);
            assert_eq!(
                result,
                Err(if panic {
                    UpdateHttpError::CallbackPanicked
                } else {
                    UpdateHttpError::Cancelled
                })
            );
            assert!(started.elapsed() < Duration::from_secs(5));
            server.finish();
        }
    }
}
