//! Who ran: the exact build of this layer and of the title, recorded at the
//! start of every run (docs/directions.md E1, E4).
//!
//! - This layer: the CodeView key (GUID and age) of our own executable, the
//!   key its PDB is filed under (E2), plus its BLAKE3, the source revision
//!   (`build.rs`) and the profile. A crash log line is only symbolized
//!   against the PDB with exactly this key.
//! - The title: the BLAKE3 of its executable, its CodeView key, timestamp
//!   and image size. No symbols for the title exist on our side; this only
//!   pins which build our inferred names (D5) were made against.

use victory_pe::ImageInfo;

/// One build's identity.
pub struct Identity {
    pub key: String,
    pub blake3: String,
    pub timestamp: u32,
    pub size_of_image: u32,
}

impl Identity {
    pub fn of(bytes: &[u8]) -> Identity {
        let info = ImageInfo::parse(bytes).ok();
        Identity {
            key: info
                .as_ref()
                .and_then(|i| i.codeview.as_ref())
                .map_or_else(|| "none".to_owned(), |c| c.symbol_key()),
            blake3: blake3::hash(bytes).to_hex()[..16].to_owned(),
            timestamp: info.as_ref().map_or(0, |i| i.timestamp),
            size_of_image: info.as_ref().map_or(0, |i| i.size_of_image),
        }
    }
}

/// This executable's identity, from its file on disk.
pub fn ours() -> Identity {
    let bytes = std::env::current_exe().and_then(std::fs::read).unwrap_or_default();
    Identity::of(&bytes)
}

pub const PROFILE: &str = if cfg!(feature = "diagnostics") { "diag" } else { "release" };
pub const SOURCE: &str = env!("VICTORY_GIT");

/// The line printed and put at the head of every crash log entry.
pub fn line(layer: &Identity, title: &Identity) -> String {
    format!(
        "build victory key={} blake3={} source={} profile={}; title key={} blake3={} timestamp={:#x} size={:#x}",
        layer.key, layer.blake3, SOURCE, PROFILE, title.key, title.blake3, title.timestamp, title.size_of_image
    )
}
