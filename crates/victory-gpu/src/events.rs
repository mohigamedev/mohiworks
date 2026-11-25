//! Structured run events for the test harness and its control app
//! (`scripts/harness.ps1`, `tools/control`): with `VICTORY_EVENTS=<file>`,
//! one JSON object per line, appended as things happen and flushed at once
//! so a reader can follow the file live.
//!
//! Every event has `t` (seconds since the first event of the run) and
//! `kind`; the other fields depend on the kind:
//! - `start`: `pid`.
//! - `adapter`: `name`.
//! - `display`: `width`, `height` (the mode reported to the title).
//! - `input`: `it` (seconds since input started: the clock `VICTORY_KEYS`
//!   counts from), `device` (`key` or `pad`), `name` (the `VICTORY_KEYS` name
//!   of the key, or of the key standing in for the pad button), `down`.
//! - `frame`: `fps`, `ms`, `draws`, `dropped`, `making`, `preparing_ms`,
//!   `gpu_ms` (one per frame line, about every 5 s).
//! - `memory`: `committed_mb`, `peak_mb`, `ram_mb`, `commit_free_mb`,
//!   `ram_free_mb`, `card_mb`, `card_budget_mb`.
//! - `removed`: the host device went (`reason`).
//!
//! Nothing here is read back by the layer; without the variable it costs
//! one check per call.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

struct Sink {
    start: Instant,
    out: Mutex<BufWriter<File>>,
}

fn sink() -> Option<&'static Sink> {
    static SINK: OnceLock<Option<Sink>> = OnceLock::new();
    SINK.get_or_init(|| {
        let path = std::env::var_os("VICTORY_EVENTS")?;
        match File::create(&path) {
            Ok(file) => {
                let sink = Sink {
                    start: Instant::now(),
                    out: Mutex::new(BufWriter::new(file)),
                };
                Some(sink)
            }
            Err(e) => {
                tracing::warn!(error = %e, path = %std::path::Path::new(&path).display(), "VICTORY_EVENTS: cannot create the file");
                None
            }
        }
    })
    .as_ref()
}

/// Whether events are being written (`VICTORY_EVENTS` is set).
pub fn enabled() -> bool {
    sink().is_some()
}

/// A field value of an event.
pub enum Value<'a> {
    Num(f64),
    Int(i64),
    Bool(bool),
    Str(&'a str),
}

/// Appends one event: `kind` and the fields, as one JSON line.
pub fn emit(kind: &str, fields: &[(&str, Value<'_>)]) {
    let Some(sink) = sink() else { return };
    let mut line = format!(
        "{{\"t\":{:.3},\"kind\":{}",
        sink.start.elapsed().as_secs_f64(),
        quote(kind)
    );
    for (name, value) in fields {
        line.push(',');
        line.push_str(&quote(name));
        line.push(':');
        match value {
            Value::Num(v) if v.is_finite() => line.push_str(&format!("{v:.3}")),
            Value::Num(_) => line.push_str("null"),
            Value::Int(v) => line.push_str(&v.to_string()),
            Value::Bool(v) => line.push_str(if *v { "true" } else { "false" }),
            Value::Str(v) => line.push_str(&quote(v)),
        }
    }
    line.push_str("}\n");
    let mut out = sink.out.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let _ = out.write_all(line.as_bytes());
    let _ = out.flush();
}

/// A JSON string literal.
fn quote(s: &str) -> String {
    let mut q = String::with_capacity(s.len() + 2);
    q.push('"');
    for c in s.chars() {
        match c {
            '"' => q.push_str("\\\""),
            '\\' => q.push_str("\\\\"),
            '\n' => q.push_str("\\n"),
            '\r' => q.push_str("\\r"),
            '\t' => q.push_str("\\t"),
            c if (c as u32) < 0x20 => q.push_str(&format!("\\u{:04x}", c as u32)),
            c => q.push(c),
        }
    }
    q.push('"');
    q
}

#[cfg(test)]
mod tests {
    use super::quote;

    #[test]
    fn strings_are_escaped_for_json() {
        assert_eq!(quote("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
    }
}
