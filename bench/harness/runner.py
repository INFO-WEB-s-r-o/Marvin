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

from . import longmemeval
from .brain_client import BrainClient


RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"


def _run_longmemeval(client: BrainClient | None, cfg: longmemeval.RunConfig | None = None) -> dict:
    # Phase 2b: scored LongMemEval-S Brain run (go-ahead granted on #739,
    # 2026-06-04, split S). A real run SPENDS MONEY — embedding spend on haystack
    # ingestion + reader/judge-model spend on scoring — so the *default* is a
    # no-cost dry-run estimate; pass --execute to actually spend. See
    # bench/harness/longmemeval.py for the pipeline and the honesty floor.
    return longmemeval.run(client, cfg or longmemeval.RunConfig(dry_run=True))


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
    # LongMemEval-specific knobs. --execute is the explicit spend switch: without
    # it the run is a no-cost dry estimate, so cron/CI never spends by accident.
    parser.add_argument("--execute", action="store_true",
                        help="longmemeval: run the SCORED (paid) pipeline; default is a dry estimate")
    parser.add_argument("--dataset", type=Path, default=longmemeval.DEFAULT_DATASET,
                        help="longmemeval: path to longmemeval_s.json")
    parser.add_argument("--limit", type=int, default=None,
                        help="longmemeval: cap number of questions (smoke / cost control)")
    parser.add_argument("--top-k", type=int, default=10,
                        help="longmemeval: recalled items fed to the reader")
    args = parser.parse_args(argv)

    runner = BENCHMARKS[args.benchmark]
    try:
        if args.benchmark == "longmemeval":
            cfg = longmemeval.RunConfig(
                dataset=args.dataset, limit=args.limit, top_k=args.top_k,
                dry_run=not args.execute,
            )
            # A dry estimate touches no Brain endpoint, so it needs no API key —
            # don't force one just to size the work.
            client = None if cfg.dry_run else BrainClient()
            result = _run_longmemeval(client, cfg)
        else:
            result = runner(BrainClient())
    except NotImplementedError as exc:
        print(f"benchmark not yet implemented: {exc}", file=sys.stderr)
        return 2
    except longmemeval.DatasetError as exc:
        print(f"dataset error: {exc}", file=sys.stderr)
        return 3
    except longmemeval.BrainResponseError as exc:
        # Unexpected Brain API shape mid-run: aborted loudly so untrackable,
        # unpurgeable benchmark data can't silently accumulate. (#768)
        print(f"brain response error: {exc}", file=sys.stderr)
        return 4

    out = args.output or RESULTS_DIR / f"{args.benchmark}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
