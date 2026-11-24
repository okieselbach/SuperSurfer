//! C interface for hosts that link SuperSurfer as a library.
//!
//! The macOS app is a Swift program with this crate linked in as a static
//! library. It talks to the routing engine through three functions:
//!
//! - [`supersurfer_call`] sends one JSON request (see
//!   [`crate::engine::Request`]) and returns the JSON reply,
//! - [`supersurfer_free`] releases such a reply,
//! - [`supersurfer_cli`] runs the ordinary command line in-process, so the app
//!   binary still answers `register`, `doctor`, `test <url>` and friends.
//!
//! JSON keeps the boundary to two pointer types and lets both sides evolve
//! their structs without layout agreements.

use crate::engine::{self, Engine};
use std::ffi::{c_char, CStr, CString};
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc::{self, Sender};
use std::sync::OnceLock;

type Job = Box<dyn FnOnce(&mut Engine) + Send + 'static>;

/// The engine lives on one dedicated thread. QuickJS is single-threaded and
/// measures its stack limit from the thread it was created on, and the
/// per-route process snapshot is thread-local, so the loaded state must not
/// wander between whatever threads the host happens to call from.
fn engine_thread() -> Option<&'static Sender<Job>> {
    static SENDER: OnceLock<Option<Sender<Job>>> = OnceLock::new();
    SENDER
        .get_or_init(|| {
            let (sender, receiver) = mpsc::channel::<Job>();
            std::thread::Builder::new()
                .name("supersurfer-engine".to_string())
                .stack_size(4 * 1024 * 1024)
                .spawn(move || {
                    let mut engine = Engine::new();
                    while let Ok(job) = receiver.recv() {
                        job(&mut engine);
                        // Answer everything that queued up meanwhile before
                        // doing any housekeeping: a waiting click comes first.
                        while let Ok(job) = receiver.try_recv() {
                            job(&mut engine);
                        }
                        if catch_unwind(AssertUnwindSafe(|| engine.maintain())).is_err() {
                            engine = Engine::new();
                        }
                    }
                })
                .ok()
                .map(|_| sender)
        })
        .as_ref()
}

fn call_engine(request: String) -> String {
    let Some(sender) = engine_thread() else {
        return engine::error_json("the routing engine could not be started");
    };
    let (reply_sender, reply_receiver) = mpsc::channel::<String>();
    let job: Job = Box::new(move |engine| {
        let reply = catch_unwind(AssertUnwindSafe(|| engine::handle_json(engine, &request)))
            .unwrap_or_else(|_| {
                // The loaded state may be half-updated. Start over; the next
                // request reloads config and browsers.
                *engine = Engine::new();
                engine::error_json("internal error while handling the request")
            });
        let _ = reply_sender.send(reply);
    });
    if sender.send(job).is_err() {
        return engine::error_json("the routing engine has stopped");
    }
    reply_receiver
        .recv()
        .unwrap_or_else(|_| engine::error_json("the routing engine has stopped"))
}

fn into_c_string(text: String) -> *mut c_char {
    let owned = CString::new(text).unwrap_or_else(|_| {
        CString::new(engine::error_json("reply contained a NUL byte")).unwrap_or_default()
    });
    owned.into_raw()
}

/// Sends one JSON request to the routing engine and returns the JSON reply.
///
/// The reply is owned by the caller and must be released with
/// [`supersurfer_free`]. Returns null only when `request_json` is null.
///
/// # Safety
///
/// `request_json` must be null or point to a NUL-terminated string that stays
/// valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn supersurfer_call(request_json: *const c_char) -> *mut c_char {
    if request_json.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: checked for null above; the caller guarantees NUL termination.
    let request = unsafe { CStr::from_ptr(request_json) }
        .to_string_lossy()
        .into_owned();
    into_c_string(call_engine(request))
}

/// Releases a reply returned by [`supersurfer_call`]. Null is ignored.
///
/// # Safety
///
/// `reply` must be null or a pointer obtained from [`supersurfer_call`] that
/// has not been released yet.
#[no_mangle]
pub unsafe extern "C" fn supersurfer_free(reply: *mut c_char) {
    if !reply.is_null() {
        // SAFETY: the caller guarantees the pointer came from `into_raw`.
        drop(unsafe { CString::from_raw(reply) });
    }
}

/// Runs the SuperSurfer command line and returns the process exit code.
///
/// `args_json` is a JSON array of strings: the arguments without the program
/// name, e.g. `["test", "https://example.com"]`. Null means no arguments.
///
/// # Safety
///
/// `args_json` must be null or point to a NUL-terminated string that stays
/// valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn supersurfer_cli(args_json: *const c_char) -> i32 {
    let args: Vec<String> = if args_json.is_null() {
        Vec::new()
    } else {
        // SAFETY: checked for null above; the caller guarantees NUL termination.
        let text = unsafe { CStr::from_ptr(args_json) }.to_string_lossy();
        match serde_json::from_str(&text) {
            Ok(args) => args,
            Err(err) => {
                eprintln!("Error: invalid argument list: {err}");
                return 2;
            }
        }
    };
    // Mirror what `fn main() -> anyhow::Result<()>` does with the outcome.
    let code = match catch_unwind(|| crate::cli::run_with_args(args)) {
        Ok(Ok(())) => 0,
        Ok(Err(err)) => {
            eprintln!("Error: {err:?}");
            1
        }
        Err(_) => 101,
    };
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(request: &str) -> serde_json::Value {
        let request = CString::new(request).unwrap();
        // SAFETY: valid NUL-terminated request; the reply is freed below.
        let raw = unsafe { supersurfer_call(request.as_ptr()) };
        assert!(!raw.is_null());
        // SAFETY: `raw` is a live reply from `supersurfer_call`.
        let text = unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: released exactly once.
        unsafe { supersurfer_free(raw) };
        serde_json::from_str(&text).expect("reply is JSON")
    }

    #[test]
    fn null_request_yields_null_and_free_ignores_null() {
        // SAFETY: null is explicitly allowed by both functions.
        unsafe {
            assert!(supersurfer_call(std::ptr::null()).is_null());
            supersurfer_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn malformed_requests_get_an_error_reply() {
        let reply = call("not json");
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].as_str().unwrap().contains("invalid request"));

        let reply = call(r#"{"op":"no-such-op"}"#);
        assert_eq!(reply["ok"], false);
    }

    #[test]
    fn cli_rejects_a_malformed_argument_list() {
        let args = CString::new("{}").unwrap();
        // SAFETY: valid NUL-terminated string.
        assert_eq!(unsafe { supersurfer_cli(args.as_ptr()) }, 2);
    }
}
