# LinkedIn Automation System
## Project Contract — Streams 1 and 2

**Status:** Draft for Approval  
**Document Type:** Executable Engineering Contract  
**Scope:** System Foundation, Network Acquisition, Network Nurturing  
**Applies To:** Human engineers, coding agents, review agents, test agents, and orchestration agents  
**Depends On:** `MINDSET.md`, `PLAN.md`, `PROPOSAL.md`, `KPI-FRAMEWORK.md`, `CONNECTION-FLOW.md`, `CONTENT-FLOW.md`

---

# 1. Purpose

This Contract defines the conditions that must be true before any implementation phase may be declared complete.

The project documents have different responsibilities:

- `MINDSET.md` defines why the system exists and its cross-cutting principles.
- `PLAN.md` defines what system is being built and its architectural boundaries.
- `PROPOSAL.md` defines the proposed implementation approach.
- Subsystem specifications define detailed domain behavior.
- This Contract defines mandatory outcomes, invariants, verification rules, failure rules, and completion criteria.

An implementation that follows the Proposal but violates this Contract is not complete.

An implementation that satisfies this Contract through a justified implementation change may be acceptable if the change does not alter product semantics or architectural boundaries and is documented.

---

# 2. Normative Language

The following terms are binding:

- **MUST** — mandatory.
- **MUST NOT** — prohibited.
- **SHOULD** — expected unless a documented engineering reason justifies another approach.
- **SHOULD NOT** — discouraged unless a documented engineering reason justifies it.
- **MAY** — optional.
- **HUMAN DECISION REQUIRED** — implementation must stop at that decision boundary until an authorized human resolves it.

---

# 3. Document Authority and Conflict Resolution

The project documents do not form one universal linear precedence chain. Each document owns a different kind of authority:

- `MINDSET.md` owns product purpose, scope boundaries, and cross-cutting technology principles.
- `PLAN.md` owns canonical system architecture, domain ownership, and build sequencing.
- `CONTRACT.md` owns mandatory acceptance criteria, execution invariants, verification rules, and Definition of Done.
- `PROPOSAL.md` owns the preferred implementation shape where the higher-authority product, architecture, and Contract constraints leave implementation freedom.
- subsystem specifications own detailed domain behavior that is consistent with the approved Mindset, Plan, and Contract.
- `RESEARCH-NOTES.md` is evidence/history and does not override settled decisions.

`CONTRACT.md` MUST NOT redefine product meaning or architecture merely because it is more enforceable. `MINDSET.md` or `PLAN.md` MUST NOT be used to bypass an explicit Contract acceptance rule.

If two documents make materially incompatible statements inside their respective authority domains, the implementation agent MUST NOT choose whichever wording is most convenient. The conflict MUST be surfaced as `HUMAN DECISION REQUIRED` and resolved in the source documents before implementation proceeds through the affected boundary.

A lower-level implementation detail MAY differ from `PROPOSAL.md` without escalation when it preserves product semantics, architecture boundaries, Contract invariants, and equivalent or stronger verification.

---

# 4. Contract Integrity

The implementation agent MUST NOT:

- modify `CONTRACT.md` merely to make implementation easier;
- weaken acceptance criteria because a test fails;
- delete or disable a valid failing test to obtain a passing suite;
- change KPI semantics without an authorized product decision;
- bypass required human approval;
- fabricate external verification results;
- mark a phase complete when mandatory live verification has not occurred;
- silently move business logic into a layer that violates the documented technology boundaries;
- replace a required durable state transition with temporary workflow memory.

If the Contract itself must change, that is a product/architecture change and requires human approval.

---

# 5. Scope

The Contract covers:

## Stream 1 — Network Acquisition

```text
Campaign
→ Budgeted Search
→ Identity Resolution
→ Profile Snapshot
→ KPI Evaluation
→ Deterministic Scoring
→ Qualification
→ Optional Contact Enrichment
→ Connection Note
→ Safe Connection Sending
→ Durable Relationship State
```

## Stream 2 — Network Nurturing

```text
Operator Source Material
→ Story / POV Discovery
→ Content Generation
→ Optional Media Generation
→ AI Review
→ Human Approval
→ Publication
→ Durable Content History
```

## Shared Foundation

The Contract also covers:

- domain identity;
- campaign revisioning;
- provider boundaries;
- cost accounting;
- state ownership;
- idempotency;
- retries;
- observability;
- secrets;
- testing;
- autonomous agent behavior.

---

# 6. Explicit Non-Goals

The implementation MUST NOT expand current scope to include:

- Customer Automation;
- cold-email campaign execution;
- public SaaS onboarding;
- billing;
- subscriptions;
- multi-tenant authentication;
- tenant administration;
- generalized CRM functionality unrelated to Streams 1 and 2.

Email discovery in Stream 1 is contact enrichment only. It MUST NOT automatically become a cold-email outreach implementation.

---

# 7. Technology Boundary Contract

The implementation MUST preserve these responsibilities:

## Supabase

Supabase MUST own durable business state and operational history.

## n8n

n8n MUST own orchestration, scheduling, branching, workflow retries, and coordination.

n8n MUST NOT become the primary home of reusable business rules when those rules belong in deterministic reusable code.

## Rust

Rust MUST be used for stable reusable deterministic business logic when that logic is shared, important to correctness, or intended as a durable interface.

The KPI scoring engine MUST be deterministic and MUST NOT depend on an LLM.

## LLMs

LLMs MAY perform semantic judgment, extraction, generation, and qualitative review.

LLMs MUST NOT be trusted to perform authoritative weighted-score arithmetic, campaign budget enforcement, idempotency decisions, or durable state validation.

## PowerShell

PowerShell MAY own the existing Windows/browser-specific LinkedIn connection action.

It MUST NOT become a general-purpose business-logic layer.

## Python

Python MAY be used for small workflow-local n8n scripting.

Reusable or business-critical deterministic Python logic SHOULD be promoted into the durable tool layer.

---

# 8. Durable State Contract

Important business state MUST NOT exist only in:

- LinkedIn;
- a browser session;
- an n8n execution;
- PowerShell memory;
- LLM context;
- local temporary files;
- repository history.

Supabase MUST remain the canonical runtime source of truth.

The repository MAY store code, migrations, prompts, workflow exports, documentation, configuration templates, and optional human-readable exports.

The repository MUST NOT be treated as the canonical runtime database for connection or content state.

---

# 9. Core Domain Entities

The implementation MUST support the following conceptual entities:

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

The physical schema MAY vary from the Proposal only when the same semantics, constraints, historical traceability, and ownership boundaries are preserved.

---

# 10. Person Identity Contract

A `Person` MUST represent a real-world individual independently from campaigns.

The same person discovered multiple times MUST NOT automatically become multiple Persons when a reliable identity match exists.

Identity resolution SHOULD prefer, in order:

1. stable platform external identifier;
2. canonicalized platform profile URL;
3. another strong deterministic provider identifier.

Display name alone MUST NOT trigger an automatic merge.

If identity cannot be resolved safely, the system MUST preserve separate records or escalate rather than merge uncertain identities.

---

# 11. External Profile Contract

An `ExternalProfile` MUST represent platform identity separately from `Person`.

The initial platform is LinkedIn.

Provider-specific raw fields MUST NOT redefine the core `Person` model.

Where reliable platform identifiers exist, uniqueness MUST be enforced.

---

# 12. Profile Snapshot Contract

Every profile evaluation MUST reference the exact `ProfileSnapshot` on which the evaluation was based.

A ProfileSnapshot MUST preserve:

- external profile reference;
- capture timestamp;
- source provider;
- normalized profile data;
- sufficient source/raw data to inspect the evidence used by the evaluator.

Historical snapshots MUST NOT be destructively overwritten merely because a newer snapshot exists.

---

# 13. Campaign Contract

A `Campaign` represents a long-lived acquisition objective.

A Campaign MUST NOT itself be used as mutable historical execution configuration after runs have started.

Material execution configuration belongs to `CampaignRevision`.

---

# 14. Campaign Revision Contract

A `CampaignRevision` MUST become immutable as soon as an execution starts using that revision, before the first provider call, external side effect, or child domain record is allowed to depend on it.

The implementation MUST enforce an explicit freeze point. A revision in use MUST NOT remain materially editable during an active or completed execution. The freeze MAY be represented by status, timestamp, database constraint/trigger, application-controlled immutable rows, or an equivalent mechanism that is testable and race-safe.

A new revision MUST be created when a material rule changes, including:

- target definition;
- KPI weights;
- qualification threshold;
- `requireField`;
- `requireLocation`;
- search policy;
- budget policy;
- contact-enrichment policy;
- connection-note strategy;
- provider strategy when that provider choice changes campaign execution semantics.

Each revision MUST have a stable version identity.

`Evaluation`, `SearchRun`, `ContactEnrichmentAttempt`, and `ConnectionAttempt` MUST be attributable to the CampaignRevision that governed them.

---

# 15. Campaign Candidate Contract

A `CampaignCandidate` represents:

```text
Campaign × Person
```

The same Person MAY participate in multiple Campaigns.

The same Person MUST NOT appear more than once as a candidate within the same Campaign unless the architecture explicitly introduces a separate candidate-instance concept in a future approved revision.

The effective uniqueness invariant is:

```text
one CampaignCandidate per Campaign + Person
```

A CampaignCandidate MUST expose an explicit reference to the Evaluation that currently governs its qualification state, such as `current_evaluation_id` or an equivalent immutable decision pointer.

When a newer valid Evaluation becomes authoritative, updating the governing Evaluation reference and candidate state MUST occur atomically or with equivalent consistency protection.

A stale or older Evaluation MUST NOT overwrite the current state merely because its workflow completes later.

---

# 16. Campaign Candidate State Ownership

`CampaignCandidate` owns discovery and qualification state only.

Canonical states are:

```text
DISCOVERED
SNAPSHOT_READY
EVALUATED
QUALIFIED
DISQUALIFIED
SKIPPED
MANUAL_REVIEW
```

Send state MUST NOT be stored as candidate truth.

Connection state MUST NOT be inferred from CampaignCandidate state.

The implementation MUST reject invalid state transitions rather than silently accepting arbitrary strings.

---

# 17. Candidate Transition Rules

At minimum, the following transitions MUST be supported:

```text
DISCOVERED
→ SNAPSHOT_READY
→ EVALUATED
→ QUALIFIED | DISQUALIFIED | MANUAL_REVIEW
```

`DISCOVERED` or `SNAPSHOT_READY` MAY transition to `SKIPPED` when the reason is persisted.

A previously evaluated candidate MAY be re-evaluated if freshness or configuration rules require it.

Re-evaluation MUST create a new Evaluation record.

Historical Evaluation records MUST remain available.

The candidate's current state MAY change based on the newest valid Evaluation, but the old decision MUST remain inspectable.

---

# 18. KPI Semantics Contract

The implementation MUST preserve the six KPI meanings defined by `KPI-FRAMEWORK.md`:

1. Field / Industry Relevance
2. Location Match
3. Role & Seniority Fit
4. Topical / Project Alignment
5. Network Proximity
6. Activity & Reachability

KPI 1 and KPI 4 MUST remain semantically distinct.

The system MUST NOT reinterpret KPI definitions merely because a model prompt produces more convenient output.

---

# 19. Default KPI Weight Contract

Unless the active CampaignRevision overrides them, default weights MUST be:

```text
KPI 1 = 25
KPI 2 = 20
KPI 3 = 15
KPI 4 = 20
KPI 5 = 10
KPI 6 = 10
```

The deterministic engine MUST validate configured weights before use.

---

# 20. Missing KPI Contract

Missing data MUST NOT be treated as a zero score.

For the currently defined case where KPI 5 cannot be measured:

- KPI 5 MUST be omitted from the composite;
- remaining weights MUST be proportionally normalized to 100%;
- the Evaluation MUST preserve the effective normalized weights used.

Example behavior:

```text
Configured weights:
25, 20, 15, 20, 10, 10

KPI 5 missing

Effective remaining weights:
25/90, 20/90, 15/90, 20/90, 10/90
scaled to 100%
```

---

# 20.1 Non-KPI-5 Missing Evidence Contract

In V1, KPI 5 is the only KPI permitted to be absent and removed from the weighted composite.

If the evaluator lacks sufficient evidence to make a defensible judgment for KPI 1, 2, 3, 4, or 6:

- it MUST NOT fabricate a score;
- it MUST NOT silently remove that KPI and renormalize weights;
- the Evaluation MUST be treated as incomplete rather than qualified;
- the workflow SHOULD first attempt a better/updated ProfileSnapshot or an approved enrichment/search source when practical;
- if sufficient evidence still cannot be obtained, the CampaignCandidate MUST move to `MANUAL_REVIEW` or another explicitly approved incomplete-evaluation path.

An incomplete Evaluation MUST NOT authorize connection-note generation or sending.

# 20.2 KPI Normalization and Adjustment Contract

All authoritative KPI values used by the deterministic scorer MUST be within `0..100`.

KPI 6 MUST preserve the seniority-offset rule from `KPI-FRAMEWORK.md`: when KPI 3 is `80` or higher, the effective KPI 6 used for scoring MUST NOT be below `50`.

Any KPI 6 reachability/activity bonus MUST still result in a final effective KPI 6 no greater than `100`.

When deterministic normalization changes a raw LLM judgment, the Evaluation MUST preserve enough information to distinguish the raw judgment from the effective score used for arithmetic. This MAY be implemented with `raw_judgment`, `score_adjustments`, explicit raw/effective fields, or an equivalent reproducible representation.

# 20.3 Composite Precision and Qualification Contract

The composite score MUST be calculated deterministically using fixed/controlled numeric precision suitable for repeatable threshold comparison.

Threshold qualification MUST use the authoritative unrounded calculation value, not a display-rounded value.

A candidate is qualified only when both are true:

```text
all enabled hard filters pass
AND
authoritative composite score >= active qualification threshold
```

Display formatting MAY round scores, but display rounding MUST NOT change qualification behavior.

---

# 21. Hard Filter Contract

CampaignRevision MUST support:

```text
require_field
require_location
```

When `require_field = true`, KPI 1 score `0` MUST fail the field hard filter.

When `require_location = true`, KPI 2 score `0` MUST fail the location hard filter.

Hard-filter outcomes MUST be persisted separately from the final composite score.

---

# 22. Score Interpretation Contract

Default qualification interpretation remains:

```text
80–100  Priority target
60–79   Good target
40–59   Backup
<40     Skip
```

The default qualification threshold is therefore `60` unless the active CampaignRevision defines another threshold.

A qualification decision MUST use the threshold from the active CampaignRevision.

---

# 23. Evaluation Provenance Contract

Every Evaluation MUST preserve:

- `campaign_candidate_id`;
- `campaign_revision_id`;
- `profile_snapshot_id`;
- Evaluation completion/status;
- all KPI scores and reasons;
- raw structured judgment when deterministic normalization adjusted it;
- deterministic score adjustments when applicable;
- composite score;
- effective weights;
- hard-filter outcomes;
- qualification result;
- qualification threshold;
- model provider;
- model name;
- prompt version;
- rubric version;
- evaluation version;
- scoring-engine version;
- creation timestamp;
- trace identifier.

If provenance is incomplete, the Evaluation MUST NOT be treated as fully reproducible.

---

# 24. LLM Evaluation Output Contract

The profile evaluator MUST return structured data.

Each measurable KPI MUST contain:

```text
score
reason
```

A missing KPI MUST use an explicit missing/null representation rather than fabricated `0`.

The LLM MUST NOT return the authoritative final weighted composite.

Malformed or schema-invalid output MUST NOT be silently coerced into a valid evaluation unless the correction is deterministic and lossless.

Otherwise the call MUST be retried or marked failed according to failure policy.

---

# 25. Evaluation Freshness Contract

The current score trust window is 30 days.

An Evaluation older than 30 days MUST NOT be used to make a new outreach decision without re-evaluation.

A fresh Evaluation MUST reference an appropriate current ProfileSnapshot.

The implementation MAY introduce a stricter snapshot-freshness policy, but MUST NOT silently extend the Evaluation trust window beyond 30 days without an approved specification change.

---

# 26. Search Provider Contract

Search MUST execute through a replaceable `SearchProvider` capability.

The core system MUST NOT depend on HarvestAPI-specific response structures.

The initial unattended implementation MUST support:

```text
HarvestApiSearchProvider
```

using `harvestapi/linkedin-profile-search`.

Authenticated LinkedIn browser search MUST remain architecturally possible as a benchmark, fallback, or high-fidelity provider.

The V1 unattended path MUST NOT depend on a callable authenticated-browser bridge that does not reliably exist in the runtime environment.

---

# 27. Search Result Normalization Contract

Every SearchProvider result MUST be normalized into an internal result containing enough information to determine:

- provider;
- provider run/reference;
- returned candidate identities;
- continuation/pagination state;
- whether the provider is exhausted;
- provider metadata;
- actual provider cost when available.

Provider-specific fields MAY be stored in metadata.

They MUST NOT leak into unrelated domain logic unless formally promoted into the internal contract.

---

# 28. Incremental Search Contract

Campaign search MUST run incrementally in bounded batches when the provider supports practical pagination or bounded execution.

The system MUST perform a policy check between batches.

The campaign runner MUST NOT blindly request the full theoretical campaign maximum when smaller bounded batches allow meaningful budget and target checks.

---

# 29. Search Counting Contract

The campaign's primary profile-volume stop condition MUST be based on:

```text
max_unique_candidates
```

not raw provider result count.

The system MUST separately record or derive:

- raw profiles returned;
- unique people resolved;
- campaign candidates created;
- qualified candidates.

Duplicates MUST NOT consume the unique-candidate limit more than once for the same Campaign.

Before a bounded provider request, the requested candidate/result capacity SHOULD be reduced to the remaining `max_unique_candidates` capacity when the provider supports such a limit.

Candidate ingestion MUST NOT create enough new CampaignCandidate rows to exceed `max_unique_candidates`, even if a provider returns more raw results than the remaining capacity. Excess raw/provider results MAY be retained for audit or ignored according to provider/storage policy, but they MUST NOT silently expand the campaign beyond the configured hard candidate cap.

---

# 30. Search Budget Contract

CampaignRevision MAY define:

```text
max_unique_candidates
max_search_cost_usd
target_qualified_profiles
max_evaluation_cost_usd
max_email_enrichments
max_email_enrichment_cost_usd
max_total_campaign_cost_usd
```

Live paid campaigns MUST have at least one practical bounded search termination condition.

The implementation MUST NOT allow an effectively unbounded paid search by accident.

---

# 31. Search Cost Semantics

`search_cost_usd` MUST represent variable SearchProvider charges necessary to discover and obtain the profile data returned by the search provider for that campaign execution.

For HarvestAPI this may include:

- search-page charges;
- full-profile retrieval charges associated with that search mode.

KPI evaluation cost, contact-enrichment cost, and connection-note LLM cost MUST be tracked separately from search cost.

---

# 32. Total Campaign Cost Semantics

`max_total_campaign_cost_usd` applies to variable external execution cost attributable to the Connection Campaign.

It includes, when applicable:

- profile search;
- full-profile retrieval;
- KPI LLM evaluation;
- contact enrichment;
- connection-note generation;
- other paid provider operations directly attributable to the campaign.

It does not include fixed shared infrastructure such as a monthly database subscription unless a future accounting design explicitly allocates those costs.

---

# 33. Budget Enforcement Contract

Budget enforcement MUST use pre-execution control, concurrency-safe reservation/serialization, provider-side caps when available, and actual-cost reconciliation.

## Pre-Execution Check

Before any paid search, evaluation, enrichment, note-generation, or other campaign-attributable provider operation begins, the system MUST evaluate the applicable remaining budget.

It MUST NOT intentionally launch an operation whose known provider-side maximum charge exceeds the remaining applicable hard budget.

## Atomic Reservation or Serialization

Concurrent workers MUST NOT be able to independently spend the same remaining budget.

Before a paid operation begins, the implementation MUST either:

- atomically reserve enough applicable budget for that operation; or
- serialize paid execution for the relevant Campaign/CampaignRevision with a database-backed lock or equivalent mechanism.

A reservation MUST be settled against actual cost after execution and unused reserved amount MUST be released.

The aggregate of settled cost plus outstanding valid reservations MUST NOT exceed a configured hard budget through normal system execution.

This rule applies independently to search cost, evaluation cost, email-enrichment cost/count, and total campaign cost where those limits are configured.

## Provider-Side Cap

When a provider exposes a reliable hard cost cap, the implementation SHOULD use it in addition to internal reservation/serialization. A provider-side cap does not replace internal concurrency protection.

## Actual Cost Reconciliation

After execution, actual provider usage/cost MUST be persisted and the reservation MUST be settled or released.

Future budget decisions MUST use actual known cost plus outstanding reservations, not estimates alone.

If actual cost cannot be determined and continuing execution would make a configured hard budget unenforceable, the system MUST stop or require human resolution rather than continue blindly.

## Stage-Specific Exhaustion

When `max_evaluation_cost_usd` is exhausted, the system MUST stop creating new paid evaluations for that campaign revision and MUST NOT continue paid search solely to accumulate candidates that cannot be evaluated. The campaign MUST pause/stop or require an explicit human policy decision.

When `max_email_enrichments` or `max_email_enrichment_cost_usd` is exhausted, additional email enrichment MUST stop, but otherwise-qualified LinkedIn connection flow MAY continue because email is optional in V1.

When `max_total_campaign_cost_usd` is exhausted, no additional variable paid campaign operation may start.

---

# 34. Search Stop Conditions

Search MUST stop when any active terminal condition becomes true:

```text
STOP_MAX_UNIQUE_CANDIDATES
STOP_SEARCH_COST_LIMIT
STOP_TOTAL_CAMPAIGN_COST_LIMIT
STOP_QUALIFIED_TARGET_REACHED
STOP_PROVIDER_EXHAUSTED
STOP_MANUAL
```

The terminal reason MUST be persisted.

---

# 35. Search Quality Benchmark Contract

The HarvestAPI vs authenticated-LinkedIn comparison MUST NOT assume that one provider must permanently replace the other.

Before Phase 1.2 is declared fully validated, at least one real campaign query MUST be compared against authenticated LinkedIn search using an authorized logged-in session, unless an authorized human explicitly waives this gate because the authenticated path is unavailable or unsafe to execute at that time.

A waiver MUST be documented with reason and date; it MUST NOT be implied merely because the benchmark is inconvenient.

The comparison MUST measure or document, where observable:

- qualified-profile rate;
- profiles scoring 80+;
- profile completeness;
- network-context availability;
- cost per qualified profile;
- result overlap;
- latency;
- failure rate;
- operational complexity.

A provider decision MUST be based on measured results from real campaigns rather than unsupported assumptions.

---

# 36. Contact Enrichment Boundary

Search and contact enrichment MUST remain separate capabilities:

```text
SearchProvider
ContactEnrichmentProvider
```

Using HarvestAPI for both is permitted.

The architecture MUST NOT require the same vendor to provide both forever.

---

# 37. Contact Point Contract

Contact information MUST be modeled separately from Person and ExternalProfile.

A Person MAY have multiple ContactPoints.

Initial supported contact type:

```text
email
```

Each ContactPoint MUST preserve:

- person;
- contact type;
- value;
- normalized value;
- source provider;
- verification status;
- discovered timestamp;
- last verified timestamp when available;
- provider metadata when useful.

Trivial duplicate contact points for the same Person, type, and normalized value MUST be prevented.

---

# 38. Email Verification Semantics

The system MUST distinguish provider-reported verification from independently verified contact information.

For example:

```text
PROVIDER_VERIFIED
```

MUST NOT be silently upgraded to a stronger internally verified state unless the system actually performs that verification.

A provider returning no email is a valid result.

---

# 39. Contact Enrichment Eligibility

Email enrichment MUST occur only if all applicable conditions pass:

- email enrichment is enabled in the active CampaignRevision;
- candidate is qualified;
- candidate score meets `minimum_score_for_email_enrichment`;
- enrichment-attempt limit has not been reached;
- email-enrichment budget remains;
- total campaign budget remains.

If any budget limit blocks enrichment, the attempt MUST be skipped or recorded as budget-blocked without failing the candidate's LinkedIn connection flow.

---

# 40. Email Non-Blocking Contract

Missing email MUST NOT block LinkedIn connection-note generation or LinkedIn connection sending in V1.

Contact enrichment is optional network data enrichment.

It is not a hard prerequisite for Stream 1 unless a future approved Campaign policy explicitly introduces such a requirement.

---

# 41. Connection Domain Contract

A `Connection` represents the long-lived relationship between:

```text
Operator × Person
```

Connection owns outreach and relationship state.

CampaignCandidate MUST NOT duplicate this state.

---

# 41.1 Connection Note Domain Contract

A generated connection note MUST be represented by a durable record or equivalent immutable artifact before a send attempt is created.

The note artifact MUST preserve at least:

- `Connection` reference;
- `CampaignCandidate` reference;
- `CampaignRevision` reference;
- exact authorizing `Evaluation` reference;
- note body;
- model/provider and prompt version when AI-generated;
- creation timestamp;
- trace identifier.

If a new Evaluation or materially different note is chosen, a new note artifact MUST be created or versioned; historical note text/provenance MUST remain inspectable.

---

# 42. Connection Attribution Contract

Every connection attempt initiated because of campaign qualification MUST be attributable to:

- `Connection`;
- `CampaignCandidate`;
- `CampaignRevision`;
- the exact `Evaluation` that authorized outreach;
- the exact persisted connection-note artifact used for that attempt.

The system MUST be able to answer which campaign, revision, evaluation, note, and evidence chain led to a request.

---

# 43. Connection Request State Contract

At minimum, request-state semantics MUST support:

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

Long-term relationship state MAY separately include:

```text
CONNECTED
ENGAGED
ACTIVE_RELATIONSHIP
```

Only states the system can actually observe or establish MUST be automatically assigned.

---

# 44. Connection Note Contract

A connection note MUST:

- be generated only for a qualified candidate or an explicitly human-approved exception;
- use real campaign/profile/evaluation context;
- reference a genuine reason for connecting;
- be persisted before send execution;
- be attributable to its prompt/model version if generated by an LLM.

A generic note unrelated to the candidate's actual qualification reason does not satisfy the requirement.

Before a new note is generated or a queued request is sent, the authorizing Evaluation MUST still satisfy the active freshness rule. If it has expired, the candidate MUST be re-evaluated and the note/outreach decision re-established from the new governing Evaluation.

---

# 45. Connection Attempt Contract

Each side-effecting send attempt MUST have a durable attempt record containing:

- Connection reference;
- CampaignCandidate reference;
- CampaignRevision reference;
- exact Evaluation reference;
- exact connection-note reference;
- idempotency key;
- attempt number;
- state;
- start/end timestamps;
- trace identifier;
- result metadata;
- error information when applicable.

---

# 46. Connection Idempotency Contract

A logical connection request MUST NOT be sent twice because of workflow retries, duplicate triggers, concurrent workers, or process restarts.

The implementation MUST use:

- a stable logical idempotency key;
- durable attempt state;
- atomic work claiming or equivalent concurrency protection.

Two workers MUST NOT be able to independently claim the same logical send operation.

---

# 47. Unknown Send Result Contract

If the external connection action may have succeeded but the system cannot confirm the outcome, the attempt MUST enter:

```text
UNKNOWN_SEND_RESULT
```

The system MUST NOT automatically resend that logical connection request.

It MUST instead:

- reconcile external state when safe and technically possible; or
- require human resolution.

---

# 48. Connection Sending Operational Contract

Connection sending MUST respect configured campaign/operator limits and applicable platform restrictions.

The implementation MUST:

- support an explicit daily maximum;
- support an allowed operating window;
- stop or require human attention when account/session challenges occur;
- avoid unbounded repeated retries.

The implementation MUST NOT introduce stealth, anti-detection, fingerprint-evasion, or challenge-bypass behavior as a completion requirement.

Platform-facing behavior should be conservative and policy-aware.

---

# 49. Story Profile Contract

Story Discovery MUST accept, when available:

- operator LinkedIn profile;
- CV;
- optional written story.

It MUST produce a versioned StoryProfile representing that operator's positioning and point of view.

Each StoryProfile MUST preserve source-material provenance sufficient to identify the LinkedIn/CV/written-story inputs or snapshots used, plus model provider/name and prompt version when generated by AI.

StoryProfile output SHOULD be structured enough to support repeatable content generation.

StoryProfiles MUST NOT be destructively overwritten when a materially new version is created.

---

# 50. Story Discovery Validation

Before Stream 2 Story Discovery is complete, it MUST be tested on both current operators.

The two outputs MUST:

- be meaningfully distinct;
- reflect their actual source material;
- avoid imposing one generic job-seeker narrative;
- avoid unsupported invented claims;
- be judged usable by the relevant human operator.

This is a required human validation gate.

---

# 51. Content Draft Contract

Content generation MUST support at least:

```text
comment
post
post_with_image
```

Each ContentDraft MUST preserve:

- operator;
- StoryProfile version;
- generation objective/context;
- generated body;
- content type;
- model/provider metadata;
- prompt version;
- trace identifier;
- lifecycle state.

---

# 52. Past Content Context Contract

Content generation MUST have access to relevant past published content or approved content history sufficient to reduce obvious repetition and maintain voice continuity.

The implementation MUST NOT assume that every new generation starts without history.

---

# 53. Content Asset Contract

Non-text media MUST be represented as a separate `ContentAsset`.

Initial supported asset type:

```text
image
```

A ContentAsset MUST preserve:

- ContentDraft reference;
- asset type;
- durable storage reference;
- generation provider when generated;
- model/prompt metadata when applicable;
- asset state;
- trace identifier.

---

# 54. Media Provider Contract

Media generation MUST sit behind a replaceable `MediaGenerator` boundary.

No specific media-generation provider is required by this Contract until the implementation phase selects one.

The rest of the content pipeline MUST NOT depend on provider-specific media APIs.

---

# 55. AI Content Review Contract

Generated content MUST pass an AI pre-review before it can reach final human approval.

The review MUST evaluate at least:

- clarity;
- one clear central idea;
- fit with StoryProfile;
- obvious repetition;
- specificity;
- generic/low-value writing;
- suitability for intended audience.

AI review MUST return a structured verdict/reasons representation that is durably associated with the reviewed draft/body/assets.

AI-generated reviews MUST preserve reviewer model/provider and prompt version.

AI review MAY send content back for rework.

AI approval alone MUST NOT authorize publication.

---

# 56. Human Approval Contract

Human final approval is mandatory for publication in the current project phase.

The system MUST record an explicit human approval record/state that identifies:

- authorized human approver identity;
- approval timestamp;
- exact content body version or deterministic content fingerprint;
- exact approved ContentAsset identifiers and immutable checksums/fingerprints when assets are present;
- related ContentDraft/ContentRevision identity;
- trace identifier.

Publication MUST NOT proceed if approval is absent, rejected, ambiguous, or does not match the exact body/assets being published.

If the approved body or approved assets are materially changed after approval, their fingerprint/version MUST change and the content MUST return to human approval before publication.

The publisher MUST verify that the artifact being published still matches the approved fingerprint/version immediately before the external side effect.

---

# 57. Content Source-of-Truth Contract

Supabase MUST be canonical for:

- draft state;
- asset state;
- AI review history;
- human approval;
- final approved content;
- publication state;
- published metadata.

The repository MUST NOT be the only record of publication state.

---

# 58. Content Publication Contract

Publishing MUST occur behind a replaceable `ContentPublisher`.

The publisher implementation MAY be selected later.

The pipeline before publication MUST remain independent from the final provider choice.

The final published body MUST be stored separately from the initial draft when they differ.

Published assets MUST be attributable to the exact publication.

---

# 59. Publication Idempotency Contract

A logical content publication MUST NOT be published twice because of retries or duplicate triggers.

Publication MUST have:

- durable publication identity;
- idempotency protection;
- attempt state or equivalent execution record;
- reconciliation for unknown external results.

Unknown publication outcome MUST NOT trigger blind automatic republishing.

---

# 60. Workflow Trace Contract

Every major execution path MUST use an end-to-end `trace_id`.

The same trace identifier SHOULD be propagated through relevant:

```text
WorkflowRun
WorkflowStepRun
SearchRun
Evaluation
ContactEnrichmentAttempt
ConnectionAttempt
ContentDraft
ContentAsset
ContentReview
ContentPublication
ProviderUsage
```

This MUST make it possible to reconstruct the execution path of a campaign or content workflow.

---

# 61. Workflow Run Contract

Major n8n workflows MUST create durable workflow-run state.

A WorkflowRun MUST record at least:

- trace identifier;
- workflow type;
- relevant entity;
- state;
- start time;
- completion time when finished;
- error information when failed.

---

# 62. Step Observability Contract

External, expensive, or failure-prone workflow steps SHOULD record:

- step name;
- attempt number;
- provider;
- state;
- latency;
- cost when applicable;
- error code/message;
- relevant metadata.

Observability MUST NOT expose secrets.

---

# 63. Provider Usage Contract

Variable provider usage SHOULD be persisted through a common usage model.

At minimum, the system MUST be able to attribute paid campaign operations to:

- campaign;
- CampaignRevision;
- trace;
- provider;
- operation type;
- actual cost when available.

The system SHOULD support later calculation of:

```text
cost per unique candidate
cost per qualified candidate
email discovery rate
cost per email found
cost per connection request
cost per accepted connection
```

---

# 64. Failure Classification Contract

Provider and workflow failures MUST map to a common taxonomy:

```text
RETRYABLE
NON_RETRYABLE
UNKNOWN_SIDE_EFFECT
REQUIRES_HUMAN
```

The original provider error MAY also be preserved for debugging.

---

# 65. Retry Contract

Safe-to-repeat operations MAY be retried automatically.

Retries MUST be bounded.

Retryable operations SHOULD use backoff.

Duplicate-sensitive side effects MUST NOT use blind generic retry.

A retry MUST NOT erase the history of earlier failed attempts.

---

# 66. Human Escalation Contract

Human intervention is required when the system encounters a decision that cannot safely be made from approved specifications.

Examples include:

- product semantics are ambiguous;
- KPI meaning must change;
- Campaign budget semantics must change;
- a major architectural boundary must change;
- a live external side effect has unknown outcome and cannot be reconciled;
- LinkedIn/session/account challenge requires manual action;
- human content approval is required;
- credentials or access needed for mandatory live validation are unavailable;
- provider behavior makes a configured hard budget impossible to enforce safely.

The agent SHOULD resolve normal implementation failures independently before escalating.

---

# 67. Secrets Contract

Real secrets MUST NOT be committed to the repository.

Secrets include:

- Supabase service credentials;
- OpenRouter/API keys;
- Apify tokens;
- LinkedIn session/authentication material;
- publishing credentials;
- webhook secrets.

Secrets MUST NOT appear in:

- ordinary application logs;
- LLM prompts;
- normal business tables;
- test fixtures committed to source control.

Only secret names, templates, and setup documentation MAY be committed.

---

# 67.1 Personal Data Governance Contract

Profile snapshots and discovered contact information are personal data and MUST be handled deliberately.

The implementation MUST:

- avoid placing full profile payloads, email addresses, CV contents, or other unnecessary personal data in routine application logs;
- restrict raw profile/contact access to components and authorized operators that need it for the documented workflow;
- use synthetic or redacted personal data in committed test fixtures whenever practical;
- preserve source/provenance for ContactPoints without exposing sensitive values in observability metadata unnecessarily;
- provide a documented administrative path to delete or anonymize Person/contact/profile data when required, while preserving non-identifying operational aggregates where appropriate;
- avoid sending personal data to an LLM/provider when that data is not needed for the specific operation.

This Contract does not define a legal retention schedule. If a retention/deletion policy becomes a product or compliance requirement, it requires an approved specification rather than being invented by an implementation agent.

---

# 68. Database Migration Contract

All schema changes MUST be reproducible from `supabase/migrations/`.

A clean development database MUST be able to reach the expected schema by applying migration history.

Production-only manual tables or undocumented schema changes violate the Contract.

---

# 69. Database Integrity Contract

The database SHOULD enforce deterministic integrity whenever practical.

Required classes of constraints include:

- foreign keys;
- uniqueness where the domain defines uniqueness;
- KPI range validation;
- non-null fields where state cannot be meaningful without them;
- prevention of duplicate campaign candidates;
- consistency of CampaignCandidate governing/current Evaluation reference;
- prevention of trivial duplicate contact points;
- uniqueness/idempotency constraints for logical connection sends and publications where database enforcement is practical.

Workflow code MUST NOT be the sole defense for invariants that PostgreSQL can reliably enforce.

---

# 70. Concurrency Contract

Work claiming for duplicate-sensitive operations MUST be atomic.

Read-then-later-update patterns MUST NOT be relied on when concurrent executions could claim the same work.

Database conditional updates, row locking, unique constraints, advisory locks, atomic budget reservations, or another equivalent mechanism MUST ensure one logical owner.

Concurrency tests MUST include both duplicate-sensitive side effects and concurrent paid operations competing for the same hard campaign budget.

---

# 71. Prompt Versioning Contract

Important prompts MUST be versioned.

At minimum:

```text
profile evaluator
connection note
story discovery
content generator
content reviewer
media generator when prompt-based
```

Changing prompt semantics materially MUST produce a new prompt version.

Historical records MUST continue identifying the prompt version that produced them.

---

# 72. Model Configuration Contract

Specific LLM/model identity SHOULD remain configuration rather than deeply embedded workflow logic.

The system MAY change models without redesigning the domain.

Historical AI records MUST preserve the model/provider actually used.

---

# 72.1 Repository Reproducibility Contract

Before a phase that changes executable workflows is declared complete, the repository MUST contain the version-controlled representation required to reproduce that implementation.

At minimum:

- Supabase schema changes MUST exist as migrations;
- n8n workflows created or materially changed for the accepted phase MUST be exported/version-controlled in the repository;
- versioned prompts used by accepted AI behavior MUST be present in the repository;
- Rust components MUST pass `cargo fmt --check` and `cargo test` (or the workspace-equivalent commands);
- Rust components SHOULD pass `cargo clippy -- -D warnings` or an equivalent strict lint gate; if not, a specific justified limitation MUST be documented rather than silently skipped.

A workflow existing only inside a live n8n instance does not satisfy reproducibility.

---

# 73. Test Integrity Contract

The implementation agent MUST NOT:

- delete a valid failing test to obtain a green suite;
- weaken assertions without a justified requirement change;
- mark a test skipped merely because the implementation cannot satisfy it;
- replace meaningful tests with trivial tests that only exercise mocks.

A test MAY be changed when the underlying approved requirement changed or the test itself is demonstrably incorrect.

Such changes MUST be documented.

---

# 74. Rust Test Contract

Deterministic Rust logic MUST have automated tests covering at least:

- default weighted score;
- custom weights;
- missing KPI 5 normalization;
- rejection/incomplete handling when KPI 1, 2, 3, 4, or 6 is missing;
- KPI range validation and cap at 100;
- KPI 6 seniority offset when KPI 3 >= 80;
- authoritative score precision around qualification threshold;
- qualification requiring hard filters plus threshold;
- hard field filter;
- hard location filter;
- custom qualification threshold;
- malformed input;
- budget-policy stop conditions if implemented in Rust.

Expected outputs MUST be deterministic.

---

# 75. Database Test Contract

Database tests MUST cover at least:

- migrations apply successfully from clean state;
- core foreign keys;
- CampaignRevision uniqueness/versioning and freeze behavior;
- duplicate CampaignCandidate prevention;
- CampaignCandidate current/governing Evaluation consistency;
- ExternalProfile identity uniqueness where applicable;
- ContactPoint duplicate prevention;
- required state-related constraints;
- valid nullable KPI 5 behavior.

---

# 76. Provider Contract Test Contract

Provider adapters MUST have tests demonstrating normalization into internal contracts.

At minimum:

- HarvestAPI search response normalization;
- exhausted pagination;
- provider failure;
- provider-reported cost handling;
- contact-enrichment result with email;
- contact-enrichment result with no email;
- malformed provider result.

A live provider call is not required for every automated test.

---

# 77. Workflow Integration Test Contract

Stream 1 integration tests MUST cover:

- bounded search batch;
- duplicate search result ingestion;
- identity resolution;
- ProfileSnapshot creation;
- structured evaluator success;
- evaluator failure;
- deterministic scoring;
- candidate qualification;
- hard-filter disqualification;
- budget stop before next batch;
- concurrent paid-operation budget protection;
- unique-candidate hard-cap protection when a provider returns more rows than remaining capacity;
- evaluation-cost exhaustion behavior;
- provider exhaustion;
- contact enrichment allowed;
- contact enrichment blocked by score;
- contact enrichment blocked by budget;
- no-email result;
- connection note tied to exact authorizing Evaluation;
- Connection reaches `NOTE_READY` only after a persisted note exists;
- connection send queue claim;
- ConnectionAttempt references exact Evaluation and note artifact;
- duplicate send prevention;
- unknown send result;
- trace propagation.

---

# 78. Content Integration Test Contract

Stream 2 integration tests MUST cover:

- StoryProfile creation;
- separate StoryProfiles for different operators;
- past-content retrieval;
- comment generation;
- post generation;
- post-with-image path;
- ContentAsset persistence;
- AI review pass;
- AI review rework;
- structured AI-review provenance;
- human approval gate;
- human approval bound to exact content/assets fingerprint;
- publication blocked without human approval;
- material edit after approval requiring re-approval;
- publisher preflight verification of approved fingerprint;
- publication idempotency;
- unknown publication result;
- trace propagation.

---

# 79. Real-Profile KPI Validation Contract

Before the KPI system is trusted for search-provider comparison or live sending:

- approximately ten real profiles MUST be evaluated for a known real campaign;
- a human MUST inspect the KPI scores and reasons;
- obvious strong and weak candidates MUST rank sensibly;
- KPI 1 and KPI 4 MUST remain meaningfully distinct;
- missing KPI behavior MUST be tested;
- hard filters MUST be tested.

If this validation is unsatisfactory, Phase 1.1 is not complete.

---

# 80. Search Benchmark Validation Contract

The HarvestAPI search path MUST be tested on real campaign queries.

At least one authorized authenticated LinkedIn search comparison MUST be executed as the high-fidelity baseline unless an authorized human records an explicit waiver as defined in the Search Quality Benchmark Contract.

The comparison MUST persist or otherwise document:

- query/campaign revision;
- results;
- scoring outputs;
- usable/qualified rate;
- cost;
- overlap;
- important completeness differences.

The project MAY keep both approaches for different roles.

No universal winner is required by the Contract.

---

# 81. Live Connection Validation Contract

Before Stream 1 is operationally complete, a real campaign MUST run end-to-end using authorized real accounts and campaign configuration.

The live validation MUST demonstrate:

- campaign revision selection;
- budget enforcement;
- profile discovery;
- identity resolution;
- snapshot capture;
- evaluation;
- deterministic scoring;
- qualification;
- optional contact enrichment according to policy;
- connection-note creation;
- safe queueing;
- connection sending;
- durable state updates;
- provider cost accounting;
- useful trace/log data.

Synthetic-only tests do not satisfy this gate.

---

# 82. Live Content Validation Contract

Before Stream 2 is operationally complete:

- Story Discovery MUST be validated on both current operators;
- real draft comments and posts MUST be generated;
- post-with-image flow MUST be exercised if that content type is enabled;
- AI review MUST reject/rework at least one intentionally weak test draft;
- human approval MUST be required;
- publication MUST remain blocked without approval;
- publication state MUST persist correctly.

A publishing provider need not be selected before its implementation phase, but Stream 2 cannot be declared fully operational until the chosen publication path is verified.

---

# 83. Regression Contract

After every meaningful implementation change, the agent MUST run the relevant local/component test suite.

Before a phase is declared complete, the agent MUST run the full test set relevant to that phase.

Before Streams 1 or 2 are declared complete, the agent MUST run the full available project regression suite.

A new phase MUST NOT knowingly break previously accepted functionality.

---

# 84. Autonomous Agent Execution Rules

The implementation agent MUST follow this loop:

```text
Read current contract and relevant specs
        ↓
Inspect repository/current implementation
        ↓
Implement the smallest coherent unit
        ↓
Run relevant tests
        ↓
Tests fail?
   ├── YES → investigate → fix → rerun
   └── NO
        ↓
Review against Contract
        ↓
Contract gap?
   ├── YES → implement/fix → rerun
   └── NO
        ↓
Proceed to next unit
```

The agent MUST NOT stop after merely writing code when validation can be performed locally.

---

# 85. Agent Review Rule

The agent MUST review completed work against:

- relevant Contract clauses;
- relevant subsystem specification;
- regression impact;
- error handling;
- observability;
- idempotency where applicable.

If a review finds a resolvable issue, the agent SHOULD fix it and re-run validation without asking the user to perform routine debugging.

---

# 86. Allowed Autonomous Decisions

The agent MAY decide without human approval:

- internal function names;
- internal module boundaries;
- Rust type organization;
- SQL index names;
- exact test-file structure;
- low-level n8n node arrangement;
- logging implementation details;
- non-semantic refactors;
- bounded retry counts consistent with the Contract;
- internal serialization details;
- implementation libraries compatible with project boundaries.

The agent MUST document significant deviations from the Proposal.

---

# 87. Decisions Requiring Human Approval

The agent MUST NOT independently change:

- product scope;
- KPI meanings;
- default scoring semantics;
- requirement that AI and deterministic scoring stay separate;
- campaign cost semantics;
- required human content approval;
- source-of-truth ownership;
- major technology boundaries;
- meaning/ownership of core domain entities;
- definition of successful live validation;
- Contract acceptance criteria.

---

# 88. No Fake Completion

The agent MUST NOT report `DONE` when:

- tests are failing;
- required migrations are unapplied or broken;
- required acceptance criteria are unverified;
- a mandatory live validation was not performed;
- required human approval is pending;
- known duplicate-side-effect risk remains unresolved;
- secrets are committed;
- unresolved Contract violations remain;
- major TODOs remain inside the accepted phase.

It MAY report a narrower status such as:

```text
IMPLEMENTED, LIVE VALIDATION PENDING
```

when that accurately describes reality.

---

# 89. Phase 0A Acceptance — Domain Foundation

Phase 0A is complete only when:

- core schema exists;
- Person is independent from Campaign;
- ExternalProfile is separate from Person;
- ProfileSnapshot exists;
- CampaignRevision exists, is versioned, and freezes before execution uses it;
- CampaignCandidate uniqueness is enforced;
- CampaignCandidate has an explicit governing/current Evaluation reference or equivalent;
- Candidate states exclude send state;
- Evaluation references CampaignRevision and ProfileSnapshot;
- ContactPoint exists;
- Connection, persisted ConnectionNote, and ConnectionAttempt are separate;
- workflow tracing entities exist or an equivalent durable mechanism exists;
- provider boundaries are documented;
- migrations and database integrity tests pass.

---

# 90. Phase 0B Acceptance — Runtime Foundation

Phase 0B is complete only when:

- n8n can read/write development Supabase data;
- n8n can invoke the configured LLM gateway;
- n8n can invoke the first deterministic Rust tool;
- secrets are configured outside source control;
- trace identifiers can propagate through at least one test workflow;
- workflow failures can be recorded durably;
- relevant integration tests pass.

---

# 91. Phase 1.1 Acceptance — KPI Evaluation

Phase 1.1 is complete only when:

- profile-evaluator prompt is versioned;
- output schema is validated;
- Rust scorer is implemented;
- all deterministic scoring tests pass;
- Evaluation provenance is persisted;
- 30-day freshness behavior is implemented;
- approximately ten real profiles have passed human sanity review;
- hard-filter and KPI-5 missing behavior have been verified;
- missing evidence for KPI 1, 2, 3, 4, or 6 cannot silently qualify a candidate;
- KPI 6 seniority offset and score precision/threshold behavior have been verified.

---

# 92. Phase 1.2 Acceptance — Budgeted Search

Phase 1.2 is complete only when:

- SearchProvider interface exists;
- HarvestAPI provider works through normalized internal output;
- search runs in bounded increments;
- identity resolution/deduplication works;
- unique-candidate count drives profile limit;
- SearchRun state is durable;
- pre-budget checks work;
- concurrent paid operations cannot double-spend the same hard budget;
- provider hard cap is used when available;
- actual provider cost is recorded;
- unique-candidate hard cap cannot be exceeded by oversized provider batches;
- evaluation-budget exhaustion stops unsafe continuation;
- all configured search stop reasons can be exercised;
- real HarvestAPI search has been validated;
- at least one authenticated-search benchmark is exercised, or an explicit authorized human waiver is recorded.

---

# 93. Phase 1.3 Acceptance — Contact Enrichment

Phase 1.3 is complete only when:

- ContactEnrichmentProvider boundary exists;
- HarvestAPI implementation exists;
- ContactPoint persists source and verification state;
- multiple contacts per Person are supported;
- duplicate contact prevention works;
- score threshold works;
- enrichment count limit works;
- enrichment cost limit works;
- total campaign budget is respected;
- no-result outcome is valid;
- no-result outcome does not block LinkedIn connection flow;
- actual enrichment usage/cost is recorded.

---

# 94. Phase 1.4 Acceptance — Connection Note

Phase 1.4 is complete only when:

- note generation uses campaign/profile/evaluation context;
- notes are persisted before sending;
- model/prompt provenance is available;
- note generation failure is recoverable;
- the corresponding Connection can reach `NOTE_READY` only after a durable note tied to the exact authorizing Evaluation exists;
- generic context-free notes are not accepted as successful output.

---

# 95. Phase 1.5 Acceptance — Safe Sending

Phase 1.5 is complete only when:

- existing browser sender is behind a stable ConnectionSender boundary;
- ConnectionAttempt exists;
- CampaignCandidate attribution exists;
- exact authorizing Evaluation and persisted note attribution exist;
- idempotency prevents duplicate logical sends;
- concurrent duplicate claims are prevented;
- failed sends are recorded;
- unknown results enter `UNKNOWN_SEND_RESULT`;
- unknown results are not blindly retried;
- session/account challenges stop safely;
- configured daily/operating limits are enforced.

---

# 96. Phase 1.6 Acceptance — End-to-End Acquisition

Phase 1.6 is complete only when a real authorized campaign demonstrates:

```text
CampaignRevision
→ bounded paid search
→ Person resolution
→ ProfileSnapshot
→ Evaluation
→ deterministic scoring
→ qualification
→ optional email enrichment
→ note generation
→ safe sending
→ durable connection state
→ actual cost accounting
→ end-to-end trace
```

All relevant automated tests MUST pass afterward.

---

# 97. Phase 2.1 Acceptance — Story Discovery

Phase 2.1 is complete only when:

- Story Discovery prompt is versioned;
- structured StoryProfile is persisted;
- source context is preserved;
- both current operators are tested;
- both operators' outputs are meaningfully distinct;
- human validation confirms useful representation;
- unsupported invented claims are not accepted.

---

# 98. Phase 2.2 Acceptance — Content Generation

Phase 2.2 is complete only when:

- content generation uses StoryProfile;
- relevant historical content is available as context;
- comment generation works;
- post generation works;
- post-with-image path can create a draft requiring an asset;
- generation provenance is stored;
- drafts are durable before review.

---

# 99. Phase 2.3 Acceptance — Media Generation

Phase 2.3 is complete only when, for enabled post-with-image workflows:

- MediaGenerator boundary exists;
- generated media is represented by ContentAsset;
- durable asset storage/reference exists;
- provider provenance is stored;
- media failure does not corrupt draft state;
- text and asset remain attributable to the same draft.

If post-with-image is disabled by approved product configuration, this phase MAY remain inactive rather than falsely implemented.

---

# 100. Phase 2.4 Acceptance — AI Review and Human Approval

Phase 2.4 is complete only when:

- AI review is implemented;
- weak/repetitive/off-positioning drafts can be rejected or sent to rework;
- human approval state is explicit and records approver/time;
- approval is bound to the exact body/assets version or fingerprint;
- publishing is technically impossible through the normal workflow without matching approval;
- material edits after approval invalidate the prior approval;
- review history remains durable.

---

# 101. Phase 2.5 Acceptance — Publishing

Phase 2.5 is complete only when:

- ContentPublisher boundary exists;
- a provider has been selected and documented;
- publication is idempotent;
- published body/assets are stored;
- external publication identifiers are stored when available;
- failure is recorded;
- unknown publication result is reconciled rather than blindly retried;
- Supabase reflects publication state correctly.

---

# 102. Phase 2.6 Acceptance — Content History

Phase 2.6 is complete only when the system can reconstruct:

```text
StoryProfile used
→ generated draft
→ generated assets
→ AI review
→ human decision
→ final approved body/assets
→ publication result
```

Supabase MUST contain the canonical history.

---

# 103. Phase 3 Acceptance — Feedback Foundation

Phase 3 does not require automated optimization.

It is complete when the stored data can support analysis of:

```text
KPI score
→ connection request
→ observed connection outcome
```

and:

```text
published content
→ observable performance data
```

without redesigning the core Person/Campaign/Content model.

---

# 104. Completion Evidence

When declaring a phase complete, the implementation agent MUST provide concise evidence including:

- implemented components;
- migrations added;
- tests run;
- test results;
- live validation performed when required;
- known limitations;
- unresolved human decisions, if any;
- Contract clauses not yet satisfied, if the status is partial.

Claims such as "works" or "done" without evidence do not satisfy the Contract.

---

# 105. Contract Verification Checklist

Before final `DONE`, verify all applicable items:

```text
[ ] Documentation hierarchy is consistent.
[ ] No known Contract violation remains.
[ ] Database migrations apply cleanly.
[ ] Core integrity constraints pass.
[ ] Deterministic tests pass.
[ ] Provider contract tests pass.
[ ] Workflow integration tests pass.
[ ] Full regression suite passes.
[ ] CampaignRevision is used historically and frozen before execution.
[ ] Candidate state and Connection state are not duplicated.
[ ] CampaignCandidate current state points to an explicit governing Evaluation.
[ ] Evaluation provenance is complete.
[ ] Search limits use unique candidates.
[ ] Search/campaign budgets are concurrency-safe through reservation or serialization.
[ ] Search budget is enforced before and after provider runs.
[ ] Unique-candidate hard cap cannot be exceeded by provider batch size.
[ ] Actual paid provider usage is recorded.
[ ] Email enrichment is optional and separately budgeted.
[ ] Missing email does not block LinkedIn connection flow.
[ ] Connection notes and attempts reference the exact authorizing Evaluation.
[ ] Connection sends are idempotent.
[ ] Unknown sends are not blindly retried.
[ ] StoryProfiles are versioned.
[ ] Content assets are first-class records.
[ ] Human approval is mandatory and bound to exact content/assets before publication.
[ ] Content publication is idempotent.
[ ] Supabase is canonical runtime state.
[ ] trace_id propagates end to end.
[ ] Secrets are not committed or logged.
[ ] Personal/contact data is minimized in logs/tests and an administrative deletion/anonymization path is documented.
[ ] Required real-profile validation has passed.
[ ] Required live campaign validation has passed.
[ ] Required live content validation has passed.
[ ] No valid tests were weakened to reach completion.
[ ] No major TODO remains inside accepted scope.
```

---

# 106. Final Definition of Done

The project covered by this Contract is `DONE` only when Streams 1 and 2 satisfy their applicable phase acceptance criteria and the system can demonstrate both of these real-world loops:

## Network Acquisition

```text
Define Campaign
→ version configuration
→ search within budget
→ resolve real people
→ capture evidence
→ evaluate
→ score deterministically
→ qualify
→ optionally enrich email
→ generate purposeful note
→ send safely
→ preserve relationship and cost history
```

## Network Nurturing

```text
understand operator
→ create versioned StoryProfile
→ generate content
→ generate media when required
→ AI review
→ human approval
→ publish safely
→ preserve complete content history
```

In addition:

- failures are observable;
- external side effects are protected against accidental duplication;
- AI decisions are traceable;
- deterministic decisions are reproducible;
- provider costs are measurable;
- provider implementations are replaceable;
- no mandatory validation remains pending;
- all applicable tests pass.

Only then may the implementation agent return:

```text
DONE — CONTRACT SATISFIED
```

If some implementation is complete but a mandatory external or human gate remains, the agent MUST report the exact narrower status instead of `DONE`.
