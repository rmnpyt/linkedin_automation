# LinkedIn Connection KPI Framework

Goal: score any LinkedIn profile 0–100 to decide whether it's a "best connection" candidate for a given search goal (e.g., *tech person in Quebec*, *professor in Quebec working with animals*).

Each profile gets a score per KPI (0–100), combined into a weighted composite score.

---

## The 6 KPIs

### KPI 1 — Field / Industry Relevance (weight 25%)
How closely the person's professional domain matches the target field.

This is a quick, broad check — which "type" of job/field is this person in. We check this
from short, surface-level info only (title, headline, skills). It answers "is this the
right kind of person?", not "do they match our exact topic?" — that's KPI 4's job.

**Measured from:** headline, current job title, industry field, top skills.
**Scoring example (target = tech):**
- Current role clearly in target field (e.g., "Software Engineer"): 80–100
- Adjacent field (e.g., product manager at a tech company): 50–79
- Weak signal (tech mentioned only in skills): 20–49
- No match: 0

### KPI 2 — Location Match (weight 20%)
Geographic fit with the target region.

**Measured from:** profile location field.
**Scoring example (target = Quebec):**
- Located in target city/region (Montreal, Quebec City, Sherbrooke, Gatineau...): 100
- Same province but rural/unspecified ("Quebec, Canada"): 90
- Neighboring region with ties to Quebec (e.g., Ottawa, works remotely for a Quebec org): 40
- Elsewhere: 0

### KPI 3 — Role & Seniority Fit (weight 15%)
Whether the person holds the *type* of position the search targets.

**Measured from:** job title, current employer type, years in role.
**Scoring example (target = professor):**
- Full/Associate/Assistant Professor at a university: 90–100
- Adjunct, lecturer, postdoc: 60–89
- PhD student / researcher in the topic: 30–59
- Unrelated role: 0

### KPI 4 — Topical / Project Alignment (weight 20%)
Deep content match: does their actual work involve the specific topic (e.g., animals in research projects)?

Unlike KPI 1, this is a deep check — we read into the detailed text (About section, project
descriptions, publications), not just the headline. This is on purpose: a person's title
might say "Neuroscience Professor" with no mention of animals at all, but one of their
actual research projects involves working with mice. KPI 1 alone would miss this person
completely; KPI 4 is what catches it.

**Decided rule: any real, clear example is enough.** If even one project/paper clearly and
explicitly involves the target topic, that counts as a strong match — it does not need to
be their main focus or most of their work. A professor who works with mice in one out of
ten projects scores the same as a professor whose whole career is animal research, as long
as the match is real and explicit (not just a vague, related mention).

**Measured from:** About section, experience descriptions, publications, projects, courses taught.
**Scoring example (target = works with animals):**
- At least one publication/project explicitly about animals (even just one clear, real example — veterinary science, animal behavior, wildlife biology, lab work with animals like mice): 80–100
- Topic appears in about/experience text but not as a clear explicit project: 50–79
- Related field only (general biology, ecology), no direct animal mention: 20–49
- No mention: 0

### KPI 5 — Network Proximity (weight 10%)
How reachable the person is through the existing network — closer means higher connection-acceptance rates.

**Data limit:** seeing "2nd degree" or "5 people we both know" needs a real, logged-in view
of LinkedIn (like Claude-in-Chrome). A no-login tool (like most Apify actors) cannot see
this at all.

**Rule when this data is missing:** if we cannot measure KPI 5 for a profile (no login was
used to find it), leave it out of that profile's score completely — don't score it as 0.
A missing measurement is not the same as a bad one. See the Composite Score section below
for how the weights adjust when a KPI is missing.

**Measured from:** connection degree, mutual connections count, shared school/employer/groups.
**Scoring:**
- 1st degree (already connected — skip or use for intros): n/a
- 2nd degree with 5+ mutual connections: 90–100
- 2nd degree with 1–4 mutuals: 60–89
- 3rd degree but shared group/school: 30–59
- 3rd+ degree, no shared context: 0–29

### KPI 6 — Activity & Reachability (weight 10%)
Likelihood the person will actually see and accept the request.

**Seniority offset:** if KPI 3 (Role & Seniority) scores 80 or higher, do not let KPI 6 go
below 50. Important people (professors, executives, senior leaders) often don't post much,
but still see and accept connection requests just fine. Don't punish someone hard for being
quiet online when they're clearly a high-value, reachable target.

**Measured from:** recency of posts/comments/reactions, Open Profile status, profile completeness.
**Scoring:**
- Posted or engaged within last 30 days: 80–100
- Active within last 90 days: 50–79
- Active within last year: 20–49
- Dormant profile (no visible activity, sparse profile): 0–19 (or 50, if the seniority offset above applies)
- Bonus +10: Open Profile / Creator mode / contact info visible.

**Implementation rule:** the authoritative KPI 6 used in arithmetic remains capped at 100, and the seniority floor (`KPI 3 >= 80` → effective `KPI 6 >= 50`) must be enforced deterministically so model variation cannot violate it. Preserve the raw model judgment when a deterministic adjustment changes the effective score.

---

## Composite Score

```
Score = 0.25·KPI1 + 0.20·KPI2 + 0.15·KPI3 + 0.20·KPI4 + 0.10·KPI5 + 0.10·KPI6
```

**If a KPI is missing** (right now this only happens with KPI 5, see its "data limit" note
above): drop it from the formula and scale the remaining weights up so they still add up to
100%. Example — if KPI 5 is missing, the other five weights (25, 20, 15, 20, 10) get
multiplied by `100 / 90` so they add back up to 100, and the formula only uses those five.
Never treat a missing KPI as a 0.

**V1 missing-evidence boundary:** KPI 5 is the only KPI that may currently be omitted and reweighted. If there is not enough evidence to make a defensible judgment for KPI 1, 2, 3, 4, or 6, do not invent a score and do not silently reweight around it. Treat the evaluation as incomplete: first try to obtain better/current profile evidence when practical; otherwise route the candidate to manual review rather than qualifying it automatically.

**Calculation precision:** qualification decisions use the deterministic scorer's authoritative unrounded/fixed-precision composite value. Display rounding must never turn a below-threshold profile into a qualified one (or vice versa). A profile qualifies only when enabled hard filters pass **and** the authoritative composite meets the campaign threshold.

**Interpretation:**
| Score | Action |
|-------|--------|
| 80–100 | Priority target — send personalized request |
| 60–79 | Good target — send request with note |
| 40–59 | Backup list — revisit if pipeline is thin |
| < 40 | Skip |

**Hard filters (applied before scoring):** each campaign sets two switches —
`requireField` and `requireLocation` (both default to ON). When a switch is ON, any profile
scoring 0 on that KPI is removed before scoring runs. Turn `requireLocation` OFF for
remote-friendly searches where location shouldn't rule anyone out, and so on — these
switches are part of the campaign setup, not a fixed rule for every search.

## Scoring Freshness
Every score is saved together with the date it was made (`scored_at`). A saved score is
only trusted for **30 days** (a starting default — adjust once we see how fast profiles
actually change in practice). After 30 days, re-run the scoring on that profile before
using it to decide on new outreach — a person's job, location, or activity may have changed
since the last check.

## How This Gets Computed (implementation note)
The AI (LLM) should only do the judgment part: read the profile and produce the 6 KPI
scores plus a short reason for each one. The AI should **not** do the weighted-sum math
itself — that arithmetic should be done by regular code (per the project's tech-boundary
rule: stable, reusable logic belongs in Rust, not in an LLM call). This keeps the scoring
consistent and removes any risk of the AI making an arithmetic mistake.

## Evaluation Provenance (implementation requirement)
Each stored evaluation must preserve enough context to reproduce and explain the decision later.
At minimum, persist references/metadata for:

- the exact `CampaignRevision` used;
- the exact `ProfileSnapshot` evaluated;
- prompt version;
- KPI rubric version;
- model provider and model name;
- evaluation/output-contract version;
- deterministic scoring-engine version;
- effective weights after any missing-KPI normalization;
- hard-filter results;
- qualification threshold;
- evaluation timestamp.

A material change to campaign scoring rules should create a new CampaignRevision rather than
silently changing the meaning of historical evaluations. Re-evaluation should normally create a
new historical evaluation record instead of overwriting the previous result.

## Notes
- KPI 1 and KPI 4 now measure different things (broad field vs. specific topic — see their
  sections above), so they no longer need to be reweighted against each other to avoid
  double-counting. Weights can still be tuned per campaign, but only when the *goal itself*
  cares more about one than the other — not to fix overlap.
- KPI 5 and 6 don't define *who* fits — they predict *acceptance likelihood*. Keep them low-weight but never zero.
