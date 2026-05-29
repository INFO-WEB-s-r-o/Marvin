"""Regenerate bench/results/summary.{json,md} (and later .png) from
whatever per-benchmark JSON files exist, plus the competitor citations.

Phase-1 scaffold: this works against placeholders. Running it on a
fresh checkout produces an honest "no scores yet" report — that is
the point. It proves the build path before any real numbers exist.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


BENCH_DIR = Path(__file__).resolve().parent.parent
RESULTS_DIR = BENCH_DIR / "results"
CITATIONS_PATH = BENCH_DIR / "data" / "competitor-citations.json"

BENCHMARKS = ("longmemeval", "locomo", "convomem", "memscore")


def _load_brain_score(benchmark: str) -> float | None:
    path = RESULTS_DIR / f"{benchmark}.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"warning: {path} is malformed — skipping ({exc})", file=sys.stderr)
        return None
    score = data.get("aggregate_score")
    return float(score) if isinstance(score, (int, float)) else None


def _load_citations() -> dict[str, Any]:
    if not CITATIONS_PATH.exists():
        return {}
    try:
        return json.loads(CITATIONS_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"warning: {CITATIONS_PATH} is malformed — returning empty citations ({exc})", file=sys.stderr)
        return {}


def build_summary() -> dict[str, Any]:
    citations = _load_citations()
    competitors = sorted(k for k in citations if not k.startswith("_"))

    rows: list[dict[str, Any]] = []
    for benchmark in BENCHMARKS:
        row: dict[str, Any] = {
            "benchmark": benchmark,
            "brain": _load_brain_score(benchmark),
            "competitors": {},
        }
        for competitor in competitors:
            cell = citations.get(competitor, {}).get(benchmark, {})
            row["competitors"][competitor] = {
                "score": cell.get("score"),
                "source_url": cell.get("source_url"),
                "retrieved_at": cell.get("retrieved_at"),
                "model": cell.get("model"),
                "dataset_version": cell.get("dataset_version"),
                "notes": cell.get("notes"),
            }
        rows.append(row)

    return {"benchmarks": rows, "competitors": competitors}


def render_markdown(summary: dict[str, Any]) -> str:
    competitors = summary["competitors"]
    header = ["Benchmark", "Brain", *competitors]
    sep = ["---"] * len(header)
    lines = ["# Memory benchmarks — summary (#739)", "", "_Regenerated from `bench/results/summary.json`. Do not edit by hand._", ""]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("| " + " | ".join(sep) + " |")
    for row in summary["benchmarks"]:
        cells = [row["benchmark"], _fmt(row["brain"])]
        for competitor in competitors:
            cells.append(_fmt(row["competitors"][competitor]["score"]))
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("`—` means no score recorded yet.")
    return "\n".join(lines) + "\n"


def _fmt(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:.3f}"


def main() -> int:
    summary = build_summary()
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    (RESULTS_DIR / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (RESULTS_DIR / "summary.md").write_text(render_markdown(summary), encoding="utf-8")
    print(f"wrote {RESULTS_DIR / 'summary.json'}")
    print(f"wrote {RESULTS_DIR / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
