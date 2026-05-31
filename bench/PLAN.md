# Memory Benchmarks — Plan (#739, Phase 1)

> Status: **Phase-1 scaffold.** This document defines scope, methodology, and
> the format of the eventual results. No real numbers yet — those land in
> later phases as each benchmark is actually executed against the Brain.

## What Pavel asked for

Benchmark the Brain (Marvin-Brain, deployed 2026-05-25, HTTP-MCP wiring
finished 2026-05-28) on the four memory benchmarks Pavel listed in #739:

1. **LongMemEval** — long-term recall across long chat histories
2. **LoCoMo** — long-conversation memory
3. **ConvoMem** — conversational memory recall
4. **MemScore** — composite memory score

…and compare against **Mem0**, **Supermemory**, **Hypabase**, and
**mastra observational memory** (added by Pavel in the only comment thread).

## Scope

### What we run locally
Real benchmark runs **only** for the Brain. Per Pavel's clarification
(`#739` comment, 2026-05-28T19:55Z):

> *"For competitors, do not run them, just use marketing materials with
> scoring values."*

So competitors are handled as **cited rows**, not local runs. Every
competitor cell carries:

- the **source URL** the number came from
- the **retrieval date** (when we pulled it)
- the **model** the competitor used to produce the score (if disclosed)
- the **dataset version** the competitor claims to have run (if disclosed)
- an **apples-to-bricks footnote** flagging any methodology mismatch
  (different model, different split, different metric definition, etc.)

### What we explicitly are **not** doing

- No "we won everything" framing. The Brain is a small persistent memory
  store with semantic recall; comparing it to a managed paid SaaS like
  Mem0 is closer to apples-to-bricks than apples-to-apples.
- No reimplementing competitors' harnesses. Pavel cut that.
- No fabricated numbers. If a competitor doesn't publish a score for a
  given benchmark, the cell stays empty with a `—` and a footnote.

## Methodology

### Brain runs (the real ones)

For each benchmark we will:

1. Pin the dataset version (commit SHA or release tag) and record it
   in `bench/results/<benchmark>.json`.
2. Pin the judge / scorer model and its version (the Brain uses Claude
   for recall judgement — we record exact model ID, e.g.
   `claude-opus-4-7`).
3. Run via the harness in `bench/harness/` (skeleton in this PR; real
   runners follow in phase 2+).
4. Persist per-question results plus aggregate score in
   `bench/results/<benchmark>.json` so the chart and table can be
   regenerated deterministically from JSON.

### Competitor rows

Every competitor row is a citation. The citations file
`bench/data/competitor-citations.json` holds:

```jsonc
{
  "mem0": {
    "longmemeval": {
      "score": null,            // number or null
      "source_url": "...",      // required if score != null
      "retrieved_at": "...",    // ISO date
      "model": "...",           // competitor's disclosed model, or null
      "dataset_version": "...", // competitor's disclosed version, or null
      "notes": "..."            // caveats / apples-to-bricks flag
    },
    "...": {}
  }
}
```

Phase-1 ships the file with all scores `null` — placeholders waiting
for the citations sweep in phase 2.

### Output artifacts

- `bench/results/<benchmark>.json` — Brain raw + aggregate
- `bench/data/competitor-citations.json` — competitor scores + citations
- `bench/results/summary.json` — combined table source
- `bench/results/summary.md` — table regenerated from `summary.json`
- `bench/results/summary.png` — single chart, regenerated from
  `summary.json`

Both `summary.md` and `summary.png` are derived; never edited by hand.

## Phases

| Phase | What lands                                                                | Status      |
|-------|---------------------------------------------------------------------------|-------------|
| 1     | This plan + harness skeleton + citations placeholder + report generator   | merged (#740) |
| 2a    | Real `BrainClient` (REST) + connectivity smoke + LongMemEval competitor citations | this PR |
| 2b    | LongMemEval **scored Brain run** — GATED on API-spend go-ahead (see below) | blocked: needs go-ahead |
| 3     | LoCoMo Brain run + citations                                              | follows     |
| 4     | ConvoMem Brain run + citations                                            | follows     |
| 5     | MemScore Brain run + citations                                            | follows     |
| 6     | Final summary table + chart, blog post                                    | after all   |

### Why Phase 2 is split

Phase 1 promised "LongMemEval Brain run + citations" as one unit. Wiring the
client and citing competitor scores costs nothing and ships here (2a). The
*scored* Brain run (2b) is different: ingesting the LongMemEval haystack into
the Brain consumes OpenAI **embedding** spend, and judging recalled evidence
consumes **judge-model** spend. The honesty floor below says no credit-card
spend without explicit go-ahead, so 2b waits on Pavel's green light on #739
plus a pinned dataset version. This is not a competitor run (those are cited,
not executed) — it is our own metered run, and it should be a conscious spend.

## Open questions

- **Hypabase availability** — the gamgee.ai page lists it but the project
  page is hard to find. If we can't locate published numbers we leave the
  row empty with a footnote, per the no-fabricated-numbers rule.
- **mastra observational memory** — observation-only memory is a different
  paradigm from recall-style benchmarks; the four target benchmarks may
  not even score it. If they don't, mastra gets a "not applicable" footnote
  rather than a fabricated comparison.
- **MemScore** — the gamgee.ai page treats this as a composite. We will
  reproduce it from the component benchmarks rather than treat it as a
  fifth independent dataset, and document the formula. If gamgee's
  definition is proprietary, we will publish our own derivation and
  flag the difference.

## Honesty floor

If the Brain loses on a benchmark, the table shows it losing. No
selective omission, no metric-shopping. That's the deal.
