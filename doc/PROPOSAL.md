# LinkedIn Automation System — Implementation Proposal

> **Status:** draft for approval before Contract  
> **Depends on:** MINDSET.md, PLAN.md, KPI-FRAMEWORK.md, CONNECTION-FLOW.md, CONTENT-FLOW.md

## 1. Objective

This document translates PLAN.md into a concrete implementation shape an engineering agent can
execute. It proposes schema, component boundaries, workflow decomposition, provider interfaces,
reliability mechanisms, observability, and build order.

PLAN.md defines what system must exist. PROPOSAL.md defines how we propose to build it.
CONTRACT.md will define mandatory outcomes and completion conditions.

## 2. Agent reading order

```text
MINDSET.md
→ PLAN.md
→ PROPOSAL.md
→ relevant subsystem spec
→ CONTRACT.md
→ implementation
```

An agent may make low-level implementation decisions but must not silently change product semantics,
KPI meaning, state ownership, human approval requirements, or major technology/domain boundaries.

## 3. Runtime architecture

```text
                         Supabase
                    Durable System State
                            │
             ┌──────────────┴──────────────┐
             │                             │
             ▼                             ▼
            n8n                       Rust Tools
       Orchestration               Business Logic
             │
    ┌────────┼───────────┬──────────────┬────────────┐
    ▼        ▼           ▼              ▼            ▼
 Search    LLMs    Contact Enrichment  Sender     Publisher
Provider             Provider          Provider     Provider
```

## 4. Repository proposal

```text
linkedin_automation/
├── doc/
│   ├── MINDSET.md
│   ├── PLAN.md
│   ├── PROPOSAL.md
│   ├── CONTRACT.md
│   ├── KPI-FRAMEWORK.md
│   ├── CONNECTION-FLOW.md
│   ├── CONTENT-FLOW.md
│   ├── RESEARCH-NOTES.md
│   └── prompts/
├── clitools/
│   ├── scoring/
│   └── campaign_policy/
├── MCP/
├── n8n/
│   ├── connection/
│   ├── content/
│   └── shared/
├── powershell/
│   └── linkedin/
└── supabase/
    └── migrations/
```

`campaign_policy/` is optional until budget/eligibility logic is shared enough to justify a
separate Rust component.

## 5. Database model

### operator

```text
id uuid PK
display_name text
primary_goal text
status text
created_at timestamptz
updated_at timestamptz
```

Avoid a rigid goal enum until real usage justifies it.

### person

```text
id uuid PK
display_name text
created_at timestamptz
updated_at timestamptz
```

Keep platform-independent identity intentionally small.

### external_profile

```text
id uuid PK
person_id uuid FK -> person
platform text
external_id text null
canonical_url text
username text null
created_at timestamptz
updated_at timestamptz
```

Prefer `UNIQUE(platform, external_id)` when a stable ID exists. Maintain normalized canonical URL
uniqueness as appropriate. Never automatically merge by name alone.

### profile_snapshot

```text
id uuid PK
external_profile_id uuid FK
source_provider text
raw_data jsonb
normalized_data jsonb
captured_at timestamptz
source_reference text null
trace_id uuid/text
```

### campaign

```text
id uuid PK
operator_id uuid FK
name text
objective text
state text
created_at timestamptz
updated_at timestamptz
```

Campaign contains stable identity/objective, not mutable execution policy.

### campaign_revision

```text
id uuid PK
campaign_id uuid FK
version integer
target_definition jsonb
kpi_weights jsonb
require_field boolean
require_location boolean
qualification_threshold numeric
search_policy jsonb
budget_policy jsonb
contact_enrichment_policy jsonb
note_strategy jsonb
created_at timestamptz
created_by text/uuid null
```

Constraint: `UNIQUE(campaign_id, version)`.

A revision becomes immutable before the first execution step/provider call uses it. Consider explicit `frozen_at`/status plus database/application enforcement so a running workflow cannot observe mid-run configuration mutation.

### campaign_candidate

```text
id uuid PK
campaign_id uuid FK
person_id uuid FK
external_profile_id uuid FK
state text
current_evaluation_id uuid null FK -> evaluation (deferred/cycle-safe constraint as appropriate)
discovered_at timestamptz
qualified_at timestamptz null
created_at timestamptz
updated_at timestamptz
```

Constraint: `UNIQUE(campaign_id, person_id)`.

Allowed qualification-domain states:

```text
DISCOVERED
SNAPSHOT_READY
EVALUATED
QUALIFIED
DISQUALIFIED
SKIPPED
MANUAL_REVIEW
```

### evaluation

```text
id uuid PK
campaign_candidate_id uuid FK
campaign_revision_id uuid FK
profile_snapshot_id uuid FK
status text
raw_judgment jsonb
score_adjustments jsonb

kpi_1_score integer
kpi_1_reason text
kpi_2_score integer
kpi_2_reason text
kpi_3_score integer
kpi_3_reason text
kpi_4_score integer
kpi_4_reason text
kpi_5_score integer null
kpi_5_reason text null
kpi_6_score integer
kpi_6_reason text

effective_weights jsonb
filter_results jsonb
composite_score numeric
hard_filter_passed boolean
qualified boolean
qualification_threshold numeric

model_provider text
model_name text
prompt_version text
rubric_version text
evaluation_version text
scoring_engine_version text
trace_id uuid/text
created_at timestamptz
```

Add CHECK constraints for all non-null KPI scores to remain in 0..100.

Evaluations are append-only in normal operation.

### contact_point

```text
id uuid PK
person_id uuid FK
type text
value text
normalized_value text
source_provider text
verification_status text
confidence numeric null
discovered_at timestamptz
last_verified_at timestamptz null
metadata jsonb
created_at timestamptz
updated_at timestamptz
```

Constraint: `UNIQUE(person_id, type, normalized_value)`.

Initial type: `email`. Multiple emails per person are allowed.

Suggested verification states:

```text
UNVERIFIED
PROVIDER_VERIFIED
VERIFIED
INVALID
STALE
```

### contact_enrichment_attempt

```text
id uuid PK
campaign_id uuid FK
campaign_revision_id uuid FK
campaign_candidate_id uuid FK
person_id uuid FK
external_profile_id uuid FK
provider text
requested_contact_type text
state text
contacts_found integer
estimated_cost_usd numeric null
actual_cost_usd numeric
trace_id uuid/text
started_at timestamptz
completed_at timestamptz null
error_code text null
error_message text null
metadata jsonb
```

States:

```text
QUEUED
RUNNING
COMPLETED
NO_RESULT
FAILED
BUDGET_BLOCKED
```

### connection

```text
id uuid PK
operator_id uuid FK
person_id uuid FK
external_profile_id uuid FK
request_state text
relationship_state text
note_sent text null
requested_at timestamptz null
connected_at timestamptz null
created_at timestamptz
updated_at timestamptz
```

Enforce one logical operator/person/platform relationship.

Request states:

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

### connection_note

```text
id uuid PK
connection_id uuid FK
campaign_candidate_id uuid FK
campaign_revision_id uuid FK
evaluation_id uuid FK
body text
model_provider text null
model_name text null
prompt_version text null
trace_id uuid/text
created_at timestamptz
superseded_at timestamptz null
```

A note is immutable once referenced by a send attempt. A materially different note or a newly authoritative Evaluation creates a new note record/version.

### connection_attempt

```text
id uuid PK
connection_id uuid FK
campaign_candidate_id uuid FK
campaign_revision_id uuid FK
evaluation_id uuid FK
connection_note_id uuid FK
idempotency_key text
attempt_number integer
state text
trace_id uuid/text
started_at timestamptz
finished_at timestamptz null
result_metadata jsonb null
error_code text null
error_message text null
```

This record preserves campaign attribution for a long-lived Connection.

### story_profile

```text
id uuid PK
operator_id uuid FK
source_snapshot jsonb
story jsonb
model_provider text
model_name text
prompt_version text
trace_id uuid/text null
created_at timestamptz
superseded_at timestamptz null
```

Suggested structured story fields include positioning, professional identity, core themes,
experience signals, beliefs, audience, voice, and content angles.

### content_draft

```text
id uuid PK
operator_id uuid FK
story_profile_id uuid FK
content_type text
objective text null
draft_body text
generation_context jsonb
state text
model_provider text
model_name text
prompt_version text
trace_id uuid/text
created_at timestamptz
updated_at timestamptz
```

Initial types: `comment`, `post`, `post_with_image`.

### content_asset

```text
id uuid PK
content_draft_id uuid FK
asset_type text
storage_reference text
content_checksum text null
state text
generation_provider text
model_name text null
prompt_version text null
generation_metadata jsonb
trace_id uuid/text
created_at timestamptz
updated_at timestamptz
```

Initial asset type: `image`.

### content_review

```text
id uuid PK
content_draft_id uuid FK
review_type text
result text
reasons jsonb
reviewer_id text/uuid null
content_fingerprint text null
approved_at timestamptz null
model_provider text null
model_name text null
prompt_version text null
trace_id uuid/text
reviewed_at timestamptz
```

Review types: `AI`, `HUMAN`.

### content_publication

```text
id uuid PK
content_draft_id uuid FK
operator_id uuid FK
final_body text
state text
publisher_provider text
approval_review_id uuid null FK -> content_review
content_fingerprint text
external_post_id text null
external_url text null
trace_id uuid/text
published_at timestamptz null
created_at timestamptz
```

Published assets are linked separately so the final approved text/media can differ from the
original draft.

### workflow_run

```text
id uuid PK
trace_id uuid/text
workflow_type text
entity_type text
entity_id uuid null
state text
started_at timestamptz
finished_at timestamptz null
error_code text null
error_message text null
metadata jsonb
```

### workflow_step_run

```text
id uuid PK
workflow_run_id uuid FK
trace_id uuid/text
step_name text
attempt_number integer
state text
provider text null
started_at timestamptz
finished_at timestamptz null
latency_ms integer null
cost_usd numeric null
error_code text null
error_message text null
metadata jsonb
```

### provider_usage

```text
id uuid PK
campaign_id uuid null
campaign_revision_id uuid null
trace_id uuid/text
provider text
operation_type text
quantity numeric null
unit text null
cost_usd numeric
metadata jsonb
created_at timestamptz
```

## 6. Rust scoring component

Initial durable Rust tool: `clitools/scoring/`.

Responsibilities:

- validate KPI values and weights;
- allow missing/reweighting only for KPI 5 in V1;
- mark other missing KPI evidence incomplete rather than inventing a score;
- enforce KPI 6 seniority floor and 0..100 effective bounds;
- preserve raw-to-effective deterministic adjustments;
- apply missing-KPI normalization;
- apply hard filters;
- calculate composite score;
- apply qualification threshold;
- return effective weights and detailed deterministic outcomes.

No LLM calls belong inside it.

Conceptual input:

```json
{
  "weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10},
  "scores": {"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":null,"kpi6":70},
  "requireField": true,
  "requireLocation": true,
  "qualificationThreshold": 60
}
```

Output includes validation, effective weights, filter results, composite score, and qualification.

## 7. Campaign policy / budget engine

Prefer deterministic reusable policy logic. If shared enough, implement in Rust under
`clitools/campaign_policy/`.

Conceptual interface:

```text
CampaignPolicy.evaluate(CurrentCampaignState)
→ PolicyDecision
```

Responsibilities may include:

- whether another search batch may run;
- whether email enrichment is allowed;
- budget stop reasons;
- target-qualified stopping.

Structured search stop reasons:

```text
STOP_MAX_UNIQUE_CANDIDATES
STOP_SEARCH_COST_LIMIT
STOP_TOTAL_CAMPAIGN_COST_LIMIT
STOP_QUALIFIED_TARGET_REACHED
STOP_PROVIDER_EXHAUSTED
STOP_MANUAL
```

## 8. Budget policy shape

Example only:

```json
{
  "max_unique_candidates": 1000,
  "max_search_cost_usd": 10,
  "target_qualified_profiles": 100,
  "max_evaluation_cost_usd": 5,
  "max_email_enrichment_cost_usd": 3,
  "max_email_enrichments": 200,
  "max_total_campaign_cost_usd": 20
}
```

No example value becomes a global default unless explicitly approved later.

Before each paid batch/action:

1. calculate remaining limits;
2. estimate next cost;
3. shrink or stop if unsafe;
4. set provider-side hard cap when supported;
5. execute;
6. record actual cost;
7. re-evaluate.

For hard budgets, add a database-backed reservation/settlement mechanism or serialize paid operations per CampaignRevision. A provider hard cap alone is not sufficient against two workers spending the same remaining budget. The campaign runner/search provider must also respect remaining unique-candidate capacity so oversized batches cannot create more than `max_unique_candidates`.

## 8.1 Budget reservation / serialization

Hard campaign budgets require concurrency-safe execution. Preferred implementation: a `campaign_budget_reservation` record (or equivalent transactional lock strategy) created before paid operations and settled afterward. A reservation may contain campaign/revision, operation type, reserved amount/count, state, trace, timestamps, and actual settled cost.

If a reservation table is not used, paid campaign operations must be serialized with a database-backed mechanism that provides equivalent hard-budget guarantees.

## 9. SearchRun

Every incremental provider call creates a SearchRun recording provider, revision, raw/unique/new
candidate counts, estimated/actual cost, cursor/pagination state, exhaustion state, trace, timing,
and errors.

## 10. SearchProvider interface

```text
SearchProvider.search(SearchRequest)
→ SearchBatchResult
```

Conceptual request:

```json
{
  "campaign_revision_id": "...",
  "target_definition": {},
  "cursor": null,
  "batch_limit": 100,
  "provider_cost_cap_usd": 1.50
}
```

Conceptual result:

```json
{
  "provider": "harvestapi",
  "provider_run_id": "...",
  "candidates": [],
  "next_cursor": null,
  "provider_exhausted": false,
  "actual_cost_usd": 0.82,
  "metadata": {}
}
```

Provider-specific data stays inside adapter/metadata unless the domain genuinely needs it.

## 11. Search implementations

### HarvestApiSearchProvider

Initial unattended implementation backed by `harvestapi/linkedin-profile-search`, using Full Profile
mode. Pricing is observed/configured externally, never hardcoded into business rules.

### AuthenticatedBrowserSearchProvider

Conceptual interface for logged-in LinkedIn search. Possible implementations include Claude browser,
Codex browser, or future agents.

Initial role: benchmark, fallback, difficult/high-value campaigns, and network-context comparison.
It is not required for unattended V1.

## 12. Search-quality experiment

Persist provider experiments rather than relying on memory.

Suggested metrics:

- raw results;
- unique profiles;
- profiles scoring 60+;
- profiles scoring 80+;
- profile completeness;
- network-context availability;
- result overlap;
- actual provider/agent cost;
- runtime;
- failure count;
- operational complexity notes.

The decision question is where each provider is economically/operationally justified, not which
provider must permanently eliminate the other.

## 13. Candidate ingestion

```text
Raw Provider Candidate
→ normalize platform identity
→ resolve ExternalProfile
→ resolve/create Person
→ create ProfileSnapshot
→ resolve/create CampaignCandidate
```

Provider output never writes campaign state directly without normalization/identity resolution.

## 14. ProfileEvaluator interface

```text
ProfileEvaluator.evaluate(CampaignRevision, ProfileSnapshot)
→ StructuredKPIJudgment
```

The evaluator returns six KPI judgments and reasons only. It does not calculate the final composite.

All important LLM calls use structured output, timeout/error classification, prompt versioning,
input/output validation, model/provider metadata, and trace propagation.

## 15. Prompt storage

Store prompts as versioned repository artifacts, for example:

```text
doc/prompts/
├── profile-evaluator/v1.md
├── connection-note/v1.md
├── story-discovery/v1.md
├── content-generator/v1.md
├── content-reviewer/v1.md
└── media-generator/v1.md
```

Material prompt changes create new versions.

## 16. ContactEnrichmentProvider interface

```text
ContactEnrichmentProvider.enrich(request)
→ ContactEnrichmentResult
```

Conceptual request:

```json
{
  "person_id": "...",
  "external_profile_url": "...",
  "requested_contact_types": ["email"]
}
```

Result:

```json
{
  "provider": "harvestapi",
  "contacts": [],
  "actual_cost_usd": 0.01,
  "metadata": {}
}
```

An empty contacts array is a successful/valid no-result, not necessarily an error.

Initial implementation: HarvestAPI email enrichment for selected qualified profiles.

## 17. Enrichment eligibility

Run email enrichment only when all are true:

- enabled in CampaignRevision;
- candidate is qualified;
- score meets `minimum_score_for_email_enrichment`;
- enrichment-attempt limit remains;
- enrichment budget remains;
- total campaign budget remains.

No email found does not block LinkedIn note/sending.

## 18. Connection-note generation

Inputs:

- CampaignRevision objective/context;
- ProfileSnapshot;
- Evaluation KPI reasons.

Output: a durable ConnectionNote record containing the short personalized note and references to the Connection, CampaignCandidate, CampaignRevision, and exact authorizing Evaluation. Persist it before creating a send attempt.

## 19. ConnectionSender interface

```text
ConnectionSender.send(request)
→ SendResult
```

Possible normalized results:

```text
SENT
FAILED
ALREADY_CONNECTED
UNKNOWN
```

Initial implementation wraps the existing PowerShell browser automation.

`UNKNOWN` enters reconciliation and is never blindly resent.

## 20. Idempotency and concurrency

Use idempotency keys for duplicate-sensitive side effects.

Example connection key concept:

```text
operator + person + request_generation
```

Example content publish key:

```text
content_publication_id
```

Use atomic database state transitions to claim work rather than read-then-update races.

Example pattern:

```sql
UPDATE connection
SET request_state = 'QUEUED'
WHERE id = $1
  AND request_state = 'NOTE_READY'
RETURNING id;
```

## 21. Connection workflow decomposition

```text
n8n/connection/
01_campaign_runner
02_search_budget_check
03_candidate_search
04_candidate_ingestion
05_profile_evaluation
06_contact_enrichment
07_connection_note
08_send_queue
09_connection_sender
10_connection_reconciliation
```

### Campaign runner

- load exact CampaignRevision;
- create/propagate trace;
- check budget/stop conditions;
- run bounded search loop;
- coordinate ingestion/evaluation;
- count qualified candidates;
- trigger permitted enrichment;
- record usage/cost;
- stop cleanly at policy terminal conditions.

### Search budget check

Pure deterministic policy call; no LLM.

### Candidate search

Invoke configured SearchProvider, persist SearchRun and provider usage.

### Candidate ingestion

Normalize, resolve identity, snapshot, create/resolve CampaignCandidate.

### Profile evaluation

Call evaluator, validate structured output, call Rust scorer, persist Evaluation, transition candidate.

### Contact enrichment

Apply policy/budget, call provider, persist attempts/contact points/usage. No scoring logic.

### Connection note

Generate/persist note for qualified candidates.

### Send queue

Check relationship state and limits, verify the current governing Evaluation/note, atomically claim work, and create ConnectionAttempt referencing the exact Evaluation and ConnectionNote.

### Sender

Call PowerShell-backed ConnectionSender and normalize result.

### Reconciliation

Resolve `UNKNOWN_SEND_RESULT` safely through external-state verification where possible or human
review. No blind resend.

## 22. Story Discovery

Inputs: LinkedIn profile, CV, optional written story.

Output: versioned structured StoryProfile.

Suggested structure:

```json
{
  "positioning": "...",
  "professional_identity": "...",
  "core_themes": [],
  "experience_signals": [],
  "beliefs": [],
  "audience": [],
  "voice": {"tone": "...", "avoid": []},
  "content_angles": []
}
```

Test on both current operators.

## 23. Content generation

```text
StoryProfile
+
Relevant Past Content
+
Objective
→ ContentDraft
```

Past content should reduce repetition and preserve voice consistency.

## 24. MediaGenerator interface

```text
MediaGenerator.generate(request)
→ ContentAssetResult
```

Media provider remains open. Initial asset type is image. Text generation and media generation are
separate capabilities so either can change independently.

## 25. Content review

AI pre-filter evaluates clarity, central idea, StoryProfile fit, repetition, specificity, generic
language, and audience value.

Human final approval is a hard gate. AI review never sets human approval state. AI review output should be structured and preserve reviewer model/prompt provenance. Human approval records `reviewer_id`, `approved_at`, and an exact deterministic fingerprint of the approved body plus ordered asset identities/checksums. The publish step verifies the fingerprint immediately before execution.

## 26. ContentPublisher interface

```text
ContentPublisher.publish(request)
→ PublishResult
```

Normalized results include published, failed, and unknown. Exact provider is selected only during
the publishing phase. Unknown external result must not be blindly republished.

## 27. Content workflow decomposition

```text
n8n/content/
01_story_discovery
02_content_generation
03_media_generation
04_ai_review
05_human_approval
06_publish_queue
07_publish
08_publish_reconciliation
```

Supabase stores canonical draft/asset/review/approval/publication history.

## 28. Observability

Every major execution artifact receives the same `trace_id`.

At minimum, support durable `workflow_run`, `workflow_step_run`, and `provider_usage` records.

The system should answer:

- which campaign/revision ran;
- which provider/model/actor was used;
- how many raw/unique/qualified candidates resulted;
- which data and configuration produced an evaluation;
- which evaluation/candidate/note caused a connection attempt;
- which paid operations consumed budget;
- how long major stages took;
- what failed/retried/escalated.

## 29. Provider usage / campaign cost ledger

ProviderUsage is the source for actual attributable external cost.

Operation types may include:

```text
profile_search
full_profile
kpi_evaluation
email_enrichment
connection_note_generation
content_generation
media_generation
content_review
content_publish
```

Connection campaign total cost includes only campaign-attributable variable external operations.
Content operations are accounted independently unless deliberately linked to a campaign later.

## 30. Failure taxonomy

All adapters map errors into:

```text
RETRYABLE
NON_RETRYABLE
UNKNOWN_SIDE_EFFECT
REQUIRES_HUMAN
```

Retry policy belongs primarily in orchestration, but only operations declared safe to retry may use
automatic retry.

## 31. Secrets

Keep Supabase/OpenRouter/Apify credentials, LinkedIn session material, publishing credentials, and
webhook secrets outside source, prompts, business tables, and normal logs. Repository contains only
environment variable names/templates and documentation.

## 32. Database migrations and constraints

All schema changes go through `supabase/migrations/` and must reproduce cleanly from an empty
development database.

Use PostgreSQL constraints for deterministic integrity wherever practical:

- foreign keys;
- uniqueness;
- KPI range checks;
- required fields;
- valid state/check constraints where maintainable.

## 33. Historical retention

Preserve history for ProfileSnapshot, Evaluation, ContactEnrichmentAttempt, ConnectionNote, ConnectionAttempt,
ContentReview, ContentPublication, WorkflowRun, and ProviderUsage. Mutable current-state records may
point to latest state without destroying historical evidence.

## 34. Testing strategy

### Rust unit tests

Test exact deterministic behavior for:

- weighted scoring;
- KPI-5-only missing/reweighting behavior;
- incomplete handling for missing KPI 1/2/3/4/6 evidence;
- KPI 6 seniority floor and 0..100 effective bounds;
- hard filters;
- fixed-precision threshold qualification;
- budget policy;
- stop conditions;
- validation.

### Database tests

Test:

- foreign keys;
- uniqueness;
- candidate duplication prevention;
- contact duplication prevention;
- CampaignRevision freeze-before-execution policy;
- CampaignCandidate current Evaluation consistency;
- state constraints;
- migration reproducibility.

### Provider contract tests

Provider adapters must normalize into the declared interfaces independent of vendor-specific fields.

### Workflow integration tests

Cover at minimum:

- incremental search;
- search budget exhaustion;
- concurrent paid-operation budget protection;
- oversized final batch cannot exceed unique-candidate cap;
- evaluation-budget exhaustion;
- provider exhaustion;
- duplicate identity result;
- evaluation persistence;
- missing KPI;
- email found;
- email missing;
- enrichment budget blocked;
- ConnectionNote tied to exact governing Evaluation;
- ConnectionAttempt tied to exact Evaluation and note;
- send duplicate prevention;
- unknown send result;
- trace propagation;
- media generation;
- structured AI-review provenance;
- mandatory human approval bound to exact content/assets fingerprint;
- approval invalidation after material edit;
- publish duplicate prevention;
- unknown publish result.

### Real-world validation

Use approximately ten manually understood real profiles to validate KPI behavior before trusting it.
Run at least one real end-to-end campaign before Stream 1 is considered operational. Test Story
Discovery/content with both current operators before Stream 2 is considered operational.

## 35. Implementation order

```text
0A — Domain model, migrations, state ownership, provider contracts
0B — Runtime foundation, secrets, Supabase/n8n/LLM/Rust integration, tracing

1.1 — KPI evaluator + Rust scorer
1.2 — SearchProvider + HarvestAPI + budget loop + identity/snapshots
1.3 — Contact enrichment + ContactPoint + budget
1.4 — Connection-note generation
1.5 — Safe ConnectionSender + reconciliation
1.6 — Real end-to-end acquisition

2.1 — Story Discovery
2.2 — Text generation
2.3 — Media generation
2.4 — AI review + human approval
2.5 — Publishing + reconciliation
2.6 — Durable content history

3 — Feedback-query foundation
```

## 36. Decisions intentionally left open

- exact PostgreSQL index set;
- exact Rust crate/module structure;
- exact n8n node arrangement;
- exact batch sizes and retry counts;
- exact structured-output library/transport;
- exact StoryProfile JSON schema details;
- final authenticated-browser implementation;
- final content MediaGenerator;
- final LinkedIn ContentPublisher;
- posting cadence;
- production Story Discovery prompt contents.

These may be resolved during build if they do not change product semantics or Contract requirements.

## 37. Risks and mitigations

### LinkedIn/platform dependency

Mitigate with provider boundaries and durable internal state. Do not encode evasion of platform
controls as an architectural goal.

### Provider/model instability

Mitigate with configuration, replaceable adapters, provenance, and usage tracking.

### AI drift

Mitigate with snapshots, prompt/rubric/model/scorer versioning and historical evaluations.

### Duplicate side effects

Mitigate with idempotency, atomic claims, attempt history, and reconciliation.

### Weak identity resolution

Mitigate with stable platform IDs/canonical URLs and no name-only auto-merge.

### n8n workflow sprawl

Mitigate with focused subflows, deterministic logic outside n8n, trace/step observability.

## 38. Proposal acceptance criteria

This Proposal is ready for CONTRACT.md when the team accepts that:

- Person is independent from Campaign;
- Campaign execution configuration is immutable/versioned through CampaignRevision;
- CampaignCandidate owns qualification only;
- Connection owns outreach/relationship state;
- ConnectionAttempt preserves campaign attribution;
- Evaluation references exact CampaignRevision and ProfileSnapshot;
- scoring stores deterministic effective weights/filter outcomes and scorer version;
- search limits unique candidates rather than raw rows;
- search performs budget pre-check + provider cap where possible + actual cost accounting;
- campaign total variable cost has explicit semantics;
- SearchProvider and ContactEnrichmentProvider are separate;
- HarvestAPI is the initial unattended search and email-enrichment implementation, not a permanent
  domain dependency;
- authenticated LinkedIn search remains a benchmark/fallback/high-fidelity provider;
- email is optional/non-blocking;
- a Person may have multiple ContactPoints;
- text and media are separate content artifacts/provider capabilities;
- human approval is mandatory before publication;
- Supabase is canonical runtime history;
- all major execution artifacts propagate trace_id;
- provider usage/cost is measurable and attributable;
- unknown side effects are never blindly retried.

## Repository reproducibility requirement

Accepted implementation is committed as reproducible repository artifacts: Supabase changes as migrations, material n8n workflows as exported/version-controlled workflow files, prompts as versioned files, and Rust code passing format/tests (plus strict clippy where practical). A workflow that exists only inside the live n8n instance is not considered fully captured.

## Personal-data handling

Routine logs and committed test fixtures should not contain unnecessary raw LinkedIn payloads, CV content, or discovered email addresses. Prefer synthetic/redacted fixtures, restrict raw profile/contact access to the components that need it, and document an administrative deletion/anonymization path for Person/ProfileSnapshot/ContactPoint data.
