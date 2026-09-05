# Content Automation — Flow

> Canonical stream specification. Content Automation expresses each operator's own story/POV,
> creates text and optional media, applies AI quality review plus mandatory human approval,
> publishes through a replaceable provider, and preserves the full lifecycle in Supabase.

## Goal

Produce and publish LinkedIn content that expresses an operator's mindset/POV clearly enough
to attract the right people and build personal brand in its own right, not merely as bait for
Connection Automation.

The system must support different operators and different narratives rather than hardcoding a
single job-seeker story.

## Content pillars

Initial pillars from the planning session:

- **General** — reshares of other people's content plus personal thoughts/takes.
- **Tech** — comparison/information content about specific tools relevant to the team's work.

These are starting categories, not a complete or permanent content strategy.

## Design principle: built for anyone's story, not hardcoded

The system must work for any operator's story and goals. The current operators have different
objectives, so Content Automation must use an explicit operator identity and StoryProfile rather
than assuming one narrative.

## Story / Mindset Discovery

Inputs:

- the operator's LinkedIn profile;
- CV;
- optional written personal story.

An AI step produces a structured, usable StoryProfile describing the operator's professional
angle, recurring themes, relevant experience, positioning, voice, and what they stand for.

The StoryProfile is versioned rather than destructively overwritten. A dedicated production
prompt remains an implementation deliverable.

## Content quality principle: attention management

Each piece should have one clear primary point and should hold the intended reader's attention.
Content should not exist simply to fill a calendar.

Quality review should consider clarity, specificity, fit with the StoryProfile, repetition,
generic language, and value to the intended audience.

## Inputs to generation

Content generation uses:

```text
StoryProfile
+
Relevant past content
+
Content objective
```

Past content is used to reduce repetition and maintain a consistent voice.

Initial output types:

- comment;
- post;
- post with image.

## Text and media are separate capabilities

A text draft is represented by `ContentDraft`.

Non-text media is represented by `ContentAsset`.

Initial asset type:

```text
image
```

Media generation sits behind a replaceable `MediaGenerator` interface. The exact image provider
is an implementation decision, not a core domain dependency.

Conceptual flow:

```text
Story / POV
+
Past Content
+
Objective
    ↓
Text Generation
    ↓
Optional Media Generation
    ↓
ContentDraft + ContentAssets
```

## Review gate

The review gate is settled as:

```text
Generated Draft + Assets
    ↓
AI Pre-filter
    ↓
Rework if required
    ↓
Human Final Approval
    ↓
Approved
```

The AI may flag, reject, or request rework. A rejected original draft may be regenerated or
converted to another format when appropriate.

**Human final approval is mandatory before publication. AI review cannot substitute for human approval.** Approval is bound to the exact text/assets being approved: record the human approver, approval time, and a deterministic fingerprint/version covering the body and asset identities/checksums. Any material edit invalidates the previous approval.

## Content state

Suggested lifecycle:

```text
GENERATED
    ↓
AI_REVIEWED
    ↓
NEEDS_REWORK ──→ regenerate/revise
    ↓
AWAITING_HUMAN_APPROVAL
    ↓
APPROVED
    ↓
PUBLISH_QUEUED
    ↓
PUBLISHED
```

Alternative terminal/error states may include:

```text
REJECTED
PUBLISH_FAILED
ARCHIVED
UNKNOWN_PUBLISH_RESULT
```

## Storage and source of truth

Supabase is the canonical source of truth for runtime content history, including:

- StoryProfiles;
- generated drafts;
- generated assets;
- AI reviews;
- human approval;
- final approved text/media;
- publication state;
- final publication metadata.

The repository stores source-controlled project artifacts such as:

- prompts;
- workflow exports;
- configuration;
- documentation;
- optional human-readable content exports.

The repository is **not** the canonical runtime publication database.

## Publishing

Publishing sits behind a replaceable `ContentPublisher` boundary.

The exact LinkedIn publishing mechanism remains intentionally open until the publishing phase is
reached. Potential implementations may include a suitable official API, browser automation, or a
future validated provider.

Generation, review, and approval must not depend on the selected publishing mechanism.

Duplicate-sensitive publication requires idempotency and attempt/reconciliation behavior similar
to connection sending. An ambiguous external result must not be blindly republished.

Immediately before publishing, the normal workflow verifies that the body/assets still match the human-approved fingerprint/version.

## Observability

Content executions participate in the common trace architecture using `trace_id` across relevant
WorkflowRun, generation, media, review, publication, and ProviderUsage records.

The system should be able to answer:

- which StoryProfile version produced the draft;
- which text/media provider and prompt/model version were used;
- what the AI review decided;
- who/what provided final approval state;
- what final version was published;
- whether a publish attempt failed or became ambiguous;
- what paid provider operations cost.

## Future performance feedback

The first implementation does not require a full analytics/optimization engine, but publication
records must allow future performance data to attach to the exact published item.

Long-term loop:

```text
Story / POV
    ↓
Content
    ↓
Publish
    ↓
Observe Performance
    ↓
Learn
    ↓
Improve Future Content
```

The objective is not superficial engagement maximization. The relevant question is whether the
content attracts or strengthens relationships with the people the operator actually cares about.

## Still open

- **Posting cadence/volume** — intentionally not fixed yet; likely configurable per operator.
- **Production Story Discovery prompt** — architecture settled, prompt still to be implemented
  and tested.
- **Publishing provider** — intentionally deferred until the publishing phase.
- **Media-generation provider** — interface is required, specific provider is not yet selected.

## End-to-end flow

```text
Operator source material
    ↓
Versioned StoryProfile
    ↓
Text generation
    ↓
Optional ContentAsset generation
    ↓
AI review
    ↓
Rework loop if required
    ↓
Human final approval
    ↓
ContentPublisher
    ↓
Supabase publication history
    ↓
Future performance feedback
```

## Verification

Content Automation is operational only after it demonstrates:

- distinct usable StoryProfiles for both current operators;
- content that reflects those different identities;
- use of past content to reduce repetition;
- text draft generation;
- optional image asset generation through a provider boundary;
- AI rejection/rework of weak drafts;
- mandatory human approval;
- duplicate-safe publishing;
- durable Supabase history;
- traceable provider/prompt/model metadata;
- ability to associate later performance data with the published item.
