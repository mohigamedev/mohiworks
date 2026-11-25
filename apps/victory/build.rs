//! Embeds the source revision (`VICTORY_GIT`: short commit, `-dirty` with
//! uncommitted changes, `unknown` without git) so a run and its crash log
//! name the source they were built from (docs/directions.md E1). The exact
//! binary is identified by its CodeView key at run time, not by this.

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn main() {
    let commit = git(&["rev-parse", "--short=12", "HEAD"]);
    let dirty = git(&["status", "--porcelain", "--untracked-files=no"]).is_some_and(|s| !s.is_empty());
    let id = match commit {
        Some(c) if dirty => format!("{c}-dirty"),
        Some(c) => c,
        None => "unknown".to_owned(),
    };
    println!("cargo:rustc-env=VICTORY_GIT={id}");
    // Again when HEAD moves or the index changes (a commit, a checkout, a stage).
    for path in ["../../.git/HEAD", "../../.git/index"] {
        println!("cargo:rerun-if-changed={path}");
    }
}
