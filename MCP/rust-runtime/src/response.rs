//! Shared response mapping: every deterministic tool in `clitools/` already produces a
//! self-describing JSON object shaped `{"ok": bool, "tool": str, "version": str, ...}`
//! (established by `clitools/health`, CONTRACT.md sec.7). This module's only job is to turn
//! that JSON into an HTTP status code + body -- it must never inspect or branch on the
//! *meaning* of a tool's result, only on the `ok` field every tool already guarantees.
//! Keeping this generic (rather than one bespoke response mapper per route) is what lets a
//! new tool be added later with no new transport-layer code (requirement: the runtime must
//! support exposing more engines later without ad-hoc services).

use axum::{http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;

/// Serializes a tool's `ToolOutput` and derives the HTTP status purely from its `ok` field:
/// `200` when `ok: true`, `400` when `ok: false` (a handled input-validation error -- the
/// same class of failure the CLI reports via exit code 1), `500` only if the tool's own
/// output type somehow fails to serialize at all (the CLI's exit-code-2 case).
pub fn tool_response<T: Serialize>(output: &T) -> impl IntoResponse {
    match serde_json::to_value(output) {
        Ok(value) => {
            let is_ok = value.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
            let status = if is_ok { StatusCode::OK } else { StatusCode::BAD_REQUEST };
            (status, Json(value))
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({
                "ok": false,
                "error": { "code": "SERIALIZATION_ERROR", "message": e.to_string() }
            })),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::response::Response;

    fn status_of(response: Response) -> StatusCode {
        response.status()
    }

    #[test]
    fn ok_output_maps_to_200() {
        let output = health::process("");
        let response = tool_response(&output).into_response();
        assert_eq!(status_of(response), StatusCode::OK);
    }

    #[test]
    fn err_output_maps_to_400() {
        let output = health::process("{not valid json");
        let response = tool_response(&output).into_response();
        assert_eq!(status_of(response), StatusCode::BAD_REQUEST);
    }
}
