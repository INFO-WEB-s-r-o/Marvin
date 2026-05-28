"""Single entry point for running one benchmark against the Brain.

Phase-1 scaffold: dispatch table and CLI exist; the per-benchmark
runners are stubs that raise NotImplementedError. They get bodies in
phases 2-5 (one phase per benchmark, see bench/PLAN.md).
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
    raise NotImplementedError("phase 2: LongMemEval Brain runner")


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
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
