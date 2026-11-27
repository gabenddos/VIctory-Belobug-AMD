# AMD TDR bisect findings (RX 6600 / GTA VI Scarlett)

Session notes from diagnosing GPU Timeout Detection and Recovery (TDR) on
Victory + GTA VI Xbox Series (`1.0.2.1`) running on an AMD RX 6600 under Windows.
Goal evolved from “black world / FSR” toward **isolating which GPU work hangs**
before/during the prison intro. The FSR black-scene bypass (separate from
TDR) is documented in [fsr-passthrough-amd.md](fsr-passthrough-amd.md).

This is a **diagnosis log**, not a fix. No code patch landed from this bisect.

## Environment

| Item | Value |
|------|--------|
| Host GPU | AMD RX 6600 |
| CPU | AMD Ryzen 5 5600 |
| OS | Windows 10/11 build 26300 |
| Title | GTA VI Scarlett `1.0.2.1` |
| Victory | diag profile (`cargo build --profile diag -p victory --features diagnostics`) |
| Data / saves | `%LOCALAPPDATA%\victory\data` (deleting `%LOCALAPPDATA%\victory` resets save + shader cache) |
| Typical repro | New game → first cutscene → cafeteria / early prison |

## Symptoms

- DXGI device removed: **`0x887A0005`** (suspended) / **`0x887A0007`** (GPU hung / won’t respond).
- AMD crash reporter sometimes opens.
- World often **pitch black** when compute and/or many meshes are skipped (expected for that diag mode).
- With selective pipeline skips and compute **on**, screen can show **some pixels** before TDR.
- DRED breadcrumbs frequently **empty** (`done/count, list) []`) even with `VICTORY_D3D12_DRED=1`; still useful via **recent GPU ops** ring in the removal report.

## Artifacts and tooling

| Path / tool | Role |
|-------------|------|
| `scripts/run-tdr.ps1` | Sets DRED + `VICTORY_TEXTURE_MAX`, tees `run-*.log`, manages skip hashes; `-Kinds` / `-LoadPool` / `-BisectStable` / `-BisectCrash` / `-FromRemoved` / `-Loop` / `-Keys` |
| `run-YYYYMMDD-HHMMSS.log` | Full tee of a run (gitignored) |
| `victory-gpu-removed.log` | Last GPU removal report (recent ops + HRESULT) |
| `tdr-skip-hashes.txt` | Active `VICTORY_SKIP_PIPELINES` list for the next/current run |
| `tdr-skip-hashes.txt.pool` | Full hash universe for binary search (~147 as of 2026-11-27) |
| `tdr-skip-hashes.txt.bisect-parent` | Parent set being halved (`-BisectStable` / `-BisectCrash`) |
| `tdr-skip-hashes.txt.hot5` | Locked minimal mesh/pixel set (see below) |
| `tdr-skip-hashes.txt.full42` | Earlier stable mesh-hash set under compute-off |
| `tdr-skip-hashes.txt.second21` / `.hot10` / `.after-*` | Bisect checkpoints |

Env knobs (also in README):

- `VICTORY_D3D12_DRED=1`
- `VICTORY_SKIP_KINDS=compute,mesh,draw,indexed,indirect`
- `VICTORY_SKIP_PIPELINES=<16-hex>,...` — skip any draw/dispatch whose pipeline contains a listed shader hash
- `VICTORY_KEYS` — auto key schedule for unattended menu (`-Loop`)

### How to read a result

| Outcome | Meaning for bisect |
|---------|-------------------|
| TDR + `victory-gpu-removed.log` | Hang; inspect recent GPU ops; peel or change skips |
| Clean quit, no removed log | Treat as **stable** for that skip set (for the scene stretch you reached) |
| Black screen | Often expected when compute/mesh are skipped; not a crash |

## Shader hashes (important)

Hashes are **blake3(Xbox shader container)[:16 hex]** — content of the title shader, **not** machine-specific.

- Same game dump / version → **same hashes** for every developer.
- Different title version or `VICTORY_SHADER_SWAP` → different hashes.
- Victory commit can change **translation**; it does not rename these Xbox hashes.

## High-level kind bisect

| Skip | Result (intro / early world) |
|------|------------------------------|
| (nothing special) | TDR |
| `mesh` only | TDR |
| `compute` only | TDR |
| `compute,mesh` | **Stable** (black) |
| `compute` + enough mesh hashes | **Stable** (black) for early stretch |

**Interpretation:** hang is tied to **both** compute translation/dispatch **and** mesh (and related) graphics work. Skipping one class is not enough; skipping both (or compute + a critical mesh subset) avoids TDR but breaks rendering.

Indirect kinds seen in trails:

- **kind 2** — compute `ExecuteIndirect`
- **kind 10** — mesh `ExecuteIndirect`
- **kind 0 / 1** — graphics indirect draws

## Hash bisect (compute off)

Procedure: `-Kinds compute` + accumulate/bisect mesh-related hashes until stable, then leave-one-out.

### Stable supersets

1. **~42 mesh-related hashes** + compute → stable black (~70s world, user quit). Saved as `tdr-skip-hashes.txt.full42`.
2. Binary search: **first 21** of 42 + compute → **TDR**.
3. **Second 21** + compute → **stable**. Checkpoint: `tdr-skip-hashes.txt.second21`.
4. Continued halving → **10**, then a path that required a **combo** across halves of a 5-set.

### Locked minimal set (`.hot5`)

Under **`VICTORY_SKIP_KINDS=compute`**, leave-one-out showed **every one** of these five is required for the early cutscene/intro window tested (omit any one → TDR):

| Hash | Stage (from diag logs) | Notes |
|------|------------------------|--------|
| `8c0c0024c3c557dc` | mesh | Appears in multiple mesh+pixel pipelines |
| `8c8f0165ddd5199d` | mesh | e.g. + pixel `4cde906781d9b043` |
| `8e0e6de930426c87` | **pixel** | e.g. + mesh `5d6f6107c4638db6` |
| `910b4be059bfb28f` | mesh | `user_data=5`, 1 sampler |
| `9630030a53ecd8ce` | mesh | `user_data=3` |

They are **necessary for that scene stretch**, not proven “the only bad shaders in the game” and not proven **sufficient for later cutscene beats**.

Reproduce:

```powershell
# skip file should be the five hashes (copy from tdr-skip-hashes.txt.hot5)
.\scripts\run-tdr.ps1 -Kinds compute
```

### Caveat: mid-cutscene beyond hot5

`compute` + `.hot5` later **TDR’d mid-cutscene** (black). Recent ops were **indexed** draws, not those five. So:

- hot5 is a **spotlight for early intro**, not a full-game quarantine list;
- later frames can need more skips or hit a different bug path;
- `compute,mesh` remains the coarse “no TDR” baseline.

## Compute-on peeling (why it stalled)

With **no** `SKIP_KINDS` and only `.hot5`:

- Still TDR; trail headed by **compute** dispatches / compute EI.
- Screen sometimes **not** fully black (partial shading).

`-FromRemoved` merging ~30 new hashes per crash grew the list (9 → 39 → 71 → 105 → 132+) without converging. Trails kept shifting (new compute hashes, then mesh EI, then indexed). **Not scalable** as a primary strategy when hundreds of compute shaders can appear.

**Prefer binary search of a large pool** (next section) or the coarse kind skip:

```powershell
.\scripts\run-tdr.ps1 -Kinds compute,mesh
```

## Binary search (~50% per run)

Peeling ~30 hashes from each `victory-gpu-removed.log` is too slow when the hang
keeps naming new shaders. Use a **pool** of all known suspect hashes and cut it
in **half** each run (`O(log n)` instead of linear peel).

### Files

| File | Meaning |
|------|---------|
| `tdr-skip-hashes.txt.pool` | Universe of candidates. Built as the union of `.hot5`, `.full42`, `.second21`, `.after-*` peels, etc. (~**147** hashes). Grows when `-FromRemoved` finds new hashes. |
| `tdr-skip-hashes.txt.bisect-parent` | The set currently being split. Written by `-LoadPool` and `-BisectStable`. |
| `tdr-skip-hashes.txt` | What the next run actually skips (`VICTORY_SKIP_PIPELINES`). |

Rebuild / refresh the pool manually if needed (PowerShell from repo root):

```powershell
$all = [System.Collections.Generic.List[string]]::new()
Get-ChildItem tdr-skip-hashes.txt* -File | ForEach-Object {
  Get-Content $_.FullName | ForEach-Object {
    $h = $_.Trim().ToLowerInvariant()
    if ($h -match '^[0-9a-f]{16}$' -and -not $all.Contains($h)) { $all.Add($h) }
  }
}
$all | Sort-Object -Unique | Set-Content tdr-skip-hashes.txt.pool -Encoding ascii
"pool=$($all.Count)"
```

### Script flags

| Flag | Effect |
|------|--------|
| `-LoadPool` | Copy `.pool` → active skip list **and** `.bisect-parent`. Start of a search. |
| `-BisectStable` | After a **stable** run: save current skips as parent, then keep only the **first half**. |
| `-BisectCrash` | After a **TDR**: keep the **second half** of `.bisect-parent` (parent unchanged). |
| `-FromRemoved` | Merge hashes from `victory-gpu-removed.log` into the active list **and** into `.pool` (grows the universe for later `-LoadPool`). |

Do not combine `-ClearSkips` with `-LoadPool` / `-BisectStable` / `-BisectCrash`.
Use only one of `-BisectStable` or `-BisectCrash` per invocation.

### Workflow

Stay in the scene stretch you care about (early cutscene vs past first scene).
Black screen with compute skipped is OK; judge **TDR vs clean quit**.

```text
                 ┌─ LoadPool (N hashes) ─┐
                 │         run            │
                 └──────────┬─────────────┘
                    ┌───────┴───────┐
                    │               │
                 stable           TDR
                    │               │
            -BisectStable     -BisectCrash
            parent=N          keep 2nd half
            skip=⌊N/2⌋        of parent
                    │               │
                    └───────┬───────┘
                            │ run again …
```

**Commands (compute-off example):**

```powershell
# 1) Start: skip the entire pool
.\scripts\run-tdr.ps1 -Kinds compute -LoadPool
#    Banner should show Hashes: <pool size> (e.g. 147)

# 2a) Stable (you quit, no victory-gpu-removed.log) → keep first half
.\scripts\run-tdr.ps1 -Kinds compute -BisectStable
#    e.g. 147 → 73

# 2b) TDR → keep second half of parent instead
.\scripts\run-tdr.ps1 -Kinds compute -BisectCrash

# 3) Repeat 2a/2b until the active list is small, then leave-one-out or dig into code.
```

Same flags work **without** `-Kinds` (compute on) if you are narrowing a
compute-on peel universe — expect more TDRs and possibly some visible pixels.

### How to read the banner

```text
Loaded pool: 147 hashes -> skip + bisect-parent
BisectStable: parent=147 -> keep first 73 (of 147)
BisectCrash: parent=147 -> keep second 74 (skipped first 73)
Kinds:  compute
Hashes: 73
```

Confirm **`Kinds:`** uses a **comma** between tokens (`compute,mesh`), not a space
(see pitfall below).

### Why this is faster than `-FromRemoved`

| Approach | Per crash / step | Steps to isolate among N |
|----------|------------------|---------------------------|
| `-FromRemoved` peel | add ~30 new names from one dump | can grow forever as trails shift |
| `-LoadPool` + half bisect | discard ~50% of candidates | ~log₂(N) runs (e.g. 147 → ~8 steps) |

`-FromRemoved` is still useful to **seed or grow** `.pool` when a new scene
exposes hashes never seen before; then go back to `-LoadPool` / half bisect.

### Combo / both-halves caveat

If **first half alone TDRs** and **second half alone TDRs**, the hang needs
hashes from **both** sides (same situation as `.hot5` leave-one-out). Then:

- restore parent (or `-LoadPool`),
- switch to leave-one-out / cross-combos, or
- fall back to `-Kinds compute,mesh` for a stable baseline.

## What is *not* concluded

- These five shaders are “broken HLSL” that must be rewritten in Rockstar source (we only have Xbox containers + Victory translation).
- Root cause is exclusively mesh **or** exclusively compute — evidence says **interaction / both paths**.
- Skipping hashes is a **workaround for localization**, not the product fix.
- Empty DRED ≠ “DRED off”; page-fault / breadcrumb capture often empty on this hang class; rely on recent-ops dump.

## Code investigation (started 2026-11-27)

Hash / kind peels **stopped** as the primary strategy (22k+ title shaders; trails
keep shifting). Findings so far:

### Not the bug

- Title mesh EI kind **10** == D3D12 `DISPATCH_MESH` (**10**). No off-by-one vs
  `INCREMENTING_CONSTANT` (11).

### Likely causes (ranked)

1. **Translated shader hangs** (spin / `LOOP_LIMIT` / wave32 hazards) when mesh
   or compute actually runs — matches “skip either class alone → TDR; skip both
   → stable.” Clamp cannot bound shader runtime.
2. **ExecuteIndirect + title count buffer** after clamp: scratch args were
   clamped, but EI still consumed the **title** count resource (no
   UAV→`INDIRECT_ARGUMENT` on that shadow; scratch slots past `eff_count` were
   left **uninitialized**).
3. Mesh barrier elision / wave64-on-wave32 translation edge cases for `.hot5`.

### Patch landed in-tree (repro next)

- `indirect.rs` clamp: **zero-fill** inactive scratch records (`id >= eff_count`).
- `draw.rs` `ExecuteIndirect`: pass **no count buffer** (rely on `max` + zeroed
  scratch) so AMD does not read a stale title count in the wrong state.

### Abandoned: hash peels

Do **not** grow `tdr-skip-hashes.txt` one dump at a time. The title has
tens of thousands of shaders; trails rotate forever. `.hot5` / `.pool` stay
as **spotlights for code**, not a quarantine list to enlarge.

### Patches landed

1. Clamp zero-fill + EI without title count buffer (`indirect.rs` / `draw.rs`).
2. **Null-UAV drop** for compute, mesh, **and** DRAW/INDEXED (same AMD hang
   class; `VICTORY_NULL_UAV_DISPATCH=1` to force-run).
3. `run-tdr.ps1` defaults `-LoopLimit 4096` (was 65536; still hung) and prints
   only `Last log:` (bisect paste prompts removed).
4. Dispatch / clamp DRED markers sit **immediately before** `Dispatch` (root
   constants between SetMarker and Dispatch made hung ops look unmarked).
5. `descriptor::host::mirror`: failed UAV create → `None` on for_draw (was
   `Some` + null descriptor; null-UAV drop never armed).
6. Dynamic tables: failed `make_at` arms `null_uav`; cache hits re-check
   `slot_live` (`bind` clears the flag each draw — run-042156 compute EI).

### Fingerprint shift (2026-11-27)

- Pre null-UAV-mesh: recent ops dominated by **mesh EI kind 10**.
- After: still `0x887A0007`, recent ops dominated by **DRAW EI kind 0**
  (vertex `25eb`/`1d7b`/`72c7` + many PS) — those three VS hashes sit in
  `.pool` from earlier peels; do **not** re-peel them.
- With `-LoopLimit 65536`: ~3.5 min then **CPU AV in `amdxc64.dll`** during
  PSO create (not TDR; no `victory-gpu-removed.log`). VEH only caught null-page
  AVs; broadened to any AV while `Making` a pipeline → `crashed.txt` quarantine.
- Next run (~3 min): **page fault `0x887A0006`** at a VA ~1 GiB past a small
  title buffer; DRED “op 46” is `BEGIN_COMMAND_LIST` (queued lists never
  started — not the faulting op). Recent ops: compute EI then mesh EI.
  Root-SRV byte limits now apply to **compute** too (were draw/mesh only);
  sampler heap indices clamped like views.
- Next: **AMD software timeout** (hung `DISPATCH`, breadcrumbs done). Recent
  ops: large compute `3680x1x1` then many EI `cabb8759…`. `-LoopLimit 4096`.
- Next (`-LoopLimit 4096`): ~7 min then **`0x887A0007`**, empty breadcrumbs,
  recent ops **mesh EI kind 10** again. No “null UAV dropped” lines despite
  “view the host does not allow” — `HostHeap::mirror` returned `Some` after
  failed UAV `make` (null descriptor). Fixed: for_draw unordered with no
  kept host resource → `None` so null-UAV drop fires.
- Next: null-UAV drop fires (3 pipelines) but **`0x887A0007`** ~2 min,
  recent ops **compute EI kind 2** (many hashes). Dynamic-table `make_at`
  failures + cache hits after `null_uav = false` at bind left null UAVs
  running. Fixed in `draw.rs` / `make_at` → bool + `slot_live`.

### Repro after rebuild (no new hashes)

```powershell
cargo build --profile diag -p victory --features diagnostics
.\scripts\run-tdr.ps1
```

Relevant crates: `crates/victory-gpu` (`draw.rs`, `indirect.rs`),
`crates/victory-shader` (DXIL emit / `LOOP_LIMIT` / barriers).

## Practical recipes

```powershell
# Coarse stable (black). -Kinds is string[]; unquoted compute,mesh is OK after script fix.
.\scripts\run-tdr.ps1 -Kinds compute,mesh
# Equivalent: .\scripts\run-tdr.ps1 -Kinds "compute,mesh"

# Early-intro spotlight (black if hot5 file loaded)
Copy-Item tdr-skip-hashes.txt.hot5 tdr-skip-hashes.txt -Force
.\scripts\run-tdr.ps1 -Kinds compute

# Binary search the pool (~50% per step) — preferred over FromRemoved peels
.\scripts\run-tdr.ps1 -Kinds compute -LoadPool
.\scripts\run-tdr.ps1 -Kinds compute -BisectStable   # after stable
.\scripts\run-tdr.ps1 -Kinds compute -BisectCrash    # after TDR

# Grow pool from a dump (also merges into active skips); then re-LoadPool to restart search
.\scripts\run-tdr.ps1 -FromRemoved

# Reset title progress (does NOT wipe repo bisect / pool files)
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\victory"
```

**Pitfall (2026-11-27):** with `[string]$Kinds`, PowerShell’s `-Kinds compute,mesh`
became `"compute mesh"`. Victory logged `unknown token` and **did not skip mesh**,
so TDR trails still showed mesh/`ba8d`/`b375`. Fixed: `-Kinds` is `string[]`, joined
with commas into `VICTORY_SKIP_KINDS`. Banner must show `Kinds: compute,mesh` (comma).

`run-tdr.ps1` prints `Last log:` only; attach that path (and `victory-gpu-removed.log` when present).

## Timeline (condensed)

1. Enable DRED + recent GPU ops dump on device removed.
2. Kind bisect → need compute **and** mesh coverage for stability.
3. Accumulate mesh hashes under compute-off → ~42 stable.
4. Bisect to second half → down to **5 required** hashes (`.hot5`) for early intro.
5. Compute-on + hot5 still TDRs; FromRemoved peel grows without bound.
6. Mid-scene shows hot5 insufficient alone; `compute,mesh` remains nuclear stable baseline.
7. `-FromRemoved` linear peel abandoned as primary strategy; **pool + 50% bisect** added to `run-tdr.ps1`.
8. Next: finish pool binary search and/or **code investigation** with `.hot5` as spotlight.

## Checkpoint files in repo root (local / gitignored patterns)

Keep these if present; they encode the bisect:

- `tdr-skip-hashes.txt.pool` — **binary-search universe** (union of peels/checkpoints)
- `tdr-skip-hashes.txt.bisect-parent` — current half-split parent
- `tdr-skip-hashes.txt.hot5` — **canonical minimal early-intro set**
- `tdr-skip-hashes.txt.full42` — first known-good large mesh set under compute-off
- `tdr-skip-hashes.txt.second21`, `.hot10`, `.after-*` — intermediate peels

`run-*.log`, `victory-gpu-removed.log`, and `tdr-skip-hashes.txt*` are local diag
outputs (see `.gitignore`).
