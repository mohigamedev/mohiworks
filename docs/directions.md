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
- **To do:** a `world` snapshot from the user's save, and the key timings
  of the menu flow.

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
