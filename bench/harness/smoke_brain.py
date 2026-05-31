"""Connectivity smoke for the Brain REST client (Phase 2).

Proves the benchmark harness can actually reach the Brain and round-trip a
write -> recall through `BrainClient`, before any benchmark spends real money
on embeddings or a judge model. It also confirms the dedup/weight-bump
behaviour the Brain promises (recording the same thought twice bumps weight
instead of inserting a duplicate).

Everything it writes is tagged `bench-smoke` so it is trivially
distinguishable from real memory. Run:

    set -a && source ~/git/Marvin-Brain/.env && set +a
    python3 -m bench.harness.smoke_brain

Exits non-zero on the first failed assertion.
"""

from __future__ import annotations

import sys
import time
from typing import NoReturn

from .brain_client import BrainClient, BrainConfigError

CONTAINER = "bench-smoke"


def _fail(msg: str) -> NoReturn:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    try:
        client = BrainClient()
    except BrainConfigError as exc:
        _fail(str(exc))

    # 1. health
    health = client.health()
    if health.get("status") != "ok":
        _fail(f"health not ok: {health}")
    print(f"ok  health: {health}")

    # A sentence unique to this run so recall can't match stale data.
    marker = f"smoke-{int(time.time())}"
    sentence = (
        f"The benchmark harness connectivity marker for #739 is {marker}; "
        "Marvin's Brain stores thoughts and recalls them by meaning."
    )

    # 2. record_thought
    first = client.record_thought(sentence, container_tag=CONTAINER)
    if "id" not in first:
        _fail(f"record_thought returned no id: {first}")
    print(f"ok  record_thought: {first}")

    # 3. record the SAME sentence again -> should bump weight, not duplicate
    second = client.record_thought(sentence, container_tag=CONTAINER)
    if second.get("id") != first.get("id"):
        _fail(f"duplicate sentence created a new thought: {first} vs {second}")
    print(f"ok  dedup (same id, weight/mentions bumped): {second}")

    # 4. recall a paraphrase -> the marker thought should come back ranked
    paraphrase = f"What is the connectivity marker value {marker} for the benchmark harness?"
    result = client.recall(paraphrase, top_k=5, kinds=["thoughts"])
    thoughts = result.get("thoughts", [])
    ids = [t.get("id") for t in thoughts]
    if first["id"] not in ids:
        _fail(
            f"recall did not return the recorded thought.\n"
            f"  looking for: {first['id']}\n  got: {ids}"
        )
    rank = ids.index(first["id"]) + 1
    print(f"ok  recall: marker thought returned at rank {rank}/{len(ids)}")

    print("\nPASS: Brain REST round-trip (write -> dedup -> recall) verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
