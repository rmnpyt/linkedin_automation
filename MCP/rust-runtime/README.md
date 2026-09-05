# rust-runtime

Thin HTTP adapter that lets n8n invoke this project's deterministic Rust engines
(`clitools/health`, `clitools/scoring`, `clitools/campaign_policy`) over the network. This
service exists to close one specific Contract gap: `doc/CONTRACT.md` sec.90 requires "n8n can
invoke the first deterministic Rust tool," and the workflow built for Phase 0B
(`n8n/shared/00_phase0b_foundation_check.json`) originally tried to invoke a locally-compiled
binary path (`./clitools/health/target/release/health`) that no real, separately-hosted n8n
instance could ever reach — that node was deliberately built to fail. This service replaces
that dead end with a real, reachable HTTP boundary.

## What this is not

- **Not a durable state store.** This service holds no state of its own and can be restarted,
  rebuilt, or scaled without any data-loss concern. Supabase remains the sole source of truth
  for everything durable (campaigns, evaluations, connections, ...).
- **Not a reimplementation of any business logic.** Every route is a one-line passthrough to
  the corresponding `clitools/` crate's existing, already-tested `process` function. If you
  find yourself writing an `if`/`match` on tool-specific data inside `src/routes/`, that logic
  belongs in the `clitools/` crate instead.
- **Not publicly exposed.** No route requires authentication because none is meant to be
  reachable from outside the Docker network it shares with n8n. Do not publish its port to a
  public interface; see "Network setup" below.

## Architecture

```text
n8n --(internal HTTP, same Docker network)--> rust-runtime --(Cargo path dependency)--> health
                                                             --(Cargo path dependency)--> scoring
                                                             --(Cargo path dependency)--> campaign_policy
```

`clitools/health`, `clitools/scoring`, and `clitools/campaign_policy` are unchanged in
purpose and remain in `clitools/` as both CLI binaries (unchanged stdin/stdout/exit-code
contract, still directly testable/runnable exactly as before) and libraries. Each crate now
has a `src/lib.rs` (the actual `process(&str) -> ToolOutput` logic, moved out of `main.rs`
verbatim) and a thin `src/main.rs` (just the stdin/stdout/exit-code wiring, unchanged
behavior). `rust-runtime` depends on the three crates' *library* targets via normal Cargo
path dependencies (`Cargo.toml`) -- it does not copy, vendor, or duplicate a single line of
their logic.

```text
MCP/rust-runtime/
  Cargo.toml           # path-dependencies on ../../clitools/{health,scoring,campaign_policy}
  src/
    main.rs             # binds a TCP listener, serves the router -- nothing else
    lib.rs               # pub fn build_router() -- shared by main.rs and integration tests
    response.rs          # the ONE place that maps a tool's {"ok":...} JSON to an HTTP status
    routes/
      health.rs           # GET  /health              -> health::process("")
      scoring.rs           # POST /tools/scoring        -> scoring::process(&body)
      campaign_policy.rs    # POST /tools/campaign-policy -> campaign_policy::process(&body)
  tests/http_test.rs    # in-process integration tests (tower::ServiceExt::oneshot)
  Dockerfile
  docker-compose.example.yml
  config.example         # env vars this service reads (no secrets)
```

## Endpoints

| Method | Path | Wraps | Request body | Response |
|---|---|---|---|---|
| GET | `/health` | `health::process("")` | none | `200` `{"ok":true,"tool":"health","version":"0.1.0","result":{"status":"ok","echo":null}}` |
| POST | `/tools/scoring` | `scoring::process` | the same JSON `clitools/scoring` reads on stdin | `200` on `ok:true`, `400` on a handled `ok:false` (e.g. `INVALID_WEIGHTS`) |
| POST | `/tools/campaign-policy` | `campaign_policy::process` | the same JSON `clitools/campaign_policy` reads on stdin | `200` on `ok:true`, `400` on a handled `ok:false` |

Every response body is exactly the tool's own JSON output, unmodified -- see each crate's
`src/lib.rs` doc comments and `doc/CONTRACT.md` for what each field means. HTTP status is
derived purely from the `ok` field (`response::tool_response`); a `500` means this service's
own (de)serialization broke, never a tool-level validation failure.

## Adding a new tool later (requirement: no ad-hoc services)

1. Add the crate as a normal path dependency in `Cargo.toml` (mirroring `health`, `scoring`,
   `campaign_policy`).
2. Add `src/routes/<tool>.rs` with one `async fn handler(body: String) -> impl IntoResponse`
   that calls `<tool>::process(&body)` and returns `response::tool_response(&output)` --
   copy `routes/scoring.rs` and rename.
3. Register one line in `build_router()` (`src/lib.rs`).
4. Add one or two integration tests in `tests/http_test.rs` following the existing pattern.

No other file changes, and no new service/container.

## Local development

```bash
cargo build --manifest-path MCP/rust-runtime/Cargo.toml
cargo test  --manifest-path MCP/rust-runtime/Cargo.toml   # unit tests (response.rs) + integration tests (tests/http_test.rs)
cargo run   --manifest-path MCP/rust-runtime/Cargo.toml   # listens on 0.0.0.0:8080 by default
```

`cargo test` exercises the full HTTP stack in-process via `tower::ServiceExt::oneshot` (no
socket bound) -- see `tests/http_test.rs`. It does not re-assert each engine's own business
rules (those tests already exist in `clitools/<tool>`'s own test suite and must not be
duplicated here); it only proves the transport layer correctly carries a request to the
engine and the engine's answer back out, including the malformed-input -> `400` path.

## Building and verifying the container locally

Build context **must be the repository root** (not this directory), because the Dockerfile
copies the `clitools/` crates this service depends on:

```bash
# from the repository root
docker build -f MCP/rust-runtime/Dockerfile -t rust-runtime:latest .

docker run -d --name rust-runtime-verify -p 18080:8080 rust-runtime:latest
curl http://localhost:18080/health
curl -X POST http://localhost:18080/tools/scoring -H "content-type: application/json" -d '{"weights":{"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10},"scores":{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70},"requireField":true,"requireLocation":true,"qualificationThreshold":60}'

docker stop rust-runtime-verify && docker rm rust-runtime-verify
```

This exact sequence was run during development (2026-09-05): the image built successfully,
the container started and logged `rust-runtime listening on 0.0.0.0:8080`, and `GET /health`,
`POST /tools/scoring`, and `POST /tools/campaign-policy` all returned correct `200` results
plus a `400` for a malformed body -- see the Phase 0B fix commit message for the exact
captured output. That is local-container evidence only; it is **not** evidence that the real
n8n instance can reach this service (see "What still needs to happen" below).

## Deployment: network setup

Both containers (n8n and `rust-runtime`) must share one Docker network, and that network must
not be published to a public interface. Two ways to get there:

**A. n8n is already running as its own container.** Create a dedicated internal network and
attach both containers to it:

```bash
docker network create linkedin-automation-internal
docker network connect linkedin-automation-internal <your-n8n-container-name>

# from the repository root
docker build -f MCP/rust-runtime/Dockerfile -t rust-runtime:latest .
docker run -d --name rust-runtime --restart unless-stopped \
  --network linkedin-automation-internal \
  rust-runtime:latest
```

Do not publish a `-p host:container` port for the `rust-runtime` container in this setup --
n8n reaches it by container name over the internal network only (requirement: not exposed
publicly by default).

**B. Bringing both up together via compose.** Adapt `docker-compose.example.yml` (fill in
your real n8n service definition, or delete that block and use option A's `docker network
connect` against your existing n8n stack instead), then:

```bash
docker compose -f MCP/rust-runtime/docker-compose.example.yml up -d --build
```

## The exact n8n runtime URL

With the container named `rust-runtime` on the shared network (as above), n8n reaches it at:

```text
http://rust-runtime:8080
```

`n8n/shared/00_phase0b_foundation_check.json`'s "Call Rust Runtime (GET /health)" node calls
`http://rust-runtime:8080/health` by default. If you name the container or network alias
something else, set `RUST_RUNTIME_URL` (e.g. `http://my-alias:8080`) in n8n's own environment
before importing/activating the workflow.

## Post-deployment validation procedure

1. Deploy per "Deployment: network setup" above.
2. From a shell with access to the same Docker network (e.g. `docker exec -it
   <n8n-container> sh`, or a throwaway container attached to the same network), confirm
   reachability directly: `wget -qO- http://rust-runtime:8080/health` (or `curl`) should
   return `{"ok":true,"tool":"health",...}`.
3. In the n8n UI, open `linkedin_automation / shared / 00_phase0b_foundation_check` and
   execute it manually (it is a webhook-triggered workflow; trigger it with `curl -X POST
   <your-n8n-webhook-url>/webhook/phase-0b-foundation-check`, or use n8n's "Test workflow"
   feature against the webhook node).
4. Confirm in the execution log that "Call Rust Runtime (GET /health)" returned a `200` with
   `ok: true`, and that "Rust Runtime Reachable?" took its true branch into "Complete Step Run
   - Rust Tool Invocation".
5. Query the live `linkedin_automation` Supabase project:
   `select * from workflow_step_run where step_name = 'rust_tool_invocation' order by
   created_at desc limit 1;` and confirm `state = 'COMPLETED'` with a `finished_at` set --
   this durable row, written by n8n as a direct result of the HTTP call succeeding, is the
   artifact that should be pointed to as evidence, not just an execution-log screenshot.

## What evidence must exist before Phase 0B can be marked `DONE — CONTRACT SATISFIED`

Per CONTRACT.md sec.90, all of the following, together:

- A `workflow_step_run` row with `step_name = 'rust_tool_invocation'`, `state = 'COMPLETED'`,
  written by an actual n8n execution (step 5 above) -- not a manually-inserted test row.
- The corresponding n8n execution log showing "Call Rust Runtime (GET /health)" actually
  returned a `200`/`ok:true` response from the deployed service (not the `onError`-caught
  failure path).
- The same execution's LLM-gateway step ("Call LLM Gateway (OpenRouter)" /
  "Complete Step Run - LLM Gateway Check") also completing successfully, since sec.90 requires
  *both* the Rust-tool and LLM-gateway invocations, not just one.
- Confirmation that the deployed `rust-runtime` container is not reachable from outside the
  Docker network it shares with n8n (i.e., requirement 8 was actually honored in the real
  deployment, not just in this template).

Until deployment happens, the correct status for this specific gate is:

```text
ACCESS_PENDING — RUST_RUNTIME_DEPLOYMENT
```

This is a deliberate, narrow classification: the mechanism (this service, its tests, the
updated n8n workflow) is fully built, tested, and locally container-verified, but the one
remaining step -- actually running it on the network n8n's real host can reach -- is a manual
deployment action reserved for the project owner (per this phase's own instructions), not
something that can be claimed complete from a development environment. No agent should
upgrade this classification without the evidence listed above actually existing.
