//! Thin CLI wrapper around `campaign_policy::process` (see `src/lib.rs` for the actual
//! deterministic logic and its tests). This binary owns only the stdin/stdout/exit-code
//! contract; it must never grow business logic of its own -- that would duplicate what
//! `MCP/rust-runtime` also depends on.

use std::io::{self, Read, Write};

use campaign_policy::{process, ToolOutput};

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("campaign_policy: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}
