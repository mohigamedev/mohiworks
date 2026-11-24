//! `victory precompile`: translate every shader the title ships into the
//! cache a run reads, before the run. Translating on first use is what
//! leaves the world without most of its draws for minutes on a first run
//! (about 1,000 pipelines queued as it is entered); with the cache full a
//! run only has the host driver's pipeline builds left to do.
//!
//! The translations must be the ones a run on this machine would make:
//! the host GPU's wave width and view heap cap are taken from a device
//! made the way a run makes it, and the loop limit and other switches come
//! from the same environment (`VICTORY_PROFILE`, `VICTORY_SHADER_LOOP_LIMIT`,
//! ...), which the cache keys on. Run it with the switches the game will
//! run with.

use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use anyhow::{Context, Result};

use crate::shader::{MAX_FILE, sources};

#[cfg(windows)]
pub fn run(paths: Vec<PathBuf>, jobs: Option<usize>) -> Result<()> {
    let cfg = victory_core::Config::load()?;
    // Without paths: the game's shader archive, not the whole folder (every
    // file read whole would be tens of GB for nothing).
    let paths = match (&paths[..], &cfg.game_dir) {
        ([], Some(game)) if game.join("shaders.rpf").is_file() => vec![game.join("shaders.rpf")],
        _ => crate::default_paths(paths)?,
    };
    let dir = cfg.cache_subdir("shaders")?;
    victory_hle::modules::d3d12x::use_shader_cache(dir.clone());
    let adapter = victory_gpu::shader_cache::prepare_offline_translation()
        .map_err(anyhow::Error::msg)
        .context("making a host device to translate for")?;
    println!("adapter        {adapter}");
    println!("cache          {}", dir.display());
    println!(
        "loop limit     {}{}",
        victory_shader::emit::loop_limit(),
        if victory_shader::emit::loop_limit() == victory_shader::emit::DEFAULT_LOOP_LIMIT {
            " (per-stage caps)"
        } else {
            ""
        }
    );

    // The containers of every file, each container once.
    let mut containers: Vec<Vec<u8>> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for root in &paths {
        for entry in walkdir::WalkDir::new(root).into_iter().filter_map(Result::ok) {
            if !entry.file_type().is_file() || entry.metadata().map(|m| m.len()).unwrap_or(0) > MAX_FILE {
                continue;
            }
            let Ok(data) = std::fs::read(entry.path()) else { continue };
            let before = containers.len();
            for source in sources(&data) {
                if let Some(bytes) = source.bytes()
                    && seen.insert(blake3::hash(&bytes))
                {
                    containers.push(bytes.into_owned());
                }
            }
            if containers.len() > before {
                println!("found          {} shaders in {}", containers.len() - before, entry.path().display());
            }
        }
    }

    let total = containers.len();
    let jobs = jobs
        .unwrap_or_else(|| std::thread::available_parallelism().map_or(4, |n| n.get()))
        .clamp(1, 64);
    println!("translating    {total} shaders on {jobs} threads");
    let next = AtomicUsize::new(0);
    let done = AtomicUsize::new(0);
    let fresh = AtomicUsize::new(0);
    let failed = Mutex::new(Vec::new());
    let started = Instant::now();
    std::thread::scope(|s| {
        for _ in 0..jobs {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(container) = containers.get(i) else { break };
                    match victory_gpu::shader_cache::precompile(container) {
                        Ok(true) => {
                            fresh.fetch_add(1, Ordering::Relaxed);
                        }
                        Ok(false) => {}
                        Err(e) => failed.lock().unwrap().push(e),
                    }
                    let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                    if n % 1000 == 0 || n == total {
                        println!(
                            "  {n}/{total} ({} translated now, {} failed) {:.0} s",
                            fresh.load(Ordering::Relaxed),
                            failed.lock().unwrap().len(),
                            started.elapsed().as_secs_f64()
                        );
                    }
                }
            });
        }
    });

    let failed = failed.into_inner().unwrap();
    let fresh = fresh.into_inner();
    println!(
        "done           {total} shaders: {fresh} translated now, {} already cached, {} failed, {:.0} s",
        total - fresh - failed.len(),
        failed.len(),
        started.elapsed().as_secs_f64()
    );
    let mut reasons = std::collections::BTreeMap::<String, usize>::new();
    for e in &failed {
        // "... GFX10 code at 0x7dc: <reason>": grouped by the reason alone.
        let line = e.lines().next().unwrap_or("");
        let reason = line.rsplit(": ").next().unwrap_or(line);
        *reasons.entry(reason.chars().take(120).collect()).or_default() += 1;
    }
    let mut reasons: Vec<_> = reasons.into_iter().collect();
    reasons.sort_by(|a, b| b.1.cmp(&a.1));
    for (reason, n) in reasons.iter().take(15) {
        println!("  {n:>6}  {reason}");
    }
    Ok(())
}

#[cfg(not(windows))]
pub fn run(_paths: Vec<PathBuf>, _jobs: Option<usize>) -> Result<()> {
    anyhow::bail!("precompile needs Windows and a D3D12 GPU")
}
