# mohiworks

Runs the Xbox Series build of the title natively on Windows PCs, built on
[VIctory](https://github.com/Marvisak/VIctory). This repository carries
VIctory's full history and adds work aimed at running the title at a usable
rate on an ordinary 16 GB machine, plus a test harness that drives the title
unattended from boot to gameplay.

**This repository contains no game files, code or assets.** You need your own
copy of the title. It is not affiliated with or endorsed by the title's
publisher or by Microsoft.

## Status (2026-11-25)

**Not playable yet: about 5 frames per second in the world, and the
prologue's gameplay shows a black picture.** Tested on one
machine: Windows 11, AMD Radeon RX 6800M 12 GB, 16 GB RAM (paging file
enlarged), as a Series S.

| Stage | State |
|-------|-------|
| Boot, splash, start screen | works, 30 fps; the start screen is passed by scripted input at 11 s |
| Opening cutscenes | play (title cards show); skipped by holding A |
| Prologue gameplay | the title draws about 4,400 draws a frame at 4.1-5.7 fps as a Series S (1080p), 1.5-2.8 as a Series X (4K), but **the picture is black**: the scene is lit by the title's ray-traced light, which does not run yet (its structure builder is the 255 dropped draws below). A window capture of a whole route (2026-11-25) shows title cards, then black |
| Pause menu | works, 22-25 fps; card memory stays flat across it |
| Stability | the recorded route (400 s) and a 12-minute soak pass unattended: no crash, no device loss |
| Draws dropped in gameplay | about 280 a frame: 255 are the ray-tracing structure builder (off on purpose), the rest shaders that do not translate yet |

Where a gameplay frame's time goes (Series S, about 210 ms): the GPU needs
about 32 ms; the rest is VIctory keeping copies of title memory in sync on
the CPU. Removing that (title memory used in place, textures detiled on the
GPU) is the main direction; see [docs/directions.md](docs/directions.md).

### Measured runs (2026-11-25)

Unattended harness runs (`scripts/harness.ps1`) on the machine above, Series S,
low preset. "World median" is the median frame time once the title is in the
open world. Each run's log and result stay on the test machine (they hold the
title's own output); the numbers are copied here.

| Run | Build | Length | Result | World median | Notes |
|-----|-------|--------|--------|--------------|-------|
| route | before in-place memory | 400 s | pass | 244 ms (4.1 fps) | CPU prep 192 ms, GPU 41 ms, copy-back 103 ms |
| route | title memory in place (default since `cac0620`) | 400 s | pass | 211-216 ms (4.6-4.7 fps) | CPU prep 163 ms, GPU 32 ms, copy-back 91 ms |
| route | + physical pages in place (`VICTORY_INPLACE_POOL=1`, off by default) | 400 s | pass | 183-205 ms (4.9-5.5 fps) | CPU prep 138-151 ms |
| soak | + physical pages in place, capped at 512 MB | 720 s | pass | 194 ms (5.2 fps) | no crash, no device loss; shared GPU memory peak 6.9 of 7.2 GB |
| soak | + physical pages in place, uncapped | 720 s | fail at 127 s | - | the card's shared memory ran out; the cap above fixes it |

Every pass had no crash and no device loss. Draws dropped in gameplay: about
280 a frame in every run (see the table above).

## What this repository adds

- **Build without Visual Studio:** Ninja, the xwin libraries and rust-lld.
- **Shader and pipeline prebuild:** `victory precompile` translates every
  shader the title ships into the run's cache; `--pipelines` replays the host
  pipelines earlier runs recorded, so gameplay starts with none left to make.
- **Lower output resolution:** run as a Series S (`--console series-s`): the
  title renders 1080p by its own choice, about twice the frame rate of 4K.
- **Test harness** (`scripts/harness.ps1`, PowerShell): scenarios with graphics
  presets, scripted input that waits for milestones (files the title opens),
  per-run events (frames, memory, input), pass thresholds, and a diagnostics
  mode that logs why draws are dropped. An Electron control app
  (`tools/control`) runs, records and follows runs live.
- **Translator:** 16-bit float wave sums where not every lane runs, bit for
  bit as the console's tree; checked on the host GPU.
- **Correct frames over speed:** the texture write guard (which showed stale
  splash frames) is off by default.

## Playing

```powershell
copy victory.example.toml victory.toml     # set game_dir to your own copy
cargo build --release -p victory
.\scripts\play.ps1                          # Series S; -Console series-x for 4K
```

`play.ps1` brings the caches up to date, then runs the title with its own
saves folder (`%LOCALAPPDATA%\victory\play`) and no scripted input. The
first run translates about 26,000 shaders (a few minutes).

## Credits

- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its
  contributors is the base of everything here: the loader, the runtime
  services, the Direct3D 12 back end and the shader recompiler. Licensed
  GPL-3.0-or-later; so is this repository. Its history is kept intact.
- **[XCL](https://github.com/ivall/xcl)** (GPL-2.0-only) was used as a
  reference only; nothing was copied from it.

Everything below this line is the earlier fork's README and, under it, upstream VIctory's own; their status sections describe those, not this repository.

---

## Earlier fork

A work-in-progress fork of [VIctory](https://github.com/Marvisak/VIctory), the
compatibility layer that runs the Xbox Series build of the title
natively on Windows from files the user supplies. This fork follows upstream
`main` and adds fixes aimed at one goal: getting the game's world to render
correctly and playably on one particular PC.

**This repository contains no game files, code or assets.** You need your own
copy of the game. It is not affiliated with or endorsed by the title's publisher.

## Credits

- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its
  contributors is the base of everything here: the loader, the runtime
  services, the Direct3D 12 back end and the shader recompiler. Licensed
  GPL-3.0-or-later; so is this fork. Upstream's history is kept intact below
  the single commit that carries this fork's changes.
- **[XCL](https://github.com/ivall/xcl)** by ivall and its contributors
  (GPL-2.0-only) was used as a reference for how the same title behaves under
  another layer. Fixes inspired by it were written anew in VIctory's code.

## Status of this fork (2026-11-25)

**Not playable yet: 2.5 to 4 frames per second, and shadowed areas are black.**
Tested on one machine: Windows 11, Intel i7-14700KF, NVIDIA RTX 4070 12 GB,
32 GB RAM. The Series X profile is used throughout.

| Stage | State in this fork |
|-------|--------------------|
| Boot, menus, start screen | works, 30 fps (as upstream) |
| Opening cutscene | plays from start to finish, in order, lit: title cards, credits cards, night and dusk shots |
| Saves | the game autosaves a checkpoint and loads it again |
| First gameplay scene (the prologue) | renders: characters, textures, sky, sunlit exterior; HUD, pause menu and pad input work |
| Light in shadow | missing: the game's ray-traced bounce light and ray-traced lamp and sun shadows do not run yet, so anything the sun does not hit directly is black |
| Frame rate in the world | 2-4 fps: 420-450 ms per frame by default, 240-350 ms with the newer switches (`VICTORY_RELAY=2`, or `VICTORY_LATE_WAIT=3 VICTORY_WIDE_BACK=1 VICTORY_CARD_BUFFERS_MIN_MB=1 VICTORY_CARD_BUFFERS_MB=1024`); it started at 3-6 seconds per frame |
| Stability | no driver hang or device loss in normal runs (a hang introduced by the wave64 update was found and fixed: its barrier form for 64-lane programs is now off unless `VICTORY_WAVE_WIDE=1`) |

### What this fork changed (summary)

Rendering:
- Meshlet culling read its scene buffers as the wrong kind of view, so the world drew almost nothing; fixed.
- Per-draw descriptor tables could run out, after which draws used slots never made for them and the card hung; fixed.
- Light packed by the game's compute shaders was read back through empty copies (sky, probes, fog); fixed for every mip level and layer.
- The fog reconstruction, shadow-mask, hair, blend-shape skinning, fire and several material programs did not translate; fixed.
- Gathers at a named mip level (with and without an offset) read level 0; fixed.
- Implicit-level samples outside pixel shaders produced invalid DXIL in 730 compute programs; fixed.
- Rectangle lists, depth and stencil twins for depth textures written by compute, texture read-backs.
- Ray tracing, in progress and off by default: the game's own structure-builder programs translate, title memory can be read by raw address from shaders, the hardware ray/box and ray/triangle test is emulated in DXIL (checked against a reference on the GPU), and 59 of the 64 trace programs translate. Nothing is lit by it yet. See [docs/fork-ray-tracing.md](docs/fork-ray-tracing.md).

Speed and memory:
- Waits for memory values, write-watch queries and page queries no longer walk page tables per call.
- Large title buffers get a copy in card memory, with shader writes found by hashing on the card.
- Submissions can be sent ahead of the wait for the card (`VICTORY_LATE_WAIT`), with a relay thread that lands results as the card finishes (`VICTORY_RELAY`): in a first five-minute run the card's idle time behind the submitting thread fell from about 136 to 30 ms per frame.
- Title memory can be opened as a graphics heap so that buffers are used in place instead of copied (`VICTORY_INPLACE`, first stage only; a probe confirmed the approach on the test GPU).
- The bindless texture queue no longer uploads stale views; the view table no longer grows without bound; the pipeline library is mapped instead of read into memory.
- An intermittent device loss was traced to the pipeline library file being replaced while mapped; fixed.

- Translated shaders get clean-up passes over the finished module (dead code, constant folding, reuse of values, branch facts); the pack's host instruction count falls by about 43 %, worth about 20 ms of GPU time per frame on the test machine (`VICTORY_SHADER_OPT=0` turns them off).

Most of the newer speed changes sit behind environment switches that are off
by default (`VICTORY_LATE_WAIT`, `VICTORY_RELAY`, `VICTORY_WIDE_BACK`,
`VICTORY_CARD_BUFFERS_MIN_MB`, `VICTORY_INPLACE`, `VICTORY_BVH_BUILDER`, ...).
Each is described in a comment where it is read.

### Known problems

- Everything in shadow is black (see above).
- The interior of the first gameplay room is sometimes not drawn after the cutscene hands over to gameplay.
- Around 24 GB of memory is in use during play.
- A few style lints are switched off for this fork in the workspace `Cargo.toml` until the newer code is tidied.
- Many changes here are specific to this title and this GPU, and some are marked `shortcut:` in the code where they approximate what we believe the console does; that behaviour is inferred from the title's calls and public sources, not verified against platform documentation.


# VIctory

Runs the title (Xbox Series X|S) natively on Windows, from files
the user supplies.

The title's x86-64 code runs unchanged inside our process; VIctory supplies
the platform underneath it and converts the title's data, ahead of time where
it can and on first use where it must (shaders). See
[docs/architecture.md](docs/architecture.md).

## Status (2026-11-23)

**Not playable yet.** The title boots, runs its menus at its own 30 fps and
loads the world, where rendering fails.

| Stage | State |
|-------|-------|
| Boot, first-boot screens (accessibility, language, settings, legal) | works, 30 fps |
| Intro video with sound | works |
| Start screen, profile and saves | works |
| Loading into the world (about 50 s) | works |
| The world (first mission's intro) | reached and runs with indirect draws; its title card renders, the scene after it is still dark; 0.5-1.8 s per frame |

Tested on one machine: Windows 11, AMD RX 6700 XT.

> **Warning.** Entering the world on a real GPU can currently hang it, and
> Windows then resets the display driver (every monitor goes black for a
> moment). To look further, use a diagnostics build with
> `VICTORY_D3D12_WARP=1`, which renders on the software adapter.

What each part does today and what it still needs:

| Subsystem | Today | Needs |
|-----------|-------|-------|
| Loader | Runs the title's executable and its DLLs in our process; crash reports name the faulting code and are kept in `crashes.log` | – |
| Runtime services | One signed-in offline user, licences, packages, saves that survive a kill at any step, text entry dialog | Speech is silent; the dialog and relaunch are untested live |
| Network | Offline by design: the title cannot reach the network | – |
| Files and streaming | Archives and streamed data read, zlib and BCPack decoded in parallel | Loading is limited by writes into title memory |
| Input | XInput pads, keyboard, keyboard stand-in pad | Trigger rumble |
| Audio | Menu, video and loading sound; XMA voices and Opus streams decode | Reverb is silent; Opus results unverified against the title |
| GPU: menus | Draws, compute and presentation on host D3D12; only changed title memory is copied | Frame pacing drifts on one screen in release builds |
| GPU: world | Mesh pipelines, shader-written buffers, descriptor lifetimes, indirect execution (arguments clamped), pipelines made by worker threads and kept on disk | Most of the scene is still missing (untranslated shaders drop draws); frames take seconds; real queries, depth bounds, HDR and scaling are missing |
| Shaders | Console GPU code recompiled to DXIL at first use, cached on disk. Menus: all. World: mesh 8,191 of 8,506, vertex/pixel 10,617 of 12,346, compute 1,643 of 2,539 | 64-bit image atomics, merged geometry stages, the ray-tracing builder's shaders; some compute programs need a GPU with 64-lane waves |
| Textures | Tiled layouts and detiling for the modes the title uses, from AMD's public address library (as in Mesa); whether the console's modes match is unverified | Render-target metadata planes |
| Series S mode | Runs through the menus to the loading screen | The world, as above |

## Getting started

Requirements: Windows 10/11 x64, a CPU with AVX2, a Direct3D 12 GPU with
shader model 6.6 (and mesh shaders for the world), Rust (pinned in
`rust-toolchain.toml`).

The title also needs several GiB of available Windows commit at startup.
Check **Committed** under **Task Manager → Performance → Memory**. If
`crashes.log` reports Windows error 1455, close other applications or increase
the Windows paging file size, then retry.

```powershell
cargo xtask install-hooks                # asset-policy check on every commit
copy victory.example.toml victory.toml   # then set your paths (outside the repo)
cargo test --workspace                   # needs no game data
cargo run -p victory -- config           # check your paths
```

Run the title:

```powershell
cargo build --release -p victory
target\release\victory.exe run <game dir>\<the title's exe> --execute
```

The window caption shows the framerate. Saves, settings and `crashes.log`
are kept under the data folder (default `%LOCALAPPDATA%\victory\data`), derived
data under the cache folder.

Input: XInput pads. With none connected the keyboard is a pad while the
title's window has focus:

| Keys | Pad |
|------|-----|
| W A S D / I J K L | left / right stick |
| arrows | D-pad |
| Enter, Backspace, X, Y | A, B, X, Y |
| Q / E, Z / C | shoulders, triggers |
| F / H | stick clicks |
| Esc, Tab | Menu, View |

## Commands

```
victory inspect <exe|dll> [--imports] [--exports]
victory census [paths...] [--missing] [--strict]
victory lib-exports <import.lib> [--list]
victory shader-info [paths...] [--verbose] [--disasm]
victory translate [paths...] [--validate] [--pipelines] [--list] [--jobs N]
victory precompile [paths...] [--jobs N]   # fill the run's shader cache ahead
                                           # (default: the game's shaders.rpf)
```

Test harness (Windows PowerShell; see `docs/directions.md`, D0): repeatable
scenarios from `scenarios/*.json`, with graphics presets, data snapshots
and scripted input kept in `%LOCALAPPDATA%\victory\harness`:

```powershell
.\scripts\harness.ps1 list
.\scripts\harness.ps1 snapshot world       # after saving in the world
.\scripts\harness.ps1 run world-continue   # or: ninja scenarios
.\scripts\harness.ps1 record my-route -SnapshotAs world   # play; your presses become the scenario's keys
.\scripts\smoke.ps1 -Seconds 300 -Env 'VICTORY_PROFILE=low'   # quick one-off

# The control app (Electron): run and record scenarios, follow a run live.
cd tools\control; npm install; npm start
victory run <exe> [--execute] [--unimplemented trap|zero] [--strict]
            [--console series-x|series-s] [-- <title arguments>]
victory config
```

Logging: `VICTORY_LOG=victory_loader=trace,info` (a release build logs
info and above).

## Debugging

A release build has no debugging aids. Build them in with

```powershell
cargo build --profile diag -p victory --features diagnostics   # target\diag\victory.exe
```

| Variable | Effect |
|----------|--------|
| `VICTORY_LOG=<target>=debug,...` | debug and trace output |
| `VICTORY_STACKS=20,60` | every thread's stack at those seconds |
| `VICTORY_WATCH=<rva>,...` | logs a title u32 when it changes |
| `VICTORY_KEYS=30:Enter,35:X` | (any build) presses keys at those seconds, focus or not; the harness (`scripts/harness.ps1`) uses it to get past menus |
| `VICTORY_CRASH_SAVE=<rva>:<len>,...` | saves title memory to the cache folder on a crash |
| `VICTORY_CAPTURE=<dir>` | saves presented frames (powers of two, or `VICTORY_CAPTURE_FRAMES=<list>`) |
| `VICTORY_DUMP_TARGETS=1` | with the two above, saves every render target of those frames |
| `VICTORY_D3D12_DEBUG=1` | host debug layer |
| `VICTORY_D3D12_GBV=1` | with the above, GPU-based validation (bad descriptor use reported, not faulted; slow) |
| `VICTORY_D3D12_DRED=1` | on a GPU failure, the allocation hit and the commands in flight |
| `VICTORY_PIPELINE_WAIT_MS=24` | reduce the per-frame wait for background pipeline creation from the default of 500 ms. A draw can be omitted until its pipeline is ready |
| `VICTORY_SKIP_PIPELINES=<hash>,...` | omit draws and dispatches, including indirect ones, whose pipeline contains a listed 16-digit shader hash |
| `VICTORY_GPU_TIMING=1` | with the above, each list of a submission run and timed on its own; slow lists logged with their slowest commands |
| `VICTORY_D3D12_WARP=1` | host device on the software adapter (slow; cannot reset the driver) |
| `VICTORY_SHADER_LOOP_LIMIT=<n>` | (any build) translated shader loops stop after `n` iterations per lane and per loop entry, in every stage, instead of the per-stage caps (pixel 128, vertex and mesh 256, compute 4,096); own shader cache entries. If a lower `n` makes world frames much faster, loops hitting the limit are what makes them slow |
| `VICTORY_PROFILE=low` | (any build) trade correctness of effects for frames: every translated loop stops after 64 iterations unless `VICTORY_SHADER_LOOP_LIMIT` says otherwise. Precompile with the same setting |
| `VICTORY_EVENTS=<file>` | (any build) one JSON line per event: start, adapter, display mode, input (key and pad presses on the `VICTORY_KEYS` clock), frame statistics, memory, device removal. The harness sets it for every run |
| `VICTORY_DISPLAY_MODE=WxH` | (any build) the display mode reported to the title (default 3840x2160). The title still presents 3840x2160 with a smaller mode (2026-11-25): its output size comes from elsewhere |
| `VICTORY_AUDIO_CAPTURE=<file.wav>` | records what the title plays (our process only) |
| `VICTORY_XMA_DUMP=<dir>` | saves the first 32 XMA voices' context and input |

Every build appends crashes and host GPU failures to `crashes.log` in the
title's data folder.

These are crashes of the title *under VIctory*: they describe our layer's
behaviour, never the console's. Crash and hang data about the title itself
comes only from real console hardware.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
