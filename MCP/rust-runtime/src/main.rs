//! Entrypoint: binds a TCP listener and serves the router built by `rust_runtime::build_router`.
//! No business logic lives here -- see `src/lib.rs` and `src/routes/`.

use rust_runtime::build_router;

const DEFAULT_BIND_ADDR: &str = "0.0.0.0:8080";

#[tokio::main]
async fn main() {
    let bind_addr = std::env::var("RUST_RUNTIME_BIND_ADDR").unwrap_or_else(|_| DEFAULT_BIND_ADDR.to_string());

    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .unwrap_or_else(|e| panic!("rust-runtime: failed to bind {bind_addr}: {e}"));

    println!("rust-runtime listening on {bind_addr}");

    axum::serve(listener, build_router())
        .await
        .unwrap_or_else(|e| panic!("rust-runtime: server error: {e}"));
}
