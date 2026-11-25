//! C ABI for MishMail's OpenPGP engine (`OpenPGPEngine` in Swift).
//!
//! Every function takes byte buffers, returns an `MMResult` that the caller
//! frees with `mm_pgp_free`, and never panics across the boundary (a panic
//! is caught and reported as `internal`). The JSON metadata carries no
//! message text and no key material; plaintext and signed text travel in
//! `data` only. Nothing is logged and nothing is kept between calls.
//!
//! Scope B (owner's decision): verify, decrypt, read keys. Nothing here signs
//! or encrypts.

pub mod engine;

use std::panic::{catch_unwind, AssertUnwindSafe};

use engine::EngineError;
use serde_json::json;

/// A buffer owned by this library. `ptr` is null when `len` is 0.
#[repr(C)]
pub struct MMBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

/// `json` is UTF-8: `{"ok":true,...}` or `{"ok":false,"error":"..."}`.
#[repr(C)]
pub struct MMResult {
    pub json: MMBuffer,
    pub data: MMBuffer,
}

impl MMBuffer {
    fn empty() -> Self {
        MMBuffer { ptr: std::ptr::null_mut(), len: 0 }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        let ptr = Box::into_raw(boxed) as *mut u8;
        MMBuffer { ptr, len }
    }

    /// Frees and, for data that may be plaintext, zeroes first.
    unsafe fn free(self) {
        if self.ptr.is_null() {
            return;
        }
        let slice = std::ptr::slice_from_raw_parts_mut(self.ptr, self.len);
        let mut boxed = Box::from_raw(slice);
        boxed.iter_mut().for_each(|b| *b = 0);
        drop(boxed);
    }
}

fn ok(json: serde_json::Value, data: Vec<u8>) -> MMResult {
    MMResult {
        json: MMBuffer::from_vec(json.to_string().into_bytes()),
        data: MMBuffer::from_vec(data),
    }
}

fn err(error: EngineError) -> MMResult {
    ok(json!({ "ok": false, "error": error }), Vec::new())
}

/// # Safety
/// `ptr` must be valid for `len` bytes, or `len` must be 0.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

fn guarded(f: impl FnOnce() -> MMResult) -> MMResult {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| err(EngineError::Internal))
}

/// # Safety
/// Each pointer must be valid for its length (or the length 0).
#[no_mangle]
pub unsafe extern "C" fn mm_pgp_verify_detached(
    data: *const u8,
    data_len: usize,
    signature: *const u8,
    signature_len: usize,
    certs: *const u8,
    certs_len: usize,
    now_unix: i64,
) -> MMResult {
    let (data, signature, certs) =
        (bytes(data, data_len), bytes(signature, signature_len), bytes(certs, certs_len));
    guarded(|| match engine::verify_detached(data, signature, certs, engine::system_time(now_unix)) {
        Ok(sigs) => ok(json!({ "ok": true, "signatures": sigs }), Vec::new()),
        Err(e) => err(e),
    })
}

/// # Safety
/// Each pointer must be valid for its length (or the length 0).
#[no_mangle]
pub unsafe extern "C" fn mm_pgp_verify_cleartext(
    message: *const u8,
    message_len: usize,
    certs: *const u8,
    certs_len: usize,
    now_unix: i64,
) -> MMResult {
    let (message, certs) = (bytes(message, message_len), bytes(certs, certs_len));
    guarded(|| match engine::verify_cleartext(message, certs, engine::system_time(now_unix)) {
        Ok(c) => ok(json!({ "ok": true, "signatures": c.signatures }), c.signed_text),
        Err(e) => err(e),
    })
}

/// # Safety
/// Each pointer must be valid for its length (or the length 0).
#[no_mangle]
pub unsafe extern "C" fn mm_pgp_decrypt(
    message: *const u8,
    message_len: usize,
    secret_keys: *const u8,
    secret_keys_len: usize,
    passphrase: *const u8,
    passphrase_len: usize,
    certs: *const u8,
    certs_len: usize,
    now_unix: i64,
) -> MMResult {
    let message = bytes(message, message_len);
    let secret_keys = bytes(secret_keys, secret_keys_len);
    let passphrase = bytes(passphrase, passphrase_len);
    let certs = bytes(certs, certs_len);
    guarded(|| {
        match engine::decrypt(message, secret_keys, passphrase, certs, engine::system_time(now_unix)) {
            Ok(d) => ok(
                json!({ "ok": true, "integrity_protected": d.integrity_protected,
                        "signatures": d.signatures }),
                d.plaintext,
            ),
            Err(e) => err(e),
        }
    })
}

/// # Safety
/// `data` must be valid for `data_len` bytes (or the length 0).
#[no_mangle]
pub unsafe extern "C" fn mm_pgp_inspect_keys(data: *const u8, data_len: usize, now_unix: i64) -> MMResult {
    let data = bytes(data, data_len);
    guarded(|| match engine::inspect_keys(data, engine::system_time(now_unix)) {
        Ok(keys) => ok(json!({ "ok": true, "keys": keys }), Vec::new()),
        Err(e) => err(e),
    })
}

/// Frees both buffers of a result (zeroing them first).
///
/// # Safety
/// `result` must come from this library and be freed once.
#[no_mangle]
pub unsafe extern "C" fn mm_pgp_free(result: MMResult) {
    result.json.free();
    result.data.free();
}

/// The rPGP version this library was built with, NUL-terminated, static.
#[no_mangle]
pub extern "C" fn mm_pgp_rpgp_version() -> *const std::ffi::c_char {
    c"rpgp 0.21.1".as_ptr()
}
