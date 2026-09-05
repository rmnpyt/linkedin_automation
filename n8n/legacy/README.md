# Legacy n8n workflows (pre-Contract prototypes)

AGENT-START.md sec.12.4 requires every material n8n workflow to have a version-controlled
representation, and the pending-items list carried forward from earlier phases flagged three
pre-existing workflows on the n8n instance that had never been inspected or reconciled:

- `Connection Automation - Apify Search` (`la6TUX9vxC2CJL4F`)
- `Connection Automation - Apify Search (Goal-Driven)` (`pFvlSwOXibZp9Ck3`)
- `Connection Automation - KPI Scorer` (`qrlaM9xlLt1inXRP`)

All three are exported here (full node/connection JSON, credential references only -- no
secret values) for traceability. **None of them are adopted by this project going forward.**
All three remain inactive on the n8n instance and this export changes nothing about that.

## Why they are not reused as-is

Inspecting their node graphs (2026-09-05) showed two problems that make them incompatible
with the Contract-driven system built from Phase 0A onward, not just superficially outdated:

1. **Schema mismatch.** They read/write a `campaign`/`profile`/`score` table shape (flat
   columns like `spent_usd`, `max_budget_usd`, `search_exhausted`, `next_search_page`,
   `linkedin_url`, `email` directly on `profile`) that predates and does not match the
   current domain schema (`campaign_revision`, `campaign_candidate`, `person`,
   `external_profile`, `profile_snapshot`, `evaluation`, `contact_point`,
   `contact_enrichment_attempt`, ...). They cannot be pointed at the current database without
   a rewrite, not just a config change.

2. **Architecture-boundary violation.** `Connection Automation - KPI Scorer` computes the
   weighted KPI composite, the seniority-floor offset, and the hard-filter decision in its own
   `Compute Composite Score` Code node, in n8n. CONTRACT.md and MINDSET.md are explicit that
   this arithmetic is Rust-owned deterministic logic and must never live in n8n or depend on
   an LLM. The two search workflows similarly do cost accounting, pagination-limit
   stop-reason precedence, and HarvestAPI response normalization inline in Code nodes.
   Phase 1.1-1.3 already reimplemented and tested all of this correctly as Rust CLI tools
   (`clitools/scoring`, `clitools/campaign_policy`, `clitools/harvestapi_normalize`,
   `clitools/enrichment_policy`, `clitools/contact_enrichment_normalize`) plus Supabase RPC
   functions with row-locked, campaign-wide budget aggregation that these workflows' plain
   `spent_usd` column update cannot provide.

## What is still genuinely useful from them

These prototypes are real prior engineering work and encode operationally-verified details
worth carrying forward when Phase 1.6's real orchestration workflow is built:

- The HarvestAPI actor names and call shape that are confirmed working against a real Apify
  account: `harvestapi~linkedin-profile-search` (search) and
  `harvestapi~linkedin-profile-scraper` with `profileScraperMode: "Profile details + email
  search ($10 per 1k)"` (enrichment).
- The free-tier Apify plan limit discovered in practice: enrichment calls are capped at 10
  URLs per run, which is why the goal-driven search workflow caps `maxItems` at 10 per page.
- Working OpenRouter model names after documented deprecations/outages:
  `nvidia/nemotron-3.5-lightning:free` for cheap/simple tasks,
  `nvidia/nemotron-3-ultra-550b-a55b:free` for the search-goal-to-parameters step (with a
  120s timeout, since Ultra is much slower).
- The `alwaysOutputData: true` workaround for n8n's default behavior of skipping downstream
  nodes entirely when a node emits zero items (needed anywhere a "found nothing this round"
  outcome must still flow through, e.g. dedup/enrichment steps).

## What Phase 1.6 must build instead

A new workflow (or set of workflows) that orchestrates the already-built and already-tested
Rust tools and Supabase RPC functions against the current schema -- calling
`clitools/campaign_policy`, `clitools/harvestapi_normalize`, `clitools/enrichment_policy`,
`clitools/contact_enrichment_normalize`, `clitools/scoring`, and `clitools/connection_sender_normalize`
as external commands (or an equivalent invocation mechanism), and the Phase 1.2-1.5 Supabase
functions (`reserve_campaign_budget`, `claim_contact_enrichment_attempt`,
`create_connection_note_and_mark_ready`, `claim_connection_for_sending`, etc.) for all durable
state and idempotency -- never reimplementing that logic in n8n Code nodes.
