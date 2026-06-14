#!/usr/bin/env python3
# =============================================================================
# Marvin — Performance Analytics (percentile statistics)
# =============================================================================
# A data-engineering companion to weekly-analytics.sh. Where the bash/jq
# pipeline reports *averages* of Claude API duration and counts, this script
# computes the distribution statistics that averages hide: p50/p95/p99
# latency, per-task throughput, and network-latency percentiles.
#
# Percentiles are awkward in jq but trivial in Python's statistics module,
# which is exactly why this is the project's first real cron-wired Python
# data-processing script (POSSIBLE_ENHANCEMENTS.md, Phase 4 "New Capabilities").
#
# Pure stdlib — no third-party dependencies, so it runs anywhere python3 does.
#
# Inputs  (read-only):
#   <metrics-dir>/claude-usage-YYYY-MM-DD.jsonl   (per Claude run)
#   <metrics-dir>/latency-YYYY-MM-DD.jsonl        (per latency probe)
#
# Outputs:
#   <out-dir>/perf-analytics-<END>.json
#   <out-dir>/perf-analytics-latest.json
#
# Usage:
#   perf-analytics.py [--end YYYY-MM-DD] [--days N]
#                     [--metrics-dir DIR] [--out-dir DIR] [--stdout]
#
# Defaults mirror weekly-analytics.sh: a 7-day window ending yesterday.
# =============================================================================

import argparse
import datetime as dt
import json
import os
import sys


def _eprint(*args):
    """Log to stderr so stdout stays clean for --stdout JSON consumers."""
    print(*args, file=sys.stderr)


def date_range(end_date, days):
    """Return the list of YYYY-MM-DD strings in the inclusive window."""
    return [
        (end_date - dt.timedelta(days=offset)).isoformat()
        for offset in range(days - 1, -1, -1)
    ]


def read_jsonl(path):
    """Yield parsed objects from a JSONL file, skipping malformed lines.

    Metric files are append-only and a crash can leave a half-written final
    line; one bad line must never sink the whole analysis."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        return


def percentile(values, pct):
    """Nearest-rank percentile (no interpolation) over a numeric list.

    Nearest-rank is deliberate: it always returns an actually-observed
    sample, which is the honest thing to report for small daily-cron
    datasets where interpolation would invent values."""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return round(float(ordered[0]), 3)
    # Rank in [1, n]; ceil(pct/100 * n), clamped.
    rank = -(-pct * len(ordered) // 100)  # ceil division
    rank = max(1, min(rank, len(ordered)))
    return round(float(ordered[rank - 1]), 3)


def stats_block(values):
    """Summary statistics for a numeric series."""
    nums = [v for v in values if isinstance(v, (int, float))]
    if not nums:
        return {"count": 0}
    total = sum(nums)
    return {
        "count": len(nums),
        "min": round(float(min(nums)), 3),
        "max": round(float(max(nums)), 3),
        "mean": round(total / len(nums), 3),
        "p50": percentile(nums, 50),
        "p95": percentile(nums, 95),
        "p99": percentile(nums, 99),
    }


def analyze_claude(records):
    """Per-task and overall distribution stats for Claude runs."""
    by_task = {}
    for rec in records:
        task = rec.get("task", "unknown")
        by_task.setdefault(task, []).append(rec)

    def task_summary(recs):
        durations = [r.get("duration_s") for r in recs if "duration_s" in r]
        out_chars = [r.get("output_chars") for r in recs if "output_chars" in r]
        errors = sum(1 for r in recs if r.get("exit_code", 0) != 0)
        total_dur = sum(d for d in durations if isinstance(d, (int, float)))
        total_out = sum(c for c in out_chars if isinstance(c, (int, float)))
        summary = {
            "runs": len(recs),
            "errors": errors,
            "error_rate_pct": round(errors / len(recs) * 100, 1) if recs else 0.0,
            "duration_s": stats_block(durations),
            "output_chars": stats_block(out_chars),
            # Throughput: output characters produced per second of wall time.
            # A useful signal for spotting tasks whose prompts have bloated.
            "output_chars_per_s": round(total_out / total_dur, 1) if total_dur > 0 else None,
        }
        return summary

    overall = task_summary(records) if records else {"runs": 0}
    tasks = {task: task_summary(recs) for task, recs in sorted(by_task.items())}
    # Surface the slowest tasks by p95 duration for quick triage.
    slowest = sorted(
        (
            (task, s["duration_s"].get("p95"))
            for task, s in tasks.items()
            if s["duration_s"].get("p95") is not None
        ),
        key=lambda kv: kv[1],
        reverse=True,
    )[:5]
    return {
        "overall": overall,
        "by_task": tasks,
        "slowest_tasks_by_p95_s": [
            {"task": t, "p95_s": p} for t, p in slowest
        ],
    }


def analyze_latency(records):
    """Percentile stats for each numeric latency field present."""
    fields = {}
    for rec in records:
        for key, val in rec.items():
            if key.endswith("_ms") and isinstance(val, (int, float)):
                fields.setdefault(key, []).append(val)
    return {key: stats_block(vals) for key, vals in sorted(fields.items())}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Marvin percentile performance analytics")
    parser.add_argument("--end", help="window end date YYYY-MM-DD (default: yesterday UTC)")
    parser.add_argument("--days", type=int, default=7, help="window length in days (default: 7)")
    parser.add_argument(
        "--metrics-dir",
        default=os.environ.get("METRICS_DIR", "data/metrics"),
        help="directory holding *-YYYY-MM-DD.jsonl metric files",
    )
    parser.add_argument(
        "--out-dir",
        help="output directory (default: same as --metrics-dir)",
    )
    parser.add_argument("--stdout", action="store_true", help="also print the JSON to stdout")
    args = parser.parse_args(argv)

    if args.days < 1:
        _eprint("ERROR: --days must be >= 1")
        return 2

    if args.end:
        try:
            end_date = dt.date.fromisoformat(args.end)
        except ValueError:
            _eprint(f"ERROR: invalid --end date: {args.end!r}")
            return 2
    else:
        end_date = dt.datetime.now(dt.timezone.utc).date() - dt.timedelta(days=1)

    metrics_dir = args.metrics_dir
    out_dir = args.out_dir or metrics_dir
    if not os.path.isdir(metrics_dir):
        _eprint(f"ERROR: metrics dir not found: {metrics_dir}")
        return 1

    days = date_range(end_date, args.days)
    start_date = days[0]

    claude_records = []
    latency_records = []
    for day in days:
        claude_records.extend(read_jsonl(os.path.join(metrics_dir, f"claude-usage-{day}.jsonl")))
        latency_records.extend(read_jsonl(os.path.join(metrics_dir, f"latency-{day}.jsonl")))

    result = {
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window": {"start": start_date, "end": end_date.isoformat(), "days": args.days},
        "claude_api": analyze_claude(claude_records),
        "network_latency_ms": analyze_latency(latency_records),
        "sample_counts": {
            "claude_runs": len(claude_records),
            "latency_probes": len(latency_records),
        },
    }

    payload = json.dumps(result, indent=2, sort_keys=False)

    os.makedirs(out_dir, exist_ok=True)
    dated = os.path.join(out_dir, f"perf-analytics-{end_date.isoformat()}.json")
    latest = os.path.join(out_dir, "perf-analytics-latest.json")
    for path in (dated, latest):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(payload + "\n")

    _eprint(
        f"perf-analytics: {len(claude_records)} Claude runs, "
        f"{len(latency_records)} latency probes over {start_date}..{end_date} "
        f"-> {dated}"
    )
    if args.stdout:
        print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
