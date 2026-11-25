//! `victory audit textures`: the texture descriptions earlier runs recorded
//! (`texture-descs.csv` in the pipeline cache folder,
//! `victory_gpu::texture_census`), checked without the title: which have
//! no console layout and why, whether every mip and slice detiles, and
//! what detiling each kind costs on this CPU (the per-frame `textures_ms`
//! is mostly this work; docs/directions.md D3).
//!
//! Writes a JSON summary when asked (`--json <file>`), which the harness's
//! audit step compares with the last one.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result};

/// Detiles at most this many array slices of one texture (the cost is
/// scaled up to all of them): arrays of hundreds of slices would take
/// minutes and say nothing more.
const SLICES: u32 = 4;

#[derive(Default)]
struct Kind {
    textures: u64,
    bytes: u64,
    seconds: f64,
    failed: u64,
}

#[cfg(windows)]
pub fn textures(file: Option<PathBuf>, json: Option<PathBuf>) -> Result<()> {
    use victory_gpu::texture_census::{FILE, Seen};
    let file = match file {
        Some(f) => f,
        None => victory_core::Config::load()?.cache_subdir("pipelines")?.join(FILE),
    };
    let text = std::fs::read_to_string(&file)
        .with_context(|| format!("reading {} (a run records it; none yet?)", file.display()))?;
    let seen: Vec<Seen> = text.lines().filter_map(Seen::parse).collect();
    println!("descriptions   {} in {}", seen.len(), file.display());

    let mut unlaid: BTreeMap<String, u64> = BTreeMap::new();
    let mut kinds: BTreeMap<(u32, u32), Kind> = BTreeMap::new();
    let mut failures: BTreeMap<String, u64> = BTreeMap::new();
    let started = Instant::now();
    for s in &seen {
        let Some(t) = victory_gpu::resource::census_layout(s) else {
            let why = if victory_formats::texture::format(s.format).is_none() {
                format!("format {} has no layout", s.format)
            } else if !matches!(s.dimension, 2..=4) {
                format!("dimension {}", s.dimension)
            } else {
                format!("layout field {:#x}", s.layout)
            };
            *unlaid.entry(why).or_default() += 1;
            continue;
        };
        let swizzle = t.planes.first().map_or(0, |p| p.layout.desc.swizzle.0);
        let kind = kinds.entry((s.format, swizzle)).or_default();
        kind.textures += 1;
        kind.bytes += t.size;
        let tiled = vec![0x5Au8; usize::try_from(t.size).unwrap_or(0)];
        let at = Instant::now();
        let mut scale = 1.0;
        'planes: for plane in &t.planes {
            let l = &plane.layout;
            let slices = l.slices.min(SLICES);
            scale = f64::from(l.slices) / f64::from(slices.max(1));
            let Some(tiled) = tiled.get(plane.offset as usize..) else {
                *failures.entry("plane beyond the texture".into()).or_default() += 1;
                kind.failed += 1;
                break;
            };
            for slice in 0..slices {
                for (mip, m) in l.mips.iter().enumerate() {
                    let row = m.width as usize * l.desc.element_bytes as usize;
                    let rows = m.height as usize;
                    let mut linear = vec![0u8; row * rows * m.depth.max(1) as usize];
                    if let Err(e) = l.detile(tiled, mip as u32, slice, &mut linear, row, row * rows) {
                        *failures.entry(format!("{e:?} (format {}, swizzle {swizzle})", s.format)).or_default() += 1;
                        kind.failed += 1;
                        break 'planes;
                    }
                }
            }
        }
        kind.seconds += at.elapsed().as_secs_f64() * scale;
    }

    let laid: u64 = kinds.values().map(|k| k.textures).sum();
    let failed: u64 = kinds.values().map(|k| k.failed).sum();
    println!(
        "laid out       {laid}, without a console layout {}, detile failures {failed}  ({:.1} s)",
        unlaid.values().sum::<u64>(),
        started.elapsed().as_secs_f64()
    );
    for (why, n) in &unlaid {
        println!("  no layout  {n:>6}  {why}");
    }
    for (why, n) in &failures {
        println!("  failed     {n:>6}  {why}");
    }
    println!("detile cost by format and swizzle (whole texture once, this CPU, one thread):");
    let mut rows: Vec<_> = kinds.iter().collect();
    rows.sort_by(|a, b| b.1.seconds.total_cmp(&a.1.seconds));
    for ((format, swizzle), k) in rows.iter().take(25) {
        let mb = k.bytes as f64 / 1e6;
        println!(
            "  format {format:>3} swizzle {swizzle:>2}  {:>6} textures  {mb:>9.1} MB  {:>8.1} ms  {:>7.0} MB/s",
            k.textures,
            k.seconds * 1e3,
            if k.seconds > 0.0 { mb / k.seconds } else { 0.0 }
        );
    }

    if let Some(json) = json {
        let mut out = String::from("{\n");
        out += &format!("  \"descriptions\": {},\n  \"laid_out\": {laid},\n  \"detile_failures\": {failed},\n", seen.len());
        out += "  \"no_layout\": {";
        out += &unlaid.iter().map(|(k, v)| format!("\"{k}\": {v}")).collect::<Vec<_>>().join(", ");
        out += "},\n  \"failures\": {";
        out += &failures.iter().map(|(k, v)| format!("\"{k}\": {v}")).collect::<Vec<_>>().join(", ");
        out += "},\n  \"kinds\": [\n";
        out += &rows
            .iter()
            .map(|((f, sw), k)| {
                format!(
                    "    {{\"format\": {f}, \"swizzle\": {sw}, \"textures\": {}, \"bytes\": {}, \"ms\": {:.3}, \"failed\": {}}}",
                    k.textures,
                    k.bytes,
                    k.seconds * 1e3,
                    k.failed
                )
            })
            .collect::<Vec<_>>()
            .join(",\n");
        out += "\n  ]\n}\n";
        std::fs::write(&json, out).with_context(|| format!("writing {}", json.display()))?;
    }
    Ok(())
}

#[cfg(not(windows))]
pub fn textures(_file: Option<PathBuf>, _json: Option<PathBuf>) -> Result<()> {
    anyhow::bail!("audit needs Windows")
}
