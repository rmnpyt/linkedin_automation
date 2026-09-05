# Research Notes & Proposals

> Working doc: raw research, comparisons, and in-progress proposals that feed decisions
> into [MINDSET.md](MINDSET.md) and other spec docs. Unlike MINDSET.md, this is expected to
> be messy, dated, and superseded — treat entries as a log, not a settled reference.
> When something here graduates into a real decision, reflect the *decision* in MINDSET.md
> (or a dedicated spec doc) and leave the reasoning/data trail here.

---

## 2026-08-26 — Whiteboard session with teammate: context for Stream 3 targets

From a planning meeting (whiteboard photos), for whenever Stream 3 (Customer Automation)
starts: there are named client projects the team wants to eventually find customers for —
written on the board as **"mystronics", "mitra", "deluminator", "AS-runes"** (spelling
uncertain, read from handwriting — confirm exact names later). One of the KPI framework's
running examples ("professor in Quebec who works with animals") is a real target-customer
profile for one of these projects, not just a hypothetical.

Not actionable yet since Stream 3 is deliberately deferred — keeping this here so the
context isn't lost by the time Stream 3 actually starts.

---

## 2026-08-21 — Apify actor comparison: LinkedIn profile search

Context: comparing Apify actors against the already-tested Claude-in-Chrome approach for
the "profile search" step of Connection Automation (see [[tech-stack-boundaries]] in
project memory — free Apify actors previously tested were not good; paid actors untested
until now). Data pulled live from the Apify Store.

### Profile search / people-finder actors

| Actor | Price | Cookie needed? | Trust signal |
|---|---|---|---|
| `harvestapi/linkedin-profile-search` | $0.10 per search page (≤25 results) + $4/1k full profiles + $10/1k with email | No | 38k users, **4.34★ (92 ratings)** — most proven option |
| `harvestapi/linkedin-company-employees` | $0.003–0.012/profile + $0.02 start | No | 23k users, 4.56★ (42 ratings) — good if targeting by company |
| `thirdwatch/linkedin-candidate-finder-scraper` | ~$0.002/result, near-zero start | No | Cheapest by far, but only 102 users, unrated — worth a cheap test run, not a bet |
| `memo23/linkedin-people-search` | $0.005 start + $0.004/profile | Optional (better filters with cookie) | 1,109 users, unrated |
| `neuralverge/...-linkedin-people-search` | $0.10/page + $0.005/profile full | No | 328 users, unrated |
| `khadinakbar/linkedin-people-search-scraper` | $0.01/person + $0.02 enriched | No | 81 users, unrated, MCP-ready |
| `crawlerbros/linkedin-people-search-scraper` | $0.005 start + $0.005/result | **Required** | 31 users — needs your own LinkedIn cookie, i.e. account risk |
| `powerai/linkedin-peoples-search-scraper` | $0.01/result + $0.09 start | No | ⚠️ 1.0★ (6 ratings) — avoid |
| `silentflow/linkedin-profiles-companies-scraper-ppr` | $0.0037/result | Optional | ⚠️ 1.22★ (2 ratings) — avoid |

### Sales Navigator variants
Need either your own SN seat/cookie or a flat per-search fee — generally pricier.
`bestscrapers` charges **$0.50 flat per search** + $0.01/result regardless of result count
(expensive for exploratory searching). `silentflow`'s SN scraper is cheaper per-result
($0.0095) but requires your own cookies.

### Read / recommendation (not yet decided — open item)
`harvestapi/linkedin-profile-search` is the only candidate with both a large user base and
a statistically meaningful rating — the one worth benchmarking head-to-head against
Claude-in-Chrome (same test queries, compare hit quality + cost per usable profile).
`thirdwatch` is worth a $1–2 throwaway test purely on price. Skip the two 1★ actors and the
cookie-required ones (those put the LinkedIn account at risk, undercutting the reason to
use Apify in the first place).

**Status: untested.** Decision on Apify go/no-go stays open in MINDSET.md until one of
these is actually run against real search queries.
