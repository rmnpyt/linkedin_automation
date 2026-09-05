//! One module per exposed tool. Adding a new deterministic engine later means: add its
//! crate as a path dependency in `Cargo.toml`, add a `routes/<tool>.rs` module following the
//! same one-line-passthrough shape as the ones here, and register one route in
//! `crate::build_router`. No other file needs to change, and no tool logic is ever
//! duplicated here (see `crate::response::tool_response`, which every handler shares).

pub mod campaign_policy;
pub mod health;
pub mod scoring;
