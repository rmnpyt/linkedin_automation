//! `connection_sender_normalize` validates and normalizes a ConnectionSender's raw output
//! into the internal SendResult contract (PROPOSAL.md sec.19, CONTRACT.md sec.43,45-48).
//! Pure transformation: no network calls, no secrets, no PowerShell/browser invocation
//! itself -- that remains the n8n workflow's job (calling the real sender script and
//! passing its output to this tool).
//!
//! IMPORTANT: the real PowerShell connection-sender script referenced by MINDSET.md
//! ("connection-request sending is a PowerShell script today") is not present in this
//! repository (powershell/linkedin/ is still empty). This tool therefore does not reverse-
//! engineer an unknown legacy output shape -- instead, it defines and validates the
//! contract that script must be adapted to produce (documented in
//! powershell/linkedin/CONNECTION_SENDER_CONTRACT.md), and normalizes strictly against it.
//! When the real script becomes available, either adapt its output to this contract or
//! (if that is impractical) update this tool to translate its actual shape -- but do not
//! silently accept an unrecognized status string as a stand-in for a real outcome.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "connection_sender_normalize";
const TOOL_VERSION: &str = "0.1.0";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SenderOutput {
    status: String,
    #[serde(default)]
    error_code: Option<String>,
    #[serde(default)]
    error_message: Option<String>,
    #[serde(default)]
    raw: Option<serde_json::Value>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum NormalizedResult {
    Sent,
    Failed,
    AlreadyConnected,
    Unknown,
}

#[derive(Debug, Serialize)]
struct NormalizeResult {
    result: NormalizedResult,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_message: Option<String>,
}

#[derive(Debug, Serialize)]
struct ToolError {
    code: &'static str,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum ToolOutput {
    Ok {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        result: NormalizeResult,
    },
    Err {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        error: ToolError,
    },
}

fn err(code: &'static str, message: impl Into<String>) -> ToolOutput {
    ToolOutput::Err {
        ok: false,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        error: ToolError {
            code,
            message: message.into(),
        },
    }
}

fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; connection_sender_normalize requires a JSON input object");
    }

    let input: SenderOutput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid sender output object: {e}")),
    };

    let status_normalized = input.status.trim().to_lowercase();
    let result = match status_normalized.as_str() {
        "sent" => NormalizedResult::Sent,
        "failed" => NormalizedResult::Failed,
        "already_connected" => NormalizedResult::AlreadyConnected,
        "unknown" => NormalizedResult::Unknown,
        other => {
            return err(
                "UNRECOGNIZED_STATUS",
                format!(
                    "status {other:?} does not match the documented ConnectionSender contract (sent|failed|already_connected|unknown) -- the calling script is not conformant, this is not a legitimate ambiguous outcome"
                ),
            );
        }
    };

    // FAILED and UNKNOWN should carry an explanation when the sender provides one; SENT
    // and ALREADY_CONNECTED do not require one. This is advisory (not enforced as a hard
    // error) since some genuine failures may not have a machine-readable reason available.
    let _ = &input.raw;

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: NormalizeResult {
            result,
            error_code: input.error_code,
            error_message: input.error_message,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("connection_sender_normalize: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok_result(output: ToolOutput) -> NormalizeResult {
        match output {
            ToolOutput::Ok { result, .. } => result,
            ToolOutput::Err { error, .. } => panic!("expected Ok, got error: {error:?}"),
        }
    }

    fn err_output(output: ToolOutput) -> ToolError {
        match output {
            ToolOutput::Err { error, .. } => error,
            ToolOutput::Ok { .. } => panic!("expected Err, got Ok"),
        }
    }

    #[test]
    fn sent_status_normalizes_correctly() {
        let input = serde_json::json!({"status": "sent"});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::Sent);
    }

    #[test]
    fn status_is_case_and_whitespace_insensitive() {
        let input = serde_json::json!({"status": "  SENT  "});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::Sent);
    }

    #[test]
    fn failed_status_carries_through_error_details() {
        let input = serde_json::json!({
            "status": "failed",
            "error_code": "RATE_LIMITED",
            "error_message": "LinkedIn returned a rate-limit response"
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::Failed);
        assert_eq!(result.error_code, Some("RATE_LIMITED".to_string()));
        assert_eq!(result.error_message, Some("LinkedIn returned a rate-limit response".to_string()));
    }

    #[test]
    fn already_connected_status_normalizes_correctly() {
        let input = serde_json::json!({"status": "already_connected"});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::AlreadyConnected);
    }

    #[test]
    fn unknown_status_normalizes_correctly() {
        let input = serde_json::json!({"status": "unknown", "error_message": "browser closed mid-action, outcome unclear"});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::Unknown);
    }

    /// A status the documented contract does not define is a hard error, not a silent
    /// fallback to UNKNOWN -- the calling script needs to be fixed, not papered over.
    #[test]
    fn unrecognized_status_is_a_hard_error_not_a_silent_unknown() {
        let input = serde_json::json!({"status": "success"});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "UNRECOGNIZED_STATUS");
    }

    #[test]
    fn missing_status_field_is_rejected() {
        let input = serde_json::json!({"error_message": "no status given"});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn malformed_json_is_rejected() {
        let error = err_output(process("{not valid json"));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn unknown_field_is_rejected() {
        let input = r#"{"status": "sent", "unexpected": 1}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn raw_debug_field_is_accepted_and_ignored() {
        let input = serde_json::json!({"status": "sent", "raw": {"anything": "the script wants to include"}});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.result, NormalizedResult::Sent);
    }

    #[test]
    fn output_always_carries_tool_name_and_version() {
        for output in [process(""), process("{not valid json")] {
            let value = serde_json::to_value(&output).unwrap();
            assert_eq!(value["tool"], "connection_sender_normalize");
            assert_eq!(value["version"], "0.1.0");
        }
    }
}
