//! FidelityFX / FSR loader stubs (Series S).
//!
//! Real FSR4 crashes or blacks out on RDNA2. Returning an error from create
//! makes this build hit a startup breakpoint. We hand back a dummy context,
//! answer resolution/jitter queries as **native 1:1**, and let
//! `victory_gpu::fsr` copy / present the pre-upscale colour. Set
//! `VICTORY_FSR=1` to load the title's DLLs.
#![allow(non_snake_case)]

use std::ffi::c_void;
use std::sync::Once;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{HleModule, hle_export};

const OK: u32 = 0;
const ERROR_PARAMETER: u32 = 6;

const QUERY_GET_VERSIONS: u64 = 4;
const QUERY_GET_PROVIDER_VERSION: u64 = 6;
const QUERY_UPSCALE_RATIO: u64 = 0x0001_0002;
const QUERY_UPSCALE_RENDER_RES: u64 = 0x0001_0003;
const QUERY_UPSCALE_JITTER_PHASE: u64 = 0x0001_0004;
const QUERY_UPSCALE_JITTER_OFFSET: u64 = 0x0001_0005;
const QUERY_UPSCALE_GPU_MEMORY: u64 = 0x0001_0008;
const QUERY_UPSCALE_GPU_MEMORY_V2: u64 = 0x0001_0009;
const QUERY_UPSCALE_RESOURCE_REQS: u64 = 0x0001_000a;

const CREATE_UPSCALE: u64 = 0x0001_0000;

const STUB_VERSION_ID: u64 = 1;
static STUB_VERSION_NAME: &[u8] = b"victory-fsr-passthrough\0";

static NEXT: AtomicU64 = AtomicU64::new(1);

fn note(symbol: &str) {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        tracing::info!(
            symbol,
            "FidelityFX / FSR stubbed as 1:1 passthrough (set VICTORY_FSR=1 for title DLLs)"
        );
        println!(
            "FidelityFX / FSR stubbed as 1:1 passthrough (set VICTORY_FSR=1 to allow)"
        );
    });
}

#[repr(C)]
struct Header {
    kind: u64,
    next: *mut Header,
}

fn ratio_for(_quality: u32) -> f32 {
    1.0
}

pub extern "C" fn ffxCreateContext(
    context: *mut *mut c_void,
    _desc: *mut c_void,
    _mem_cb: *const c_void,
) -> u32 {
    note("ffxCreateContext");
    if context.is_null() {
        return ERROR_PARAMETER;
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    // SAFETY: title out-pointer for the context.
    unsafe { *context = id as *mut c_void };
    OK
}

pub extern "C" fn ffxDestroyContext(
    context: *mut *mut c_void,
    _mem_cb: *const c_void,
) -> u32 {
    note("ffxDestroyContext");
    if !context.is_null() {
        // SAFETY: context slot from create.
        unsafe { *context = std::ptr::null_mut() };
    }
    OK
}

pub extern "C" fn ffxConfigure(_context: *mut c_void, _desc: *const c_void) -> u32 {
    note("ffxConfigure");
    OK
}

pub extern "C" fn ffxDispatch(_context: *mut c_void, desc: *const c_void) -> u32 {
    note("ffxDispatch");
    if desc.is_null() {
        return ERROR_PARAMETER;
    }
    // SAFETY: title descriptor; only the type word is logged here.
    let kind = unsafe { *(desc as *const u64) };
    static KIND: Once = Once::new();
    KIND.call_once(|| tracing::info!(kind, "FSR stub: first ffxDispatch type"));
    victory_gpu::fsr::dispatch(desc as *const u8);
    OK
}

pub extern "C" fn ffxQuery(_context: *mut c_void, desc: *mut c_void) -> u32 {
    note("ffxQuery");
    if desc.is_null() {
        return ERROR_PARAMETER;
    }
    // SAFETY: title passes a query descriptor headed by ffxApiHeader.
    let kind = unsafe { (*(desc as *const Header)).kind };
    match kind {
        QUERY_UPSCALE_RATIO => {
            #[repr(C)]
            struct Q {
                header: Header,
                quality: u32,
                out_ratio: *mut f32,
            }
            let q = unsafe { &*(desc as *const Q) };
            if q.out_ratio.is_null() {
                return ERROR_PARAMETER;
            }
            unsafe { *q.out_ratio = ratio_for(q.quality) };
            OK
        }
        QUERY_UPSCALE_RENDER_RES => {
            #[repr(C)]
            struct Q {
                header: Header,
                display_w: u32,
                display_h: u32,
                quality: u32,
                out_w: *mut u32,
                out_h: *mut u32,
            }
            let q = unsafe { &*(desc as *const Q) };
            if q.out_w.is_null() || q.out_h.is_null() {
                return ERROR_PARAMETER;
            }
            let r = ratio_for(q.quality);
            let w = ((q.display_w as f32) / r).round().max(1.0) as u32;
            let h = ((q.display_h as f32) / r).round().max(1.0) as u32;
            unsafe {
                *q.out_w = w;
                *q.out_h = h;
            }
            OK
        }
        QUERY_UPSCALE_JITTER_PHASE => {
            #[repr(C)]
            struct Q {
                header: Header,
                _render_w: u32,
                _display_w: u32,
                out_phases: *mut i32,
            }
            let q = unsafe { &*(desc as *const Q) };
            if q.out_phases.is_null() {
                return ERROR_PARAMETER;
            }
            unsafe { *q.out_phases = 1 };
            OK
        }
        QUERY_UPSCALE_JITTER_OFFSET => {
            #[repr(C)]
            struct Q {
                header: Header,
                _index: i32,
                _phases: i32,
                out_x: *mut f32,
                out_y: *mut f32,
            }
            let q = unsafe { &*(desc as *const Q) };
            if q.out_x.is_null() || q.out_y.is_null() {
                return ERROR_PARAMETER;
            }
            unsafe {
                *q.out_x = 0.0;
                *q.out_y = 0.0;
            }
            OK
        }
        QUERY_GET_VERSIONS => {
            #[repr(C)]
            struct Q {
                header: Header,
                create_desc_type: u64,
                _device: *mut c_void,
                output_count: *mut u64,
                version_ids: *mut u64,
                version_names: *mut *const i8,
            }
            let q = unsafe { &*(desc as *const Q) };
            if q.output_count.is_null() {
                return ERROR_PARAMETER;
            }
            let want = unsafe { *q.output_count };
            if q.create_desc_type != 0 && q.create_desc_type != CREATE_UPSCALE {
                unsafe { *q.output_count = 0 };
                return OK;
            }
            if want == 0 {
                unsafe { *q.output_count = 1 };
                return OK;
            }
            unsafe { *q.output_count = 1 };
            if !q.version_ids.is_null() {
                unsafe { *q.version_ids = STUB_VERSION_ID };
            }
            if !q.version_names.is_null() {
                unsafe {
                    *q.version_names = STUB_VERSION_NAME.as_ptr().cast();
                }
            }
            OK
        }
        QUERY_GET_PROVIDER_VERSION => {
            #[repr(C)]
            struct Q {
                header: Header,
                version_id: u64,
                version_name: *const i8,
            }
            let q = unsafe { &mut *(desc as *mut Q) };
            q.version_id = STUB_VERSION_ID;
            q.version_name = STUB_VERSION_NAME.as_ptr().cast();
            OK
        }
        QUERY_UPSCALE_GPU_MEMORY | QUERY_UPSCALE_GPU_MEMORY_V2 => OK,
        QUERY_UPSCALE_RESOURCE_REQS => {
            #[repr(C)]
            struct Q {
                header: Header,
                required: u64,
                optional: u64,
            }
            let q = unsafe { &mut *(desc as *mut Q) };
            q.required = (1 << 0) | (1 << 1) | (1 << 2);
            q.optional = (1 << 3) | (1 << 4) | (1 << 5);
            OK
        }
        _ => OK,
    }
}

pub(crate) fn module() -> HleModule {
    HleModule {
        name: "fidelityfx",
        dlls: &["amd_fidelityfx_*"],
        exports: vec![
            hle_export!(ffxCreateContext),
            hle_export!(ffxDestroyContext),
            hle_export!(ffxConfigure),
            hle_export!(ffxDispatch),
            hle_export!(ffxQuery),
        ],
    }
}
