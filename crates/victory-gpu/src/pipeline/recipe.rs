//! What it takes to make a host pipeline again without the title: a recipe
//! per pipeline a run drew or dispatched with, kept beside the pipeline
//! library, and `victory precompile --pipelines`, which replays them
//! (docs/directions.md D4).
//!
//! Translating the title's shaders is cached ahead of a run, but the host
//! driver's compile of each pipeline was not: a first run found over a
//! thousand pipelines queued as the world loaded, and every draw whose
//! pipeline was still "being made" was dropped (`make`). The early list
//! (`library::EARLY_FILE`) cannot help there: its keys are one-way hashes.
//! A recipe is what the key was made from.
//!
//! `pipeline-recipes.bin`: a header, then records.
//! - Header: `VPR1`, the format version, the translator the writing run had
//!   (`victory_shader::emit::TRANSLATOR_ID`) and the host adapter's vendor
//!   and device ids, as little-endian words and length-prefixed strings. It
//!   names the run that began the file; records appended later by other
//!   builds keep it. It does not gate a replay: a recipe holds the title's
//!   own inputs (containers and state), and a replay translates and builds
//!   them for the machine and translator it runs on. A pipeline whose
//!   library name changed with either is made again and stored under the
//!   new name.
//! - Record: a length (u32), then the pipeline's key (as `make::Pending`
//!   makes it), its kind (compute, vertex and pixel, mesh and pixel), its
//!   shaders (stage, and the full BLAKE3 of the container), and the graphics
//!   state by value (`GraphicsState::to_bytes`) for the graphics kinds. A
//!   record that does not read back is skipped; a torn last record (a run
//!   that ended mid-write) is cut off by the next append.
//!
//! The containers are in `recipes/containers/<blake3>` beside it, each
//! written once however many recipes name it: a vertex shader is shared by
//! many pipelines.
//!
//! A run appends at its first use of a pipeline (`note`, from `make::ready`)
//! in memory only; the periodic library save writes the new records
//! (`flush`), so the title's threads do no file work. Pipelines the host
//! cannot make anyway (plain descriptions without a graphics state, domain,
//! hull, geometry and amplification stages) get no recipe.

use std::collections::{HashSet, VecDeque};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use super::Shader;
use super::host::{GraphicsState, Reader, Writer};
use super::make::{self, Pending};

const FILE: &str = "pipeline-recipes.bin";
const MAGIC: &[u8; 4] = b"VPR1";
const VERSION: u32 = 1;

const COMPUTE: u32 = 0;
const GRAPHICS: u32 = 1;
const MESH: u32 = 2;

/// The shader stages a title pipeline holds, as the pipeline keeps them.
const STAGES: [&str; 8] = ["vertex", "pixel", "domain", "hull", "geometry", "compute", "amplification", "mesh"];

/// One pipeline's inputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Recipe {
    /// `Pending`'s key: what a replay must come to again.
    pub(crate) key: String,
    pub(crate) kind: u32,
    /// Each shader's stage and the full hash of its container.
    pub(crate) shaders: Vec<(String, [u8; 32])>,
    /// `GraphicsState::to_bytes` (the graphics kinds).
    pub(crate) graphics: Option<Vec<u8>>,
}

impl Recipe {
    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut w = Writer::default();
        w.bytes(self.key.as_bytes());
        w.word(self.kind);
        w.word(self.shaders.len() as u32);
        for (stage, hash) in &self.shaders {
            w.bytes(stage.as_bytes());
            w.0.extend(hash);
        }
        match &self.graphics {
            Some(g) => {
                w.word(1);
                w.bytes(g);
            }
            None => w.word(0),
        }
        w.0
    }

    pub(crate) fn decode(bytes: &[u8]) -> Option<Recipe> {
        let mut r = Reader(bytes);
        let key = String::from_utf8(r.bytes()?.to_vec()).ok()?;
        let kind = r.word()?;
        if kind > MESH {
            return None;
        }
        let n = r.word()? as usize;
        let mut shaders = Vec::with_capacity(n.min(8));
        for _ in 0..n {
            let stage = String::from_utf8(r.bytes()?.to_vec()).ok()?;
            shaders.push((stage, r.take(32)?.try_into().ok()?));
        }
        let graphics = match r.word()? {
            0 => None,
            1 => Some(r.bytes()?.to_vec()),
            _ => return None,
        };
        r.0.is_empty().then_some(Recipe { key, kind, shaders, graphics })
    }
}

/// Whose file it is: see the module's notes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Header {
    pub(crate) translator: String,
    pub(crate) vendor: u32,
    pub(crate) device: u32,
}

impl Header {
    fn current() -> Header {
        let (vendor, device) = crate::host::adapter_ids().unwrap_or((0, 0));
        Header { translator: victory_shader::emit::TRANSLATOR_ID.to_owned(), vendor, device }
    }

    fn encode(&self) -> Vec<u8> {
        let mut w = Writer(MAGIC.to_vec());
        w.word(VERSION);
        w.bytes(self.translator.as_bytes());
        w.word(self.vendor);
        w.word(self.device);
        w.0
    }
}

/// A recipe file read: its header (`None`: not one of ours), its recipes,
/// and how many bytes of it are whole (header and complete records).
#[derive(Default)]
pub(crate) struct Loaded {
    pub(crate) header: Option<Header>,
    pub(crate) recipes: Vec<Recipe>,
    pub(crate) whole: usize,
}

pub(crate) fn parse(bytes: &[u8]) -> Loaded {
    let mut out = Loaded::default();
    let mut r = Reader(bytes);
    let header = (|| {
        if r.take(4)? != MAGIC || r.word()? != VERSION {
            return None;
        }
        let translator = String::from_utf8(r.bytes()?.to_vec()).ok()?;
        Some(Header { translator, vendor: r.word()?, device: r.word()? })
    })();
    let Some(header) = header else { return out };
    out.header = Some(header);
    out.whole = bytes.len() - r.0.len();
    while let Some(body) = r.bytes() {
        out.whole = bytes.len() - r.0.len();
        if let Some(recipe) = Recipe::decode(body) {
            out.recipes.push(recipe);
        }
    }
    out
}

fn load(dir: &Path) -> Loaded {
    std::fs::read(dir.join(FILE)).map(|b| parse(&b)).unwrap_or_default()
}

/// Appends `records` to the file `path` after its first `whole` bytes (a
/// torn tail goes), beginning it with `header` if it has none.
fn append(path: &Path, header: &Header, whole: usize, records: &[Vec<u8>]) -> std::io::Result<usize> {
    let mut file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
    let mut whole = whole;
    if whole == 0 {
        file.set_len(0)?;
        file.write_all(&header.encode())?;
        whole = header.encode().len();
    } else {
        file.set_len(whole as u64)?;
        file.seek(SeekFrom::Start(whole as u64))?;
    }
    let mut out = Vec::new();
    for r in records {
        out.extend((r.len() as u32).to_le_bytes());
        out.extend(r);
    }
    file.write_all(&out)?;
    Ok(whole + out.len())
}

fn container_path(dir: &Path, hash: &[u8; 32]) -> PathBuf {
    dir.join("recipes").join("containers").join(blake3::Hash::from_bytes(*hash).to_hex().as_str())
}

/// Writes the containers of `shaders` that are not in the store yet.
fn store_containers(dir: &Path, shaders: &[Arc<Shader>], written: &mut HashSet<[u8; 32]>) -> std::io::Result<()> {
    for s in shaders {
        if !written.insert(s.full) {
            continue;
        }
        let path = container_path(dir, &s.full);
        if path.exists() {
            continue;
        }
        std::fs::create_dir_all(path.parent().unwrap_or(dir))?;
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &s.container)?;
        if let Err(e) = std::fs::rename(&tmp, &path) {
            written.remove(&s.full);
            return Err(e);
        }
    }
    Ok(())
}

/// What a run has noted since it began.
struct Recording {
    /// The keys on disk, and noted since.
    known: HashSet<String>,
    /// Noted and not written yet, with the shaders whose containers they
    /// need stored.
    pending: Vec<(Recipe, Vec<Arc<Shader>>)>,
    /// The file's whole bytes (0: write a header first).
    whole: usize,
    /// Containers known to be in the store.
    written: HashSet<[u8; 32]>,
}

static RECORDING: Mutex<Option<Recording>> = Mutex::new(None);
/// One flush at a time: it works on what it took out of [`RECORDING`].
static FLUSHING: Mutex<()> = Mutex::new(());

/// The kind of host pipeline these inputs give, or `None` if the host makes
/// none from them (see `HostPipeline::new`).
fn kind_of(shaders: &[Arc<Shader>], graphics: bool) -> Option<u32> {
    if let [cs] = shaders
        && cs.stage == "compute"
    {
        return Some(COMPUTE);
    }
    let any = |stage| shaders.iter().any(|s| s.stage == stage);
    let only = shaders.iter().all(|s| matches!(s.stage, "vertex" | "pixel" | "mesh"));
    if !graphics || !only || !(any("vertex") || any("mesh")) {
        return None;
    }
    Some(if any("mesh") { MESH } else { GRAPHICS })
}

/// The recipe of a pipeline a draw or dispatch requested for the first time
/// (in memory: [`flush`] writes it).
pub(super) fn note(p: &Pending) {
    let Some(dir) = super::library::DIR.get() else { return };
    let (shaders, graphics) = (p.shaders(), p.graphics.as_deref());
    let Some(kind) = kind_of(shaders, graphics.is_some()) else { return };
    let mut guard = RECORDING.lock().unwrap_or_else(|e| e.into_inner());
    let rec = guard.get_or_insert_with(|| {
        let loaded = load(dir);
        Recording {
            known: loaded.recipes.into_iter().map(|r| r.key).collect(),
            pending: Vec::new(),
            whole: loaded.whole,
            written: HashSet::new(),
        }
    });
    if !rec.known.insert(p.key().to_owned()) {
        return;
    }
    let recipe = Recipe {
        key: p.key().to_owned(),
        kind,
        shaders: shaders.iter().map(|s| (s.stage.to_owned(), s.full)).collect(),
        graphics: graphics.map(GraphicsState::to_bytes),
    };
    rec.pending.push((recipe, shaders.to_vec()));
}

/// Writes the recipes noted since the last flush, and their containers.
/// Called by the library's save (at most every 20 s), so the title's
/// threads do no file work.
pub(super) fn flush(dir: &Path) {
    let _one = FLUSHING.lock().unwrap_or_else(|e| e.into_inner());
    let (batch, whole, mut written) = {
        let mut guard = RECORDING.lock().unwrap_or_else(|e| e.into_inner());
        let Some(rec) = guard.as_mut().filter(|r| !r.pending.is_empty()) else { return };
        (std::mem::take(&mut rec.pending), rec.whole, std::mem::take(&mut rec.written))
    };
    let result = (|| {
        for (_, shaders) in &batch {
            store_containers(dir, shaders, &mut written)?;
        }
        std::fs::create_dir_all(dir)?;
        let records: Vec<Vec<u8>> = batch.iter().map(|(r, _)| r.encode()).collect();
        append(&dir.join(FILE), &Header::current(), whole, &records)
    })();
    let mut guard = RECORDING.lock().unwrap_or_else(|e| e.into_inner());
    let Some(rec) = guard.as_mut() else { return };
    rec.written = written;
    match result {
        Ok(whole) => {
            rec.whole = whole;
            tracing::debug!(recipes = batch.len(), bytes = whole, "pipeline recipes saved");
        }
        Err(e) => {
            tracing::warn!(error = %e, "pipeline recipes not saved; tried again at the next save");
            let later = std::mem::replace(&mut rec.pending, batch);
            rec.pending.extend(later);
        }
    }
}

/// What a replay did.
#[derive(Debug, Default)]
pub struct ReplayReport {
    /// Recipes read.
    pub total: usize,
    /// Pipelines compiled by the driver now (and stored).
    pub made: usize,
    /// Pipelines the library had already.
    pub loaded: usize,
    /// Recipes that gave no host pipeline, by the first few reasons.
    pub failed: usize,
    pub failures: Vec<String>,
    /// Recipes whose rebuilt pipeline has another key than the recorded one
    /// (the state or a shader's identity did not come back the same).
    pub key_changed: usize,
    pub seconds: f64,
    /// The slowest (seconds, shaders), slowest first.
    pub slowest: Vec<(f64, String)>,
}

/// Rebuilds the pipelines of the recipes in the pipeline cache folder
/// (`use_pipeline_cache`) through the path a run uses (`Pending`, then
/// `make::now`: the library's load-or-create), so that the library names,
/// and so the entries, are the run's.
///
/// `workers` threads, of which at most `compute_limit` build compute
/// pipelines at once: the driver's compile of a big compute program takes
/// seconds and gigabytes, and a dozen of them at once is the machine's
/// memory (runs saw compiles of 3.4 s each with eight workers).
/// `progress` gets a line about every ten seconds and at the start.
pub fn replay(workers: usize, compute_limit: usize, progress: &(dyn Fn(&str) + Sync)) -> Result<ReplayReport, String> {
    let dir = super::library::DIR.get().ok_or("no pipeline cache folder")?.clone();
    if crate::host::host().is_none() {
        return Err("no host D3D12 device".into());
    }
    let loaded = load(&dir);
    let header = loaded.header.ok_or_else(|| format!("no pipeline recipes in {}", dir.display()))?;
    let now = Header::current();
    progress(&format!(
        "recipes        {} in {} (written with translator {}, adapter {:04x}:{:04x}; now {}, {:04x}:{:04x})",
        loaded.recipes.len(),
        dir.display(),
        &header.translator[..header.translator.len().min(12)],
        header.vendor,
        header.device,
        &now.translator[..now.translator.len().min(12)],
        now.vendor,
        now.device
    ));
    let recipes = loaded.recipes;
    let total = recipes.len();

    struct Work {
        graphics: VecDeque<usize>,
        compute: VecDeque<usize>,
        computing: usize,
    }
    let mut work = Work { graphics: VecDeque::new(), compute: VecDeque::new(), computing: 0 };
    for (i, r) in recipes.iter().enumerate() {
        if r.kind == COMPUTE { &mut work.compute } else { &mut work.graphics }.push_back(i);
    }
    let work = Mutex::new(work);
    let changed = Condvar::new();
    let compute_limit = compute_limit.max(1);
    // The next recipe: a compute one if a slot is free (they are the slow
    // ones, so they start first), else a graphics one; waits for a slot
    // when only compute ones are left.
    let take = || {
        let mut w = work.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if w.computing < compute_limit
                && let Some(i) = w.compute.pop_front()
            {
                w.computing += 1;
                return Some((i, true));
            }
            if let Some(i) = w.graphics.pop_front() {
                return Some((i, false));
            }
            if w.compute.is_empty() {
                return None;
            }
            w = changed.wait(w).unwrap_or_else(|e| e.into_inner());
        }
    };

    let (done, made, from_library, failed, key_changed) =
        (AtomicUsize::new(0), AtomicUsize::new(0), AtomicUsize::new(0), AtomicUsize::new(0), AtomicUsize::new(0));
    let failures = Mutex::new(Vec::<String>::new());
    let slowest = Mutex::new(Vec::<(f64, String)>::new());
    let last_line = Mutex::new(Instant::now());
    let started = Instant::now();
    let workers = workers.clamp(1, 64);
    progress(&format!(
        "replaying      {total} pipelines on {workers} threads (at most {compute_limit} compute builds at once)"
    ));
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| {
                while let Some((i, heavy)) = take() {
                    let recipe = &recipes[i];
                    let began = Instant::now();
                    let result = rebuild(&dir, recipe);
                    let label = recipe
                        .shaders
                        .iter()
                        .map(|(stage, hash)| format!("{stage} {}", &blake3::Hash::from_bytes(*hash).to_hex()[..16]))
                        .collect::<Vec<_>>()
                        .join(" + ");
                    match result {
                        Ok((outcome, same_key)) => {
                            match outcome {
                                super::library::Outcome::Loaded => from_library.fetch_add(1, Ordering::Relaxed),
                                _ => made.fetch_add(1, Ordering::Relaxed),
                            };
                            if !same_key {
                                key_changed.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        Err(why) => {
                            failed.fetch_add(1, Ordering::Relaxed);
                            let mut f = failures.lock().unwrap_or_else(|e| e.into_inner());
                            if f.len() < 20 {
                                f.push(format!("{label}: {why}"));
                            }
                        }
                    }
                    let secs = began.elapsed().as_secs_f64();
                    {
                        let mut s = slowest.lock().unwrap_or_else(|e| e.into_inner());
                        s.push((secs, label));
                        if s.len() > 64 {
                            s.sort_by(|a, b| b.0.total_cmp(&a.0));
                            s.truncate(10);
                        }
                    }
                    if heavy {
                        work.lock().unwrap_or_else(|e| e.into_inner()).computing -= 1;
                    }
                    changed.notify_all();
                    let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                    super::library::save(false);
                    let mut last = last_line.lock().unwrap_or_else(|e| e.into_inner());
                    if n == total || last.elapsed().as_secs() >= 10 {
                        *last = Instant::now();
                        progress(&format!(
                            "  {n}/{total} ({} made now, {} in the library, {} failed) {:.0} s",
                            made.load(Ordering::Relaxed),
                            from_library.load(Ordering::Relaxed),
                            failed.load(Ordering::Relaxed),
                            started.elapsed().as_secs_f64()
                        ));
                    }
                }
            });
        }
    });
    super::library::save(true);
    let mut slowest = slowest.into_inner().unwrap_or_else(|e| e.into_inner());
    slowest.sort_by(|a, b| b.0.total_cmp(&a.0));
    slowest.truncate(10);
    Ok(ReplayReport {
        total,
        made: made.into_inner(),
        loaded: from_library.into_inner(),
        failed: failed.into_inner(),
        failures: failures.into_inner().unwrap_or_else(|e| e.into_inner()),
        key_changed: key_changed.into_inner(),
        seconds: started.elapsed().as_secs_f64(),
        slowest,
    })
}

/// One recipe through the run's path; how the library answered, and
/// whether the rebuilt pipeline's key is the recorded one.
fn rebuild(dir: &Path, recipe: &Recipe) -> Result<(super::library::Outcome, bool), String> {
    let mut shaders = Vec::new();
    for (stage, hash) in &recipe.shaders {
        let stage = STAGES.into_iter().find(|s| s == stage).ok_or_else(|| format!("unknown stage {stage}"))?;
        let bytes = std::fs::read(container_path(dir, hash)).map_err(|e| format!("container missing: {e}"))?;
        if blake3::hash(&bytes).as_bytes() != hash {
            return Err("container does not match its name".into());
        }
        shaders.push(super::shader(stage, &bytes));
    }
    let graphics = match &recipe.graphics {
        Some(g) => Some(Box::new(GraphicsState::from_bytes(g).ok_or("graphics state does not read back")?)),
        None => None,
    };
    let pending = Arc::new(Pending::new(shaders, graphics));
    let same_key = pending.key() == recipe.key;
    super::library::take_outcome();
    if make::now(&pending) {
        Ok((super::library::take_outcome(), same_key))
    } else {
        Err("no host pipeline (a shader that does not translate, or the driver refused it)".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recipe() -> Recipe {
        Recipe {
            key: "0123456789abcdef0123456789abcdef".into(),
            kind: GRAPHICS,
            shaders: vec![("vertex".into(), [1; 32]), ("pixel".into(), [2; 32])],
            graphics: Some(GraphicsState::default().to_bytes()),
        }
    }

    #[test]
    fn a_recipe_reads_back_as_written() {
        let r = recipe();
        assert_eq!(Recipe::decode(&r.encode()), Some(r.clone()));
        let compute = Recipe { kind: COMPUTE, shaders: vec![("compute".into(), [3; 32])], graphics: None, ..r };
        assert_eq!(Recipe::decode(&compute.encode()), Some(compute.clone()));
        // Damage and cut-off records are refused, not misread.
        let bytes = compute.encode();
        assert_eq!(Recipe::decode(&bytes[..bytes.len() - 1]), None);
        assert_eq!(Recipe::decode(&[bytes.clone(), vec![0]].concat()), None);
    }

    #[test]
    fn the_file_takes_appends_and_cuts_a_torn_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        let header = Header { translator: "abc".into(), vendor: 0x1002, device: 0x73df };
        let (a, b) = (recipe(), Recipe { key: "b".into(), ..recipe() });
        let whole = append(&path, &header, 0, &[a.encode()]).unwrap();
        let loaded = load(dir.path());
        assert_eq!(loaded.header, Some(header.clone()));
        assert_eq!(loaded.recipes, vec![a.clone()]);
        assert_eq!(loaded.whole, whole);
        // A run that ended mid-record.
        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&[200, 0, 0, 0, 1, 2, 3]).unwrap();
        drop(file);
        let torn = load(dir.path());
        assert_eq!((torn.recipes.len(), torn.whole), (1, whole));
        append(&path, &header, torn.whole, &[b.encode()]).unwrap();
        assert_eq!(load(dir.path()).recipes, vec![a, b]);
        // Not our file: nothing read, and the next append begins a new one.
        std::fs::write(&path, b"something else").unwrap();
        assert!(load(dir.path()).header.is_none());
        append(&path, &header, 0, &[]).unwrap();
        assert_eq!(load(dir.path()).header, Some(header));
    }

    #[test]
    fn containers_are_stored_once_by_content() {
        let dir = tempfile::tempdir().unwrap();
        let shader = super::super::shader("vertex", b"a container the test stores");
        let mut written = HashSet::new();
        store_containers(dir.path(), &[shader.clone(), shader.clone()], &mut written).unwrap();
        let path = container_path(dir.path(), &shader.full);
        assert_eq!(std::fs::read(&path).unwrap(), b"a container the test stores");
        assert_eq!(blake3::hash(&std::fs::read(&path).unwrap()).as_bytes(), &shader.full);
        assert_eq!(std::fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn pipelines_the_host_cannot_make_get_no_recipe() {
        let s = |stage, bytes: &[u8]| super::super::shader(stage, bytes);
        assert_eq!(kind_of(&[s("compute", b"c")], false), Some(COMPUTE));
        assert_eq!(kind_of(&[s("vertex", b"v"), s("pixel", b"p")], true), Some(GRAPHICS));
        assert_eq!(kind_of(&[s("mesh", b"m"), s("pixel", b"p")], true), Some(MESH));
        assert_eq!(kind_of(&[s("vertex", b"v"), s("pixel", b"p")], false), None);
        assert_eq!(kind_of(&[s("vertex", b"v"), s("hull", b"h")], true), None);
        assert_eq!(kind_of(&[], true), None);
    }
}
