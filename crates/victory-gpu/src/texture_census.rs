//! The texture descriptions a run sees, kept for offline checks
//! (`victory audit textures`, `scripts/harness.ps1 audit`).
//!
//! Textures only show their layout when the title creates them, so a run
//! records each distinct description once: `texture-descs.csv` beside the
//! pipeline library, one line per description,
//! `dimension,width,height,depth_or_array,mips,format,samples,layout,flags,laid_out`
//! (D3D12 resource dimension, the console's layout field, and whether
//! VIctory gave it a console layout). A later audit replays the layouts
//! and detiles without the title: unsupported formats, swizzle modes and
//! the CPU cost of detiling each kind show up before a run, not in one.
//!
//! The title's threads only look a description up in a set; a writer
//! thread appends the new ones.

use std::collections::HashSet;
use std::io::Write;
use std::sync::mpsc::{Sender, channel};
use std::sync::{LazyLock, Mutex, PoisonError};

/// The file's name in the pipeline cache folder.
pub const FILE: &str = "texture-descs.csv";

/// One texture description as the title gave it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Seen {
    pub dimension: u32,
    pub width: u64,
    pub height: u32,
    pub depth_or_array: u16,
    pub mips: u16,
    pub format: u32,
    pub samples: u32,
    pub layout: u32,
    pub flags: u32,
    /// VIctory gave it a console layout.
    pub laid_out: bool,
}

impl Seen {
    pub fn line(&self) -> String {
        format!(
            "{},{},{},{},{},{},{},{:#x},{:#x},{}",
            self.dimension,
            self.width,
            self.height,
            self.depth_or_array,
            self.mips,
            self.format,
            self.samples,
            self.layout,
            self.flags,
            u8::from(self.laid_out)
        )
    }

    pub fn parse(line: &str) -> Option<Seen> {
        let f: Vec<&str> = line.trim().split(',').collect();
        let [d, w, h, a, m, fmt, s, l, fl, ok] = f[..] else { return None };
        let hex = |t: &str| u32::from_str_radix(t.trim_start_matches("0x"), 16).ok();
        Some(Seen {
            dimension: d.parse().ok()?,
            width: w.parse().ok()?,
            height: h.parse().ok()?,
            depth_or_array: a.parse().ok()?,
            mips: m.parse().ok()?,
            format: fmt.parse().ok()?,
            samples: s.parse().ok()?,
            layout: hex(l)?,
            flags: hex(fl)?,
            laid_out: ok == "1",
        })
    }
}

struct Census {
    seen: HashSet<Seen>,
    writer: Option<Sender<String>>,
}

static CENSUS: LazyLock<Mutex<Census>> = LazyLock::new(|| {
    Mutex::new(Census {
        seen: HashSet::new(),
        writer: None,
    })
});

/// Records `seen` the first time this run sees it (needs the pipeline
/// cache folder; without one nothing is kept).
pub(crate) fn note(seen: Seen) {
    let mut c = CENSUS.lock().unwrap_or_else(PoisonError::into_inner);
    if !c.seen.insert(seen) {
        return;
    }
    if c.writer.is_none() {
        let Some(dir) = crate::pipeline::cache_dir() else { return };
        let path = dir.join(FILE);
        // What earlier runs wrote is not written again.
        if let Ok(text) = std::fs::read_to_string(&path) {
            c.seen.extend(text.lines().filter_map(Seen::parse));
            c.seen.insert(seen);
        }
        let (tx, rx) = channel::<String>();
        let spawned = std::thread::Builder::new().name("victory texture census".into()).spawn(move || {
            let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) else { return };
            for line in rx {
                let _ = writeln!(file, "{line}");
            }
        });
        if spawned.is_err() {
            return;
        }
        c.writer = Some(tx);
    }
    if let Some(tx) = &c.writer {
        let _ = tx.send(seen.line());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_reads_back() {
        let s = Seen {
            dimension: 3,
            width: 4096,
            height: 2048,
            depth_or_array: 1,
            mips: 13,
            format: 71,
            samples: 1,
            layout: 0x105,
            flags: 0,
            laid_out: true,
        };
        assert_eq!(Seen::parse(&s.line()), Some(s));
        assert_eq!(Seen::parse("3,1,2"), None);
    }
}
