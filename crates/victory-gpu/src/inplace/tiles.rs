//! Whether the GPU can be given the title's own page mapping: a reserved
//! resource whose 64 KiB tiles are mapped (`UpdateTileMappings`) onto a
//! committed section of physical pages opened as a heap. The console's
//! page is the tile's size, so `XMemMapPhysicalPages` would become one
//! tile mapping per run of pages, and scattered or holed title memory could
//! be used in place instead of copied.
//!
//! Answer (2026-11-25, WARP with the debug layer): no. "UpdateTileMappings
//! does not work with cross-adapter shared heaps", and every heap opened on
//! an address or a section is cross-adapter shared; the device is removed.
//! The probe stays as the record and to notice a runtime that allows it.
//! It asks: does the runtime take the mapping, does the GPU read the
//! section's pages through it in the order mapped, does a hole read zero,
//! does a GPU write land in the section, and is the device still there.

use super::{From, K64, Rig, fill, hr, open};
use windows::Win32::Graphics::Direct3D12::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC;
use windows_sys::Win32::System::Memory as mem;

/// What the probe found.
#[derive(Debug, Default)]
pub(crate) struct Tiles {
    pub(crate) lines: Vec<String>,
    /// The device's tiled resources tier (0 none).
    pub(crate) tier: i32,
    /// A reserved buffer was made, with the flags that worked.
    pub(crate) reserved: bool,
    /// The GPU read the section's pages through the tiles, in mapped order.
    pub(crate) reads: bool,
    /// An unmapped tile read zero.
    pub(crate) hole_zero: bool,
    /// A GPU write through a tile landed in the section's page.
    pub(crate) writes: bool,
    /// The device was not removed by any of it.
    pub(crate) device_alive: bool,
}

fn reserved_desc(size: u64, flags: D3D12_RESOURCE_FLAGS) -> D3D12_RESOURCE_DESC {
    D3D12_RESOURCE_DESC {
        Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
        Width: size,
        Height: 1,
        DepthOrArraySize: 1,
        MipLevels: 1,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        Flags: flags,
        ..Default::default()
    }
}

/// Maps tile `tile` of `resource` onto tile `at` of `heap`, or unmaps it
/// with `at` `None`.
fn map_tile(rig: &Rig, resource: &ID3D12Resource, heap: &ID3D12Heap, tile: u32, at: Option<u32>) {
    let start = D3D12_TILED_RESOURCE_COORDINATE { X: tile, Y: 0, Z: 0, Subresource: 0 };
    let size = D3D12_TILE_REGION_SIZE { NumTiles: 1, UseBox: false.into(), Width: 1, Height: 1, Depth: 1 };
    let (flag, offset, count) = match at {
        Some(at) => (D3D12_TILE_RANGE_FLAG_NONE, at, 1u32),
        None => (D3D12_TILE_RANGE_FLAG_NULL, 0, 1u32),
    };
    // SAFETY: live objects; one region of one tile, one range.
    unsafe {
        rig.queue.UpdateTileMappings(
            resource,
            1,
            Some(&start),
            Some(&size),
            heap,
            1,
            Some(&flag),
            Some(&offset),
            Some(&count),
            D3D12_TILE_MAPPING_FLAG_NONE,
        );
    }
}

/// The probe on `device`, with a section of its own (four 64 KiB pages).
pub(crate) fn probe(device: &ID3D12Device) -> Tiles {
    let mut t = Tiles::default();
    let mut options = D3D12_FEATURE_DATA_D3D12_OPTIONS::default();
    // SAFETY: a valid out struct of the right size.
    let asked = unsafe {
        device.CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, (&raw mut options).cast(), size_of_val(&options) as u32)
    };
    t.tier = if asked.is_ok() { options.TiledResourcesTier.0 } else { 0 };
    t.lines.push(format!("tiled resources tier {}", t.tier));
    if t.tier < 2 {
        t.lines.push("tier 2 is needed for holes that read zero: not tried".to_owned());
        return t;
    }
    // SAFETY: a section and views of the probe's own, released below.
    unsafe {
        use windows_sys::Win32::System::Memory::{CreateFileMappingW, FILE_MAP_WRITE, MapViewOfFile, SEC_COMMIT, UnmapViewOfFile};
        let handle = CreateFileMappingW(-1isize as _, std::ptr::null(), mem::PAGE_READWRITE | SEC_COMMIT, 0, 4 * K64 as u32, std::ptr::null());
        if handle.is_null() {
            t.lines.push("no section".to_owned());
            return t;
        }
        let view = MapViewOfFile(handle, FILE_MAP_WRITE, 0, 0, 4 * K64);
        let base = view.Value as *mut u8;
        for page in 0..4 {
            fill(base.add(page * K64), K64, 0x40 + page as u8);
        }
        let heap = open(device, From::Section(handle as usize));
        t.lines.push(format!("the section opened as a heap: {}", hr(&heap)));
        if let Ok(heap) = &heap {
            tiles_on(device, heap, base, &mut t);
        }
        drop(heap);
        UnmapViewOfFile(view);
        windows_sys::Win32::Foundation::CloseHandle(handle);
    }
    // SAFETY: a plain query.
    t.device_alive = unsafe { device.GetDeviceRemovedReason() }.is_ok();
    t.lines.push(format!(
        "VERDICT: tier {}, reserved buffer {}, reads in mapped order {}, hole reads zero {}, writes land in the section {}, device alive {}",
        t.tier, t.reserved, t.reads, t.hole_zero, t.writes, t.device_alive
    ));
    t
}

/// The part with a heap: `base` is a view of the whole section.
unsafe fn tiles_on(device: &ID3D12Device, heap: &ID3D12Heap, base: *mut u8, t: &mut Tiles) {
    let Ok(mut rig) = Rig::new(device) else {
        t.lines.push("no queue".to_owned());
        return;
    };
    // The heap is shared across adapters; a reserved resource may or may
    // not have to say so too: both are tried.
    let mut resource = None;
    for (name, flags) in [
        ("unordered access", D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS),
        ("unordered access, cross-adapter", D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_ALLOW_CROSS_ADAPTER),
    ] {
        let mut made: Option<ID3D12Resource> = None;
        // SAFETY: plain creation.
        let r = unsafe { device.CreateReservedResource(&reserved_desc(3 * K64 as u64, flags), D3D12_RESOURCE_STATE_COMMON, None, &mut made) };
        t.lines.push(format!("a reserved buffer of 3 tiles ({name}): {}", hr(&r)));
        if r.is_ok() && made.is_some() {
            resource = made;
            break;
        }
    }
    let Some(resource) = resource else { return };
    t.reserved = true;
    // Tiles 0, 1 of the buffer onto pages 2, 0 of the section; tile 2 a hole.
    map_tile(&rig, &resource, heap, 0, Some(2));
    map_tile(&rig, &resource, heap, 1, Some(0));
    map_tile(&rig, &resource, heap, 2, None);
    // SAFETY: a plain query.
    if let Err(e) = unsafe { device.GetDeviceRemovedReason() } {
        t.lines.push(format!("the device was removed by the mappings: {e}"));
        return;
    }
    match rig.fetch(&resource, 0, 3 * K64) {
        Ok(got) => {
            // SAFETY: the view holds four pages.
            let (page2, page0) = unsafe { (std::slice::from_raw_parts(base.add(2 * K64), K64), std::slice::from_raw_parts(base, K64)) };
            t.reads = &got[..K64] == page2 && &got[K64..2 * K64] == page0;
            t.hole_zero = got[2 * K64..].iter().all(|&b| b == 0);
            t.lines.push(format!("the GPU read through the tiles: pages 2 then 0 {}; the hole zero {}", t.reads, t.hole_zero));
        }
        Err(e) => t.lines.push(format!("the GPU's read failed: {e}")),
    }
    match rig.store(&resource, K64 as u64 + 64, &[0xc3; 128]) {
        Ok(()) => {
            // SAFETY: the view holds page 0.
            t.writes = unsafe { std::slice::from_raw_parts(base.add(64), 128) }.iter().all(|&b| b == 0xc3);
            t.lines.push(format!("a GPU write through tile 1 shows in the section's page 0: {}", t.writes));
        }
        Err(e) => t.lines.push(format!("the GPU's write failed: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::warp;
    use super::*;
    use windows::core::Interface;

    /// The tile probe on the software adapter. Found 2026-11-25: the
    /// runtime refuses it ("UpdateTileMappings does not work with
    /// cross-adapter shared heaps") and removes the device, and a heap
    /// opened on a section is always cross-adapter shared. This test holds
    /// that; if a runtime ever allows it, it fails and says so. By hand
    /// only (`-- --ignored`): the software adapter's device is one per
    /// process, and its removal fails every other test running beside it.
    #[test]
    #[ignore]
    fn warp_tiles_onto_a_section_are_refused_by_the_runtime() {
        let Some(device) = warp() else { return };
        let t = probe(&device);
        for line in &t.lines {
            eprintln!("tiles: {line}");
        }
        if t.tier >= 2 && t.reserved {
            assert!(!t.device_alive && !t.reads, "the runtime now maps tiles onto a section's heap: scattered title memory can be placed");
        }
    }

    /// With the debug layer (if installed), what the runtime says of the
    /// mappings: run by hand, `-- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn warp_tiles_debug_layer_says_why() {
        use windows::Win32::Graphics::Direct3D::D3D_FEATURE_LEVEL_12_0;
        use windows::Win32::Graphics::Dxgi::*;
        // SAFETY: debug layer, then a device on the software adapter.
        unsafe {
            let mut debug: Option<ID3D12Debug> = None;
            if D3D12GetDebugInterface(&mut debug).is_err() {
                eprintln!("tiles: no debug layer installed");
                return;
            }
            debug.unwrap().EnableDebugLayer();
            let factory: IDXGIFactory4 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0)).unwrap();
            let adapter: IDXGIAdapter = factory.EnumWarpAdapter().unwrap();
            let mut device: Option<ID3D12Device> = None;
            D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_12_0, &mut device).unwrap();
            let device = device.unwrap();
            let t = probe(&device);
            for line in &t.lines {
                eprintln!("tiles: {line}");
            }
            let queue: ID3D12InfoQueue = device.cast().unwrap();
            for i in 0..queue.GetNumStoredMessages() {
                let mut len = 0usize;
                let _ = queue.GetMessage(i, None, &mut len);
                let mut buf = vec![0u8; len];
                let msg = buf.as_mut_ptr().cast::<D3D12_MESSAGE>();
                if queue.GetMessage(i, Some(msg), &mut len).is_ok() {
                    eprintln!("debug: {}", std::ffi::CStr::from_ptr((*msg).pDescription.cast()).to_string_lossy());
                }
            }
        }
    }

    /// The same on the first hardware adapter, by hand only (it may remove
    /// the device): `cargo test -p victory-gpu card_tiles -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn card_tiles_onto_a_section() {
        use windows::Win32::Graphics::Direct3D::D3D_FEATURE_LEVEL_12_0;
        use windows::Win32::Graphics::Dxgi::*;
        // SAFETY: plain DXGI queries and device creation.
        let device = unsafe {
            let factory: IDXGIFactory4 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0)).unwrap();
            let mut found = None;
            for i in 0.. {
                let Ok(adapter) = factory.EnumAdapters1(i) else { break };
                let desc = adapter.GetDesc1().unwrap();
                if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 == 0 && desc.DedicatedVideoMemory > 1 << 30 {
                    found = Some(adapter);
                    break;
                }
            }
            let mut device: Option<ID3D12Device> = None;
            D3D12CreateDevice(&found.expect("a card"), D3D_FEATURE_LEVEL_12_0, &mut device).unwrap();
            device.unwrap()
        };
        let t = probe(&device);
        for line in &t.lines {
            eprintln!("tiles: {line}");
        }
    }
}
