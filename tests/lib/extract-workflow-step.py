#!/usr/bin/env python3
"""Extract a piece of a GitHub Actions workflow so it can be executed under test.

The point of this file is that the shell-syntax gate must be tested by running
*the gate*, not a copy of it. A reimplementation in the test would agree with
itself perfectly and would keep agreeing after the real gate regressed.

Extraction is anchored to the job id and the step's `name:` — both of which are
already load-bearing identifiers in the workflow — rather than to line numbers.
A `sed -n 'A,Bp'` harness goes stale the moment anyone adds a comment above the
block, and then prints a complete, plausible pass table from a truncated
fragment. Parsing the YAML cannot silently return the wrong region: the step is
found by name or it is not found at all.

Usage:
    extract-workflow-step.py <workflow.yml> <job-id> <step-name> run
    extract-workflow-step.py <workflow.yml> <job-id> --            timeout

Exits 2 with a message on stderr if the requested piece is absent. Every exit
path is loud; there is no "returned nothing, printed nothing, exited 0".
"""

import sys

import yaml


def die(msg):
    print(f"extract-workflow-step: {msg}", file=sys.stderr)
    sys.exit(2)


def main():
    if len(sys.argv) != 5:
        die(f"expected 4 arguments, got {len(sys.argv) - 1}")

    path, job_id, step_name, what = sys.argv[1:5]

    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        die(f"workflow not found: {path}")
    except yaml.YAMLError as exc:
        die(f"workflow is not valid YAML: {exc}")

    if not isinstance(doc, dict):
        die(f"workflow did not parse to a mapping: {path}")

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        die("workflow has no `jobs:` mapping")

    job = jobs.get(job_id)
    if not isinstance(job, dict):
        die(f"no job `{job_id}` (jobs present: {sorted(jobs)})")

    if what == "timeout":
        # Absent is reported as absent, not as some default. A test that reads a
        # missing `timeout-minutes` as "fine, 360 then" would pass on exactly the
        # defect it exists to catch.
        if "timeout-minutes" not in job:
            die(f"job `{job_id}` has no `timeout-minutes`")
        print(job["timeout-minutes"])
        return

    if what != "run":
        die(f"unknown extraction target `{what}` (expected `run` or `timeout`)")

    steps = job.get("steps")
    if not isinstance(steps, list):
        die(f"job `{job_id}` has no `steps:` list")

    matches = [s for s in steps if isinstance(s, dict) and s.get("name") == step_name]
    if not matches:
        names = [s.get("name") for s in steps if isinstance(s, dict)]
        die(f"no step named `{step_name}` in job `{job_id}` (steps: {names})")
    if len(matches) > 1:
        # Two steps with one name means the caller's anchor is ambiguous and the
        # test would be asserting against whichever happened to come first.
        die(f"{len(matches)} steps named `{step_name}` in job `{job_id}` — ambiguous anchor")

    run = matches[0].get("run")
    if not isinstance(run, str) or not run.strip():
        die(f"step `{step_name}` has no non-empty `run:` block")

    # No trailing newline fixups: the block is written out byte-for-byte as the
    # runner will execute it.
    sys.stdout.write(run)


if __name__ == "__main__":
    main()
