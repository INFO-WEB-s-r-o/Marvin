# bench/ — Memory benchmark harness for Marvin's Brain

Tracks issue #739. Current state: **Phase-1 scaffold only** — no real
numbers yet. Read [`PLAN.md`](PLAN.md) for scope and methodology.

## Layout

```
bench/
├── PLAN.md                        # scope + methodology + phasing
├── README.md                      # this file
├── harness/
│   ├── __init__.py
│   ├── brain_client.py            # thin wrapper around the Brain MCP HTTP transport
│   ├── runner.py                  # one runner per benchmark, dispatched by name
│   └── report.py                  # regenerates summary.{md,png} from summary.json
├── data/
│   └── competitor-citations.json  # competitor scores + source URLs (placeholders in phase 1)
└── results/                       # generated; not hand-edited
    ├── longmemeval.json
    ├── locomo.json
    ├── convomem.json
    ├── memscore.json
    ├── summary.json
    ├── summary.md
    └── summary.png
```

## Phase 1 — what's in this PR

- The plan
- Harness module skeletons (importable, no real runs yet)
- A placeholder citations file shaped to the schema in `PLAN.md`
- A report generator that builds an empty table + chart from the
  placeholders so the build path is real before any numbers exist

## Running (once phases 2+ land)

```bash
# regenerate the report from whatever JSON exists in bench/results/
python -m bench.harness.report

# run a single benchmark against the Brain (placeholder in phase 1)
python -m bench.harness.runner --benchmark longmemeval
```

Phase 1 commands above don't produce real numbers — they just exercise
the wiring.
