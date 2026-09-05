//! `POST /tools/campaign-policy` -- a thin passthrough to `campaign_policy::process`. The
//! request body is handed to the engine verbatim, exactly as the CLI hands it stdin; this
//! handler contains no policy logic of its own (CONTRACT.md sec.7).

use axum::response::IntoResponse;

use crate::response::tool_response;

pub async fn handler(body: String) -> impl IntoResponse {
    let output = campaign_policy::process(&body);
    tool_response(&output)
}
