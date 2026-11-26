# Decision record, 2026-11-24 to 2026-11-26

Every direction this fork took in its first three days: what was adopted
(won), what was tried and failed or was rejected (lost), what was started and
then parked or dropped (drifted), the process mistakes behind the losses, and
every related repository that was evaluated. Numbers are from unattended
harness runs on one machine (Windows 11, AMD RX 6800M 12 GB laptop, 16 GB
RAM, Series S profile unless noted). Frame times are world medians.

Read the numbers with two cautions:

- **Picture:** runs before 2026-11-26 were judged by numbers only. Their
  gameplay picture was black (ADR-L12), so their frame times measure a frame
  whose lighting and upscale never ran.
- **Machine state:** GPU times on 2026-11-25 morning and 2026-11-26 are
  inflated by the driver state after Modern Standby (ADR-P2). Compare
  same-session runs only.

## Status key

- **Won:** adopted and kept, on `main` unless a branch is named.
- **Lost:** tried and failed, measured worse, or disproved.
- **Drifted:** started or planned, then parked, dropped or overtaken.
- **Open:** in progress now.

## Won

| ID | Decision | Evidence | Where |
|----|----------|----------|-------|
| W1 | Build without Visual Studio: Ninja, xwin libraries, rust-lld | builds on a machine with no MSVC | `main` |
| W2 | Precompile every shader the title ships; cache keyed by translator source (`TRANSLATOR_ID`), not the exe | rebuilds keep the cache; ~26k shaders in ~3 min when the translator changes | `main` |
| W3 | Pipeline recipes recorded at first use and replayed by `precompile --pipelines` (D4) | 0 pipelines being made in gameplay | `main` |
| W4 | Test harness (D0): scenarios, presets, snapshots, events JSONL, milestone-driven scripted input, backup and restore of title data, power mode per run | every result in this record comes from it | `main` |
| W5 | Series S profile as the default test target | title renders 1080p by itself; ~2x the frame rate of 4K | `main` |
| W6 | Drop reasons explained (N2): of ~285 drops a frame, 255 are the ray-tracing structure builder (off by design) and ~20 are the upscaler (see W13) | diagnostics run | `main` |
| W7 | 16-bit wave sum where not every lane runs, bit for bit as the console | drops 300 to 280 a frame | `main` |
| W8 | Upstream translator batch I1 (40 commits); console-exact float rules made opt-in (`VICTORY_F16_NEAREST`, `VICTORY_EXACT_FLOATS`, `VICTORY_DISCARD_HELPERS`) | tests pass; always-on cost too much GPU time | `main` |
| W9 | Title memory in place (B1), on by default | route 244 to 211 ms, CPU prep 192 to 163 ms | `main` (`cac0620`) |
| W10 | Physical pages in committed 64 MiB sections, placed in place (`VICTORY_INPLACE_POOL=1`, capped by `VICTORY_INPLACE_POOL_MB=512`), off by default | route 183-205 ms; 12-minute soak passes with the cap | `main` (`e62f085`) |
| W11 | Evidence track: build identity on every run and crash (E1), local symbol store (E2), hang detector with a minidump of our process (E5, E6), layer behaviour not stated as console fact (E11), `docs/assumptions.md` (E12) | in use by every run | `main` |
| W12 | Harness proof of the picture: a window grab every 15 s, brightness per grab, a `picture` summary; runs fail on an early title exit or a host GPU failure; inherited `VICTORY_*` switches recorded | caught the black gameplay that numbers missed | `main` working tree, uncommitted |
| W13 | Root cause of the black gameplay found: (1) the title's 16-bit depth mapped to D24 made every tiled-lighting draw fail its depth test on AMD (upstream `98c654b`); (2) the title's FSR4 upscaler programs (an ACCC/FSPX payload, no DXIL) don't translate, so the world never reaches the 3840x2160 present target | presented targets show the drawn G-buffer, the lit 1280x720 scene with the depth fix, and the lit 1920x1080 image after the stop-gap (`media/proof/`) | `depth-float` |
| W14 | Port of upstream `98c654b` (16-bit depth with stencil is float depth on the host), plus upstream `842b0cb` (depth bounds) | lit scene appears in the 1280x720 colour target | `depth-float` (`4e71a18`, `1496486`) |
| W15 | Diagnostics tool `VICTORY_PRESENT_TARGET`, picked from the AMD-focused branch | made W13 provable | `depth-float` (`054edb3`) |
| W16 | Fast 128-bit texture digest instead of BLAKE3 for change detection | texture refresh 59 to 22 ms, CPU prep 147 to 116 ms (same session) | `fps` (`25509b4`) |
| W17 | DirectStorage page lists: the title fills them after enqueueing, so a page number 0 is waited for at execution | write failures 1-14 a run, then 0 in the runs since | `main` (`2ed16da`) |
| W18 | Publishing: public repo `mohigamedev/mohiworks` (GPL-3.0), local rules (no personal account name, no AI attribution, no title name in the tree), GitHub CLI signed in as the publishing account | pre-push checks on every push | `main` |
| W19 | Tracking request on the community tracker (issue #148), with a correction comment once the black picture was seen | posted | tracker |

## Lost

| ID | What was tried | Result | Lesson |
|----|----------------|--------|--------|
| L1 | Show a reservation of physical pages whole (`VICTORY_INPLACE_VIEWS=1`, the view half of B1) | never qualifies: the title maps one ~4 GB allocation into a 16 GiB reservation page by page | the other branch's memory layout does not carry over |
| L2 | Mirror the title's page mapping on the GPU with tiled resources over a section heap | D3D12 refuses: "UpdateTileMappings does not work with cross-adapter shared heaps"; the device is removed | runtime rule; ~210 MB of scattered memory stays copied (probe kept, by hand) |
| L3 | Pool sections uncapped | 1.3 GB open ran the card's shared budget (7.2 GB) out a minute later; the title exited | capped at 512 MB (W10) |
| L4 | Pool switch on by default | margin of ~300 MB of shared budget on a 16 GB machine | stays opt-in |
| L5 | Copy DirectStorage page lists at enqueue | almost every read saw page 0; the world never loaded | the title fills them after enqueue (W17) |
| L6 | Bring the fxceless fork's 27 performance commits | 5 picked; the rest are a chain built on a heap-sync layer we don't have, overlapping our in-place design; the 5 picks ran slower (349 ms) | a real merge is a design decision, not picks |
| L7 | Turn on the faster forks' off-by-default switches all at once (`tmp-fastflags`) | slower, 287 to 344 ms; the card-buffer pair alone raised GPU 158 to 216 ms and the frame to 326 ms | test switches singly; card buffers stay off while the GPU is the bottleneck |
| L8 | Ray-tracing structure builder on (`VICTORY_BVH_BUILDER=1`) | the title crashes at ~110 s | needs write marks first |
| L9 | Report a 1080p display mode to make the title skip its upscaler | still upscales, still black | the upscaler must run or be replaced |
| L10 | Upscaler stop-gap (`VICTORY_UPSCALE_BLIT=1`): first version | copied the output-sized history (black) | prefer a smaller colour input |
| L11 | Stop-gap through the normal per-view setup, then a tone-mapped composite into the 4K target at the first render-target bind | lit image reaches 1920x1080, but the presented 4K image stays black | in progress (O1) |
| L12 | Claim "renders at 4-5 fps" in the README and the tracker | the picture was black; claims corrected | see P1 |
| L13 | Explanations that turned out wrong: black = missing ray-traced light; black start screen; low profile, low preset, texture guard or the I1 batch as the cause; the depth fix as the source of the GPU jump | each disproved by a run | test the explanation before reporting it |
| L14 | X post with a demo video | no usable gameplay footage (black) | parked until the picture is fixed |

## Drifted

| ID | Item | State |
|----|------|-------|
| D1 | Write marks (I2): copy back only pages shaders wrote | M1 (translator emission, off by default) done on `write-marks` (`101d063`); M2-M5 parked |
| D2 | GPU texture detile (D3) | designed (one generic shader, the title uses no XOR modes in sampled textures); not started; the fast digest (W16) took most of the cheap gain first |
| D3 | GPU upload heaps (Agility SDK, Resizable BAR) | designed; needs the Agility SDK shipped and a capability probe; not started |
| D4 | Official components: Gaming Services runtime for async, dialogs and networking behind a switch; GameInput shim; FidelityFX PC upscaler | evaluated; correctness, not frame rate; not started |
| D5 | Remaining evidence items E3 (symbolize), E8 (GPU hang report), E13 (assumption lint), E10, E9, E7 | parked behind the picture work |
| D6 | Frame pacing (D6), handle-pool root cause (D7), symbols for the title's own code (D5) | not started |
| D7 | 4K output tuning | dropped by the owner: Series S is the target |
| D8 | Real console as a reference | dropped: the console's owner doesn't own the title |
| D9 | `fx-perf` branch (5 picks) | parked, slower |
| D10 | `deserialize-pipelines` branch (stop-gap origin) | superseded by `depth-float`, which carries its commits |
| D11 | Ambient stand-in light, as the other forks use | needs an owner decision; not the title's own light |
| D12 | Picking LNX-victory commits | needs an owner decision: their messages carry AI co-author trailers, outside our exemption list |

## Open

| ID | Item |
|----|------|
| O1 | Black-frame agent: put the world into the presented 4K image (present-time test, then the right hook point), with proof frames |
| O2 | Frame-rate agent: single-switch A/B runs, the BLAKE3 control, then write marks; copy-back (~190 ms today) sets the pace |
| O3 | The real upscaler: implement device slots 0x1c8/0x218 (`DeserializeComputePipelineStateX`) or translate the FSPX payload |
| O4 | Re-measure everything on a lit, presented picture after a driver reset |

## Process lessons

| ID | Lesson | Now |
|----|--------|-----|
| P1 | For about 24 hours every result was judged by frame time, draws and removals; a black picture passed every check, and claims went public | harness window grabs and a `picture` summary (W12); a standing rule to look at frames before reporting |
| P2 | Modern Standby left the GPU driver in a slow state twice (2026-11-25 morning, 2026-11-26): GPU 30 to 110-230 ms until a reset | compare same-session runs; reset the driver (Win+Ctrl+Shift+B) or reboot before baselines; keep-awake during work |
| P3 | Builds or a second process during a run caused GPU hangs (memory pressure on 16 GB) | a GPU lock file shared by agents; one run or build at a time |
| P4 | A single agent waited on runs and drifted; a strict priority rule starved the second agent | two focused agents (picture, frame rate) that alternate the GPU |
| P5 | Agent and tool reports were relayed without a check (a wrong "known limit" explanation, a misread capture) | verify against a run or an older build before relaying |

## Repositories evaluated

| Repository | What it is | Verdict for us |
|------------|------------|----------------|
| Marvisak/VIctory (upstream) | the base; ~480 commits past our merge base | I1 translator batch taken (W8); `98c654b` and `842b0cb` ported (W14); its memory batch (`c75fdba` and others) and write marks (`cd94d35`) diverge from our in-place design (D1) |
| fxceless/victory-fork | earlier fork, 8-10 fps on an RTX 4070 | `c96b4f2` defaults and the 5 picks tried (L6, L7); the perf chain needs a merge decision |
| Zettrox/ztrx | the fork plus a README and launcher | no code we lack; its lead is long test sessions; ignored |
| the earlier fork clone, xcl | this fork's earlier clones | retired; their GitHub forks deleted; XCL (GPL-2.0) used for ideas only |
| Local reference project (Vulkan, does not boot the title) | read from a downloaded archive | ideas I8-I10 (content-addressed descriptors, hardware-measured float rules, structure-builder notes) |
| Belobug/VIctory-Belobug-AMD | AMD-focused branch, 3-5 fps on an RX 9070 XT | B1 in-place idea adopted in our own form (W9); its whole-view half failed here (L1); present-target tool picked (W15); ambient stand-in pending (D11) |
| avatarmanz/VIctory-7900XTX | 6-16 fps on an RX 7900 XTX, i9-12900K, 64 GB, 1440p, with an ambient stand-in | fast digest ported (W16); its other gains are many-thread CPU work and a 40-46 GB footprint that doesn't fit 16 GB |
| DexNom/VIctory, Ryanabcraft/scarlett-victory-bench, ZSlayerHQ runtime | AMD fork and a benchmark fork with measured before/after | measurement method worth copying; their rejected ideas skipped; card-buffer defaults hurt here (L7) |
| Linox-IDK/LNX-victory | 7-8 fps on an RTX 5060 Ti, Series S plus host FSR (PC FidelityFX DLL), ambient stand-in | its FSR route is a candidate for O3; picks blocked on D12 |
| 4lwayz/portwatch-vi | community tracker | listed via issue #148 (W19) |

## Branches and commits at the time of writing

| Branch | Head | Pushed | Contents |
|--------|------|--------|----------|
| `main` | `f609482` | yes | W1-W11, W17-W19 |
| `depth-float` | `51f3c54` (+ uncommitted composite work) | no | W13-W15, stop-gap (L10, L11) |
| `fps` | `25509b4` | no | W16 on top of `depth-float` |
| `write-marks` | `101d063` | no | D1 step M1 |
| `fx-perf` | `1472e8e` | no | L6 picks |
| `deserialize-pipelines` | `9dad1f1` | no | stop-gap origin (D10) |
