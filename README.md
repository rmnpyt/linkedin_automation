# LinkedIn Automation System

## Project purpose and current scope

Automates LinkedIn connection acquisition (Stream 1: search → identity resolution → scoring
→ qualification → optional email enrichment → note generation → safe sending) for a small
number of individual operators. Governed by the documents in [`doc/`](doc/); `doc/CONTRACT.md`
is the binding acceptance-criteria document, `doc/PROPOSAL.md` is non-binding suggested shape
where the Contract leaves room, `doc/PLAN.md` defines build order and architecture, and
`doc/MINDSET.md` states the guiding principles.

**Explicitly out of scope for this build:** Stream 3 (Customer Automation), a public SaaS
product, billing/subscriptions, a generalized CRM, and multi-tenant admin.

**Current status at handoff:** Phases 0A through 1.5 are implemented, tested, independently
reviewed, and committed. Phase 2.1 (Story Discovery) has its persistence layer built and
tested but not its full human-validation acceptance. Phase 1.6 (real end-to-end acquisition)
and the rest of Phase 2.x require external authorization/access this repository does not
have — see "Current implementation/validation status" below.

## Architecture overview

Three cleanly separated technology roles, enforced throughout:

- **Supabase (Postgres)** owns all durable state and every invariant that can be expressed as
  a constraint, trigger, or transaction (budget caps, idempotency, state machines,
  append-only/versioned history). Every table has row-level security enabled with zero
  policies — this project has no anon/authenticated client access pattern; Rust tools never
  touch the database directly, and n8n uses a `service_role` credential internally.
- **n8n** orchestrates: it calls Rust tools and Supabase functions, but contains no scoring
  arithmetic, budget logic, or other business rules of its own.
- **Rust CLI tools** (`clitools/`) own deterministic, reusable logic — most importantly the
  KPI scoring engine, which never depends on an LLM. Each tool reads one JSON object from
  stdin and writes one line of JSON to stdout (`{"ok": true, "result": ...}` or
  `{"ok": false, "error": {"code", "message"}}`), exiting 0 or 1 accordingly.

LLMs are used only for semantic judgment (search-parameter translation, note drafting) —
never for arithmetic, budget decisions, idempotency, or state validation.

## Repository structure

```text
doc/                     Canonical governing documents (read in the order above)
clitools/                Rust workspace — one crate per deterministic tool (see below)
supabase/migrations/     Every schema/function change, in apply order
supabase/tests/          pgTAP test suites, one file per phase
n8n/shared/              Exported, Contract-adopted n8n workflows
n8n/legacy/              Pre-Contract prototype workflows (exported for reference, not adopted — see n8n/legacy/README.md)
powershell/linkedin/     ConnectionSender invocation contract (interface only; the real script is not present in this repo)
.env.example             Variable/capability names this system expects, no values
```

## Core runtime components

| Rust tool (`clitools/<name>`) | Purpose |
|---|---|
| `health` | Establishes the stdin/stdout/exit-code tool contract; no business logic. |
| `scoring` | Deterministic weighted KPI composite score, hard filters, seniority floor. Never calls an LLM. |
| `campaign_policy` | Campaign-wide search stop-reason precedence and next-batch sizing. |
| `harvestapi_normalize` | Normalizes/deduplicates/canonicalizes raw HarvestAPI search results. |
| `enrichment_policy` | Decides per-candidate email-enrichment eligibility and cap enforcement. |
| `contact_enrichment_normalize` | Validates/normalizes a raw enrichment provider result. |
| `connection_sender_normalize` | Validates/normalizes a ConnectionSender's raw stdout into `SENT`/`FAILED`/`ALREADY_CONNECTED`/`UNKNOWN`. |

Each has its own `Cargo.toml` and unit tests; `clitools/Cargo.toml` is the workspace root.

Supabase durable-state functions of note (see the migration that introduces each for full
rationale in comments): `reserve_campaign_budget`, `claim_contact_enrichment_attempt`,
`create_connection_note_and_mark_ready`, `claim_connection_for_sending`,
`mark_connection_attempt_send_attempted`, `record_connection_attempt_result`,
`reconcile_connection_attempt`, `retry_failed_connection_attempt`, `create_story_profile`.

## Prerequisites

- Rust toolchain (stable) — this project was built and tested against 1.98.1.
- A Supabase project for development (schema changes are applied only via
  `supabase/migrations/`, never hand-edited on a project).
- n8n instance with the [n8n-mcp](https://github.com/czlonkowski/n8n-mcp) server (or
  equivalent) for workflow management, and a Supabase MCP server for migrations/queries, if
  continuing development the way this repository's history was built.
- `pgTAP` (already enabled via `supabase/migrations/20260905090019_pgtap.sql`).

## Development/setup instructions

```bash
# Rust: build and test the whole workspace
cargo build --manifest-path clitools/Cargo.toml
cargo test  --manifest-path clitools/Cargo.toml
```

No `rustfmt`/`clippy` component is currently installed for the active toolchain in this
environment; `cargo build`/`test` do not require them.

## Supabase development-project setup and migration procedure

1. Create (or use) a dedicated **development** Supabase project. Never point this system at
   a production project.
2. Apply every file in `supabase/migrations/` **in filename order** (the timestamp prefix is
   the order) — either via the Supabase CLI (`supabase db push` / `supabase migration up`
   against a linked project) or by applying each file's SQL through your own tooling. All 30
   migrations in this repository have been applied to and verified against a live
   development project during this build.
3. Run a phase's tests by executing its file under `supabase/tests/` inside a transaction
   that rolls back (every file already wraps itself in `begin; ... rollback;`), so running
   them leaves no residue in a shared project. `supabase test db` runs the whole pgTAP suite
   if you have the Supabase CLI installed locally; otherwise any tool that can execute raw
   SQL against the project (e.g. a Postgres client, or the Supabase MCP server's
   `execute_sql`) works equally well.
4. After any schema change, check the project's security/performance advisors. This project
   intentionally carries one class of `INFO`-level advisory — "RLS enabled, no policy" — on
   every table; that is the deliberate posture described above, not an oversight.

## n8n workflow import/export and naming conventions

- Every material, Contract-adopted workflow is exported as JSON under `n8n/shared/`.
  Currently: `00_phase0b_foundation_check.json` (a smoke-test workflow verifying Supabase
  connectivity and the Rust tool contract).
- `n8n/legacy/` holds three pre-Contract prototype workflows found on the instance at the
  start of this build, exported for institutional-knowledge purposes (working Apify actor
  names, confirmed OpenRouter model names, a documented free-tier rate limit) but **not
  adopted** — they target a superseded schema and put business logic in n8n Code nodes,
  which this project's architecture forbids. See `n8n/legacy/README.md` for the full
  reconciliation notes before building on top of them.
- New or materially changed workflows must start **inactive** and stay inactive unless a
  specific, controlled validation step requires activation. None of this repository's
  workflows are currently active.

## Required credential/capability names (no values)

Documented in `.env.example` and, for n8n-internal credentials, kept entirely inside n8n's
own credential store (never in this repository). At minimum, a working deployment needs:
a Supabase project URL and `service_role` key (n8n-side only), an Apify API token, an
OpenRouter (or equivalent LLM provider) API key, and `TEST_SPEND_BUDGET_USD` (defaults to
`0` — see below).

## MOCK / TEST / LIVE execution modes and the provider-budget safety model

Automated testing defaults to mocks/fixtures and must never spend real money. Every Rust
tool that models a paid-provider interaction is tested exclusively against synthetic
fixtures (see each crate's `tests` module). `TEST_SPEND_BUDGET_USD` defaults to `0`; no
component in this repository is authorized to raise it or to make a real paid-provider call
without an explicit, human-authorized non-zero budget for that specific test. No such
authorization has been given during this build, so **no real Apify or OpenRouter call has
ever been made by this system** — every provider interaction exercised so far has been
against synthetic fixture data.

## Human approval / live-validation boundaries

This system must never send a real LinkedIn connection request or publish real content
without an explicit, separately authorized live-validation step, and must never attempt to
bypass a LinkedIn challenge, CAPTCHA, or rate limit. `powershell/linkedin/` documents the
invocation contract the real connection-sending script must satisfy; the actual script is
not present in this repository (this is an access gate, not something this system can
generate for itself — see "Known limitations" below).

## Configuring CampaignRevision budgets

`campaign_revision.search_policy`, `.budget_policy`, and `.contact_enrichment_policy` (all
`jsonb`) hold the per-revision limits `clitools/campaign_policy` and the budget-reservation
functions enforce — search-cost caps, total-campaign-cost caps, max unique candidates, and
contact-enrichment score thresholds/attempt limits. `operator.max_daily_connection_sends`
and `operator.send_window_start_hour_utc`/`send_window_end_hour_utc` (added in Phase 1.5)
cap real connection sends per UTC day and restrict the hours sending is allowed; all of these
are optional and default to uncapped/unrestricted when not set. See the comments in
`supabase/migrations/20260905090007_campaign_revision.sql` and
`20260905130001_connection_send_lifecycle.sql` for the exact fields and semantics.

## Operational start/stop guidance

Every workflow ships inactive by design (see above). There is currently no automated
schedule anywhere in this system — every run to date has been a manual/test execution
against synthetic data, which is the required default until a human explicitly authorizes a
live run.

## Troubleshooting / known limitations

- **The real PowerShell connection-sender script is not in this repository.** MINDSET.md
  references an existing working script; it was never supplied during this build. Until it
  is (or an equivalent is written and reviewed), Phase 1.6 and any real send are blocked.
  This is an **ACCESS_PENDING** item, not a design gap — `powershell/linkedin/CONNECTION_SENDER_CONTRACT.md`
  and `clitools/connection_sender_normalize` are fully built and tested against the
  documented contract.
- **`rustfmt`/`clippy` are not installed** for the active Rust toolchain in this environment,
  and installing the component was blocked by this environment's own tooling policy.
  `cargo build`/`test` are unaffected.
- **The n8n-mcp server used during this build (v2.22.17) has a confirmed bug**: applying a
  partial workflow update (`n8n_update_partial_workflow` with `validateOnly: false`) can fail
  with a schema error even when the identical payload validates successfully with
  `validateOnly: true`. Full-workflow creation/replacement was not affected. A Manual-Trigger
  or Execute-Workflow-Trigger workflow also cannot currently be executed through this MCP
  toolchain — only webhook-triggered workflows can, which requires activation. This limited
  how much n8n orchestration work could be built and verified to the same standard as the
  Rust/SQL work in this repository during this session.
- **No real provider call has been made** (see the budget section above) — every Rust tool's
  provider-facing behavior is verified against fixtures capturing realistic response shapes,
  not live responses.

## Documentation map

Read in this order: [`AGENT-START.md`](AGENT-START.md) →
[`doc/MINDSET.md`](doc/MINDSET.md) → [`doc/PLAN.md`](doc/PLAN.md) →
[`doc/CONTRACT.md`](doc/CONTRACT.md) → [`doc/PROPOSAL.md`](doc/PROPOSAL.md) →
[`doc/KPI-FRAMEWORK.md`](doc/KPI-FRAMEWORK.md), [`doc/CONNECTION-FLOW.md`](doc/CONNECTION-FLOW.md),
[`doc/CONTENT-FLOW.md`](doc/CONTENT-FLOW.md) → [`doc/RESEARCH-NOTES.md`](doc/RESEARCH-NOTES.md)
(history only, non-authoritative).

## Current implementation/validation status

| Phase | Status |
|---|---|
| 0A — Domain foundation schema | **DONE — CONTRACT SATISFIED.** Reviewed, tested, committed (`c5d3fcc`). |
| 0B — Runtime foundation | **DONE — CONTRACT SATISFIED.** Reviewed, tested, committed (`b7a437f`). |
| 1.1 — KPI scoring engine | **DONE — CONTRACT SATISFIED.** 25 Rust tests, reviewed, committed (`0ce6c47`). |
| 1.2 — Search/identity/budget | **DONE — CONTRACT SATISFIED** (scoped to what does not require a real paid search). Reviewed, tested, committed (`78b0688`). |
| 1.3 — Contact enrichment | **DONE — CONTRACT SATISFIED** (scoped to what does not require a real paid enrichment call). Reviewed, tested, committed (`bb0f414`). |
| 1.4 — Connection note generation | **DONE — CONTRACT SATISFIED.** Reviewed, tested, committed (`69ce34e`). |
| 1.5 — Safe sending | **DONE — CONTRACT SATISFIED** for everything not requiring a real send. Reviewed, tested, committed (`fa54612`). |
| n8n legacy reconciliation | Done — pre-Contract prototypes inspected, exported, documented as not-adopted (`3265eeb`). |
| 2.1 — Story Discovery | **IMPLEMENTED — LIVE VALIDATION PENDING.** Persistence/versioning/provenance built, reviewed, tested (`5dc6939`). Running Story Discovery on both real current operators and the required human usability judgment (CONTRACT.md sec.50) needs real personal source material not available in this repository — **ACCESS_PENDING / HUMAN_DECISION_REQUIRED.** |
| 1.6 — End-to-end acquisition | **BLOCKED.** Every building block it needs (search/enrichment/scoring/notes/sending) is already built and tested individually. Full acceptance additionally requires a real paid search, a real paid enrichment call, and a real LinkedIn send — all of which need an explicit non-zero test-budget authorization and a real-send authorization this repository does not have, plus the missing PowerShell sender script. |
| 2.2-2.4 (further Stream 2) | Not started — depend on a real Phase 2.1 StoryProfile. |

**No commit in this history was pushed to any remote** — this repository currently has no
remote configured at all (`git remote -v` returns nothing). All work is local and ready for
human review before any push, remote setup, or deployment decision.
