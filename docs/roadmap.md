# Roadmap: stable, cached, fast on ordinary machines

Status 2026-11-24. Built from a read-only review of this fork, of
[XCL](https://github.com/ivall/xcl) (GPL-2.0-only; ideas only, never code),
and two runs on a second machine. Companion: [xcl-techniques.md](xcl-techniques.md).

**Goal.** Reach the world, and stay there, on a 16 GB RAM / 12 GB VRAM PC,
AMD or NVIDIA. Make a second launch much faster than the first by caching
everything that can be derived once.

## Evidence

The test machine: AMD Radeon RX 6800M 12 GB (RDNA2, native wave64), 15.4 GB RAM,
Windows 11. It ran a release build with default settings unless noted.

| Phase | Measured |
|-------|----------|
| Menus | 30 fps, 2-5 ms GPU, 0 dropped draws |
| First world frame | 8126 ms. Of that, 3975 ms copies 1388 MB of title memory into host shadows, and 7299 ms is "heap buffers" passes |
| World, run 1 | 0.6-1.0 fps. About 1900 draws/frame, of which 1600-3400 are dropped without a host pipeline. The pipeline queue (877-1199 being made) never drains. The card is only 15-32 % busy, so the CPU is the limit |
| World, run 2 (`VICTORY_PIPELINE_WAIT_MS=24 VICTORY_RELAY=2`) | about 1.4 fps, 700-750 ms/frame |
| Texture refresh time | 90-95 % of it is spent waiting for title memory to "hold still" (the `MAPPING` lock), for example 260 of 273 ms |
| Memory | 17 GB private, 2.4 GB resident, 1.3 GB commit free: heavy paging |
| Crash | Run 1, after 3.5 min in the world: device removed (0x887A0006), no breadcrumbs. One compute pipeline (`39f0e9aeb156a61c`, a 72 KB container) had been inside `CreateComputePipelineState` for 117 s. Five other compiles were running on other threads |
| Crash, run 2 | After about 6 min in the world. No GPU fault. The title's own fatal path (`int3`, 0x80000003) fired at image `+0x5149aec` on 6 worker threads with the same stack (`+0xa5db22`, `+0x5453ac7`, `+0x23d0f9a`, ...). Its Breakpad reporter then built a 35 MB minidump, whose upload was blocked. The cause is not logged. Hypothesis: a title watchdog or timeout tripped by frames of about 1 s |
| Cache effect | Run 2 loaded 641 pipelines from the library against 50 in run 1, and the early list grew to 2418 keys. Warm caches already help |

Facts the review confirmed in code:
- The real loop caps are 128 (pixel), 256 (vertex/mesh) and 4096 (compute)
  per loop entry, so nested loops multiply. The README's "2^20" is stale
  (`victory-shader/src/emit/lower.rs:10536-10548`).
- The translation cache is keyed by a hash of the whole `victory.exe`
  (`victory-gpu/src/shader_cache.rs:44-46`). Every rebuild therefore
  discards all cached DXIL, and with it every pipeline-library name.
- The "library did not load it (0x80070057)" lines are ordinary misses,
  not a bug: the name was not in the library yet.
- `XMemMapPhysicalPagesScatter` remaps one page per call, and each call
  takes the global remap lock (`victory-hle/src/modules/xmem.rs:606,639,675`).
  Texture refreshes queue behind that lock.
- A texture is held three times: tiled in title memory, linear in a staging
  buffer, and again in VRAM. Buffers of 1 MB or more also keep a system-RAM
  staging mirror of their VRAM copy. Numbered window copies are never freed.
- There is no residency management (`MakeResident`/`Evict`), and only
  shaders and the pipeline library are cached on disk.

## Done so far (2026-11-24, not yet committed)

- **0.1 Memory heartbeat.** A `memory:` line beside every frame line:
  committed MB (with the peak), RAM in use, system commit and RAM free,
  and the card's own and shared memory against their budgets.
- **0.2 Adapter line.** `host adapter` is logged at boot with the name,
  vendor and device ids, and dedicated and shared memory.
- **0.3 Smoke script.** `scripts/smoke.ps1` prints a `victory-smoke v1`
  block. Windows PowerShell 5.1.
- **1.5 README.** The real loop caps are documented.
  `VICTORY_SHADER_LOOP_LIMIT` now works in release builds.
- **2.1 Stable translation key.** The cache now keys on a hash of
  `victory-shader`'s sources (its `build.rs`) plus `shader_cache.rs`, the
  host wave width, and the switches already in the key. Rebuilding other
  crates keeps the cache: on a rebuild, 25,586 of 25,586 entries hit.
- **2.2, first half: `victory precompile`.**
  - It translates every shader in `shaders.rpf` into the run's cache, on a
    device probed like a run's.
  - Result: 25,889 unique shaders in 197 s on 16 threads, 966 MB on disk.
  - 303 fail, unsupported today:
    - 195 geometry-stage containers (ES/GS);
    - 40 descriptors chosen by control flow;
    - 40 descriptors read as data;
    - 10 hardware SGPR inputs;
    - 8 half interpolations;
    - 5 `v_cvt_f32_f64`;
    - and a few singles.
  - Host PSO prebuild (the driver half) is still to do.
- **Low profile.** `VICTORY_PROFILE=low` caps every translated loop at 64,
  trading correct effects for frames. It is part of the cache key, so
  precompile with the same setting.

## Round 2 findings (2026-11-24)

This round adds a run on the low profile with all shaders precompiled.
Smoke result:
- The run lasted 520 s; in the world the median frame was 764 ms
  (1.3 fps).
- About 900 draws were dropped per frame, with 600-800 host pipelines
  still being made.
- Shaders: 421 cache hits, 0 misses. The pipeline backlog is now the
  driver's half only.
- Peak commit was 24.4 GB.
- It ended in a title fatal at `+0x63966f`.

Five read-only design reviews followed. Their designs are below.

### A. Title fatals are object-pool exhaustion

Both fatals (`+0x5149aec` in run 2, `+0x63966f` in run 3) are the
title's lock-free handle pools running empty. The pools hold 17-bit slot
indices, at most 131,070 live objects, and an empty pool reads
`head == 0x1fffe`, which matched `rax` in both crashes.
- Run 2: pool cell RVA `0xabbe2e8`, about 2,170 users. The pool was
  emptied by a typed-factory batch job on 6 workers.
- Run 3: pool cell RVA `0x98d79a8`. A scene or entity proxy registration
  (`0x3e54a70`) appends handles.

The pools fill steadily and free on some later event, so something
VIctory does delays or blocks the frees. Hypotheses, in order:
1. A deferred free waits on a fence, event or frame completion that
   signals late or never.
2. Under memory pressure, an allocation failure is reported as success.
3. Slow frames let the simulation create objects faster than the render
   side retires them.

Experiments:
- Diag build with `VICTORY_STACKS=60,120,180,240`: is the render thread
  advancing as the crash nears?
- Fence and event values over time (`d3d12x.rs` `GetCompletedValue`,
  fence events).
- Repeat with 8+ GB commit free.
- Run with `VICTORY_SHADER_LOOP_LIMIT=16`, faster frames, and see
  whether the crash moves.

### B. Physical-page remaps (the texture-refresh stall)

`XMemMapPhysicalPagesScatter` (`xmem.rs:639`) remaps page by page. Each
call takes the remap lock, and `unmap` (`xmem.rs:797-840`) unmaps the
whole surrounding view and maps its head and tail again, so one
scatter costs O(pages × view length). Texture refreshes
(`texture.rs:667-677`) hold the reader side, and the lock prefers
writers, so refreshes convoy behind it. Fixes:
- (a) Coalesce scatter into runs under one lock, and batch `map_alias`.
- (b) Skip a remap that would show the same section slice at the same
  address. This is the cheapest fix and likely the biggest.
- (c) Split big views into 64 KiB views once, so later edits cost O(page).
- (d) Make `VICTORY_TEXTURE_NO_WAIT` the default after checking how it
  retries.

The estimate is 70-90 % of the "hold still" wait (unmeasured). Add
counters for calls, pages, runs, skips and lock hold time.

### C. Host pipeline prebuild (missing models)

- **Recipes.** `early-pipelines.txt` holds one-way keys only. Add
  `pipeline-recipes.bin`, with the containers in a content-addressed side
  store. Write it at first `note_used`. Each record holds the kind, the
  stage and full container hash of each shader, and the raw stream
  subobjects, replayed through `GraphicsState::read`. It also holds input
  elements by value and a priority from the draw count.
- **Replay.** `victory precompile --pipelines` replays the recipes through
  `Pending::new` and `make::now`, so the library entries are identical to
  a run's. Use about 12 workers, with 2-3 at most for heavy compute
  compiles, and save every 20 s.
- **Runtime.** Warm-start every recipe at boot. `Queue::pop` serves
  newest first instead of oldest first. Raise the wait budget only on
  loading frames. Keep dropping rather than standing in.
- **Unmeasured.** Make durations are not logged in release builds; add a
  log line for them first.

### D. Splash flicker and cutscene smoothness

Causes:
- **Pacing.** The panels here run at 165 Hz, and the 33.3 ms software
  clock is 5.5 refreshes there, so frames alternate between two lengths.
  `Present(0,0)` uses a 2-buffer flip-discard chain with no vsync and no
  waitable object (`host.rs:6080`).
- **Window.** The window is 3840×2160 on a 1080p or 1440p panel. On a
  hybrid laptop, DWM may also copy each frame across adapters.
- **Not dropped draws.** Menus drop none.

Fixes:
- Use `Present(1,0)` or a waitable chain with `SetMaximumFrameLatency(1)`
  and 3 buffers.
- Quantize the frame interval to the panel's refresh.
- Fit the window to the monitor.
- Prefer the high-performance adapter.
- In frames with 60 or fewer draws, hold the last frame while pipelines
  are not ready, for at most 2-3 s.

The credits stutter is mostly CPU preparation (B and copies) plus the
500 ms pipeline wait.

### E. In-place title memory (long term)

The rules recorded in `inplace.rs` were measured on WARP only. Stages:
0. Run `VICTORY_INPLACE_PROBE=2` and the census on the RX 6800M.
1. `VICTORY_INPLACE=2` for private buffers that shaders mostly write, and
   hook the title's `VirtualFree` and `VirtualProtect` so the heap is
   released first.
2. The physical-page pool as `SEC_COMMIT` sections in 256-512 MiB
   chunks, one heap per chunk. This conflicts with lazy commit, so decide
   after the census.
3. Sparse tiled buffers for 64 KiB reservations, only if the census
   shows they matter.

Shaders reach raw memory through a page directory, so XCL's 4 GiB
windows are not needed. Don't combine in-place memory with
`VICTORY_LATE_WAIT`, and cap pinned memory on 16 GB machines.

### Next order

1. B (a)+(b) with tests and counters.
2. C, starting with the make-duration log, then recipes.
3. D: present, window and adapter, plus hold-last-frame.
4. A: experiments, then a fix.
5. E stage 0.

## Phase 0: Measure (do first, small)

Make every later change provable on more than one machine.

1. **Commit and VRAM heartbeat.** Every 2 s, log committed MB, working
   set, local and non-local VRAM usage against budget, shadow, staging and
   card-copy MB, and the pipeline queue depth. XCL's `XCL_ACTIVITY` found
   its 5.7 GB of double commit this way.
2. **Adapter line at boot.** Log the name, vendor, driver, wave lane range,
   mesh shader tier and RAM. Add a `VICTORY_ADAPTER=<index|name>` choice.
   The log does not currently say whether the dGPU or the iGPU ran.
3. **`scripts/smoke.ps1`.** Run N seconds with `VICTORY_KEYS` to reach the
   world. Print a fixed block: commit hash, GPU, frames, median ms/frame,
   peak commit, device removals, crash. Compare `main` against the change.
   Following XCL, reject a change with fewer than 80 % of main's frames,
   more than 125 % of its peak commit, or any device loss.
4. **Run report.** Write one `report.json` per run: stub calls,
   unimplemented device slots (`0x1c8` and `0x218` today), refused views,
   dropped and skipped pipelines, cache hit rates.

## Phase 1: Stability (the device loss)

1. **Diagnostic run** (`ninja diag`, then `VICTORY_D3D12_DRED=1
   VICTORY_D3D12_DEBUG=1`) to name the faulting command. Then bisect:
   - `VICTORY_SKIP_PIPELINES=39f0e9aeb156a61c`, the 117 s compile, first;
   - then the 7-15 s compute hashes;
   - then `VICTORY_SHADER_LOOP_LIMIT=64`, then `VICTORY_GROUP_SYNC=0`,
     then `VICTORY_SHADER_OPT=0`, one at a time.
   - Run twice: a hang only on the cold run points at the driver compile.
2. **Cap concurrent driver compiles at 2-3**, with heavy compute in its own
   lane. Six simultaneous `CreateComputePipelineState` calls, one 117 s
   long, were in flight at the removal.
3. **Shader-side bounds.**
   - Replace the per-loop cap with a per-shader total iteration budget, so
     nested 4096 × 4096 loops can't happen.
   - Refuse or split programs whose groupshared memory exceeds D3D12's 32 KB.
   - Behind a switch, pin `[WaveSize(64)]` on every wave64 compute program
     on native-wave64 GPUs. Today a wave64 program without cross-lane ops
     lets the AMD driver pick wave32.
4. **Fail fast on removal.** Stop submitting at the first removal, write
   the report and exit. A title that keeps submitting to a lost device can
   stop the driver recovering (XCL `real::stop_if_device_removed`).
5. **Fix the README** loop-limit text.
6. **Title fatal at `+0x5149aec` (run 2).**
   - Disassemble the site and its callers (`+0xa5db22`, `+0x5453ac7`) to
     find the check that fails.
   - Save the title memory it reads with `VICTORY_CRASH_SAVE`, and use
     `VICTORY_WATCH` on the values it tests.
   - Check whether it is a timeout. If so, it should go away once frame
     time is down.

## Phase 2: Caching (second launch fast)

1. **Stable translation key.** Replace the whole-exe hash with a translator
   version: a constant bumped on any emit change, or a hash of the
   `victory-shader` sources taken at build time. Keep the env-dependent
   parts (loop limit, wave switches, opt level). Rebuilds of unrelated
   crates then keep the DXIL cache and the pipeline library.
2. **Offline PSO prebuild.**
   - Extend `victory translate --pipelines`
     (`apps/victory/src/translate.rs:158-177`) to create and store host PSOs
     in `host-pipelines.bin` on the user's own GPU.
   - Drive it from the pipeline keys in `early-pipelines.txt` (about 2100
     after one run), which needs the graphics state saved next to each key.
   - XCL's `--precompile --pipelines` took one pipeline from 41.6 s to 0.2 s.
   - Also offer it as a first-launch "preparing shaders" step.
3. **Warm start.**
   - Queue all early keys at boot on all workers.
   - Make REQUESTED last-in-first-out, or rank it by draws per frame.
   - Raise `VICTORY_PIPELINE_WAIT_MS` only during loading frames and keep it
     low (24) in play.
   - Hold the loading screen until the early list drains.
4. **Shrink the slow compiles.**
   - Use the census in `bitcode/census.rs` to list the largest programs.
   - Add cross-block CSE, LICM of descriptor handles and `waveReadLaneFirst`,
     and a smaller guarded-per-lane form.
   - XCL's biggest compile wins came from fewer `switch(pc)` dispatch blocks
     and fewer memory-window switches: DXC 771 s → 424 s, 41.6 s → 22.5 s
     for one program.
5. **Asset cache (later).**
   - Key a content-addressed cache (`victory-pipeline` already has one,
     unused by the GPU side) on (archive offset or bytes hash, layout).
   - Store the BCPack/zlib output and the detiled linear mips.
   - This helps loading and streaming on later runs. It does not reduce
     steady-state RAM.

## Phase 3: Frame time (CPU-bound today)

In rough order of measured payoff:

1. **Batch physical-page remaps.** Make `XMemMapPhysicalPagesScatter`
   coalesce its pages into runs and take the remap lock once per call. This
   targets the 90 % texture-refresh wait. Check first with
   `VICTORY_TEXTURE_NO_WAIT=1`: if "textures" ms collapses, this is
   confirmed.
2. **Parallel work** on 8+ core machines: `VICTORY_WIDE_BACK=1` (copy-back
   compare), `VICTORY_WIDE_REFRESH=1` (texture refresh; measure, since it
   was off on purpose), and parallel detile across mips and textures.
3. **Make the late-wait and relay switches default**
   (`VICTORY_LATE_WAIT=3 VICTORY_RELAY=2`) after a 5-minute soak with no
   device loss on AMD and NVIDIA.
4. **Card buffers** `VICTORY_CARD_BUFFERS_MIN_MB=1 VICTORY_CARD_BUFFERS_MB=1024`,
   so fewer CPU compares are needed. Scale the size from the VRAM budget.
5. **Narrower change tracking.** Scan write-watch only over ranges a
   submission consumes, merging gaps under 1 MB (XCL: 10 ms → 0.8 ms per
   submit). Detile and upload only the changed 64 KB pages of a texture,
   not the whole texture.
6. **GPU detile** with a compute pass from the tiled bytes. This removes
   the CPU detile and the linear staging copy (90-450 ms → a few ms). It is
   large work, so it comes after 1-5.

## Phase 4: Memory (fit 16 GB RAM / 12 GB VRAM)

1. **Lazy commit of mapped physical pages.** A page whose contents are
   zero is mapped as reserve-only. A vectored exception handler commits it
   on the first CPU touch, and every I/O path that writes title memory
   pre-touches it first (XCL `kernelx/lazy.rs`). Combined with items 2-3,
   XCL went from 28.7 to about 15 GB committed on this same title.
2. **No double commit.** Audit copies against their homes with a
   `VirtualQueryEx` walk of the process.
3. **Staging budget.**
   - Free a texture's staging once uploaded and unchanged, or use a ring or
     pool with a byte budget (for example 512 MB).
   - Drop the system-RAM mirror of card buffers and upload through a ring.
   - Free idle numbered window copies (least recently used).
4. **Residency.** Evict and `MakeResident` host textures, least recently
   used, against the `QueryVideoMemoryInfo` budget.
5. **Aliased render targets.** Back render-target, depth-stencil and UAV
   homes with reserved (tiled) resources on one shared 64 KiB VRAM page per
   title page, keeping the console's aliasing. Use exact-size arenas only
   for D32S8 and MSAA (XCL `vram.rs`: 15 GB of arenas → 3.2 GB).
6. **Structural, long term.**
   - Use title memory in place: UMA windows opened with
     `OpenExistingHeapFromAddress`, under 4 GiB each, plus tiled sparse
     windows for partial commits. This removes the shadow-copy path.
   - `inplace.rs` already records the API rules, and `VICTORY_INPLACE=1`
     is stage 1.
   - This is the change that removes both the copies (phase 3) and the
     duplicates (phase 4).

## Phase 5: Any machine

1. **Auto-tune at boot** from the adapter line and RAM:
   - native wave64 or a wave32 split;
   - card-buffer sizes from the VRAM budget;
   - worker count, compile concurrency and staging budget from cores and
     RAM;
   - a "low memory" profile for 16 GB machines.
2. **Matrix.** Run the smoke test on at least one AMD RDNA2/3, NVIDIA and
   16 GB configuration before raising a default.
3. **Correctness backlog from the logs:**
   - depth bounds (4 pipelines);
   - device slots `0x1c8` and `0x218` returning E_NOTIMPL (29 calls);
   - buffer and UAV views left null or off-element;
   - a CBV not 256-byte aligned;
   - dropped indirect draws (`VICTORY_INDIRECT_WINDOW`);
   - ray-traced lighting ([fork-ray-tracing.md](fork-ray-tracing.md)).

## Order of work

| Step | Work | Why first |
|------|------|-----------|
| 1 | Phase 0.1-0.3 | Nothing else can be proven without them |
| 2 | Phase 1.1 (diag run) plus 1.2 (compile cap) | The crash blocks long runs |
| 3 | Phase 2.1 (stable key) | Small; every later iteration benefits |
| 4 | Phase 3.1 (scatter batching) | Largest measured single cost |
| 5 | Phase 2.2-2.3 (prebuild, warm start) | Removes the 1000-pipeline backlog |
| 6 | Phase 4.1-4.3 (lazy commit, staging) | Stops paging on 16 GB machines |
| 7 | Phase 3.2-3.5, 1.3-1.4, 4.4-4.5 | Incremental |
| 8 | Phase 3.6, 4.6 | Large structural work, once the above is measured |
