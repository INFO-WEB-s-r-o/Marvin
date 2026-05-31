"""Single entry point for running one benchmark against the Brain.

The dispatch table and CLI route to one runner per benchmark. The Brain
transport (`brain_client.BrainClient`) is wired against the live REST API as
of Phase 2a. The scored runners themselves land one phase at a time
(see bench/PLAN.md); each currently-unimplemented runner raises
NotImplementedError with the phase that will fill it.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Callable

from .brain_client import BrainClient


RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"


def _run_longmemeval(client: BrainClient) -> dict:
    # Phase 2a wired the real BrainClient (REST) and the LongMemEval competitor
    # citations. Phase 2b is the scored Brain run itself, which is GATED: it
    # ingests the LongMemEval haystack and judges recalled evidence, incurring
    # OpenAI embedding spend (ingestion) + judge-model spend (scoring). Per the
    # honesty floor in PLAN.md ("nothing that needs a credit card without
    # explicit go-ahead"), this stays unimplemented until Pavel green-lights the
    # spend on #739 and the dataset is pinned.
    raise NotImplementedError(
        "phase 2b (gated): LongMemEval scored Brain run needs a pinned dataset "
        "and explicit go-ahead on embedding+judge API spend — see #739"
    )


def _run_locomo(client: BrainClient) -> dict:
    raise NotImplementedError("phase 3: LoCoMo Brain runner")


def _run_convomem(client: BrainClient) -> dict:
    raise NotImplementedError("phase 4: ConvoMem Brain runner")


def _run_memscore(client: BrainClient) -> dict:
    raise NotImplementedError("phase 5: MemScore Brain runner (derived from components)")


BENCHMARKS: dict[str, Callable[[BrainClient], dict]] = {
    "longmemeval": _run_longmemeval,
    "locomo": _run_locomo,
    "convomem": _run_convomem,
    "memscore": _run_memscore,
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run one memory benchmark against the Brain.")
    parser.add_argument("--benchmark", required=True, choices=sorted(BENCHMARKS.keys()))
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Where to write the result JSON. Defaults to bench/results/<benchmark>.json.",
    )
    args = parser.parse_args(argv)

    client = BrainClient()
    runner = BENCHMARKS[args.benchmark]
    try:
        result = runner(client)
    except NotImplementedError as exc:
        print(f"benchmark not yet implemented: {exc}", file=sys.stderr)
        return 2

    out = args.output or RESULTS_DIR / f"{args.benchmark}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
