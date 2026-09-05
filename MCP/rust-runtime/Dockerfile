# syntax=docker/dockerfile:1
#
# Build context MUST be the repository root (not MCP/rust-runtime/), because this service
# depends on the existing clitools/health, clitools/scoring, and clitools/campaign_policy
# crates via normal Cargo path dependencies -- their source is never copied or duplicated
# into this directory. Build from the repository root with:
#
#   docker build -f MCP/rust-runtime/Dockerfile -t rust-runtime:latest .
#
# See MCP/rust-runtime/README.md for the full deployment procedure.

FROM rust:1.82-slim-bookworm AS builder
WORKDIR /build

# Copy only the crates this service's dependency graph actually needs -- not the whole
# repository (no Supabase migrations, no doc/, no unrelated clitools crates) -- keeping the
# build context and resulting image free of anything this service does not use.
COPY clitools/health ./clitools/health
COPY clitools/scoring ./clitools/scoring
COPY clitools/campaign_policy ./clitools/campaign_policy
COPY MCP/rust-runtime ./MCP/rust-runtime

WORKDIR /build/MCP/rust-runtime
RUN cargo build --release

FROM debian:bookworm-slim AS runtime

# Runs as an unprivileged, non-root user; this service has no filesystem/network needs
# beyond listening on one port and calling out to nothing (CONTRACT.md sec.7: no network
# calls, no secrets -- the deterministic engines it wraps are pure functions).
RUN useradd --system --no-create-home --shell /usr/sbin/nologin runtime

COPY --from=builder /build/MCP/rust-runtime/target/release/rust-runtime /usr/local/bin/rust-runtime

USER runtime
ENV RUST_RUNTIME_BIND_ADDR=0.0.0.0:8080
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/rust-runtime"]
