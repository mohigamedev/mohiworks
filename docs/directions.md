# Directions

The working order of this fork: root causes, the directions that follow
from them, and the order of work. Reviewed together before
implementation starts, and updated as evidence comes in.
[roadmap.md](roadmap.md) holds the history and the detailed designs;
[xcl-techniques.md](xcl-techniques.md) holds the reference techniques.

**Principle.** Virtualize, don't simulate. Map the console's resources
onto the host: title memory becomes GPU memory, console textures are
detiled by the GPU, and frames are paced by the display. The CPU stays out
of the frame. Translate what has no host equivalent (shaders, command
packets, descriptors). Name the title's own code (symbolification) so
crashes, profiles and hooks talk about the engine, not about addresses.

Evidence tags: **[M]** measured (log line or run), **[C]** read in code
(file:line), **[H]** hypothesis.

## 1. Where we are (2026-11-25)

Test machine: AMD RX 6800M 12 GB (RDNA2), 15.4 GB RAM, 16 logical
cores, panels at 165 Hz. The settings are the low profile with every
shader precompiled.

| Area | State |
|------|-------|
| Menus | 30 fps, 0 dropped draws [M] |
| World | 0.5-2.3 fps, median 764 ms/frame. The GPU is only 5-30 % busy [M] |
| Shaders | All precompiled: 25,586 of 25,889 translate, and a run has 0 cache misses [M] |
| Host pipelines | 600-1900 still being made by the driver. 441-3897 draws are dropped per frame, which is why models are missing [M] |
| Stability | No device loss on the low profile. The title stops itself after 6-9 min: its handle pools run empty [M] |
| Memory | 24.4 GB peak commit on 15.4 GB of RAM. The page file is now 64-96 GB [M] |
| Display | The splash judders: a 33.3 ms clock on a 165 Hz panel, `Present(0,0)`, and a 4K window [C][H] |

### Route coverage (2026-11-25, recorded and replayed unattended)

`scenarios/world-continue.json`:
1. Boot.
2. Start screen: A.
3. The logo animation (now stable), then the loading art.
4. Opening cutscene: A held 2.5 s to skip.
5. Loading.
6. Second cutscene: A held 3 s to skip.
7. Prologue gameplay, which the pause menu confirms as PROLOGUE.

The unattended replay passed: 2758 frames, world median 598 ms, no device
removal.

| Phase | fps | Measured |
|-------|-----|----------|
| Start screen, logo, loading art | 30 | stable |
| Opening cutscene | 0.4-2 | textures up to 1.8 s/frame at its start (the texture guard is off) |
| Gameplay load and second cutscene | 0.1-1.9 | frames up to 16 s; up to 4,896 draws dropped |
| Prologue gameplay | 1.5-2.8 | 4,000-7,000 draws, 350-1,600 dropped, **with 0 pipelines being made** |
| Pause menu | 3-8 | card memory 7.9 → 9.5 GB, and the budget falls 11.2 → 10.6 GB |
| Back in gameplay after the pause menu | – | one frame: 6.4 s on the GPU and 7.6 s of copy-back, then the device was removed (recorded run) |

New leads, ranked:
- **N1. Device removal after the pause menu.** Card memory is not given
  back, and the GPU then oversubscribes [M]. Whether that causes the
  removal is [H].
- **N2. Draws dropped with no pipeline being made.** These drops are not
  the pipeline backlog. Likely candidates: untranslatable shaders (303,
  of which 195 are ES/GS) and refused pipelines [H]. The diagnostics
  build counts drops by reason.
- **N3. The cost of the guard off.** Textures take 80-170 ms per gameplay
  frame and up to 1.8 s on cutscene loads [M]. A correct replacement
  (D2 class B) gets the speed back.
- **N4. Dark interiors in gameplay:** the missing ray-traced light
  (fork README).

## 2. Root causes

### R1. The CPU and GPU never overlap
Every submission is waited for (`host.rs:5-6`, `queue.rs:1`) [C], so the
GPU sits idle through all the CPU's preparation [M]. The wait exists
because host copies of title memory must stay coherent (R2). It can only
go once R2 is gone: `VICTORY_LATE_WAIT` is unsafe while shadows exist
(`inplace.rs:68-72`) [C].

### R2. Console shared memory is simulated on the CPU
A world frame closes to within 4 % as:
- serial preparation under one lock: 60-77 %;
- the title's own CPU: 7-22 %;
- waits for the card: 6-14 % [M].

The preparation is five simulation layers [C][M]:

| Layer | Code | Cost per frame |
|-------|------|----------------|
| E8 Heap-buffer and bindless-texture passes | `draw.rs:1267-1592` | 237-1418 ms. The code assumes about 30 ms for the unwatched whole-buffer refresh; it measures 330-375 ms |
| E2 Shadow copies of title memory | `shadow.rs`, `memory.rs` | 80-830 ms, 71-358 MB |
| E4 Compare and copy-back of GPU writes | `shadow.rs:1742,1875-1970` | 100-410 ms |
| E5 CPU detile of whole textures | `victory-formats texture.rs:588`, `victory-gpu texture.rs:13,774` | 37-1138 ms |
| E6 Physical-page remaps one page at a time, unmapping whole views | `xmem.rs:639,797-840` | Up to 1745 ms of lock wait inside "textures". It tracks remap churn (223,876 ranges in one sample) [M] |

### R3. Paging amplifies R2 but is not the main cause
The same copy runs at anywhere from 12 MB/s to 1.2 GB/s, the signature of
hard faults [M]. Paging is at least 8-27 % of frame time [M]. Even the
best rate is about 5× below memcpy, which is the design [C]. One frame
spent 2.5 s under the lock that no stat line itemizes [M]. Unknown until
profiled.

### R4. Host pipelines are not prebuilt
Translation is solved. The driver's compile is not: the library holds
one-way keys only, so nothing can be built ahead of a run [C]. Measured
throughput is about 2.2 makes/s in-game [M].

### R5. Presentation is not tied to the display
- A 33.3 ms software clock runs on a 165 Hz panel, which is 5.5
  refreshes per frame.
- `Present(0,0)` uses 2 flip-discard buffers and no waitable object.
- The window is 3840×2160 on a 1080p or 1440p panel.
- The adapter is not chosen on a hybrid laptop.

[C] (`frame.rs`, `host.rs:6080,6112,6430`). That the flicker comes from
this is [H].

### R5b. Splash and logo flicker: stale textures from the write guard
Measured (2026-11-25) with the harness's screen probe
(`scripts/lib/screen-probe.ps1`, grabs of the window from the desktop)
and diagnostics captures:
- **Start screen:** the frames are pixel-identical (40 consecutive
  captures), and the screen shows 80 identical grabs. Presentation is
  fine there.
- **Logo animation after A:** the presented frames themselves cycle
  through three stale images (period 3: half-formed logo, star only,
  full logo). On screen: 17 distinct images in 150 grabs, 46 reversals.
- **`VICTORY_TEXTURE_GUARD=0`:** a smooth fade in the captures, and on
  screen 119 distinct images and 18 reversals, which is the animation
  itself.

So the guarded texture path shows stale contents. The texture guard is
now off by default (fixed). The open question is how, because three
hypotheses were ruled out by measurement:
- writes through alias views (a page-index alias guard was built:
  `VICTORY_GUARD_ALIASES=1`, no change);
- DirectStorage and `write_physical` page writes (now announced with
  `physical_written`, no change);
- writes missed at hash time (the diagnostics `missed_write` log found
  none).

The guard's purpose was speed: about 51 ms and 229 MB less hashing per
world frame. Getting that back correctly belongs to D2's class B (write
tracking by physical page, GPU-side detile), not to this guard.

Not yet measured as a cause: presentation itself (`Present(0,0)`, 2
buffers, 165 Hz panel). D6 stays.

### R6. Title handle pools run empty: probably repeated loads, not late frees
Two lock-free pools of 131,070 slots (cells `0xabbe2e8` and `0x98d79a8`)
empty out after 6-9 min [M].

Static analysis of the free paths [C, title disassembly]:
- **No fence, frame or deferred-release gate exists on either free path.**
- Pool P3 (`0x98d79a8`) is freed only at module shutdown or session
  reset (`0x54ea20`, called from teardown code). Its allocation is a
  registration job (`0x3e54a70`, job `0x9d9da0`), one proxy per model
  element, appended to an owner array that is never trimmed during a
  session. On the console this works because each model is registered
  once per load.
- Pool P2 (`0xabbe2e8`) is freed by its object's deleting destructor
  (`0x51f2ab0`): teardown plus virtual delete. Its runtime trigger was
  not traced.

So exhaustion most likely means the title repeats a load or registration
many times [H], for example a streaming retry or evict-and-reload loop
driven by something the layer reports: memory status, short or failed
reads, "not ready" results, or remap stalls. Fence lag is deprioritized:
the free paths read no fence.

The fix is to make the layer answer as the console would. Never enlarge
or free the pools from outside: the 17-bit indices are in the title's
code, and live handles reference the slots.

### R7. The title's code has no names, but its pools do
A survey of what the executable carries [C, static analysis]:

| Source | What it gives |
|--------|---------------|
| `.pdata` | All 299,257 functions, exact bounds. Crash unwinding already uses it |
| RTTI | Library classes only (97 vtables: `std`, `xbox::services`). The game itself was built without RTTI, so there are no engine class names |
| Debug directory | The CodeView GUID and age only. No PDB ships |
| Source and assert strings | Effectively none |
| Pool creation | One generic constructor with about 596 call sites, each passing the pool's name hash (joaat), element size and global cell. About 590 distinct pools. Names resolve with a joaat dictionary: 13 so far, for example Object, Building, Peds, Vehicles, CTask, InteriorInst, CWeapon |

So names come from the engine's hashed pool names and function bounds,
not from `class::method`. The two crash pools resolve:
- **`0xabbe2e8` is the engine's "Object" pool** (element 0x110). The crash
  site is its allocator, shared with "Building" by an entity-type
  dispatch.
- `0x98d79a8` is a pool whose name has not been resolved yet (element
  0x100).

Each pool's capacity comes from one config lookup function
(`0x50cef40`). That gives a place to read each pool's real capacity at
run time, and an engine-level hook point. The 17-bit index caps capacity
at 131,070, so raising a capacity is a fallback, not the fix for R6.

## 3. Directions

### D0. Test harness: groundwork for every other direction
A scenario runner in Rust and PowerShell, driven by `ninja scenarios`.
Each scenario is a small file:

- **Graphics preset.** Before launch, write the engine's own
  `storage/settings/settings.xml` (`rage__fwSystemSettingsCollection`,
  88 values). Today it holds `resolutionFullscreen` 3840×2160,
  `rtDynamicShadows=true`, motion blur on, `lodScale` and
  `texLodScale_Global` at 1.0, and `frameRateLimit` 30 [M]. Presets: low,
  medium, and as-shipped. Which values the title honours is the first
  test.
- **Start point.** Snapshot and restore the data folder
  (`%LOCALAPPDATA%\victory\data\7952987A`: `saves/`, `storage/`), so
  "Continue" leads straight to a known place in the world.
- **Skipping intros.** The retail (master) executable has no skip
  switches (no intro or logo options in its strings) [M]. So intros are
  skipped by input: `VICTORY_KEYS` scripted presses, today a
  diagnostics-only switch that should be enabled in release. An
  engine-level hook can follow once D5 names the code.
- **Switches.** `VICTORY_*` variables and the console mode.
- **Duration and pass thresholds.** For example: at least 80 % of the
  baseline's frames, at most 125 % of its peak commit, no device removal,
  no crash.
- **Output.** One JSON result per scenario: the `victory-smoke` block
  fields, the memory heartbeat, and later the profiler (D1). It also
  keeps the paging counters (`\Memory\Pages Input/sec`, per-process page
  faults; no admin needed) sampled beside the run.

**Status (2026-11-25): stage 1 built.**
- **Code.** `scripts/harness.ps1` with `list`, `snapshot <name>`,
  `run <scenario>`, `run-all` and `restore`; `ninja scenarios` runs them
  all. `scripts/lib/victory-run.ps1` is shared with `smoke.ps1`.
- **Data.** Scenarios live in `scenarios/*.json`. Presets, snapshots,
  backups and results live in `%LOCALAPPDATA%\victory\harness`, never in
  the repo, because the presets name the title's own settings.
- **Scripted keys.** `VICTORY_KEYS` now works in release builds.
- **Checked end to end.** The low preset wrote its 8 settings, and the
  user's own settings came back byte for byte afterwards. Paging counters
  were sampled (median 3,500 hard-faulted pages/s at boot), and the
  result was written as JSON.
- **Event stream.** `VICTORY_EVENTS=<file>` makes the layer write JSON
  lines (`victory-gpu/src/events.rs`): start, adapter, display mode,
  input, frame statistics, memory and device removal. Input events carry
  the `VICTORY_KEYS` clock. The harness sets the variable for every run.
- **Recording.** `harness.ps1 record <name> [-Snapshot] [-Preset] [-Env]
  [-SnapshotAs]` runs until the title is closed. The real key and pad
  presses become the new scenario's `keys`, so menu timings are captured
  rather than guessed. `-SnapshotAs` keeps the end state, for example
  `world`.
- **Control app** (`tools/control`, Electron 45.3.0). It runs, records,
  snapshots and restores, and stops the title. While a run is on it
  shows:
  - the phase (menus, loading, world, crashed);
  - frame time, fps, dropped draws, pipelines being made, commit and free
    RAM, with a frame-time chart;
  - inputs as they happen;
  - errors and warnings from the log;
  - results from earlier runs.
- **To do:** record the route into the world once, saving it as the
  `world` snapshot; that replaces the guessed keys in the world
  scenarios.

**Stage 2: control switches.** These are the title's rigid limits: 4K
output, the 30/60 fps lock, its own settings. Each becomes a harness
switch, found and made to work one by one:
- **Output resolution.** `VICTORY_DISPLAY_MODE=WxH` already exists: the
  layer reports that display mode to the title, and the log confirms it.
  But the title still presents 3840×2160 [M]. Its back-buffer size comes
  from elsewhere (console model, or its own resolution setting [H]).
  Finding the source is the first stage-2 task.
- **Frame-rate limit:** the title's 30 fps setting and its frame
  interval (`SetFrameIntervalX`).
- **Graphics settings** the title honours: test each preset value
  against the frame statistics.
- **Skipping intros** through an engine-level hook, once D5 names the
  code.

Initial scenarios:
1. **boot-menu:** 90 s. Catches startup regressions.
2. **world-continue:** from a snapshot, 120 s in the world. Measures
   frame time, drops and commit.
3. **world-soak:** 10 min. Pool exhaustion, device loss, memory growth.
4. 1-3 at each graphics preset.

### D1. Measure what the stat lines cannot
- **Sampling profiler.** Extend `victory-loader/src/stacks.rs` (suspend,
  thread context, `.pdata` unwind) to sample about 5 threads at 100 Hz:
  the lock holder, the title's render and simulation threads, and the
  relay thread. Record each thread's wait reason
  (`NtQuerySystemInformation`; `WrPageIn` means a hard fault), so lock
  wait, paging and work separate. Name the frames with D5.
- **Counters.** Count calls, pages, runs, no-op skips and lock hold time
  for E6. Log make durations. Log `PageFaultCount` deltas on the frame
  line.
- **The in-place probe** `VICTORY_INPLACE_PROBE=2` on the RX 6800M. The
  rules in `inplace.rs` were measured on WARP only.

### D2. Virtualize title memory (removes E2, E4, E3, then R1)
Three classes:

| Class | Native mapping | Removes |
|-------|----------------|---------|
| A: CPU-written, GPU-read buffers (constants, vertex, index) | In place: `OpenExistingHeapFromAddress1`; the page pool as `SEC_COMMIT` sections, opened with `OpenExistingHeapFromFileMapping` | Shadow copies, compare, write-watch |
| B: GPU-resident (textures, targets, UAVs) | Reserved resources over a VRAM tile pool, with batched `UpdateTileMappings`. Streaming writes are flagged dirty by the known writers (DirectStorage, `write_physical`) | Per-page remaps, hashing |
| C: GPU-written, CPU-read | An explicit read-back on a fence | Blind compare-everything |

Known limits [C] (`inplace.rs`):
- in-place heaps are system memory read over PCIe, take buffers only, and
  pin their pages;
- the title cannot free or protect those pages while a heap stands;
- tile mappings into such heaps remove the device.

So classes A and B are separate worlds. Once A and B are native, the
per-submission wait (R1) and the bindless passes (E8) can go.

### D3. Detile on the GPU (removes E5)
Upload the tiled 64 KiB blocks as they are and detile them in a compute
pass, using the addrlib logic already in `victory-formats` ported to
HLSL. Uploading GFX10 swizzle into a D3D12 layout directly is not
reliable: 64 KB standard swizzle is optional, and the undefined swizzle
is opaque [C][H]. A one-off check of the RX 6800M's cap settles that.

### D4. Prebuild host pipelines (removes R4)
- **Recipes.** Persist a pipeline recipe at first use: the kind, the
  stage and container hash of each shader, the raw stream subobjects,
  and input elements by value. Keep the containers in a side store.
- **Replay.** `victory precompile --pipelines` replays the recipes on the
  user's GPU, with heavy compute compiles capped at 2-3 at a time.
- **Runtime.** Warm-start the recipes at boot, and serve the newest
  request first.
- **Until then.** Hold the last frame on menu and cutscene frames while
  pipelines are not ready, instead of showing a frame with holes.

### D5. Symbolify the title
**`victory symbols <exe>`** writes a sidecar `symbols-<blake3>` in
`cache_dir`, checked with `ensure_outside_repo`. It is derived from the
executable, so the asset policy forbids it in the repo. It holds:
- the `.pdata` function table;
- the pool table: hash, resolved name, element size, cell, creator;
- the library RTTI vtables;
- referenced strings (Flash `HAL::*` and so on);
- the build identity (BLAKE3, CodeView GUID and age).

The joaat name dictionary stays outside the repo as well. Names we
choose (for example "Object pool") and hook offsets may be committed.

**Uses:**
- **Crash reports** (`crash.rs`) print
  `module+rva (fn <start>+<off> [pool Object])`.
- **The profiler** (D1) groups samples by function and by the pool or
  hash a function touches.
- **Logs** get a `symbolize()` helper.

**Engine-level hooks it opens:**
- The pool constructor (one function, about 596 sites), to log every
  pool's capacity and live count. This feeds D7 directly.
- The pool-size config lookup.
- The title's exported `__XMemAllocationHooks__`, to watch its
  allocations.

The same name-hash-then-config pattern probably covers the job and
streaming systems [H]. That is where to hook instead of emulating the
hardware underneath.

### D6. Pace by the display (removes R5)
- A waitable swap chain with 3 buffers and `SetMaximumFrameLatency(1)`.
- The frame interval quantized to the panel's refresh.
- A window that fits the monitor.
- The high-performance adapter by preference.

### D7. Root-cause the pool exhaustion (R6)
One decisive run, no title changes:
1. A diagnostics thread logs, every 2 s, the live counts of both pools
   (`*(u32*)(*(u64*)(base+cell)+0x10)`) and their real capacities (D5's
   pool table), beside the frame line. A steady rise with frames means a
   leak; a rise only while loading means repeated loads.
2. A breakpoint hook at `0x3e54a70` (the registration job) counts hits
   and logs the model pointer. The same models registered again and
   again confirms repeated loads.
3. In the same run, log the title's I/O and status calls with result
   codes (DirectStorage, `ReadFile`, memory-status queries, timed-out
   waits) against the pool curves.
4. Run once with and once without `VICTORY_LATE_WAIT`/`VICTORY_RELAY`.
   An unchanged growth rate clears fences.

This becomes a D0 scenario (world-soak with pool counters).

## 4. Order (proposed, for review)

| # | Step | Why here | Measured by |
|---|------|----------|-------------|
| 1 | D0 harness: settings presets, snapshots, release `VICTORY_KEYS`, JSON results | Every later step is compared through it | the scenarios run reproducibly |
| 2 | D1 profiler, counters and in-place probe | Turns R3, R2 and the unexplained 2.5 s into numbers. Decides D2's shape on this GPU | profiler buckets; probe verdicts |
| 3 | Graphics presets in D0 (720p, no ray-traced shadows, lower LOD) | Cheapest possible win if the title honours them | world-continue at low vs as-shipped |
| 4 | D5 symbols (first cut) and D7 pool root cause | The fatals end every long run; names make the profiler readable | world-soak duration |
| 5 | E6 batching and no-op skip (within D2 class B) | Largest single measured stall; small change | the "hold still" ms |
| 6 | D4 pipeline recipes and prebuild | Missing models; first-run backlog | dropped and being-made counts reach about 0 |
| 7 | D2 class A in place, then the per-submission wait | Removes E2 and E4, then R1 | copies, copy-back, GPU busy % |
| 8 | D3 GPU detile, then D2 class B tiles | Removes E5, E3 and E6 fully | textures ms |
| 9 | D6 presentation | Independent; can slot in anywhere | flicker gone; frame-time variance |

### 4b. Inherited work (2026-11-25 review, proposed order, for review)

Three related repositories were compared with ours (all GPL-3.0-or-later):

- **ztrx**: our shared base plus a README, a launcher and the same de-naming;
  no code we lack. Its lead is testing: the prologue played to the boat chase
  on an RTX 3050 at 1-3 fps, 1 h 30 min without a crash.
- **fxceless/victory-fork** (ztrx's base): 5 commits beyond our base.
- **Upstream VIctory** (Marvisak): 319 commits beyond our base, mostly from
  2026-11-24/25. A full merge conflicts in 45 files (about 360 hunks: the
  fork and upstream rewrote the same memory layer) and brings the title's
  name back into about 30 files. Cherry-pick by theme instead; every picked
  hunk is checked for the name and commit trailers before it is committed.

What upstream and the fork have that we lack, ranked by our bottleneck
(about 190 ms of a 240 ms Series S frame is CPU sync: copy-back ~90, copies
~60, textures ~58; 255 of ~280 drops a frame are the structure builder):

| # | Step | Source | Attacks | Measured by |
|---|------|--------|---------|-------------|
| I1 | Translator batch: small independent instruction and accuracy commits (v_sad, v_mul_hi24, cvt_off, tbuffer d16, quadmask, interp_p2_f16, readfirstlane, op_sel, f64 converts, phi compression, BDD cap) | upstream; fork 3bff182 | the ~30 untranslated compute shaders; low conflict risk | `precompile` failure reasons; drops a frame |
| I2 | Memory theme as one unit on a branch: page journal per 64 KiB page, one page table per view heap per submission, shader write marks (copy back only pages shaders wrote), raw-address page table | upstream c75fdba, 86a5ed6, bacb06a, 6d021fe, 27c3dc9, cd94d35, 940d32f | copy-back (~90 ms) and part of copies; makes the structure builder safe to run (255 drops) | `back_ms`, `copies_ms`; drops with `VICTORY_BVH_BUILDER=1` by default |
| I3 | Depth bounds test reaches the host; adjacent textures stop taking each other out of the upload queue | fork c96b4f2 (depth bounds part), 310c6eb | a known wrong-output case; texture churn | the depth-bounds log line gone; `textures_ms` |
| I4 | One host texture per texture memory; writable depth twins | upstream 13bbd6f | duplicate texture copies | `textures_ms`; logo flicker re-checked |
| I5 | Pipelines from the shader pack, beside our recipes | upstream 9c58a1c | pipelines not yet drawn (new areas) | `making` stays 0 past the prologue |
| I6 | Diagnostics (peek/poke, DRED breadcrumbs, GPU timing) and stability, audio, HLE fixes | upstream | tooling, crashes | harness PASS rate |
| I7 | Texture re-check after upload (skin and hair colour) | fork a803c87 | visible error; costs uploads | `textures_ms` with and without `VICTORY_HEAP_RECHECK=0` |

Kept as ours (no equivalent there): the 16-bit wave sum for partial waves,
the harness and milestone input, Series S as the test target, pipeline
recipes. Skipped: fork 8dd30ab (the same page-alias index as ours, built
differently), fork 31714de unless our view-heap probe misses its case.

Still ours to build after I1-I7 (nobody has them): D3 GPU detile, D2 class B
tiles, D6 pacing and the 30 fps lock, D7 pool root cause, D5 symbols, the
195 merged geometry-stage programs.

## 5. Open questions

- Which `settings.xml` values does the title honour on this console build?
  Resolution, ray-traced shadows, LOD.
- How do the stat lines divide between paging, lock wait and work? (D1)
- Do in-place heaps work on the RX 6800M, and at what PCIe cost? (D1 probe)
- Which title decision repeats loads into the pools, and which layer
  answer drives it? (D7; the frees themselves are teardown only)
- Does the same name-hash pattern name the job, streaming and fiber
  systems? (D5)
- What is the real capacity of the Object pool and of `0x98d79a8`'s pool?
  (D5 pool table, read at run time)
- Does the RX 6800M support 64 KB standard swizzle? (one cap query)

## 6. Decision log

| Date | Decision |
|------|----------|
| 2026-11-24 | Build without Visual Studio: Ninja, xwin libraries and rust-lld |
| 2026-11-24 | Precompile all shader translations; the cache is keyed by translator source, not by the executable |
| 2026-11-25 | Direction: virtualize instead of simulate; root causes before fixes; this document sets the order |
| 2026-11-25 | Stay with Rust and PowerShell (no C++ rewrite); build the test harness (D0) first |
| 2026-11-25 | Root causes R1-R7 and directions D0-D7 approved. Start with the harness, then extend it with switches that control the title's rigid limits (resolution, frame lock, settings) |
| 2026-11-25 | Graphics presets and snapshots stay outside the repo (they name or contain the title's own data) |
| 2026-11-25 | Texture write guard off by default: correct frames over speed (R5b) |
| 2026-11-25 | D4 implemented: pipeline recipes recorded at first use; `precompile --pipelines` replays them; the harness prepare step runs it |
| 2026-11-25 | Next, screen by screen along the recorded route: N1 (removal after the pause menu), N2 (drop reasons), then N3 and the 4K output |
| 2026-11-25 | Lower render resolution through the console model, not by shrinking the title's targets. As a Series S (`--console series-s`, the same package: `MicrosoftGame.Config` targets Anaconda and Lockhart) the title presents 1920×1080 instead of 3840×2160 by its own choice. `VICTORY_DISPLAY_MODE` alone does not change its output. Series S route (`scenarios/world-continue-s.json`): PASS, world median 318 ms against 655-742 ms, gameplay steady at 3.8-4.3 fps against 1.5-2.8, peak commit 21 GB against 22-24, GPU 35-50 ms of a 240 ms frame. The rest is CPU preparation (R2). Series S becomes the default test target on 16 GB machines |
| 2026-11-25 | Textures are not "4K only": one package serves Series X and S, and textures stream by mip level with per-category LOD scales (`texLodScale_*`). The 4K cost was the render resolution |
| 2026-11-25 | Pipeline replay checked: run 2's prepare replayed 2,103 recorded recipes (2,092 already in the library, 4 made, 7 failed); 0 pipelines were being made in gameplay. The remaining drops (about 300-550 a frame) are not the pipeline backlog (N2) |
| 2026-11-25 | Harness scenarios run as a Series S by default (`world-continue-x` keeps 4K). Input waits for milestones (the stems of files the title opens): A is pressed every 2 s until `core_restofworld001` opens, and the cutscene skips count from it. Start screen passed at 11 s instead of 27 s; gameplay at about 245 s instead of 270 s |
| 2026-11-25 | N2 answered (diagnostics run, `harness.ps1 run world-continue -Diag`): of about 300 drops a frame in gameplay, 255 are the ray-tracing structure builder's dispatches, off on purpose (`VICTORY_BVH_BUILDER=1` turns it on; it stored into title objects in run 98), and the settings have no switch that stops the title asking for them. About 30 come from compute shaders that do not translate: 20 have no DXIL part, the rest are translator gaps. The largest gap (14 dispatches a frame, a 16-bit float wave sum where not every lane runs) is translated now, bit for bit as the console's tree, checked on the host GPU; gameplay drops 300 → 280 a frame. Next: the builder (with its own memory checks) is the one large drop left |
