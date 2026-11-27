//! FidelityFX stub support: remember the pre-upscale colour so Series S
//! can present it as the scene plane (UI overlays the FSR output, which
//! stays black when FSR is stubbed).

use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};

use crate::object::This;

static COLOR: AtomicPtr<crate::object::Object> = AtomicPtr::new(std::ptr::null_mut());
static COPIES: AtomicU64 = AtomicU64::new(0);
static FAILS: AtomicU64 = AtomicU64::new(0);

/// Record the colour buffer from an upscale dispatch.
pub fn note_color(color: This) {
    if color.is_null() {
        return;
    }
    COLOR.store(color.cast_mut(), Ordering::Release);
}

/// The colour buffer last named by the FSR stub, as a presentable plane.
pub fn color_plane()
-> Option<(&'static windows::Win32::Graphics::Direct3D12::ID3D12Resource, u32)> {
    let resource = COLOR.load(Ordering::Acquire);
    if resource.is_null() {
        return None;
    }
    let resource = resource as This;
    let texture = crate::resource::host_resource(resource)?;
    const COPY_SOURCE: u32 = 0x800;
    let state = crate::resource::host_transition(resource, COPY_SOURCE)
        .map_or(COPY_SOURCE, |(_, before)| before);
    crate::resource::host_transition(resource, state);
    Some((texture, state))
}

/// Handle an `ffxDispatch` descriptor: find colour/output, copy when
/// possible, always remember colour for present.
pub fn dispatch(desc: *const u8) {
    if desc.is_null() {
        return;
    }
    let (list, color, output) = upscale_resources(desc).unwrap_or_else(|| scan_resources(desc));
    if color.is_null() {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| tracing::warn!("FSR stub: dispatch with no colour texture"));
        return;
    }
    passthrough(list, output, color);
}

fn passthrough(list: This, dst: This, src: This) {
    note_color(src);
    if src == dst || dst.is_null() {
        return;
    }
    if crate::list::copy_resource_on(list, dst, src) {
        let n = COPIES.fetch_add(1, Ordering::Relaxed) + 1;
        if n == 1 || n.is_power_of_two() {
            tracing::info!(n, "FSR stub: colour copied to output");
        }
        return;
    }
    let n = FAILS.fetch_add(1, Ordering::Relaxed) + 1;
    if n == 1 || n.is_power_of_two() {
        tracing::warn!(
            n,
            list_ok = crate::list::host_list(list).is_some(),
            src_ok = crate::resource::host_resource(src).is_some(),
            dst_ok = crate::resource::host_resource(dst).is_some(),
            "FSR stub: colour→output copy failed (present will use colour)"
        );
    }
}

fn upscale_resources(desc: *const u8) -> Option<(This, This, This)> {
    #[repr(C)]
    struct Header {
        kind: u64,
        next: u64,
    }
    #[repr(C)]
    struct ApiResource {
        resource: u64,
        _desc: [u8; 32],
        _state: u32,
        _pad: u32,
    }
    #[repr(C)]
    struct UpscaleDispatch {
        header: Header,
        command_list: u64,
        color: ApiResource,
        _depth: ApiResource,
        _motion: ApiResource,
        _exposure: ApiResource,
        _reactive: ApiResource,
        _transparency: ApiResource,
        output: ApiResource,
    }
    // SAFETY: desc is the title's ffx dispatch blob.
    let d = unsafe { &*(desc as *const UpscaleDispatch) };
    let color = d.color.resource as This;
    if color.is_null() || crate::resource::host_resource(color).is_none() {
        return None;
    }
    Some((
        d.command_list as This,
        color,
        d.output.resource as This,
    ))
}

fn scan_resources(desc: *const u8) -> (This, This, This) {
    // SAFETY: read pointer-sized words from the title descriptor.
    let words = unsafe { std::slice::from_raw_parts(desc as *const u64, 64) };
    let list = words.get(2).copied().unwrap_or(0) as This;
    let mut textures = Vec::new();
    for &w in &words[3..] {
        let p = w as This;
        if p.is_null() || textures.iter().any(|&t| t == p) {
            continue;
        }
        if crate::resource::host_resource(p).is_some() {
            textures.push(p);
            if textures.len() == 2 {
                break;
            }
        }
    }
    let color = textures.first().copied().unwrap_or(std::ptr::null());
    let output = textures.get(1).copied().unwrap_or(std::ptr::null());
    (list, color, output)
}
