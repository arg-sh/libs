//! Shell FFI bridge for argsh plugins.
//!
//! Provides safe wrappers around bash's C API for reading/writing variables,
//! iterating WordList arguments, and writing to stderr.

use std::ffi::{c_char, c_int, CStr, CString};

// ── Bash FFI types ──────────────────────────────────────────────

#[repr(C)]
pub struct ShellVar {
    pub name: *const c_char,
    pub value: *const c_char,
    pub exportstr: *const c_char,
    pub dynamic_value: *const libc::c_void,
    pub assign_func: *const libc::c_void,
    pub attributes: c_int,
    pub context: c_int,
}

#[repr(C)]
pub struct WordList {
    pub next: *const WordList,
    pub word: *const WordDesc,
}

#[repr(C)]
pub struct WordDesc {
    pub word: *const c_char,
    pub flags: c_int,
}

pub type BuiltinFunc = extern "C" fn(*const WordList) -> c_int;

/// Raw pointer wrapper that is Sync (safe for static bash structs).
pub struct SyncPtr(pub *const c_char);
unsafe impl Sync for SyncPtr {}

#[repr(C)]
pub struct BashBuiltin {
    pub name: *const c_char,
    pub function: BuiltinFunc,
    pub flags: c_int,
    pub long_doc: *const *const c_char,
    pub short_doc: *const c_char,
    pub handle: *const c_char,
}

// Safety: BashBuiltin is only accessed from bash's main thread.
unsafe impl Sync for BashBuiltin {}

pub const BUILTIN_ENABLED: c_int = 0x01;

// ── Bash C API ──────────────────────────────────────────────────

extern "C" {
    fn find_variable(name: *const c_char) -> *mut ShellVar;
    fn bind_variable(name: *const c_char, value: *const c_char, flags: c_int) -> *mut ShellVar;
}

// ── Public helpers ──────────────────────────────────────────────

/// Read a bash scalar variable. Returns None if unset or null.
pub fn get_scalar(name: &str) -> Option<String> {
    let cname = CString::new(name).ok()?;
    unsafe {
        let var = find_variable(cname.as_ptr());
        if var.is_null() || (*var).value.is_null() {
            return None;
        }
        Some(CStr::from_ptr((*var).value).to_string_lossy().into_owned())
    }
}

/// Set a bash scalar variable.
pub fn set_scalar(name: &str, value: &str) {
    let Ok(cname) = CString::new(name) else { return };
    let Ok(cval) = CString::new(value) else { return };
    unsafe {
        bind_variable(cname.as_ptr(), cval.as_ptr(), 0);
    }
}

/// Write a message to stderr (with trailing newline).
pub fn write_stderr(msg: &str) {
    use std::io::Write;
    let _ = std::io::stderr().write_all(msg.as_bytes());
    let _ = std::io::stderr().write_all(b"\n");
}

/// Iterate a bash WordList into a Vec<String>.
pub fn word_list_to_vec(wl: *const WordList) -> Vec<String> {
    let mut result = Vec::new();
    let mut cur = wl;
    while !cur.is_null() {
        unsafe {
            if !(*cur).word.is_null() && !(*(*cur).word).word.is_null() {
                let cstr = CStr::from_ptr((*(*cur).word).word);
                if let Ok(s) = cstr.to_str() {
                    result.push(s.to_string());
                }
            }
            cur = (*cur).next;
        }
    }
    result
}
