# Assumptions that platform documentation would settle

VIctory reimplements console system APIs, GPU objects and formats without
the platform's documentation, which is under NDA and which we do not have.
What it believes about them comes from three sources: the **title's calls**
(what the title passes and expects, read under this layer), **public
sources** (Mesa's AMD address library, AMD's RDNA2 ISA reference, FFmpeg,
LLVM) and **measurement** on PC hardware. None of it is console fact until
someone with platform access confirms it.

This index lists those claims. In code each carries a tag of the form

    // unverified(nda): <what> | src=<call|public|measured> | id=A001

(one tag at the head of a method-slot table, not one per slot). A
`shortcut:` comment is different: it marks a deliberate approximation, not
a claim about the platform.

Status:
- `open`: derived, not checked against anything else.
- `verified-public`: checked against a public source that states it.
- `needs-platform-docs`: only platform documentation (or someone with
  access to it) can settle it.

Nothing here is console crash or hang data: that comes only from real
console hardware.

| ID | Claim | Source | Where | Risk if wrong | Status |
|----|-------|--------|-------|---------------|--------|
| A001 | The console device's method slots (IUnknown, object, device methods 0x18-0x290, the `ID3D12Device1..8` additions in order, console methods among them) | call | `crates/victory-gpu/src/device.rs` (`FUNCTIONS`) | a call reaches the wrong method silently | needs-platform-docs |
| A002 | Command list and allocator method slots, including console methods (ExecuteIndirect 0x1e8, state flush, 0x470 ignored) | call | `crates/victory-gpu/src/list.rs` (method table) | wrong commands recorded | needs-platform-docs |
| A003 | Other object tables: descriptor heaps, fences, queues, DXGI device, adapter, factory and output (3 console output methods) | call | `descriptor.rs`, `fence.rs`, `dxgi.rs`, `queue.rs` (`FUNCTIONS` tables) | as A001 | needs-platform-docs |
| A004 | Descriptor and root-view layouts: the creation-interface layouts, root views without a size (64 KiB taken for constant buffers) | call, measured | `crates/victory-gpu/src/descriptor.rs`, `draw.rs` | corrupt descriptors, missing draws | needs-platform-docs |
| A005 | `XMemAlloc` attribute bits: alignment as log2 in 5 bits at bit 24, then the memory type, bit 33 for a 32-bit address | call | `crates/victory-hle/src/modules/xmem.rs` | wrong alignment or placement | needs-platform-docs |
| A006 | Title memory budgets: Series X 10 GiB GPU-optimal plus 3.5 GiB standard; Series S 7,776 MiB | public figure, call | `crates/victory-gpu/src/console.rs` (`title_memory`) | budget queries answered wrong; the title sizes nothing from them today | needs-platform-docs |
| A007 | The console's texture swizzle modes are the GFX10 address library's, numbered as `ADDR_SW_*`; no compression planes (HTILE, CMASK, FMASK, DCC) | public (Mesa addrlib), call | `crates/victory-formats/src/texture.rs` | garbled textures | open (addrlib part public; the numbering on the console needs platform docs) |
| A008 | The console's default float mode: f16 rounding to nearest, f32 denormals read as zero for max/min/med3 and conversions | public (AMD RDNA2 ISA), measured on PC RDNA2 | `crates/victory-shader/src/emit/float_switches.rs` | small numeric drift; the exact forms are opt-in switches | open (ISA part public; the console's MODE defaults need platform docs) |
| A009 | BCPack (DirectStorage compression) and its constant tables | call, title data | `crates/victory-formats/src/bcpack.rs`, `bcpack-tables.bin` | failed decompression (fails loudly) | needs-platform-docs |
| A010 | XMA and the audio processor's contexts | public (FFmpeg XMA), call | `crates/victory-formats/src/xma.rs`, `crates/victory-hle/src/modules/apu.rs`, `audio.rs` | audio glitches | open |
| A011 | Save, package, user and store formats and behaviour | call | `crates/victory-hle/src/modules/xgamesave.rs`, `xpackage.rs`, `xuser.rs`, `xstore.rs`, `xgameruntime.rs` | saves not compatible with a console | needs-platform-docs |
| A012 | DirectStorage requests, queues and physical-page allocation | call | `crates/victory-hle/src/modules/dstorage.rs` | failed or wrong streaming | needs-platform-docs |

To add a claim: a row here with the next ID, and the tag at the code that
relies on it.
