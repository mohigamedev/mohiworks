# XCL techniques and where VIctory stands

[XCL](https://github.com/ivall/xcl) runs Minecraft Preview and Unicorn
Overlord fully, and Fortnite and XDefiant as far as each goes without its
servers. It also reached this title's menus and settings at a steady
30 fps, with about 15 GB committed. This list records what it does that
matters to VIctory.

**Licence.** XCL is GPL-2.0-only and VIctory is GPL-3.0-or-later, so XCL
code cannot be copied in. Re-implement the ideas. File references point at
`crates/xcl/src/` in XCL.

The **VIctory** column is from a read-only review: *have* means an
equivalent exists, *partial* means it is incomplete or unverified, and
*missing* means it was not found.

## Memory

| Technique | How it works | XCL evidence | VIctory |
|-----------|--------------|--------------|---------|
| Lazy commit of mapped physical pages | Zero pages are mapped reserve-only. A vectored exception handler commits on the first CPU access violation, and kernel-routed writes (ReadFile, DirectStorage) call `ensure()` first | `hle/kernelx/lazy.rs`. Part of the 28.7 → ~15 GB result | missing |
| Home pages reserved until used | A physical page is committed only where it is mapped, and given back when mapped elsewhere. Done in 256 MB runs, because page by page took 20 s | 28.7 → 16-17 GB, first frame at 3.6 s | partial |
| Tiled aliasing for render targets | RT, DS and UAV homes are reserved resources on one shared 64 KiB VRAM page per title page. Pages idle for 2 s are freed. Exact-size arenas are kept only for D32S8 and MSAA | `hle/d3d12x/vram.rs`. 15 GB of arenas plus a device removal became 3.2 GB | missing |
| Placeholders never released | Split and replace work on a logical region map, and the address range is never handed back to Windows. Descriptor heaps go in the first 1 GiB, because shaders use 32-bit offsets | `hle/kernelx/placeholders.rs` | have (`xmem.rs`) |
| Counting VRAM in commit | WDDM charges video memory to the process commit, so pool heaps count. XCL budgets for it | 126 × 64 MB pool heaps found as private commit | missing (not budgeted) |
| O(n) page scatter | Mapping many pages is done in one pass, not page by page under a lock | `2c5fe3f` (16 384 pages took 24 + 10 s before) | missing: VIctory takes the lock per page, its biggest frame-time cost |

## GPU memory and submission

| Technique | How it works | XCL evidence | VIctory |
|-----------|--------------|--------------|---------|
| Title memory used in place (UMA windows) | VirtualAlloc regions are opened with `OpenExistingHeapFromAddress`, each under 4 GiB, at `base + k·4 GiB`. Shaders index `mem0..3`. Nothing is copied per submit | `gpu/uma.rs` | partial: `inplace.rs` stage 1 exists; the runtime uses shadow copies |
| Sparse windows | Reservations the title commits itself get tiled 4 GiB buffers whose tiles map to VRAM as committed. CPU writes go up through a staging ring, only changed 64-byte chunks, and queues GPU-wait on an upload fence | `hle/d3d12x/sparse.rs`. Made XDefiant's 8 GB fit | missing |
| Narrow write-watch | Scan only ranges a submission consumes, merging gaps under 1 MiB | ~10 ms → 0.8 ms per submit; menu 50 → 53 fps | partial (`watch.rs`) |
| Deferred, batched texture uploads | The first upload is deferred to the next ExecuteCommandLists and batched; barriers are tracked per list and applied at submit | Fortnite's 41 s watchdog kill fixed | partial |
| Bottom-of-pipe CPU writes | Writes into memory the GPU cannot see are done by a worker after an XCL fence | A title stalled after frame 2 without it | check |
| Fail fast on device removal | Removal is detected on present or fence errors. XCL logs DRED, writes the report and terminates | `real.rs` | partial: VIctory logs well but does not stop |
| Vtable return-address guard | Thunks in the hidden D3D12 vtable slots tell title calls from runtime calls | `hle/d3d12x/guard.rs` | missing |

## Pipelines and shaders

| Technique | How it works | XCL evidence | VIctory |
|-----------|--------------|--------------|---------|
| Stand-in pipelines | If the DXIL is not cached, return a stand-in at once and build on one worker per core. Graphics draws nothing until ready. Compute waits at its first bind, because a skipped dispatch corrupts results | `hle/d3d12x/pso_async.rs` | partial: VIctory drops draws after a 500 ms wait per frame, and compute is dropped too |
| Compile concurrency by memory | Run concurrent DXC compiles only while commit allows: 6 GB plus 1 GB per running compile | `gpu/recomp/dxc.rs` | missing (fixed 2-8 workers) |
| Offline warm-up | `xcl shaders --precompile --pipelines` | One pipeline 41.6 s → 0.2 s | partial: `translate --pipelines` translates only |
| Stable cache key | DXIL is keyed by source plus toolchain identity | `db5dc26` | missing: VIctory keys by the hash of the whole exe |
| Compile-time reduction | Skip-flag structuring (pc-dispatcher programs 42 % → 9.4 %), one memory-window switch per 4 dwords (771 s → 424 s), `v_dot4` as `dot4add_i8packed` (604 s → 74 s) | HANDOFF | partial: VIctory emits DXIL directly; it needs its own census of the largest programs |
| Wave64 on wave32 | Two 32-lane halves of one group exchange masks and lanes at whole-wave ops; bounded spins with a dead-lane escape; liveness skips unneeded exchanges | `docs/wave64-on-wave32.md`; 1.64x → 1.04x on RTX 3090 | partial; not needed on RDNA |
| Explicit WaveSize on native wave64 | `[WaveSize(64)]` compute where lanes allow it | `gpu/recomp/mod.rs` | partial: set only for programs with cross-lane ops |
| Two-pass NGG mesh | Console NGG and GS become a compute pass plus a pass-through mesh shader | `mesh_dispatch.rs` | VIctory translates mesh programs its own way |
| Refusing pipelines as an explicit workaround | The minimap's AS/MS pipelines are refused and logged instead of being translated wrongly | README | partial (29 slots answer E_NOTIMPL) |

## Runtime, diagnostics and workflow

| Technique | How it works | VIctory |
|-----------|--------------|---------|
| `report.json` per run | Crash, stubs called with their first caller, unknown interfaces and slots, VFS misses, shader, DXC and pipeline counts, DirectStorage refusals | missing |
| Activity heartbeat (`XCL_ACTIVITY`) | Commit, VRAM, arenas and fps every 2 s | missing |
| Smoke gate | `smoke.ps1` on main and on the change; at least 80 % of main's frames, at most 125 % of its commit, no device removal; enforced on PRs | missing |
| Data-driven stub database | `stubdb.toml`: per-DLL defaults (E_NOTIMPL, so failure is loud), wildcard overrides, ordinals | partial |
| Per-title config | `xcl.toml`; the memory budget comes from MicrosoftGame.Config; env vars override | have (`victory.toml`) |
| Frame clock events | Frame-event slots feed the title's present thread from a high-resolution timer thread | have (`frame.rs`) |
| Console-only CPU instructions | clwb, clzero, rdpru, monitorx/mwaitx and rdpid emulated in a vectored handler | have (`console_insn*.rs`) |
| Offline by default | Xbox Live token requests fail like a console without network; crash-report uploads are blocked (`XCL_NETWORK=0`) | have (offline by design) |
| Tests against game data | Tests use `XCL_SAMPLE_*` variables that point at the user's own files and pass empty without them; per-instruction GPU tests against a reference | partial |

## Method lessons

1. When a title writes to address 0 or a bad vtable slot, look first for a failed or mis-ABI'd D3D12.X call.
2. A cold cache looks like a black screen or a hang. Warm the caches before judging a change, and test cold runs on purpose with an empty cache directory.
3. Commit (with VRAM counted in it) is a hard limit. Log it all the time.
4. The D3D12 debug layer found XCL's device removals on this title, for example a B5G5R5A1 UAV on an RGBA8 target.
5. Check GPU contents against the CPU view: stale textures are otherwise invisible. The missing menu glyphs were found this way.
6. Console vtable layouts shift between GDK versions, so detect them at runtime instead of hard-coding them.
7. Gate every runtime change with a before/after smoke run, and bisect regressions in a separate git worktree.
