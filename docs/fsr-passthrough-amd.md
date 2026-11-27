# FidelityFX / FSR passthrough (RDNA2 / RX 6600)

Xbox Series S GTA VI drives the scene through AMD FidelityFX (FSR4-class
upscale). Consumer RDNA2 cards such as the **RX 6600 do not have FSR4
native hardware**. Loading the title’s `amd_fidelityfx_*` / FSR4 DLLs on
that host either crashes, falls back through NewBE, or leaves the **scene
plane black** while UI still draws on top.

This fork **does not run real FSR**. By default it **bypasses** the title
upscaler with an HLE 1:1 passthrough: dummy context, native-resolution
queries, colour→output copy on dispatch, and present of the pre-upscale
colour as the scene. That is what keeps the world from going full black
on RX 6600 and similar RDNA2 hosts.

Related black-screen path: ACCC-only compute pipelines (title upscaler
shader containers without DXIL) are refused unless `VICTORY_ACCC=1`.

## Default behaviour (recommended)

| Knob | Default | Effect |
|------|---------|--------|
| *(unset)* | passthrough on | HLE module serves `amd_fidelityfx_*`; title DLLs are not mapped |
| `VICTORY_FSR=1` | opt-out | Title FidelityFX / FSR DLLs load; stub module is **not** registered |
| `VICTORY_ACCC=1` | opt-in (off) | Allow create of ACCC-only upscaler compute pipelines |

Unset `VICTORY_FSR` for playable colour on RDNA2. Set it only when you
intentionally want the title’s upscaler (expect black scene / crashes on
RX 6600).

## Why the scene went black

Series S composites roughly as:

1. Title renders the world at **internal / render** resolution into a
   colour buffer.
2. FidelityFX **upscales** colour → a display-sized **output**.
3. Present draws **UI over the FSR output** (scene under, HUD on top).

If step 2 never writes the output (stubbed create that returns failure,
DLL crash, or ACCC pipelines created then never dispatched usefully),
present still uses the empty FSR plane → **full black world**, UI may
still show.

Returning an error from `ffxCreateContext` is not viable either: this
build hits a startup breakpoint. The stub must succeed and look like a
working 1:1 upscaler.

## How the bypass is wired

Three layers cooperate. All are on unless `VICTORY_FSR=1`.

```
title LoadLibrary / imports  amd_fidelityfx_*
        │
        ▼
apps/victory  refuses mapping title FidelityFX / FSR images
        │     (fidelityfx_refused)  →  LoadLibrary falls through to HLE
        ▼
victory-hle   fidelityfx module  (ffxCreateContext / Query / Dispatch / …)
        │     1:1 ratios, dummy context id "victory-fsr-passthrough"
        ▼
victory-gpu   fsr::dispatch  →  colour→output copy + note_color
        │
        ▼
queue present  present_over(fsr colour plane, UI overlay)
```

### 1. Refuse the title DLLs

`apps/victory` (`run.rs`) treats names starting with `amd_fidelityfx_`,
or containing `fidelityfx` / `fsr4`, as refused unless `VICTORY_FSR=1`.
Import walks and late `LoadLibrary` skip mapping those images so the HLE
stub can answer instead. Returning `Err` / module-not-found aborts before
the stub is found; the late loader returns `Ok(None)` so binding falls
through to HLE.

### 2. HLE FidelityFX stub

`crates/victory-hle/src/modules/fidelityfx.rs` is registered for
`amd_fidelityfx_*` when `VICTORY_FSR` is not `1`
(`modules/mod.rs`).

| Export | Stub behaviour |
|--------|----------------|
| `ffxCreateContext` | Dummy non-null context id; status OK |
| `ffxDestroyContext` | Clears the slot; OK |
| `ffxConfigure` | OK no-op |
| `ffxQuery` | Upscale **ratio 1.0**, render size = display size, **1** jitter phase, **(0,0)** offset, one provider version named `victory-fsr-passthrough`, resource reqs filled; other queries OK |
| `ffxDispatch` | Calls `victory_gpu::fsr::dispatch` then OK |

So the title believes upscale is native 1:1: no TAA jitter pattern from
FSR, no reduced internal resolution from this path.

### 3. GPU colour passthrough and present

`crates/victory-gpu/src/fsr.rs`:

- Parses the upscale dispatch descriptor (typed layout, else a pointer
  scan) for command list, **colour**, and **output**.
- Remembers colour (`note_color`) for present.
- Copies colour → output on the open list when both are real host
  resources (`list::copy_resource_on`); if copy fails, present still has
  colour.

`queue` present for Series S UI-over-scene:

- If a stub colour plane exists, **`present_over` uses that colour as the
  scene** instead of the (often empty) FSR output under the HUD.

Logs to expect once:

- `FidelityFX / FSR stubbed as 1:1 passthrough…`
- `FSR stub: colour copied to output` (and powers of two thereafter)
- `presenting FSR stub colour as the scene plane`

Warnings if colour is missing or the copy fails (present still prefers
the remembered colour when possible).

## ACCC upscaler pipelines

Separate from the FidelityFX DLL: some Series S upscaler **compute**
pipelines ship as Xbox containers with an **ACCC** part and **no DXIL**.
Victory cannot run those programs on the host.

`pipeline` create **refuses** them by default (`E_NOTIMPL`, null pipeline)
so the title falls back to working without that pass (native scene
resolution). `VICTORY_ACCC=1` accepts create; if those dispatches are then
dropped or useless, the Series S scene plane can go black again.

Use `VICTORY_ACCC=1` only when debugging translation of those containers,
not for day-to-day RDNA2 runs.

## Opting into real title FSR (`VICTORY_FSR=1`)

When set:

1. The HLE `fidelityfx` module is **not** pushed into the registry.
2. Title `amd_fidelityfx_*` / FSR images are **allowed** to map.
3. `victory_gpu::fsr` is not driven by the stub (no automatic colour
   note / copy from HLE).

On RX 6600 / RDNA2 without FSR4 hardware this usually returns the original
failure mode: black scene and/or crash. Useful for confirming that the
bypass is what was keeping colour, or for hosts that can actually run the
title path.

## File map

| Path | Role |
|------|------|
| `crates/victory-hle/src/modules/fidelityfx.rs` | API stub (create / query / dispatch) |
| `crates/victory-hle/src/modules/mod.rs` | Registers stub unless `VICTORY_FSR=1` |
| `apps/victory/src/run.rs` | Refuses title FidelityFX / FSR DLL mapping |
| `crates/victory-gpu/src/fsr.rs` | Colour remember + colour→output copy |
| `crates/victory-gpu/src/list.rs` | `copy_resource_on` used by the stub |
| `crates/victory-gpu/src/queue.rs` | Present scene from stub colour under UI |
| `crates/victory-gpu/src/pipeline.rs` | ACCC-only pipeline refuse / `VICTORY_ACCC` |

## What this does **not** do

- No real FSR2/3/4 quality, temporal accumulation, or frame generation.
- No FSR4 hardware feature enablement on RDNA2.
- No fix for unrelated black frames (skipped compute/mesh in TDR bisect,
  phone-out unlit world, refused mesh/compute translation). Those are
  separate; see [tdr-bisect-amd.md](tdr-bisect-amd.md) for hang bisect
  vs expected black under skip modes.

## Quick check

1. Run without `VICTORY_FSR` on RX 6600 (or other RDNA2).
2. Confirm the one-shot stub / present log lines above.
3. World colour should appear under UI (subject to other known limits in
   the README), not a solid black scene plane.
4. Optional contrast: `VICTORY_FSR=1` → expect black / crash on the same
   card if the title path still needs FSR4-class hardware.
