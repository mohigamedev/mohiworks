//! Gives the crate an identity of its translator: a hash of every source
//! file under `src/`, so a cache of translations can survive rebuilds of
//! unrelated crates and still miss after any change to the translator.

use std::path::{Path, PathBuf};

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    collect(&root.join("src"), &mut files);
    files.push(root.join("Cargo.toml"));
    files.sort();

    // FNV-1a, 64-bit, over each file's path (relative, '/'-separated) and
    // contents: dependency-free and the same on every machine.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for &b in bytes {
            hash ^= u64::from(b);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    for file in &files {
        let relative = file.strip_prefix(root).unwrap_or(file);
        let name = relative.to_string_lossy().replace('\\', "/");
        feed(name.as_bytes());
        feed(&[0]);
        // Line endings normalised: a checkout with CRLF must give the same
        // identity as one with LF.
        let text = std::fs::read(file).unwrap_or_default();
        let text: Vec<u8> = text.into_iter().filter(|&b| b != b'\r').collect();
        feed(&text);
        feed(&[0]);
        println!("cargo::rerun-if-changed={}", file.display());
    }
    println!("cargo::rerun-if-changed=src");
    println!("cargo::rustc-env=VICTORY_SHADER_SOURCE_HASH={hash:016x}");
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, out);
        } else {
            out.push(path);
        }
    }
}
