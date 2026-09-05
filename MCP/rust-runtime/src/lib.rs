//! `rust-runtime` is the thin HTTP adapter layer that lets n8n invoke this project's
//! deterministic Rust engines (`clitools/health`, `clitools/scoring`,
//! `clitools/campaign_policy`) over the network, closing the Phase 0B gap: the prior
//! `00_phase0b_foundation_check` workflow tried to invoke a locally-compiled binary path
//! that no real n8n host can reach. This crate is deployed as a small, non-public container
//! on the same Docker network as n8n; n8n reaches it over plain internal HTTP (see
//! `MCP/rust-runtime/README.md`).
//!
//! Architecture (see AGENT-START.md / CONTRACT.md sec.7 technology boundaries):
//!
//! ```text
//! n8n --(internal HTTP)--> rust-runtime --(normal Rust crate dependency)--> health
//!                                        --(normal Rust crate dependency)--> scoring
//!                                        --(normal Rust crate dependency)--> campaign_policy
//! ```
//!
//! This crate owns ONLY the transport (routing, request/response shape). Every route handler
//! is a one-line passthrough to the corresponding `clitools/` crate's existing `process`
//! function -- no deterministic logic is duplicated here, and this service holds no durable
//! state of its own (Supabase remains the source of truth; this runtime is stateless and can
//! be restarted or scaled without any data-loss concern).

pub mod response;
pub mod routes;

use axum::{
    routing::{get, post},
    Router,
};

/// Builds the application's route table. Kept as a free function (rather than inlined in
/// `main`) so integration tests can exercise the exact same router in-process via
/// `tower::ServiceExt::oneshot`, without binding a real socket.
pub fn build_router() -> Router {
    Router::new()
        .route("/health", get(routes::health::handler))
        .route("/tools/scoring", post(routes::scoring::handler))
        .route("/tools/campaign-policy", post(routes::campaign_policy::handler))
}
