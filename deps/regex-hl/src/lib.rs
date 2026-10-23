use std::os::raw::c_uchar;
use std::slice;

#[repr(C)]
pub struct Match {
    pub start: usize,
    pub end: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn regex_find_all_ffi(
    pattern: *const c_uchar, pattern_len: usize,
    text:    *const c_uchar, text_len:    usize,
    matches_out: *mut *mut Match,
    len_out:     *mut usize,
) -> bool {
    if pattern.is_null() || text.is_null() || matches_out.is_null() || len_out.is_null() {
        return false;
    }

    let pat  = unsafe { slice::from_raw_parts(pattern, pattern_len) };
    let hay  = unsafe { slice::from_raw_parts(text,    text_len) };

    let Ok(pat_str) = std::str::from_utf8(pat) else { return false };
    let Ok(hay_str) = std::str::from_utf8(hay) else { return false };

    let re = match regex::Regex::new(pat_str) {
        Ok(r) => r,
        Err(_) => return false,
    };

    let matches: Vec<Match> = re
        .find_iter(hay_str)
        .map(|m| Match { start: m.start(), end: m.end() })
        .collect();

    let mut boxed = matches.into_boxed_slice();
    unsafe {
        *matches_out = boxed.as_mut_ptr();
        *len_out     = boxed.len();
        std::mem::forget(boxed);
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn regex_free_matches(matches: *mut Match, len: usize) {
    if matches.is_null() { return; }
    unsafe {
        let _ = Box::from_raw(std::slice::from_raw_parts_mut(matches, len));
    }
}
