//! SPIR-V in, WGSL out. Browsers' WebGPU only takes WGSL, so the preview runs
//! PyShader's SPIR-V through naga first. Same calling convention as the Swift
//! module: the host allocates, calls `naga_spirv_to_wgsl`, reads the result
//! through `naga_result_ptr` / `naga_result_len`, then frees it.

use naga::back::wgsl;
use naga::front::spv;
use naga::valid::{Capabilities, ValidationFlags, Validator};
use std::alloc::{alloc, dealloc, Layout};

mod split_samplers;

static mut RESULT: Vec<u8> = Vec::new();

fn store(bytes: Vec<u8>) {
    // Single-threaded wasm: the static is only ever touched from the host's calls, one at a time.
    unsafe { RESULT = bytes };
}

fn convert(spirv: &[u8]) -> Result<String, String> {
    let split = split_samplers::split(spirv)?;
    let spirv = split.as_slice();
    let options = spv::Options {
        // PyShader's graphics wrapper flips gl_Position's y for Vulkan; naga
        // flips it back, which is what WebGPU's y-up clip space wants.
        adjust_coordinate_space: true,
        strict_capabilities: false,
        ..Default::default()
    };
    let module = spv::parse_u8_slice(spirv, &options).map_err(|e| format!("spirv: {e}"))?;
    let info = Validator::new(ValidationFlags::all(), Capabilities::all())
        .validate(&module)
        .map_err(|e| format!("validation: {}", e.emit_to_string("")))?;
    wgsl::write_string(&module, &info, wgsl::WriterFlags::empty()).map_err(|e| format!("wgsl: {e}"))
}

#[no_mangle]
pub extern "C" fn naga_alloc(size: u32) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    unsafe { alloc(Layout::from_size_align_unchecked(size as usize, 4)) }
}

#[no_mangle]
pub extern "C" fn naga_dealloc(ptr: *mut u8, size: u32) {
    if !ptr.is_null() && size > 0 {
        unsafe { dealloc(ptr, Layout::from_size_align_unchecked(size as usize, 4)) }
    }
}

/// Returns 0 on success (result = WGSL text), 1 on failure (result = error text).
#[no_mangle]
pub extern "C" fn naga_spirv_to_wgsl(ptr: *const u8, len: u32) -> i32 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len as usize) };
    match convert(bytes) {
        Ok(text) => {
            store(text.into_bytes());
            0
        }
        Err(text) => {
            store(text.into_bytes());
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn naga_result_ptr() -> *const u8 {
    unsafe { (*std::ptr::addr_of!(RESULT)).as_ptr() }
}

#[no_mangle]
pub extern "C" fn naga_result_len() -> u32 {
    unsafe { (*std::ptr::addr_of!(RESULT)).len() as u32 }
}

#[no_mangle]
pub extern "C" fn naga_result_free() {
    store(Vec::new());
}
