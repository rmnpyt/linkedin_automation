# LinkedIn Automation System — Mindset

> This is the top-level document for the whole project. Any new session/sub-project
> (a CLI tool, an MCP server, an n8n flow) should start by reading this file to inherit
> the big picture before diving into its own narrow scope.
>
> Status: **living document, v0.1** — written from an early brainstorm. Sections marked
> 🟡 Open are not decided yet and should be revisited as we learn more.

---

## 1. Why this project exists

The core belief: **a network of the right people, nurtured with the right content, is the
asset** — everything else (finding a job, finding clients) is just a different exit off the
same road.

- **Job search** and **customer acquisition** are structurally the same problem: you need
  people who either refer you directly (a job, a project) or become a customer themselves.
  A "warm, relevant connection" is the unit of value in both cases.
- Content is how you become worth connecting to, and worth remembering. It's not
  volume-driven; it's positioning-driven — it should reflect *our* mindset/POV clearly
  enough that the right people self-select ("hook them"). **Personal branding is also a
  goal in its own right** for Content Automation, not just a means to warm up connections
  for a job/customer outcome — see the two personal use cases in section 4.
- Connections are not a numbers game. "Useful and purposeful" means every connection has
  a legible reason to exist (shared context, relevant role, a real interest) — this is a
  quality filter baked into the system from the start, not a moderation layer added later.
  This is now a defined, scored framework, not just a principle — see
  [doc/KPI-FRAMEWORK.md](KPI-FRAMEWORK.md): 6 weighted factors (field, location, role/seniority,
  topic match, network closeness, reachability) combine into one 0–100 score per profile,
  with hard filters and a freshness window (scores expire after 30 days).

## 2. The three streams

1. **Connection Automation** — find the right people, request/accept connections with a
   genuine reason, keep the relationship graph in a real data model (not just LinkedIn's
   own UI).
2. **Content Automation** — plan, draft, and publish content that expresses our mindset/POV
   consistently, so the network self-selects toward the kind of people we want to attract.
3. **Customer Automation** *(final goal, not in current scope)* — take warm connections and
   move them along a funnel from "in the network" → "engaged" → "active customer." Concrete
   mechanism as currently pictured: once potential customers are identified within the
   network, send them cold email to convert them into active customers. Not being designed
   in detail yet — streams 1–2 come first.

**Current focus is 1 and 2 only.** Stream 3 is the reason streams 1–2 exist, but it is
deliberately *not* being built yet — the data model and tooling for 1–2 should be designed
so stream 3 can plug in later without a rewrite, not so stream 3 is half-built now.

## 3. The one funnel, two exits

```
   Identify  →  Connect (purposeful)  →  Nurture (content that hooks)  →  Convert
                                                                          ├─ exit A: job referral
                                                                          └─ exit B: active customer
```

Both exits run through the *same* mechanism: identify the right person, connect for a real
reason, stay visible/relevant through content, and let the relationship mature into
something concrete. The system should model "a person in the network" once, and treat
"job lead" vs "customer lead" as a **label/state on that person**, not two parallel systems.

## 4. Current phase & scope

- **Not solo — a small founding team.** Right now there are two real people using the
  system, each on their own LinkedIn account, with two different personal goals:
  - **One teammate** — find a job. This is the live, dogfooded use case, not a demo.
  - **The other teammate** — build personal brand/authority through the same kind of
    connections and content. Not job-seeking — a standalone goal.
  Content Automation needs to serve both framings, not assume a single "job seeker" persona.
- **Audience today: the founding team's own accounts.** Not a public product yet — built
  for these two people's personal LinkedIn accounts, not a multi-tenant service.
- **Shape for tomorrow: general product.** Confirmed: the final goal is a system multiple
  users can run, but building for personal use first is the right call — it gets streams
  1–2 actually working without the extra weight of auth/billing/per-user isolation. Even so,
  the data model and architecture should avoid decisions that only make sense for exactly
  one user (e.g. don't hardcode "my" identity where a `person`/`account` row would do). We
  are not building multi-tenant auth/billing now — we are just not *blocking* it later.
- Stream 3 and multi-tenant are both deliberately deferred until streams 1–2 are working —
  not scheduled yet, see the open questions log.

## 5. Tech stack — roles

| Layer | Role in this project |
|---|---|
| **Rust** | CLI tools, reusable "tools", and MCP servers — the durable, compiled engine layer. Anything that's business logic used by more than one place, or that needs to be a stable interface other layers call. |
| **Supabase** | Single source of truth: people/profiles, connection state, content calendar, outreach/campaign state, funnel stage per person. Also the future home of auth if/when this becomes multi-tenant. |
| **n8n** | Orchestration/glue: sequencing steps, scheduling, webhooks, retries and branching. n8n calls out to the other layers (Rust tools/MCP, PowerShell, Claude, Apify) — it should not contain business logic itself, just the flow between tools. |
| **PowerShell** | Windows-native automation for actions that need a real logged-in browser/session and no official API/token exists. Concrete example already working: **connection-request sending** is a PowerShell script today. Use PowerShell where the win is "it already works on this machine," not as a general scripting layer. |
| **Authenticated browser agents (Claude in Chrome / Codex browser / future equivalent)** | High-fidelity, logged-in LinkedIn access for search-quality benchmarking, difficult campaigns, network-context checks, and future fallback/enrichment use. This capability is valuable because authenticated LinkedIn can expose user-specific search ordering and network context, but it is **not required for the initial unattended n8n execution path**. Keep it behind the same search-provider boundary as other implementations. |
| **Apify / HarvestAPI** | Initial unattended provider for LinkedIn profile discovery and contact enrichment because it can be invoked programmatically from n8n, produces structured results, and supports measurable cost/limits. Search and contact enrichment are separate capabilities even when HarvestAPI supplies both. Provider-specific behavior must remain behind replaceable interfaces. |
| **Python** | Lives *inside* n8n, not as a separate layer — when an n8n workflow needs custom logic that plain node config can't do (a small script step), write it in n8n's own Code/Python node. Python is n8n's scripting layer, not a standalone service. If a piece of Python logic gets reused across many workflows or needs to be fast/stable, that's the signal to graduate it into a Rust tool instead. |

### How to decide where new logic goes (working heuristic)
- Needs to be fast, reused, and stable → **Rust** (CLI/MCP).
- Just sequencing/calling other things, no real logic of its own → **n8n**.
- Needs a real Windows browser session and already has a working script → **PowerShell**.
- Needs judgment/interpretation on messy, unstructured input → **LLM / agent**, behind a versioned provider boundary.
- Needs unattended LinkedIn discovery or contact enrichment with bounded cost → **Apify / HarvestAPI** initially, behind replaceable provider interfaces.
- Needs logged-in LinkedIn context, personalized search quality, or network-context benchmarking → **authenticated browser agent**, used as a benchmark/fallback/high-fidelity provider rather than a required always-on dependency.
- Needs a small custom script step inside a workflow that plain n8n nodes can't do →
  **Python**, written directly in n8n's Code node. If that script logic starts getting
  reused across multiple workflows or needs to be fast/stable → graduate it to **Rust**.

This table is a first cut from real experience (the PowerShell connect script and
search-provider experiments), not a theoretical assignment — update it as more
streams get built.

### Search-provider strategy

LinkedIn profile discovery is provider-based. The initial unattended implementation uses
HarvestAPI through Apify because it can be orchestrated reliably from n8n and its cost can
be bounded per campaign. Search runs incrementally rather than as an unlimited one-shot job.

Authenticated LinkedIn browser search remains a separate high-fidelity capability. It is
used initially for benchmarking, difficult searches, fallback, and network-context checks.
It is not a mandatory dependency for the unattended n8n path.

The system must not permanently couple the domain model to either approach. Both belong
behind a replaceable `SearchProvider` boundary.

### Contact enrichment

Email discovery is separate from profile search. A `SearchProvider` finds candidate profiles;
a `ContactEnrichmentProvider` attempts to discover contact information for selected qualified
people. The initial implementation may use HarvestAPI for both capabilities, but the
interfaces remain independent so either provider can be replaced later.

Email is optional enrichment for Stream 1 and is **not required** to send a LinkedIn
connection request.

## 6. Repo structure convention

```
linkedin_automation/
├── doc/                  ← this file and other cross-cutting docs (architecture decisions, per-stream specs)
├── clitools/             ← Rust CLI tools
├── MCP/                  ← Rust MCP servers
├── n8n/                  ← exported n8n workflows + their docs
├── powershell/           ← Windows/browser automation integrations
└── supabase/migrations/  ← Supabase schema, in the Supabase CLI's own convention
```

Each sub-project (a CLI tool, an MCP server, an n8n flow's supporting code) is expected to
live in its own folder under the relevant directory above, and to use **Graphify**
(https://github.com/Graphify-Labs/graphify) as the standard way to make its own codebase
queryable — run `/graphify .` inside it once it has real code, rather than re-explaining
its structure by hand in docs. Graphify is registered globally for Claude Code (`graphify
install`), so this is available automatically in every future session on this project.

### Kinds of docs under `doc/`
- **This file (MINDSET.md)** — settled, cross-cutting decisions only. Stays clean.
- **Spec docs** (e.g. [KPI-FRAMEWORK.md](KPI-FRAMEWORK.md),
  [CONNECTION-FLOW.md](CONNECTION-FLOW.md), [CONTENT-FLOW.md](CONTENT-FLOW.md)) — a
  worked-out design for one specific piece of the system, detailed enough to build from.
  Early drafts can still carry their own 🟡 Open items until fully settled.
- **[RESEARCH-NOTES.md](RESEARCH-NOTES.md)** — the messy, dated log: raw research, tool
  comparisons, and proposals still being worked out. Once something here turns into a real
  decision, the decision moves into this file or its own spec doc; the reasoning trail stays
  in RESEARCH-NOTES.md.
- **[PLAN.md](PLAN.md)** — the build roadmap: phases, build order, and what's explicitly out
  of scope. Update it as phases complete or priorities change, so it stays the current plan
  rather than a snapshot of one planning session.

## 7. How future sessions should use this doc

- Other sessions building a specific CLI tool / MCP server / n8n flow should treat this
  file as **inherited context**, not something to re-derive from scratch.
- When a 🟡 Open item gets resolved in another session, that session should come back and
  update this file (or leave a note here to sync), so this stays the single current
  picture rather than drifting out of date.
- When a genuinely new cross-cutting decision gets made (a new tech boundary, a change to
  the funnel model, stream 3 kicking off), it belongs here, not buried in a sub-project's
  own README.

## 8. Open questions log

- ✅ ~~What defines "purposeful" precisely enough to encode as a rule/filter?~~ Resolved —
  see [doc/KPI-FRAMEWORK.md](KPI-FRAMEWORK.md).
- ✅ ~~Python's exact role~~ Resolved — Python lives inside n8n's Code node for custom
  script steps, not as its own standalone layer. See the tech stack table above.
- ✅ ~~Initial unattended search-provider direction~~ Resolved — HarvestAPI through Apify is
  the initial unattended implementation, while authenticated browser search remains a
  benchmark/fallback/high-fidelity provider. The interfaces stay replaceable; this is not a
  permanent winner-takes-all decision. See [doc/RESEARCH-NOTES.md](RESEARCH-NOTES.md) for the
  original actor research.
- 🟡 Stream 3 timing and design — deliberately deferred until streams 1–2 are working.
  Current rough shape: identify potential customers from the network, then convert them
  with cold email outreach. Still needs: what "activation" concretely means, and the actual
  cold-email flow/design.
- ✅ ~~Multi-tenant timing~~ Resolved for now — building personal-use-only first is the
  right sequencing call; multi-tenant stays the eventual goal but isn't being built yet
  (see section 4). Revisit once streams 1–2 are solid.
