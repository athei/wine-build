//! A logger that can never abort the process. Lines go straight to fd 2 with a
//! `compatdb:` prefix, so they land wherever wine's own stderr goes.
//! `eprintln!` is avoided on purpose: it panics if fd 2 is closed, and this
//! crate is built `panic = "abort"`.

use core::ffi::c_void;

/// Write one `compatdb: <msg>` line to stderr, ignoring any error.
pub fn line(msg: &str) {
    let text = format!("compatdb: {msg}\n");
    let bytes = text.as_bytes();
    // SAFETY: a read-only pointer/length pair into an owned buffer; write(2)
    // touches nothing else and its result is deliberately ignored.
    unsafe {
        let _ = libc::write(2, bytes.as_ptr().cast::<c_void>(), bytes.len());
    }
}
