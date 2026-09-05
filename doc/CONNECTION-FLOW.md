# Connection Automation — Flow

> Canonical stream specification. This document defines the Connection Automation pipeline
> under the project-wide architecture in MINDSET.md and PLAN.md.

## Goal

Take a campaign objective, find real LinkedIn people that fit, evaluate them using the KPI
framework, optionally enrich qualified people with contact information, and send purposeful
LinkedIn connection requests while preserving durable state, cost, provenance, and failure
history.

The flow is designed to be unattended through n8n for its default path while keeping external
providers replaceable.

## Core pieces

| Piece | Job |
|---|---|
| **n8n** | Orchestrates the flow: campaign execution, bounded search batches, Supabase calls, LLM calls, Rust tools, enrichment, queueing, retries, and provider calls. It does not own core business rules. |
| **Supabase** | Canonical durable state: campaigns/revisions, people, external profiles, snapshots, candidates, evaluations, contact points, connections, attempts, workflow traces, and provider cost. |
| **Rust tools** | Deterministic reusable business logic: KPI calculation, hard filters, weight normalization, qualification decisions, and shared campaign/budget policy where appropriate. |
| **LLM via configured provider** | Semantic judgment and generation: six KPI judgments/reasons and personalized connection-note drafting. The LLM does not calculate the weighted composite. |
| **SearchProvider** | Finds LinkedIn candidates behind a replaceable interface. Initial unattended implementation: HarvestAPI through Apify. |
| **AuthenticatedBrowserSearchProvider** | Logged-in LinkedIn search for benchmarking, difficult campaigns, fallback, and network-context checks. Claude-in-Chrome, Codex browser tooling, or future equivalents may implement this role. It is not required for initial unattended n8n execution. |
| **ContactEnrichmentProvider** | Attempts to discover contact information for selected qualified people. Initial implementation: HarvestAPI email enrichment. Search and enrichment remain separate capabilities. |
| **ConnectionSender** | Sends the LinkedIn request behind a stable interface. Initial implementation wraps the already-working PowerShell browser automation. |

## Campaign configuration

A campaign is executed through an immutable `CampaignRevision`. The revision contains the
rules used for that execution, including:

- target definition;
- KPI weights;
- `requireField` / `requireLocation`;
- qualification threshold;
- search-provider strategy;
- search budget;
- contact-enrichment policy;
- note strategy.

Material changes create a new CampaignRevision so historical evaluations and actions remain
traceable to the exact configuration that produced them.

## Search strategy

### Default unattended search

The initial unattended SearchProvider is:

`harvestapi/linkedin-profile-search`

Use Full Profile mode for discovery. The provider is an implementation choice, not part of
the domain model.

### Authenticated LinkedIn search

Logged-in LinkedIn search remains valuable because it can expose personalized search ordering
and network context that no-login providers may not reproduce. Authenticated browser search is
therefore retained as:

- a search-quality benchmark;
- a fallback for difficult campaigns;
- a high-fidelity option for selected campaigns;
- a possible future enrichment path.

It is not required for the first unattended n8n workflow.

## Incremental search

Search runs in bounded batches, not as an unlimited one-shot request.

```text
Search budget check
    ↓
Run next search batch
    ↓
Persist provider result
    ↓
Resolve Person / ExternalProfile
    ↓
Deduplicate
    ↓
Capture ProfileSnapshot
    ↓
Evaluate + score
    ↓
Update qualified count
    ↓
Record actual provider cost
    ↓
Check stop conditions
    ├── stop
    └── continue → next batch
```

The primary count limit is **unique campaign candidates**, not raw provider results.

Track separately:

- raw profiles returned;
- unique people resolved;
- campaign candidates created;
- qualified candidates.

## Search stop conditions

Stop when any configured condition becomes true:

- `max_unique_candidates` reached;
- `max_search_cost_usd` reached;
- `max_total_campaign_cost_usd` reached;
- `target_qualified_profiles` reached;
- provider exhausted results;
- campaign manually stopped.

Budget enforcement uses layered control:

1. estimate the next paid operation before execution;
2. atomically reserve the applicable campaign budget or serialize paid execution for that CampaignRevision so concurrent workers cannot spend the same remaining budget;
3. use a provider-side hard charge/run cap when supported;
4. record actual cost after execution, settle/release the reservation, and re-evaluate the remaining budget.

The requested search batch should shrink to remaining unique-candidate capacity when possible. Candidate ingestion must never create more CampaignCandidates than `max_unique_candidates`, even if the provider returns an oversized final batch.

If the evaluation budget is exhausted, paid search must not continue merely to accumulate profiles that cannot be qualified. If only email-enrichment limits are exhausted, email enrichment stops while otherwise-qualified LinkedIn connection flow may continue.

## Campaign cost

Campaign variable cost includes attributable paid execution such as:

- search pages / search execution;
- full-profile retrieval;
- KPI LLM evaluation;
- email enrichment;
- connection-note generation;
- other paid provider operations used by the campaign.

Fixed shared infrastructure subscriptions are not counted as campaign variable cost.

## Candidate ingestion and identity resolution

Provider output must pass through the internal identity model before becoming campaign state.

```text
Raw candidate
    ↓
Normalize LinkedIn identity
    ↓
Resolve or create ExternalProfile
    ↓
Resolve or create Person
    ↓
Create ProfileSnapshot
    ↓
Resolve or create CampaignCandidate
```

Prefer stable platform IDs, then canonical profile URLs. Do not automatically merge people by
name alone.

A `CampaignCandidate` represents `Campaign × Person` and owns qualification state only.

Candidate states:

```text
DISCOVERED
SNAPSHOT_READY
EVALUATED
QUALIFIED
DISQUALIFIED
SKIPPED
MANUAL_REVIEW
```

Sending/relationship states do not belong on CampaignCandidate.

CampaignCandidate keeps an explicit governing/current Evaluation reference. When a new valid Evaluation becomes authoritative, the pointer and qualification state update consistently so older asynchronous evaluations cannot overwrite newer state.

## KPI evaluation

For each candidate snapshot:

1. n8n sends profile evidence plus the active CampaignRevision context to the LLM evaluator.
2. The LLM returns six KPI scores/reasons in structured form. In V1 only KPI 5 may be `null` under the framework's missing-data rule. Missing evidence for KPI 1, 2, 3, 4, or 6 makes the Evaluation incomplete/manual-review rather than triggering invented scores or generic reweighting.
3. Rust validates the result, applies missing-KPI weight normalization, applies hard filters,
   calculates the composite score, and applies the qualification threshold.
4. Supabase stores a historical Evaluation record.

The LLM never performs weighted-sum math.

Evaluation provenance includes:

- CampaignRevision;
- ProfileSnapshot;
- prompt version;
- rubric version;
- model provider/name;
- evaluation version;
- scoring-engine version;
- effective weights;
- filter results;
- qualification threshold.

## Score freshness

The current KPI framework trusts a score for 30 days by default. Before reusing an older
score for new outreach, re-evaluate according to the freshness policy in KPI-FRAMEWORK.md.

## Optional contact enrichment

Search and email discovery are separate capabilities.

A qualified candidate may be sent to a `ContactEnrichmentProvider` when the active
CampaignRevision enables enrichment.

Initial provider: HarvestAPI.

Policy may define:

- `email_enrichment_enabled`;
- `minimum_score_for_email_enrichment`;
- `max_email_enrichments`;
- `max_email_enrichment_cost_usd`.

A Person may have multiple `ContactPoint` records. Each contact point preserves source,
verification state, timestamps, and provider metadata.

**Missing email is a valid result and does not block the LinkedIn connection flow.**

## Connection-note drafting

For a qualified candidate, the LLM drafts a short personalized note using:

- campaign objective;
- relevant profile evidence;
- KPI reasons / actual reason the candidate matched.

The note is persisted as a durable ConnectionNote before any send attempt, with references to the Connection, CampaignCandidate, CampaignRevision, and exact Evaluation that authorized outreach.

## Connection state ownership

`Connection` represents the long-lived `Operator × Person` relationship and owns outreach
state.

Request states may include:

```text
NOT_PLANNED
NOTE_READY
QUEUED
SEND_ATTEMPTED
SENT
FAILED
UNKNOWN_SEND_RESULT
ALREADY_CONNECTED
MANUAL_REVIEW
```

Longer-term observable relationship states may be added later, such as `CONNECTED` or
`ENGAGED`.

`ConnectionAttempt` represents one external send attempt and references the CampaignCandidate, CampaignRevision, exact authorizing Evaluation, and exact ConnectionNote used for the action. This preserves the complete campaign/decision attribution chain.

## Safe sending

The initial ConnectionSender wraps the existing PowerShell implementation.

Operational pacing remains conservative and configurable, with campaign/operator limits and
an allowed daytime window. The system should respect platform restrictions rather than use
behavior intended to evade platform detection.

Duplicate-sensitive sends require:

- idempotency key;
- attempt record;
- atomic queue/claim state transition;
- persisted result;
- explicit handling of ambiguous outcomes.

If the external action may have succeeded but the local result is unknown, mark
`UNKNOWN_SEND_RESULT`. Do not blindly resend. Reconcile the external state or require human
review.

## Observability

A campaign execution receives a shared `trace_id` propagated through major artifacts such as:

- WorkflowRun;
- SearchRun;
- Evaluation;
- ContactEnrichmentAttempt;
- ConnectionAttempt;
- ProviderUsage.

The system must be able to answer:

- which campaign revision ran;
- which provider was used;
- how many raw/unique/qualified candidates were produced;
- what each paid operation cost;
- which step failed or retried;
- which evaluation justified a connection attempt.

## End-to-end flow

```text
Campaign + CampaignRevision
    ↓
Budget check
    ↓
Search batch
    ↓
Identity resolution + deduplication
    ↓
ProfileSnapshot
    ↓
LLM KPI evaluation
    ↓
Rust scoring / filters / qualification
    ↓
Optional email enrichment
    ↓
Personalized connection note
    ↓
Connection queue
    ↓
Safe ConnectionSender
    ↓
Persist result + provider cost + trace
    ↓
Re-check campaign stop conditions
```

## Verification

Connection Automation is operational only after a real campaign demonstrates:

- bounded incremental search;
- unique-candidate limiting;
- real cost limiting;
- identity resolution;
- historical snapshots;
- KPI evaluation and deterministic scoring;
- qualification;
- optional/non-blocking email enrichment;
- connection-note generation;
- duplicate-safe sending;
- ambiguous-result handling;
- durable final state;
- campaign attribution;
- end-to-end traceability.
