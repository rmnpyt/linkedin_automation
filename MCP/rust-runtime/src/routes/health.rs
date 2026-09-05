//! `GET /health` -- the runtime's own liveness probe, AND a literal, real invocation of the
//! first deterministic Rust tool (CONTRACT.md sec.90 "n8n can invoke the first deterministic
//! Rust tool"). It calls `health::process("")`, the exact function the `clitools/health` CLI
//! binary calls for an empty/no-op input -- no logic is duplicated here.

use axum::response::IntoResponse;

use crate::response::tool_response;

pub async fn handler() -> impl IntoResponse {
    let output = health::process("");
    tool_response(&output)
}
