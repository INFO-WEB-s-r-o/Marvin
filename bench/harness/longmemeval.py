"""LongMemEval scored run against the Brain — Phase 2b (see bench/PLAN.md, #739).

Pipeline per question (the honest, apples-to-apples QA-accuracy metric the
cited competitor numbers use — a memory system *plus* a reader, not raw recall):

    ingest haystack sessions -> recall(top_k) -> reader answers -> judge vs gold

Scoring follows the LongMemEval methodology:
  * normal questions  -> correct iff the judge rules the answer matches gold
  * abstention (`_abs`) questions -> correct iff the reader abstains
    ("I don't know"), since the evidence is deliberately absent.

Money boundary (the honesty floor in PLAN.md):
  * Ingestion embeds the haystack -> OpenAI **embedding** spend (inside the Brain).
  * Reader + judge are **Claude** calls -> judge/reader-model spend.
  * `--dry-run` / `estimate_cost()` touch NO paid API: they only size the work.
  The scored run is gated on explicit go-ahead (#739, granted 2026-06-04: "S").

Dataset is **hash-pinned, not fabricated**: the operator supplies the official
LongMemEval_S JSON via --dataset; we record its SHA-256 in the results so the
number is reproducible against an exact file. We never hardcode a download URL
we cannot verify — see load_dataset().
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .brain_client import BrainClient

# Canonical dataset, documented rather than auto-fetched. Pin the exact file
# you ran by recording its SHA-256 (we do, automatically, in the result JSON).
LONGMEMEVAL_SOURCE = (
    "LongMemEval (Wu et al., 2024). Obtain longmemeval_s.json from the official "
    "release and place it at bench/data/longmemeval_s.json, then pass --dataset."
)
DEFAULT_DATASET = Path(__file__).resolve().parent.parent / "data" / "longmemeval_s.json"

# Defaults are recorded verbatim into the result JSON so a number is never
# decoupled from the models that produced it (PLAN.md §"Brain runs").
DEFAULT_READER_MODEL = "claude-haiku-4-5-20251001"
DEFAULT_JUDGE_MODEL = "claude-haiku-4-5-20251001"

_ABSTAIN_MARKER = "i don't know"
_REQUIRED_FIELDS = ("question_id", "question", "answer", "haystack_sessions")
# question_id is interpolated into a Brain container tag (lme_s/<qid>), so it is
# a path-shaped value crossing a trust boundary. A crafted id like
# "../../marvin/production" would otherwise let a malicious/corrupt dataset
# target real Brain containers during ingest/recall/cleanup. Validate at load
# time and fail loud — never silently rewrite ids, or two distinct ids could
# collapse into the same container. (#765)
_SAFE_QID = re.compile(r"[A-Za-z0-9_\-]+")


class DatasetError(RuntimeError):
    """The LongMemEval dataset is missing or malformed."""


@dataclass(frozen=True)
class RunConfig:
    dataset: Path = DEFAULT_DATASET
    limit: int | None = None          # cap questions (smoke / cost control)
    top_k: int = 10                   # recalled items fed to the reader
    container_prefix: str = "lme_s/"  # isolated, purgeable Brain containers
    reader_model: str = DEFAULT_READER_MODEL
    judge_model: str = DEFAULT_JUDGE_MODEL
    cleanup: bool = True              # forget ingested thoughts after each Q
    dry_run: bool = False             # size the work, spend nothing


# --- dataset -------------------------------------------------------------

def load_dataset(path: Path) -> tuple[list[dict[str, Any]], str]:
    """Return (questions, sha256). Validates the LongMemEval schema."""
    if not path.exists():
        raise DatasetError(
            f"dataset not found: {path}\n{LONGMEMEVAL_SOURCE}"
        )
    raw = path.read_bytes()
    sha256 = hashlib.sha256(raw).hexdigest()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DatasetError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(data, list) or not data:
        raise DatasetError(f"{path}: expected a non-empty JSON array of questions")
    for i, q in enumerate(data):
        missing = [f for f in _REQUIRED_FIELDS if f not in q]
        if missing:
            raise DatasetError(f"{path}: question {i} missing fields {missing}")
        qid = str(q["question_id"])
        if not _SAFE_QID.fullmatch(qid):
            raise DatasetError(
                f"{path}: question {i} has unsafe question_id {qid!r}; "
                "expected only [A-Za-z0-9_-] (it becomes a Brain container tag)"
            )
    return data, sha256


def _is_abstention(question: dict[str, Any]) -> bool:
    return str(question.get("question_id", "")).endswith("_abs")


def _turn_texts(question: dict[str, Any]) -> list[str]:
    """Flatten haystack sessions into ('role: content') strings to ingest."""
    texts: list[str] = []
    for session in question.get("haystack_sessions", []):
        for turn in session or []:
            content = turn.get("content") if isinstance(turn, dict) else None
            if not content:
                continue
            role = turn.get("role", "user")
            texts.append(f"{role}: {content}")
    return texts


# --- cost estimation (no paid calls) -------------------------------------

def _approx_tokens(text: str) -> int:
    # Deliberately tokenizer-free (no tiktoken dep): ~4 chars/token. Documented
    # as approximate; good enough to size spend to the right order of magnitude.
    return max(1, len(text) // 4)


def estimate_cost(questions: list[dict[str, Any]], cfg: RunConfig) -> dict[str, Any]:
    """Order-of-magnitude spend estimate. Touches no API."""
    qs = questions[: cfg.limit] if cfg.limit else questions
    ingest_tokens = sum(_approx_tokens(t) for q in qs for t in _turn_texts(q))
    # Reader sees recalled context (bounded by top_k); judge sees a short rubric.
    reader_in = sum(
        _approx_tokens(q["question"]) + cfg.top_k * 200 for q in qs
    )
    judge_in = sum(_approx_tokens(q["question"]) + 300 for q in qs)
    return {
        "questions": len(qs),
        "approx_embedding_tokens": ingest_tokens,
        "approx_reader_input_tokens": reader_in,
        "approx_judge_input_tokens": judge_in,
        "note": (
            "Approximate (4 chars/token, no tiktoken). Dollar cost depends on the "
            "embedding model the Brain uses and the reader/judge model IDs above; "
            "multiply token counts by the live per-token rates to get $."
        ),
    }


# --- reader + judge (Claude) ---------------------------------------------

def _anthropic_client():
    try:
        import anthropic  # noqa: imported lazily so dry-run needs no SDK/key
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "anthropic SDK not installed; needed for the scored (non-dry) run"
        ) from exc
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise RuntimeError("ANTHROPIC_API_KEY not set; source it before a scored run")
    return anthropic.Anthropic()


def _read_answer(client, model: str, question: str, evidence: list[str]) -> str:
    context = "\n".join(f"- {e}" for e in evidence) or "(no relevant memory found)"
    prompt = (
        "Answer the question using ONLY the recalled memory below. If the memory "
        f"does not contain the answer, reply exactly \"{_ABSTAIN_MARKER}\".\n\n"
        f"Recalled memory:\n{context}\n\nQuestion: {question}\nAnswer:"
    )
    resp = client.messages.create(
        model=model, max_tokens=256,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.content[0].text.strip()


def _judge_correct(client, model: str, question: str, gold: str, answer: str) -> bool:
    prompt = (
        "You are grading a question-answering system. Reply with exactly CORRECT "
        "or INCORRECT.\n\n"
        f"Question: {question}\nReference answer: {gold}\nSystem answer: {answer}\n\n"
        "The system answer is CORRECT if it conveys the same factual information as "
        "the reference answer (wording may differ). Otherwise INCORRECT."
    )
    resp = client.messages.create(
        model=model, max_tokens=8,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.content[0].text.strip().upper().startswith("CORRECT")


# --- main run ------------------------------------------------------------

def run(client: BrainClient | None, cfg: RunConfig) -> dict[str, Any]:
    questions, sha256 = load_dataset(cfg.dataset)
    if cfg.limit:
        questions = questions[: cfg.limit]

    meta = {
        "benchmark": "longmemeval",
        "split": "S",
        "dataset_path": str(cfg.dataset),
        "dataset_sha256": sha256,
        "dataset_source": LONGMEMEVAL_SOURCE,
        "top_k": cfg.top_k,
        "reader_model": cfg.reader_model,
        "judge_model": cfg.judge_model,
        "n_questions": len(questions),
    }

    if cfg.dry_run:
        return {**meta, "dry_run": True, "estimate": estimate_cost(questions, cfg),
                "aggregate_score": None, "per_question": []}

    # A dry run returns above without a client; a scored run requires one. Fail
    # loud here rather than as an opaque AttributeError mid-ingest. (#764)
    if client is None:
        raise ValueError("a scored (non-dry-run) longmemeval run requires a BrainClient")

    llm = _anthropic_client()
    per_question: list[dict[str, Any]] = []
    correct = 0

    for q in questions:
        qid = q["question_id"]
        tag = f"{cfg.container_prefix}{qid}"
        abstain = _is_abstention(q)
        ingested_ids: list[str] = []

        # 1. ingest this question's haystack into an isolated, purgeable container
        for text in _turn_texts(q):
            res = client.record_thought(text, container_tag=tag)
            tid = res.get("id") or res.get("thought", {}).get("id")
            if tid:
                ingested_ids.append(tid)

        # 2. recall, 3. read, 4. judge
        recalled = client.recall(q["question"], top_k=cfg.top_k, container_tag=tag)
        evidence = [t.get("content", "") for t in recalled.get("thoughts", [])]
        answer = _read_answer(llm, cfg.reader_model, q["question"], evidence)

        if abstain:
            is_correct = _ABSTAIN_MARKER in answer.lower()
        else:
            is_correct = _judge_correct(llm, cfg.judge_model, q["question"], q["answer"], answer)
        correct += int(is_correct)

        per_question.append({
            "question_id": qid,
            "question_type": q.get("question_type"),
            "abstention": abstain,
            "answer": answer,
            "gold": q["answer"],
            "correct": is_correct,
            "n_evidence": len(evidence),
        })

        # 5. cleanup so the benchmark never pollutes Marvin's real memory
        if cfg.cleanup:
            for tid in ingested_ids:
                try:
                    client.forget_thought(tid, reason="longmemeval cleanup")
                except Exception:  # noqa: best-effort purge; never fail the run on cleanup
                    pass

    return {
        **meta,
        "dry_run": False,
        "aggregate_score": correct / len(questions) if questions else None,
        "n_correct": correct,
        "per_question": per_question,
    }
