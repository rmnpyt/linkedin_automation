# LinkedIn Automation System — System Plan

> **Status:** canonical planning document  
> **Scope:** system foundation, Network Acquisition (Stream 1), Network Nurturing (Stream 2)  
> **Current stage:** pre-implementation

## 1. Purpose

This document defines the system being built, its boundaries, core domain model, reliability
principles, cost controls, and implementation order. It is both a system-design plan and a build
roadmap.

A future engineer or implementation agent should be able to read it and understand:

- the product objective;
- what is in and out of scope;
- the core entities and state ownership;
- where durable data lives;
- which work belongs to deterministic code versus AI;
- how external providers are isolated;
- how costs, retries, side effects, and observability work;
- what must be built first.

## 2. Documentation authority

1. **MINDSET.md** — highest-level project purpose, scope boundaries, technology roles, and
   cross-cutting principles.
2. **PLAN.md** — canonical system architecture and implementation order.
3. **Subsystem specs** — `KPI-FRAMEWORK.md`, `CONNECTION-FLOW.md`, `CONTENT-FLOW.md` define
   detailed behavior for their domains.
4. **RESEARCH-NOTES.md** — research history and experiments, not final architecture truth.

Newer canonical decisions take precedence over older unresolved wording in lower-level specs.

## 3. System mission

The project is not fundamentally a LinkedIn automation tool. LinkedIn is the first operating
channel.

The real objective is to build a durable professional-network system:

```text
Identify the right people
    ↓
Understand and qualify them
    ↓
Create purposeful relationships
    ↓
Remain relevant through content
    ↓
Develop the relationship
    ↓
Create useful outcomes
```

Possible outcomes include job opportunities, referrals, professional relationships, personal-brand
growth, and future customer relationships.

The network is the durable asset. A real person is modeled once; campaigns, evaluations,
relationships, and future outcomes attach to that identity.

## 4. Current scope

### Stream 1 — Network Acquisition

```text
Target
→ Discover
→ Resolve Identity
→ Capture Evidence
→ Evaluate
→ Score
→ Qualify
→ Optionally Enrich Contact Data
→ Connect
→ Preserve Relationship State
```

### Stream 2 — Network Nurturing

```text
Understand Operator
→ Build Story / POV
→ Generate Content
→ Generate Supporting Assets
→ AI Review
→ Human Approval
→ Publish
→ Preserve History
→ Observe Performance Later
```

## 5. Explicitly deferred

Not currently included:

- Customer Automation / Stream 3;
- cold-email conversion flows;
- public SaaS functionality;
- billing/subscriptions;
- multi-tenant authentication and administration;
- public onboarding.

The architecture should preserve extension points without partially building these systems now.

## 6. Operating model

The first real users are the founding team. Operators may have different goals, including job
search and personal-brand growth. The system must not hardcode a single persona or assume every
operator is a job seeker.

## 7. Technology boundaries

- **Rust** — reusable deterministic business logic, CLI tools, MCP tools, stable interfaces.
- **Supabase** — canonical durable business state and history.
- **n8n** — orchestration, scheduling, retries, branching, webhooks, provider coordination.
- **PowerShell** — Windows/browser automation where an existing working integration justifies it.
- **LLMs / agents** — semantic judgment, extraction, generation, qualitative review.
- **Apify / HarvestAPI** — initial unattended external provider for LinkedIn discovery and contact
  enrichment, behind replaceable interfaces.
- **Authenticated browser agents** — logged-in LinkedIn benchmark/fallback/high-fidelity providers,
  not required for the initial unattended n8n path.
- **Python** — small workflow-local scripting inside n8n; reusable business logic graduates to Rust.

## 8. Core architectural principles

### Supabase owns durable business state

Important state must not exist only in LinkedIn, browser sessions, n8n history, PowerShell process
memory, LLM context, or repository files.

The repository stores source code, migrations, prompt versions, workflow exports, docs, config
templates, and optional human-readable exports. It is not the runtime source of truth.

### n8n orchestrates

n8n coordinates components but does not become the business-logic layer.

### AI judgment and deterministic logic are separate

AI performs semantic interpretation and generation. Deterministic code performs arithmetic,
budget decisions, thresholds, filters, state validation, and idempotency policy.

### Providers are replaceable

Provider-specific response formats and vendor concepts must not become the domain model.

### Side effects are protected

Connection sending and content publishing require idempotency, attempt history, atomic work claims,
and explicit ambiguous-result handling.

### AI decisions are traceable

Important AI outputs preserve input evidence, model/provider, prompt/rubric version, decision
version, and timestamp.

### Execution is observable

Major workflow artifacts participate in a common end-to-end trace and cost model.

## 9. Core domain model

```text
Operator
Person
ExternalProfile
ProfileSnapshot

Campaign
CampaignRevision
CampaignCandidate
Evaluation

ContactPoint
ContactEnrichmentAttempt

Connection
ConnectionNote
ConnectionAttempt

StoryProfile
ContentDraft
ContentAsset
ContentReview
ContentPublication

WorkflowRun
WorkflowStepRun
ProviderUsage
```

## 10. Identity domain

### Operator

Represents a person operating the system and owns campaigns/content context.

### Person

Represents a real-world person independently from any campaign or platform.

### ExternalProfile

Represents a person's identity on an external platform, initially LinkedIn. Identity resolution
prefers stable platform identifiers, then canonical URLs. Name-only automatic merging is not
allowed.

### ProfileSnapshot

Represents what the system knew about an ExternalProfile at a point in time. Evaluations reference
the exact snapshot used so historical decisions remain explainable even after profiles change.

## 11. Campaign domain

### Campaign

Represents a long-lived acquisition objective.

### CampaignRevision

Represents an immutable version of execution configuration. Create a new revision when a material
rule changes, including:

- target definition;
- KPI weights;
- hard filters;
- qualification threshold;
- search/provider policy;
- budget policy;
- contact-enrichment policy;
- connection-note strategy.

Historical SearchRuns, Evaluations, enrichment attempts, and ConnectionAttempts reference the exact
revision they used.

A CampaignRevision freezes before execution begins using it; an active execution must never observe material configuration changes mid-run.

### CampaignCandidate

Represents `Campaign × Person` and owns discovery/qualification state only.

Canonical states:

```text
DISCOVERED
SNAPSHOT_READY
EVALUATED
QUALIFIED
DISQUALIFIED
SKIPPED
MANUAL_REVIEW
```

It does not own sending or relationship state.

The candidate keeps an explicit pointer to the Evaluation that currently governs its qualification state. Re-evaluation under a newer snapshot/revision atomically updates this governing decision so an older asynchronous result cannot overwrite newer state.

## 12. Evaluation and KPI architecture

The existing six KPIs and semantics remain authoritative.

Flow:

```text
ProfileSnapshot
    ↓
LLM KPI Judgment
    ↓
Structured KPI Result
    ↓
Rust Scoring Engine
    ↓
Missing-KPI Weight Normalization
    ↓
Hard Filters
    ↓
Composite Score
    ↓
Qualification
```

Evaluation stores:

- CampaignCandidate;
- CampaignRevision;
- ProfileSnapshot;
- six KPI scores/reasons;
- effective weights;
- hard-filter results;
- composite score;
- qualification result and threshold;
- model/provider;
- prompt version;
- rubric version;
- evaluation/output-contract version;
- deterministic scoring-engine version;
- timestamp.

Evaluations are historical records and normally append rather than overwrite.

In V1 only KPI 5 may be missing and reweighted. Missing evidence for KPI 1, 2, 3, 4, or 6 produces an incomplete/manual-review path rather than an invented score. The deterministic scorer also enforces KPI 6's seniority floor, caps effective KPI values at 100, preserves deterministic adjustments, and compares qualification thresholds using the authoritative non-display-rounded score.

## 13. Search architecture

LinkedIn discovery is provider-based.

### Initial unattended provider

Use `harvestapi/linkedin-profile-search` through Apify in Full Profile mode as the first unattended
SearchProvider implementation.

### Authenticated browser search

Logged-in LinkedIn search remains a separate provider capability for:

- search-quality benchmarking;
- difficult/high-value campaigns;
- fallback;
- network-context checks;
- future enrichment.

Possible implementations include Claude-in-Chrome, Codex browser tooling, or future equivalents.
It is not required for the initial unattended n8n path.

### Provider comparison objective

The comparison is not winner-takes-all. Measure where unattended search is good enough and where
authenticated search provides enough extra value to justify its cost/operational complexity.

Measure at least:

- qualified-profile rate;
- profiles scoring 80+;
- profile completeness;
- network-context availability;
- cost per qualified profile;
- result overlap;
- latency/failure rate;
- automation complexity.

## 14. Incremental search and search budget

Search runs in bounded batches:

```text
Budget check
→ Search batch
→ Persist provider result
→ Resolve identity / deduplicate
→ ProfileSnapshot
→ Evaluate / score
→ Update qualified count
→ Record actual cost
→ Stop check
→ Continue if allowed
```

The primary count limit is `max_unique_candidates`, not raw provider rows.

Track separately:

- raw profiles returned;
- unique people resolved;
- campaign candidates created;
- qualified candidates.

Stop search when any configured terminal condition is reached:

- `max_unique_candidates`;
- `max_search_cost_usd`;
- `max_total_campaign_cost_usd`;
- `target_qualified_profiles`;
- provider exhaustion;
- manual stop.

Budget enforcement uses three layers where possible:

1. estimate the next batch cost;
2. apply a provider-side hard cap when supported;
3. record actual cost and re-evaluate remaining budget.

Hard budgets must also be concurrency-safe. Paid operations reserve budget atomically or execute under an equivalent campaign/revision serialization lock before provider execution, then settle against actual cost. Search ingestion must never create candidates beyond `max_unique_candidates`, even if a provider returns an oversized batch. Evaluation-budget exhaustion pauses/stops further paid discovery that cannot be qualified; email-enrichment count/cost exhaustion stops enrichment only, because email remains non-blocking for LinkedIn outreach in V1.

## 15. Campaign cost semantics

`max_total_campaign_cost_usd` covers variable external execution cost attributable to the campaign,
including:

- search;
- full-profile retrieval;
- KPI LLM evaluation;
- contact enrichment;
- connection-note generation;
- other paid provider operations for the campaign.

Fixed shared infrastructure subscriptions and developer time are excluded.

## 16. Contact enrichment

Search and contact enrichment are separate provider capabilities.

### ContactPoint

Represents contact information attached to a Person. Initial type: `email`. A Person may have
multiple contact points. Preserve source provider, verification state, discovery/verification
timestamps, and metadata.

### Initial provider

Use HarvestAPI as the first ContactEnrichmentProvider implementation for selected qualified
profiles.

### Policy

CampaignRevision may define:

- `email_enrichment_enabled`;
- `minimum_score_for_email_enrichment`;
- `max_email_enrichments`;
- `max_email_enrichment_cost_usd`.

**Email enrichment is optional and non-blocking.** No email found is a valid result and does not
prevent LinkedIn connection sending in V1.

## 17. Connection domain

### Connection

Represents the long-lived `Operator × Person` relationship and owns outreach/relationship state.

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

Longer-term observable states such as `CONNECTED` or `ENGAGED` may be added later.

### ConnectionNote

Represents the exact persisted note that will be used for outreach. It references the Connection, CampaignCandidate, CampaignRevision, and the exact Evaluation that authorized the outreach, together with note text and generation provenance. Historical notes are preserved when evaluation/context changes.

### ConnectionAttempt

Represents one external send attempt and references:

- Connection;
- CampaignCandidate;
- CampaignRevision;
- exact Evaluation;
- exact ConnectionNote;
- idempotency key;
- trace ID;
- result/error metadata.

This preserves attribution from the relationship action back to the campaign/evaluation context.

Unknown external results are not blindly retried.

## 18. Content domain

### StoryProfile

A versioned structured representation of an operator's positioning derived from LinkedIn profile,
CV, and optional written story.

### ContentDraft

Represents generated text before publication.

Initial types:

- comment;
- post;
- post with image.

### ContentAsset

Represents non-text media attached to a draft. Initial asset type: image.

Media generation sits behind a replaceable `MediaGenerator` interface.

### ContentReview

Stores AI and human review decisions.

### ContentPublication

Stores the final approved version actually published. It is distinct from the original draft.

## 19. Content review and source of truth

Flow:

```text
StoryProfile
→ Text Generation
→ Optional Media Generation
→ AI Pre-filter
→ Rework if required
→ Human Final Approval
→ Publish
```

Human approval is mandatory before publication. The approval must identify the human approver and exact approved body/assets version or fingerprint; any material change invalidates the approval before publish.

Supabase is canonical for StoryProfiles, drafts, assets, reviews, approval state, final published
version, and publication metadata. The repository is not the runtime content-history database.

## 20. Provider boundaries

Conceptual provider capabilities:

```text
SearchProvider
ProfileEvaluator
ContactEnrichmentProvider
ConnectionSender
ContentGenerator
MediaGenerator
ContentReviewer
ContentPublisher
```

The Proposal defines their implementation shape. The Contract will define required behavior.

## 21. Observability and tracing

Every significant execution receives a shared `trace_id` propagated through relevant artifacts,
including:

- WorkflowRun;
- WorkflowStepRun;
- SearchRun;
- Evaluation;
- ContactEnrichmentAttempt;
- ConnectionAttempt;
- content-generation/review/publication records;
- ProviderUsage.

The system must be able to answer what ran, which campaign revision/provider was used, what it cost,
what failed/retried, which data produced a decision, and which decision justified an external action.

## 22. Failure model

Common failure categories:

```text
RETRYABLE
NON_RETRYABLE
UNKNOWN_SIDE_EFFECT
REQUIRES_HUMAN
```

Provider adapters map provider-specific errors into this taxonomy. Duplicate-sensitive operations
never use blind generic retries.

## 23. Secrets

Secrets and session material must not appear in repository source, prompt files, normal business
tables, or normal logs. Use appropriate deployment/orchestration secret mechanisms.

Personal/profile/contact data should also be minimized outside the domain records that need it: do not place full profile payloads or email addresses in routine logs, use redacted/synthetic test fixtures where practical, and provide a documented administrative deletion/anonymization path.

## 24. Feedback foundation

Do not build a premature optimization engine. Preserve enough history to later analyze:

```text
KPI score → connection outcome
content → observable audience response
```

The goal is to improve attraction/relationship quality, not optimize superficial engagement alone.

## 25. Repository structure

```text
linkedin_automation/
├── doc/
├── clitools/
├── MCP/
├── n8n/
├── powershell/
└── supabase/
    └── migrations/
```

## 26. Implementation roadmap

```text
Phase 0A — Domain Foundation
Phase 0B — Runtime Foundation

Phase 1.1 — KPI Evaluation
Phase 1.2 — Budgeted Profile Discovery
Phase 1.3 — Contact Enrichment
Phase 1.4 — Connection Note Generation
Phase 1.5 — Safe Sending
Phase 1.6 — End-to-End Acquisition

Phase 2.1 — Story Discovery
Phase 2.2 — Content Generation
Phase 2.3 — Media Generation
Phase 2.4 — AI Review + Human Approval
Phase 2.5 — Publishing
Phase 2.6 — Content History

Phase 3 — Feedback Foundation
```

## 27. Phase 0A — Domain Foundation

Implement schema and constraints for:

```text
operator
person
external_profile
profile_snapshot
campaign
campaign_revision
campaign_candidate
evaluation
contact_point
contact_enrichment_attempt
connection
connection_note
connection_attempt
workflow_run
workflow_step_run
provider_usage
```

Define state machines and provider contracts before large workflows are built.

## 28. Phase 0B — Runtime Foundation

Establish:

- Supabase development project/migrations;
- n8n connectivity;
- LLM gateway;
- Rust tool invocation path;
- secret storage strategy;
- trace/logging foundation.

## 29. Phase 1.1 — KPI Evaluation

Build versioned structured profile evaluation, Rust deterministic scoring, CampaignRevision-aware
results, provenance, and real-profile validation.

## 30. Phase 1.2 — Budgeted Profile Discovery

Build SearchProvider, HarvestApiSearchProvider, SearchRun, budget policy, incremental pagination,
identity resolution, snapshots, provider usage tracking, and authenticated-search benchmark path.

## 31. Phase 1.3 — Contact Enrichment

Build ContactPoint, ContactEnrichmentProvider, HarvestAPI implementation, enrichment attempts,
policy/budget checks, and provenance. Missing email remains valid.

## 32. Phase 1.4 — Connection Note

Generate and persist personalized notes based on campaign objective, profile evidence, and KPI
reasons. Email availability is not required.

## 33. Phase 1.5 — Safe Sending

Wrap the existing sender behind ConnectionSender. Add queueing, atomic claiming, idempotency,
attempt history, campaign attribution, and ambiguous-result reconciliation.

## 34. Phase 1.6 — End-to-End Acquisition

Validate a real campaign with:

- campaign revision;
- bounded/budgeted search;
- identity resolution;
- snapshots;
- evaluation/scoring;
- qualification;
- optional email enrichment;
- cost accounting;
- note generation;
- safe sending;
- durable state;
- end-to-end tracing.

## 35. Phase 2.1 — Story Discovery

Create versioned StoryProfiles for both current operators using the defined source inputs.

## 36. Phase 2.2 — Content Generation

Generate comments/posts using StoryProfile + relevant past content + objective.

## 37. Phase 2.3 — Media Generation

Generate optional ContentAssets behind MediaGenerator. Select the provider during implementation.

## 38. Phase 2.4 — Review and Human Approval

Implement AI review/rework plus mandatory explicit human final approval.

## 39. Phase 2.5 — Publishing

Select and implement the publishing mechanism behind ContentPublisher with idempotency and
ambiguous-result handling.

## 40. Phase 2.6 — Content History

Persist drafts, assets, AI reviews, human decisions, final body/assets, publication state, and
provider metadata in Supabase.

## 41. Phase 3 — Feedback Foundation

Make connection and content histories queryable for later outcome/performance analysis. Do not
introduce premature automated optimization.

## 42. Phase completion rule

A phase is complete only when it has been:

```text
implemented
→ integrated
→ tested
→ failure-tested
→ observed
→ verified against requirements
```

Exact autonomous execution and Definition of Done belong in CONTRACT.md.

## 43. System success state

The architecture succeeds when:

- Person is independent from Campaign;
- campaign execution config is historically versioned;
- profile evidence and AI decisions are reproducible;
- deterministic decisions are testable and versioned;
- search/enrichment are budget-bound and provider-independent;
- email enrichment is optional;
- qualification and relationship state have separate owners;
- text and media content are first-class, reviewable artifacts;
- Supabase is the runtime source of truth;
- external side effects are duplicate-safe;
- provider costs are attributable;
- execution is traceable end to end;
- future outcomes can attach to the same relationship graph.
