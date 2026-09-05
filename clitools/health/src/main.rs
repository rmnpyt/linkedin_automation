//! `health` is the first tool in the `clitools/` family. Its only job is to establish and
//! prove the invocation contract every future deterministic Rust tool (the KPI scoring
//! engine in Phase 1.1, the campaign policy engine, etc.) will follow, so n8n only has to
//! learn this convention once:
//!
//! - The tool reads at most one JSON object from stdin. Empty/whitespace-only stdin is a
//!   valid "no input" call.
//! - The tool writes exactly one line of JSON to stdout, always shaped as
//!   `{"ok": bool, "tool": str, "version": str, "result": ... }` on success or
//!   `{"ok": false, "tool": str, "version": str, "error": {"code": str, "message": str}}`
//!   on a handled error. Callers should parse stdout, not stderr, for the outcome.
//! - Exit code 0 means `ok: true`. Exit code 1 means `ok: false` with a structured error on
//!   stdout (a handled, expected failure — e.g. malformed input). Exit code 2 means the
//!   process could not even produce a structured error (a bug); stderr carries a raw
//!   message in that case only.
//!
//! No network calls, no secrets, no I/O beyond stdin/stdout/stderr: this tool (and every
//! deterministic tool that follows this contract) is a pure function of its input
//! (CONTRACT.md sec.7 -- the KPI scoring engine "MUST NOT depend on an LLM", and more
//! generally Rust here is reusable deterministic business logic, not an orchestration or
//! network layer).

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "health";
const TOOL_VERSION: &str = "0.1.0";

#[derive(Debug, Deserialize, Default)]
struct HealthInput {
    /// Optional value the caller can pass to confirm round-tripping; not required.
    #[serde(default)]
    echo: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
struct HealthResult {
    status: &'static str,
    echo: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "outcome")]
enum ToolOutput {
    #[serde(rename = "ok")]
    Ok {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        result: HealthResult,
    },
    #[serde(rename = "error")]
    Err {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        error: ToolError,
    },
}

#[derive(Debug, Serialize)]
struct ToolError {
    code: &'static str,
    message: String,
}

/// The pure, testable core: given raw stdin text, decide the outcome. No I/O here, so this
/// is unit-testable without spawning a subprocess.
fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();

    let input: HealthInput = if trimmed.is_empty() {
        HealthInput::default()
    } else {
        match serde_json::from_str(trimmed) {
            Ok(parsed) => parsed,
            Err(e) => {
                return ToolOutput::Err {
                    ok: false,
                    tool: TOOL_NAME,
                    version: TOOL_VERSION,
                    error: ToolError {
                        code: "INVALID_INPUT",
                        message: format!("stdin was not a valid JSON object: {e}"),
                    },
                };
            }
        }
    };

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: HealthResult {
            status: "ok",
            echo: input.echo,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        // Serialization of our own output type failing is the one case that does not fit
        // the structured-error contract; report it plainly and exit 2.
        eprintln!("health: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_stdin_is_a_valid_no_op_call() {
        let output = process("");
        match output {
            ToolOutput::Ok { ok, result, .. } => {
                assert!(ok);
                assert_eq!(result.status, "ok");
                assert!(result.echo.is_none());
            }
            ToolOutput::Err { .. } => panic!("expected Ok for empty stdin"),
        }
    }

    #[test]
    fn whitespace_only_stdin_is_treated_as_empty() {
        let output = process("   \n\t  ");
        assert!(matches!(output, ToolOutput::Ok { ok: true, .. }));
    }

    #[test]
    fn valid_input_echoes_the_provided_value() {
        let output = process(r#"{"echo": {"trace_id": "abc-123"}}"#);
        match output {
            ToolOutput::Ok { result, .. } => {
                assert_eq!(
                    result.echo,
                    Some(serde_json::json!({"trace_id": "abc-123"}))
                );
            }
            ToolOutput::Err { .. } => panic!("expected Ok for valid input"),
        }
    }

    #[test]
    fn malformed_json_produces_a_structured_error_not_a_panic() {
        let output = process("{not valid json");
        match output {
            ToolOutput::Err { ok, error, .. } => {
                assert!(!ok);
                assert_eq!(error.code, "INVALID_INPUT");
            }
            ToolOutput::Ok { .. } => panic!("expected Err for malformed input"),
        }
    }

    #[test]
    fn output_always_carries_tool_name_and_version() {
        for output in [process(""), process("{not valid json")] {
            let value = serde_json::to_value(&output).unwrap();
            assert_eq!(value["tool"], "health");
            assert_eq!(value["version"], "0.1.0");
        }
    }
}
