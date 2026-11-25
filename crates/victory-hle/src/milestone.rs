//! Milestones: named points a run reaches, which scripted input
//! (`VICTORY_KEYS`) can wait for instead of a fixed time, and which the
//! harness sees as `milestone` events (`VICTORY_EVENTS`).
//!
//! A milestone is reached the first time the title opens a file through
//! DirectStorage, named by the file's stem in lower case: Grand Theft Auto
//! VI opens `core_restofworld001.rpf` as the start screen is accepted, so
//! `core_restofworld001` marks "the world is loading". Names are the
//! title's file names, so nothing here knows a title.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::Instant;

static REACHED: LazyLock<Mutex<HashMap<String, Instant>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// Marks `name` reached (the first time only), with an event and a log line.
pub fn reach(name: &str) {
    let name = name.to_ascii_lowercase();
    let mut reached = REACHED.lock().unwrap_or_else(PoisonError::into_inner);
    if reached.contains_key(&name) {
        return;
    }
    reached.insert(name.clone(), Instant::now());
    drop(reached);
    tracing::info!(name, "milestone");
    victory_gpu::events::emit("milestone", &[("name", victory_gpu::events::Value::Str(&name))]);
}

/// A file the title opened: its stem is a milestone.
pub fn file_opened(path: &str) {
    let file = path.rsplit(['\\', '/']).next().unwrap_or(path);
    let stem = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
    if !stem.is_empty() {
        reach(stem);
    }
}

/// When `name` was reached, if it was.
pub fn reached(name: &str) -> Option<Instant> {
    REACHED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&name.to_ascii_lowercase())
        .copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_names_its_milestone_by_stem() {
        assert!(reached("milestone_test_pack001").is_none());
        file_opened(r"G:\pack\milestone_test_pack001\Milestone_Test_Pack001.rpf");
        let first = reached("milestone_test_pack001").expect("reached");
        file_opened("G:/pack/milestone_test_pack001.rpf");
        assert_eq!(reached("MILESTONE_TEST_PACK001"), Some(first), "the first time counts");
    }
}
