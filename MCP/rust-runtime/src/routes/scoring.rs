//! `POST /tools/scoring` -- a thin passthrough to `scoring::process`. The request body is
//! handed to the engine verbatim, exactly as the CLI hands it stdin; this handler contains
//! no scoring logic of its own (CONTRACT.md sec.7: deterministic logic lives in the Rust
//! engine, never in the transport layer).

use axum::response::IntoResponse;

use crate::response::tool_response;

pub async fn handler(body: String) -> impl IntoResponse {
    let output = scoring::process(&body);
    tool_response(&output)
}
