//! `health` is the first tool in the `clitools/` family. Its only job is to establish and
//! prove the invocation contract every future deterministic Rust tool (the KPI scoring
//! engine in Phase 1.1, the campaign policy engine, etc.) will follow, so callers only have
//! to learn this convention once:
//!
//! - The tool accepts at most one JSON object as input. Empty/whitespace-only input is a
//!   valid "no input" call.
//! - The tool produces exactly one JSON object shaped as
//!   `{"ok": bool, "tool": str, "version": str, "result": ... }` on success or
//!   `{"ok": false, "tool": str, "version": str, "error": {"code": str, "message": str}}`
//!   on a handled error.
//!
//! This crate is both a library (the `process` function below, reused by `MCP/rust-runtime`
//! so the HTTP transport layer never re-implements this logic -- CONTRACT.md sec.7) and a
//! CLI binary (`src/main.rs`) that wraps `process` behind the original stdin/stdout/exit-code
//! contract: exit 0 means `ok: true`, exit 1 means `ok: false` with a structured error (a
//! handled, expected failure), exit 2 means the process could not even produce a structured
//! error (a bug).
//!
//! No network calls, no secrets, no I/O beyond what the caller (CLI stdin/stdout, or the
//! runtime's HTTP request/response) provides: this tool (and every deterministic tool that
//! follows this contract) is a pure function of its input.

use serde::{Deserialize, Serialize};

pub const TOOL_NAME: &str = "health";
pub const TOOL_VERSION: &str = "0.1.0";

#[derive(Debug, Deserialize, Default)]
struct HealthInput {
    /// Optional value the caller can pass to confirm round-tripping; not required.
    #[serde(default)]
    echo: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
pub struct HealthResult {
    pub status: &'static str,
    pub echo: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum ToolOutput {
    Ok {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        result: HealthResult,
    },
    Err {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        error: ToolError,
    },
}

#[derive(Debug, Serialize)]
pub struct ToolError {
    pub code: &'static str,
    pub message: String,
}

/// The pure, testable core: given raw input text (stdin for the CLI, the request body for
/// the HTTP runtime), decide the outcome. No I/O here, so this is reusable and unit-testable
/// without spawning a subprocess or a server.
pub fn process(raw_input: &str) -> ToolOutput {
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
                        message: format!("input was not a valid JSON object: {e}"),
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
