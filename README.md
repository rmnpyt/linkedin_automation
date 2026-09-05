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

**Current status at handoff:** Phases 0A through 1.5 are implemented and automated-tested,
but an independent completion audit (2026-09-05, see "Current implementation/validation
status" below) found that an earlier report overstated several of them as fully
Contract-satisfied. Only **Phase 0A** holds up as `DONE — CONTRACT SATISFIED` under
re-verification. **Phase 0B is `INCOMPLETE`**: the Contract requires n8n to actually invoke
the first deterministic Rust tool, and there is no evidence this has ever succeeded — the
only workflow built for this has zero recorded executions, and its Rust-invocation node is
built to deliberately fail (a local relative path an n8n host cannot reach), with an explicit
comment not to make it succeed. Phases 1.1-1.4 have real automated-verification-passed
mechanisms but unmet real/human/live criteria (detailed below). Phase 1.5 has 7 of 9
criteria solidly built and tested, but two depend on the real PowerShell sender script,
which was never obtained. Phase 2.1 (Story Discovery) has its persistence layer built and
tested but not its full human-validation acceptance. Phase 1.6 and the rest of Phase 2.x
require external authorization/access this repository does not have.

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
  Currently: `00_phase0b_foundation_check.json`, a workflow *designed* to check Supabase
  connectivity, the LLM gateway, and Rust-tool invocation from n8n — but it has **never
  actually been executed** (confirmed via `n8n_list_executions` and an empty `workflow_run`
  table). Its Rust-invocation node is also built to deliberately fail. See "Current
  implementation/validation status" below; treat this workflow as a design draft, not
  verified plumbing.
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

**Corrected 2026-09-05 by an independent completion audit.** An earlier report in this
project's history claimed Phases 0A-1.5 were `DONE — CONTRACT SATISFIED`. That claim was
re-verified line-by-line against `doc/CONTRACT.md`'s exact acceptance criteria, the live
development Supabase project (every phase's pgTAP suite was rerun fresh, not assumed from
memory), and available n8n execution evidence. The audit found several criteria that
automated tests cannot satisfy — real/paid-provider validation, human review of real data,
and one architecturally-blocked runtime requirement — had been silently treated as met. The
table below reflects the corrected findings; the classifications below are precise, not
approximate.

| Phase | Status | Unresolved gate(s) |
|---|---|---|
| 0A — Domain foundation schema | **DONE — CONTRACT SATISFIED.** | None. All 14 CONTRACT.md sec.89 criteria map to a passing pgTAP assertion or a directly-inspected schema fact (35 assertions re-run live, 35/35 pass, zero residue). No criterion in sec.89 requires real/live/human validation. |
| 0B — Runtime foundation | **INCOMPLETE.** | CONTRACT.md sec.90 requires n8n to actually invoke the Supabase project, the LLM gateway, and the first deterministic Rust tool. The only workflow built for this (`n8n/shared/00_phase0b_foundation_check.json`) has **zero recorded executions** — confirmed via both `n8n_list_executions` (empty for this workflow) and the live `workflow_run`/`workflow_step_run` tables (0 rows total, from any workflow, ever). The Rust-tool-invocation node is not merely unexecuted — it is built to deliberately fail (`command: "./clitools/health/target/release/health"`, a path only valid on the machine this was built on, not any real n8n host) with an explicit code comment: "Do not attempt to make this succeed by installing Rust on the n8n host or exposing local infra." No successful `n8n → Rust tool` invocation has ever occurred, and the current design cannot produce one without new infrastructure (an HTTP-wrapped tool or a host-reachable binary) that has not been built. Secrets-outside-source-control is the one criterion independently confirmed true (every credential is referenced by n8n credential-store ID, never embedded). |
| 1.1 — KPI scoring engine | **IMPLEMENTED — AUTOMATED VERIFICATION PASSED — LIVE VALIDATION PENDING.** | The deterministic Rust scorer, its 25 tests (re-run, 25/25 pass), the versioned `doc/prompts/profile-evaluator/v1.md` prompt, and the missing-evidence/hard-filter/KPI-6-floor rules are all real and correct. But CONTRACT.md sec.91 also requires "approximately ten real profiles have passed human sanity review" — this has not happened; no real profile has ever been scored by this system, mock or otherwise, and no human has reviewed any output. `evaluation.model_provider`/`model_name`/`prompt_version` are nullable and were never populated by any test fixture, so "Evaluation provenance is persisted" is schema capacity, not demonstrated behavior. |
| 1.2 — Search/identity/budget | **IMPLEMENTED — AUTOMATED VERIFICATION PASSED — LIVE VALIDATION PENDING.** | Budget-reservation concurrency safety, identity resolution, and the unique-candidate cap are real and tested (re-run, 27/27 pass). CONTRACT.md sec.92 explicitly requires "real HarvestAPI search has been validated" and "at least one authenticated-search benchmark is exercised, or an explicit authorized human waiver is recorded" — neither has happened; no real Apify/HarvestAPI call has ever been made and no waiver is on record. An earlier report's "(scoped to what does not require a real paid search)" framing was an invented narrowing not present in the Contract text, and is retracted. |
| 1.3 — Contact enrichment | **IMPLEMENTED — AUTOMATED VERIFICATION PASSED — LIVE VALIDATION PENDING.** | CONTRACT.md sec.93 has no explicit "real"/"live" bullet (unlike sec.91/92), and every listed criterion (score threshold, count/cost caps, campaign-wide aggregation, no-result handling) is mechanism-tested (re-run, 7/7 pass). Downgraded from DONE anyway for honesty: no real enrichment provider call has ever been made, so "actual enrichment usage/cost is recorded" has only ever recorded synthetic zero-cost data, never a real provider response. |
| 1.4 — Connection note generation | **IMPLEMENTED — AUTOMATED VERIFICATION PASSED — LIVE VALIDATION PENDING.** | The persistence/state-machine layer (NOTE_READY gating tied to an exact fresh/qualified/governing Evaluation, supersession, recoverable-failure, 300-char limit) is real and tested (re-run, 15/15 pass). But every test supplies the note body as a literal string — the actual LLM generation step described in `doc/prompts/connection-note/v1.md` has never been invoked by anything in this repository, mock or real (same zero-n8n-execution gap as Phase 0B). CONTRACT.md sec.94's "generic context-free notes are not accepted as successful output" is also not enforced by any code — only instructed in the prompt document; no mechanism here would actually reject a generic note if one were supplied. |
| 1.5 — Safe sending | **ACCESS_PENDING.** | 9 of 11 CONTRACT.md sec.95 criteria (ConnectionAttempt exists, CampaignCandidate attribution, exact authorizing Evaluation + persisted note attribution, idempotency, concurrent-claim prevention via row locks, failed-send recording, UNKNOWN_SEND_RESULT, no-blind-retry, daily/window limits) are real and tested (re-run, 26/26 pass). The remaining two are unmet, not pending a live click: "existing browser sender is behind a stable ConnectionSender boundary" — the existing script referenced in MINDSET.md was never obtained, so nothing was ever wrapped, only a contract for a hypothetical future script was written; "session/account challenges stop safely" — this is a real sender's runtime behavior, unverifiable without that sender. Both gate on the same missing external asset. |
| n8n legacy reconciliation | Done — pre-Contract prototypes inspected, exported, documented as not-adopted (`3265eeb`). | None. |
| 2.1 — Story Discovery | **IMPLEMENTED — AUTOMATED VERIFICATION PASSED — LIVE VALIDATION PENDING.** | Persistence/versioning/provenance built, reviewed, tested (`5dc6939`, 18/18 pass). Running Story Discovery on both real current operators and the required human usability judgment (CONTRACT.md sec.50) needs real personal source material not available in this repository — **ACCESS_PENDING / HUMAN_DECISION_REQUIRED.** |
| 1.6 — End-to-end acquisition | **BLOCKED.** | Every individual building block it needs is built and unit/integration-tested at the Rust/SQL layer, but Phase 0B's unresolved n8n↔Rust-tool gap means no phase of this pipeline has ever actually been orchestrated end-to-end by n8n either. Full acceptance additionally requires a real paid search, a real paid enrichment call, and a real LinkedIn send, none authorized, plus the missing PowerShell sender script. |
| 2.2-2.4 (further Stream 2) | Not started — depend on a real Phase 2.1 StoryProfile. | |

**No commit in this history was pushed to any remote** — this repository currently has no
remote configured at all (`git remote -v` returns nothing). All work is local and ready for
human review before any push, remote setup, or deployment decision.
