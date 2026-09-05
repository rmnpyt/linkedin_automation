# LinkedIn Automation System — Agent Start

**Status:** Operational Kickoff Instructions  
**Audience:** Main implementation/orchestration agent and its sub-agents  
**Scope:** Local implementation of the approved project documentation for Streams 1 and 2  
**Execution Model:** Local repository, local commits, remote development services through approved MCP access, human-controlled GitHub push and live side effects

---

# 1. Purpose

This file defines how an autonomous engineering agent must start, delegate, implement, test, review, fix, commit, and hand off this project.

It does not redefine product semantics or architecture.

The implementation agent must derive product and engineering truth from the approved project documents and use this file only as the operational execution policy.

---

# 2. Required Reading Order

Before changing code, schema, workflows, prompts, or configuration, the main agent MUST read the current repository versions of:

```text
MINDSET.md
PLAN.md
CONTRACT.md
PROPOSAL.md
KPI-FRAMEWORK.md
CONNECTION-FLOW.md
CONTENT-FLOW.md
RESEARCH-NOTES.md when historical/provider context is needed
```

The agent MUST respect the authority boundaries defined in `CONTRACT.md`.

The repository copies are authoritative for implementation. Conversation attachments, cached copies, or remembered earlier versions MUST NOT override the current checked-out repository documents.

---

# 3. Current Development Environment

The intended environment is:

```text
Local Development Machine
│
├── Local Git repository
├── Rust toolchain
├── PowerShell
├── Docker Desktop / MCP tooling
├── local tests and fixtures
│
├── n8n MCP
│      └── remote self-hosted n8n instance
│             ├── existing Apify credential
│             ├── existing OpenRouter credential
│             ├── existing OpenAI credential
│             └── existing Supabase credential
│
└── Supabase MCP
       └── development project: linkedin_automation
```

The Supabase project `linkedin_automation` is a development project and is currently expected to be empty before initial migrations.

The n8n instance is self-hosted remotely and already contains provider credentials. Those credentials remain inside n8n and MUST NOT be copied into the repository or exposed to sub-agents unnecessarily.

---

# 4. Access Preflight

Before implementation, the main agent MUST perform a non-destructive preflight.

Verify:

```text
[ ] The expected local repository is open.
[ ] The current branch is known.
[ ] git status has been inspected.
[ ] Existing Git author identity is readable.
[ ] Rust toolchain is available.
[ ] Relevant local test/runtime tools are available.
[ ] n8n MCP is reachable.
[ ] Supabase MCP is reachable in the current agent runtime, if available.
[ ] Supabase access is scoped to the development project linkedin_automation.
[ ] No production database is being targeted.
[ ] No GitHub push credential is required for implementation.
```

Failure of one external integration MUST NOT automatically stop unrelated local implementation.

If an integration is unavailable, the main agent MUST:

1. continue all work that can be safely completed with local code, fixtures, mocks, exported artifacts, and tests;
2. mark only the affected acceptance gate as `ACCESS_PENDING` or `LIVE_VALIDATION_PENDING`;
3. avoid inventing or bypassing credentials;
4. report the exact missing access during handoff.

---

# 5. Git Safety Policy

The agent works in the user's local Git repository.

The agent MAY use:

```text
git status
git diff
git add
git commit
git log
git branch --show-current
other local inspection commands that do not contact or mutate a remote
```

The agent MUST NOT:

```text
git push
git push --force
gh pr
gh merge
create or publish remote tags
change remote repository configuration
modify GitHub credentials
```

Remote publication is owned by the human operator.

## 5.1 Git Identity

Before the first commit, read:

```bash
git config user.name
git config user.email
```

The agent MUST use the existing Git identity configured by the user.

The agent MUST NOT change `user.name`, `user.email`, commit signing identity, or credential configuration merely to identify itself as an AI agent.

Commits created by the agent are normal local project commits under the user's existing Git configuration.

## 5.2 Existing Working Tree

The agent MUST inspect pre-existing modifications before editing.

It MUST NOT overwrite, discard, reset, or accidentally commit unrelated human changes.

If unrelated changes exist, the agent SHOULD isolate its work by path and commit only files belonging to the current phase.

Destructive cleanup such as `git reset --hard`, deletion of untracked user files, or broad checkout/revert operations MUST NOT be used unless explicitly authorized.

## 5.3 Repository Hygiene and `.gitignore`

Early in Phase 0A, the Agent MUST inspect the repository and create or update the root `.gitignore`.

The `.gitignore` MUST reflect the actual toolchain and generated files used by the implementation, including as applicable:

```text
.env
.env.*
!.env.example
*.local
secrets/
*.secret
*.key
*.pem

target/
coverage/
.tmp/
tmp/
.cache/

__pycache__/
*.py[cod]

.vscode/
.idea/
.DS_Store
Thumbs.db
```

The exact entries MAY differ based on the repository and tools actually used.

The Agent MUST verify that the ignore rules do **not** accidentally exclude required project artifacts such as:

```text
supabase/migrations/
n8n workflow exports
doc/prompts/
source code
test fixtures intentionally committed
configuration templates such as .env.example
README.md
```

Before each commit, the Agent MUST inspect staged files for accidentally included secrets, credentials, provider tokens, session material, generated build output, and unrelated local files.

If an existing `.gitignore` is present, the Agent SHOULD extend it conservatively rather than replacing project-specific rules without review.

---

# 6. Commit Policy

Do not wait until the entire project is finished to make one giant commit.

A coherent phase or accepted implementation unit SHOULD produce a local commit after:

```text
implementation
→ tests
→ independent review
→ fixes
→ regression verification
→ Contract check
```

Suggested commit granularity follows the project roadmap:

```text
Phase 0A — domain foundation
Phase 0B — runtime foundation
Phase 1.1 — KPI evaluation
Phase 1.2 — budgeted discovery
Phase 1.3 — contact enrichment
Phase 1.4 — connection note
Phase 1.5 — safe sending
Phase 1.6 — acquisition integration
Phase 2.x — content phases
```

The main agent owns final staging and commit creation.

Sub-agents SHOULD NOT independently create competing commits unless explicitly assigned by the main agent.

---

# 7. Multi-Agent Operating Model

The main agent acts as the **Orchestrator**.

For non-trivial phases, it SHOULD delegate focused work to sub-agents when the runtime supports sub-agents.

Each sub-agent receives one narrow responsibility and explicit acceptance criteria.

Recommended roles:

```text
Orchestrator
│
├── Implementation Agent
├── Database Agent
├── n8n Workflow Agent
├── Test Agent
├── Review Agent
├── Fix Agent
└── Contract Verification Agent
```

Not every phase requires every role.

The Orchestrator decides which roles are relevant.

---

# 8. Sub-Agent Responsibilities

## 8.1 Orchestrator

The Orchestrator MUST:

- read the governing documents;
- identify the current phase and acceptance criteria;
- inspect the existing implementation before assigning work;
- divide the phase into coherent tasks;
- prevent conflicting simultaneous edits;
- delegate implementation and verification;
- integrate results;
- run final regression for the phase;
- compare the implementation against `CONTRACT.md`;
- create the local Git commit when the unit is accepted;
- preserve a concise evidence trail for final handoff.

The Orchestrator MUST NOT accept a sub-agent's claim of completion without verification.

## 8.2 Implementation Agent

The Implementation Agent writes the smallest coherent code/configuration unit required by the assigned task.

It MUST stay within the assigned architectural boundary.

It MUST NOT redefine domain semantics, KPI rules, budget semantics, approval rules, or state ownership.

## 8.3 Database Agent

The Database Agent owns schema design within the approved model, migrations, constraints, and database tests for its assigned phase.

Schema changes MUST be represented in:

```text
supabase/migrations/
```

Direct schema mutation through an interactive SQL tool MUST NOT become the only source of a schema change.

## 8.4 n8n Workflow Agent

The n8n Workflow Agent creates or updates workflows through the approved n8n MCP access.

It MUST export/version-control material workflow changes in the repository.

It MUST NOT treat the live n8n server as the only copy of a workflow.

## 8.5 Test Agent

The Test Agent independently derives test cases from the Contract and subsystem specifications.

It MUST NOT merely test the happy path produced by the builder.

It SHOULD actively test:

- boundary values;
- invalid states;
- concurrency;
- duplicate triggers;
- budget exhaustion;
- provider failure;
- unknown external outcomes;
- stale/asynchronous results;
- regression behavior.

## 8.6 Review Agent

The Review Agent MUST assume the implementation may be wrong.

It reviews against:

```text
CONTRACT.md
PLAN.md
relevant subsystem specification
implementation diff
tests
failure behavior
state ownership
idempotency
observability
security and data handling
```

It returns concrete findings, not generic praise.

The Review Agent SHOULD be independent from the agent that wrote the implementation.

## 8.7 Fix Agent

The Fix Agent receives concrete failed tests or review findings and fixes them without weakening requirements.

After a fix, relevant tests MUST be rerun.

## 8.8 Contract Verification Agent

Before a phase is accepted, a final verification agent compares the implementation and evidence directly against the applicable Contract clauses and phase acceptance criteria.

It MUST report unmet criteria explicitly.

---

# 9. Parallelism Rules

Sub-agents MAY work in parallel only when their write scopes do not conflict.

Examples of safe parallelism:

```text
Rust implementation     || read-only review of existing migrations
fixture creation        || documentation inspection
database tests          || provider mock tests
```

Two write-capable agents MUST NOT simultaneously edit the same file or tightly coupled state without explicit coordination.

Review and Test agents SHOULD normally be read-only until their findings are handed to a Fix Agent.

The Orchestrator remains responsible for integration consistency.

---

# 10. Autonomous Phase Loop

For each phase:

```text
Read applicable requirements
        ↓
Inspect current implementation
        ↓
Define phase task map
        ↓
Delegate implementation
        ↓
Run tests
        ↓
Failures?
   ├── YES → Fix Agent → rerun tests
   └── NO
        ↓
Independent Review Agent
        ↓
Findings?
   ├── YES → Fix Agent → tests → review as needed
   └── NO
        ↓
Contract Verification Agent
        ↓
Acceptance gap?
   ├── YES → implement/fix → verify again
   └── NO
        ↓
Regression suite
        ↓
Create local commit
        ↓
Proceed to next phase
```

The agent MUST continue this loop autonomously for resolvable engineering issues.

Routine coding/test/review failures are not reasons to ask the human operator for debugging help.

---

# 11. Supabase Development Policy

The approved development Supabase project is:

```text
linkedin_automation
```

The Agent MUST treat it as the only write-enabled Supabase project for this implementation unless the human explicitly approves another project.

The agent MUST NOT create, delete, or modify unrelated Supabase projects or account-level resources.

## 11.1 Preferred Access

Use Supabase MCP when available in the current agent runtime.

The Agent MAY use Supabase MCP for:

- inspecting the development schema;
- applying repository migrations;
- executing controlled development queries;
- checking logs/advisors when available;
- validating migration results.

## 11.2 Migration Discipline

The repository migration history is canonical for schema reproduction.

Preferred sequence:

```text
write migration locally
→ review migration
→ apply to development project through approved Supabase access
→ run database tests
→ inspect resulting schema
→ commit migration
```

Do not make an undocumented schema change in Supabase and then attempt to reconstruct it later.

## 11.3 Missing Supabase MCP

If the implementation runtime cannot access Supabase MCP:

- continue writing migrations and database tests locally;
- do not substitute production credentials or scrape secrets from n8n;
- mark remote migration application as `ACCESS_PENDING`;
- continue unaffected phases where possible.

---

# 12. n8n Development Policy

The project uses an existing self-hosted n8n instance reachable through approved MCP access.

Existing credentials inside n8n include provider access for:

```text
Apify
OpenRouter
OpenAI
Supabase
```

These credentials are runtime capabilities, not source files.

## 12.1 Secret Isolation

The Agent MUST NOT:

- export provider secrets into the repository;
- print secrets into logs;
- copy secrets into prompts;
- create plaintext secret files;
- expose credential values to unrelated sub-agents;
- move n8n secrets into Supabase business tables.

The Agent should reference existing n8n credential bindings without retrieving secret values.

## 12.2 Workflow Namespacing

New project workflows SHOULD use an unambiguous project namespace/prefix, for example:

```text
linkedin_automation / connection / 01_campaign_runner
linkedin_automation / connection / 02_search_budget_check
linkedin_automation / content / 01_story_discovery
```

The exact n8n naming syntax may adapt to server capabilities, but the workflows MUST be clearly distinguishable from unrelated workflows on the shared n8n instance.

## 12.3 Workflow Activation

New or materially changed workflows MUST start inactive unless activation is explicitly required for a controlled validation.

The Agent MUST NOT create uncontrolled schedules that immediately begin making paid provider calls, sending LinkedIn actions, or publishing content.

Routine testing SHOULD use manual/test execution.

## 12.4 Repository Export

Every material accepted n8n workflow MUST have a version-controlled representation under:

```text
n8n/
```

A workflow that exists only on the server is incomplete.

---

# 13. Provider Execution Modes

External provider usage must be safe for autonomous development.

The implementation SHOULD support three conceptual modes:

```text
MOCK
TEST
LIVE
```

Exact configuration storage is implementation-defined as long as it is explicit, testable, and not hardcoded into business semantics.

## 13.1 MOCK

Default automated-test mode.

Use deterministic fixtures/mocks.

No paid provider call should occur.

Examples:

```text
MockSearchProvider
MockProfileEvaluator
MockContactEnrichmentProvider
MockContentGenerator
MockMediaGenerator
MockContentPublisher
MockConnectionSender
```

## 13.2 TEST

Controlled real-provider validation.

TEST mode MAY call real providers only when all required cost guards are active.

## 13.3 LIVE

Operational real-world execution.

LIVE mode is not automatically authorized merely because implementation is complete.

Real LinkedIn side effects and content publication remain subject to their human/live-validation gates.

---

# 14. Paid Provider Safety

Autonomous development MUST default to zero authorized external spend.

If no explicit development/test provider budget is configured:

```text
allowed live/test external cost = 0
```

The Agent MUST use mocks instead of real paid calls.

A real paid integration test is allowed only when an explicit non-zero test budget has been configured by the human/operator or approved environment configuration.

## 14.1 Test Budget Guard

Before the first paid provider test, the implementation MUST have an environment-level test-spend guard in addition to campaign budgets.

Conceptually:

```text
effective_allowed_cost
=
minimum(
  campaign/revision remaining budget,
  environment test-spend remaining budget,
  provider-side cap when supported
)
```

The exact implementation may vary.

The test-spend guard MUST default to zero or disabled.

The Agent MUST NOT invent a positive budget for itself.

## 14.2 Campaign Budgets Remain Runtime Configuration

Search/enrichment limits MUST remain configurable per `CampaignRevision`.

Examples include:

```text
max_unique_candidates
max_search_cost_usd
max_evaluation_cost_usd
max_email_enrichments
max_email_enrichment_cost_usd
max_total_campaign_cost_usd
target_qualified_profiles
```

These are runtime campaign configuration, not hardcoded constants.

The product must allow the human operator to create different campaigns with different limits later.

## 14.3 Provider Tests

Automated unit and integration tests SHOULD use mocks/fixtures.

Real Apify/OpenRouter/OpenAI calls are validation tests, not the default test suite.

A failing test suite MUST NOT repeatedly consume paid provider budget.

---

# 15. Search Provider Safety

The initial unattended search implementation is HarvestAPI/Apify behind `SearchProvider`.

The Agent MUST first validate logic with recorded/synthetic provider responses.

Before a real search test:

```text
[ ] TEST mode is explicit.
[ ] A positive test budget was explicitly configured.
[ ] max_unique_candidates is small.
[ ] campaign search budget is small.
[ ] environment test-spend cap is active.
[ ] provider-side cost cap is used when technically supported.
[ ] workflow is manually triggered, not scheduled.
```

If any required guard is missing, do not perform the paid search.

---

# 16. LLM Provider Safety

OpenRouter and OpenAI credentials already exist inside n8n.

The Agent SHOULD use mocks/fixtures for repeated automated tests.

Real LLM calls SHOULD be limited to small validation sets after prompt/schema behavior has already passed local/fixture validation.

Provider/model identity remains configuration and must be preserved in provenance records.

The Agent MUST NOT perform uncontrolled large prompt loops merely to search for a passing output.

---

# 17. LinkedIn and Browser Side Effects

The Agent is not assumed to have unrestricted LinkedIn credentials or session material.

Connection sending MUST be implemented behind `ConnectionSender` with a safe mock/dry-run path.

The Agent may fully implement and test:

- queueing;
- note persistence;
- idempotency;
- atomic claims;
- attempt history;
- error classification;
- unknown-result reconciliation logic;
- sender adapter contract;
- PowerShell invocation contract;
- dry-run behavior.

A real LinkedIn send is a controlled live-validation boundary.

If a real authorized account/session is not available, report:

```text
IMPLEMENTED — LIVE LINKEDIN VALIDATION PENDING
```

and continue unrelated work.

The Agent MUST NOT attempt to bypass account challenges, platform restrictions, authentication boundaries, or anti-abuse controls.

---

# 18. Authenticated LinkedIn Search Benchmark

The Contract requires an authenticated search comparison unless explicitly waived by an authorized human.

The Agent may implement all benchmark tooling and documentation without receiving the user's LinkedIn session.

If authenticated access is unavailable, it MUST preserve the benchmark gate as pending rather than silently removing it.

Allowed status:

```text
SEARCH IMPLEMENTED — AUTHENTICATED BENCHMARK PENDING
```

A human may later provide the authorized comparison result or record the Contract-defined waiver.

---

# 19. Content and Publishing Safety

Stream 2 implementation may use synthetic/redacted fixtures until real operator source material is available.

The Agent may implement:

- StoryProfile model;
- content generation pipeline;
- ContentAsset handling;
- AI review;
- human approval state;
- approval fingerprinting;
- publisher interface;
- publication idempotency;
- reconciliation;
- mocks and integration tests.

Real content publication requires the configured human approval and live publication access.

The Agent MUST NOT publish content merely to satisfy a test.

If publishing credentials/provider are not available yet:

```text
IMPLEMENTED — LIVE PUBLICATION VALIDATION PENDING
```

is valid.

---

# 20. Human Gates

The project is intentionally designed so most implementation can proceed without human interruption.

The Agent SHOULD batch human-dependent validation near phase boundaries instead of stopping for every small issue.

Expected human gates include:

- missing mandatory MCP/runtime access that cannot be worked around with local implementation;
- authorization of non-zero real provider test spend;
- real-profile KPI sanity validation;
- authenticated LinkedIn search benchmark or explicit waiver;
- real LinkedIn connection validation;
- operator-specific StoryProfile validation using actual source material;
- final human content approval;
- real content publication validation;
- product/architecture decisions explicitly classified as human decisions by the Contract.

All other ordinary implementation, debugging, testing, reviewing, and fixing SHOULD proceed autonomously.

---

# 21. Failure and Blocked-State Policy

The Agent MUST distinguish:

```text
IMPLEMENTATION FAILURE
ACCESS PENDING
LIVE VALIDATION PENDING
HUMAN DECISION REQUIRED
CONTRACT VIOLATION
```

Do not collapse every external limitation into a project-wide blocker.

When possible:

```text
finish implementation
→ finish mock/integration tests
→ commit the coherent implementation
→ record the precise external gate still pending
→ continue to another independent phase
```

However, a phase MUST NOT be falsely marked Contract-complete when its mandatory live/human acceptance gate remains pending.

---

# 22. Local Quality Gates

Before accepting a phase, run all relevant available checks.

For Rust, at minimum:

```bash
cargo fmt --check
cargo test
```

Use strict clippy when the repository/toolchain supports it:

```bash
cargo clippy -- -D warnings
```

Database changes MUST pass migration/integrity tests.

n8n workflow behavior MUST be exercised using safe test paths and exported to the repository.

Relevant regression tests MUST run before commit.

---

# 23. No Requirement Weakening

No agent or sub-agent may obtain a green result by:

- deleting valid tests;
- weakening assertions;
- changing the Contract;
- changing KPI meaning;
- relaxing budget limits;
- removing idempotency;
- removing human approval;
- converting a failed live validation into a fake mock success;
- fabricating provider responses as if they were live results;
- silently changing a MUST to optional behavior.

If a requirement appears incorrect, report it as a human decision rather than silently rewriting it.

---

# 24. Security Boundaries

The Agent MUST preserve least privilege.

Do not request or retrieve a secret merely because a tool technically makes that possible.

Prefer capability access over raw credential access.

Examples:

```text
GOOD:
n8n executes a workflow using its stored Apify credential.

BAD:
extract the Apify token from n8n and store it in .env.
```

```text
GOOD:
Supabase MCP applies an approved development migration.

BAD:
copy a service-role key into source control for convenience.
```

Personal-data rules in `CONTRACT.md` remain binding for profile data, contact information, CVs, and logs.

---

# 25. First Implementation Sequence

Unless the current repository already contains accepted implementation, begin with:

```text
Phase 0A
  Domain model
  Supabase migrations
  constraints
  state ownership
  provider interfaces
  database tests

Phase 0B
  runtime integration
  n8n connectivity
  Supabase connectivity
  first Rust invocation
  trace/failure persistence
  safe secret references

Phase 1.1
  KPI evaluator contract
  versioned prompt
  deterministic Rust scorer
  exact scoring tests
```

Do not jump directly into large n8n workflows before the durable domain model and deterministic scoring foundation exist.

Continue in the order defined by `PLAN.md` and `CONTRACT.md` unless a dependency requires a documented adjustment.

---

# 26. Phase Task Packet for Sub-Agents

Every delegated task SHOULD include:

```text
Phase:
Role:
Goal:
Files/components allowed to modify:
Files/components read-only:
Relevant Contract clauses:
Relevant Plan/Proposal/spec sections:
Required tests:
Forbidden decisions:
Expected output/evidence:
```

This prevents sub-agents from solving a narrow task by accidentally redesigning the system.

---

# 27. Review Packet

The independent Review Agent SHOULD receive:

```text
implementation diff
relevant tests and results
applicable Contract clauses
applicable domain spec
known limitations
```

Review questions should include:

```text
Does this preserve source-of-truth ownership?
Does this preserve state ownership?
Can duplicate execution cause duplicate side effects?
Can concurrency violate a hard budget?
Can stale asynchronous work overwrite newer decisions?
Can provider-specific fields leak into the domain?
Are external costs bounded?
Are errors observable and classified?
Are secrets or personal data exposed?
Can the implementation be reproduced from the repository?
Does a mock result masquerade as live validation?
```

---

# 28. Final README Deliverable

Before final project handoff, the Agent MUST create or update the root `README.md` so a technically capable human can understand, configure, test, and operate the implemented system without reconstructing the architecture from commit history.

The README MUST describe the implementation that actually exists at handoff time. It MUST NOT claim pending or mocked functionality is live.

At minimum, it SHOULD include:

```text
Project purpose and current scope
Architecture overview
Repository structure
Core runtime components
Prerequisites
Development/setup instructions
Supabase development-project setup and migration procedure
n8n workflow import/export and naming conventions
Required credential/capability names without secret values
Rust build/test commands
Relevant workflow/integration test commands
MOCK / TEST / LIVE execution modes
Provider-budget and test-spend safety model
Human approval/live-validation boundaries
How to configure CampaignRevision search/evaluation/enrichment budgets
Operational start/stop or manual-trigger guidance
Troubleshooting / known limitations
Documentation map pointing to MINDSET, PLAN, PROPOSAL, CONTRACT, and subsystem specs
Current implementation/validation status
```

The README MUST NOT contain:

- real API keys or tokens;
- Supabase service-role credentials;
- LinkedIn cookies/session material;
- n8n credential values;
- fabricated setup commands that were not verified when verification was possible;
- claims that live validations passed when they remain pending.

If setup requires a secret or environment value, document only the variable/capability name and how the human operator should configure it securely.

The README SHOULD prefer reproducible commands and concise operational examples over a long conceptual restatement of the architecture documents.

The final Contract/review pass MUST verify that `README.md` matches the actual implementation and that `.gitignore` protects local/generated/secret material without hiding required source artifacts.

---

# 29. Final Handoff

The Agent MUST NOT push to GitHub.

At handoff, the human operator receives a local repository containing the completed local commits.

The final report MUST include:

```text
Current branch
Commits created
Phases completed
Phases partially completed
Tests executed and results
Migrations applied to linkedin_automation
n8n workflows created/updated/exported
README.md created/updated and verified against the actual implementation
.gitignore created/updated and checked for secret/generated-file coverage
Real provider tests performed and actual recorded cost
Live validations performed
Live validations still pending
Human decisions still pending
Known limitations
Contract criteria not yet satisfied, if any
Suggested human verification before git push
```

If every applicable Contract requirement is actually satisfied, the Agent may report:

```text
DONE — CONTRACT SATISFIED
```

If not, it MUST use an accurate narrower status.

The human operator alone decides when to review and push the resulting commits to the remote Git repository.

---

# 29. Start Command to the Orchestrator

After reading this file and all governing documents, begin with the following behavior:

```text
1. Perform the access and repository preflight.
2. Inspect the current implementation state.
3. Map existing work against the Contract phases.
4. Select the earliest incomplete dependency-safe phase.
5. Create a phase task map.
6. Delegate focused implementation/testing/review work to sub-agents.
7. Run the autonomous implement → test → review → fix → verify loop.
8. Use mocks by default for external providers.
9. Do not spend real provider budget without an explicit non-zero test budget.
10. Keep new n8n workflows inactive unless controlled validation requires otherwise.
11. Apply schema changes only to the development Supabase project linkedin_automation.
12. Commit accepted coherent work locally using the user's existing Git identity.
13. Never push to GitHub.
14. Continue through resolvable work without requesting routine human debugging.
15. Stop only at genuine Contract-defined human/access/live-validation boundaries.
```
