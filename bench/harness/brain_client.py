"""Thin client over the Brain's REST API at 127.0.0.1:8787.

Phase 2: real implementation.

Phase 1 scaffolded this against the MCP HTTP transport (127.0.0.1:3100/mcp).
For batch benchmark traffic the REST API is the simpler, more robust surface:
plain request/response, no per-request MCP session handshake. It sits behind
the *same* security boundary (127.0.0.1-only, no public port) and the same
`BRAIN_API_KEY` bearer auth, so the transport swap costs nothing on security.

Endpoints used (see Marvin-Brain `src/api/routes/`):
  POST /v1/thoughts            {content, container_tag?, metadata?}
  POST /v1/facts               {statement, sources?, confidence?, parent_fact_id?}
  GET  /v1/recall?q=&k=&container_tag=&kinds=
  GET  /v1/thoughts/recent?limit=
  POST /v1/thoughts/:id/forget {reason}
  POST /v1/facts/:id/forget    {reason}
  GET  /health

The API key is read from the BRAIN_API_KEY environment variable and never
stored in this repo. Source it from Marvin-Brain/.env before running:
    set -a && source ~/git/Marvin-Brain/.env && set +a
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

import requests


DEFAULT_ENDPOINT = os.environ.get("BRAIN_API_URL", "http://127.0.0.1:8787")


class BrainConfigError(RuntimeError):
    """Raised when the client is not configured (e.g. missing API key)."""


@dataclass(frozen=True)
class BrainConfig:
    endpoint: str = DEFAULT_ENDPOINT
    api_key: str = field(default_factory=lambda: os.environ.get("BRAIN_API_KEY", ""))
    timeout_seconds: float = 30.0


class BrainClient:
    """REST client for the surface the benchmark runners need."""

    def __init__(self, config: BrainConfig | None = None) -> None:
        self._config = config or BrainConfig()
        if not self._config.api_key:
            raise BrainConfigError(
                "BRAIN_API_KEY is not set. Source it from Marvin-Brain/.env before "
                "running the harness — it never lives in this repo."
            )
        self._session = requests.Session()
        self._session.headers.update(
            {
                "Authorization": f"Bearer {self._config.api_key}",
                "Content-Type": "application/json",
            }
        )

    # -- transport ---------------------------------------------------------

    def _url(self, path: str) -> str:
        return f"{self._config.endpoint.rstrip('/')}{path}"

    @staticmethod
    def _decode(resp: requests.Response, path: str) -> Any:
        """Raise with context on HTTP errors and non-JSON bodies.

        A bare ``raise_for_status()`` + ``resp.json()`` loses the response body
        on 4xx/5xx (where the error message usually lives) and gives a contextless
        ``JSONDecodeError`` when the body is non-JSON (nginx 502, plain-text crash,
        truncated response). Both are painful to diagnose mid-benchmark, so we
        attach the path, status, and a body snippet. See issue #750.
        """
        try:
            resp.raise_for_status()
        except requests.HTTPError as exc:
            raise requests.HTTPError(f"{exc} — body: {resp.text[:300]}", response=resp) from exc
        try:
            return resp.json()
        except ValueError as exc:
            raise ValueError(
                f"Brain API returned non-JSON from {path} "
                f"(status {resp.status_code}): {resp.text[:300]}"
            ) from exc

    def _post(self, path: str, payload: dict[str, Any]) -> Any:
        resp = self._session.post(self._url(path), json=payload, timeout=self._config.timeout_seconds)
        return self._decode(resp, path)

    def _get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        resp = self._session.get(self._url(path), params=params, timeout=self._config.timeout_seconds)
        return self._decode(resp, path)

    # -- surface -----------------------------------------------------------

    def health(self) -> dict[str, Any]:
        return self._get("/health")

    def record_thought(
        self,
        content: str,
        *,
        container_tag: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"content": content}
        if container_tag is not None:
            payload["container_tag"] = container_tag
        if metadata is not None:
            payload["metadata"] = metadata
        return self._post("/v1/thoughts", payload)

    def record_fact(
        self,
        statement: str,
        *,
        sources: list[str] | None = None,
        confidence: float | None = None,
        parent_fact_id: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"statement": statement}
        if sources is not None:
            payload["sources"] = sources
        if confidence is not None:
            payload["confidence"] = confidence
        if parent_fact_id is not None:
            payload["parent_fact_id"] = parent_fact_id
        return self._post("/v1/facts", payload)

    def recall(
        self,
        query: str,
        *,
        top_k: int = 5,
        container_tag: str | None = None,
        kinds: list[str] | None = None,
    ) -> dict[str, Any]:
        """Return the raw recall payload: {thoughts, facts, chunks, kinds}."""
        params: dict[str, Any] = {"q": query, "k": top_k}
        if container_tag is not None:
            params["container_tag"] = container_tag
        if kinds is not None:
            params["kinds"] = ",".join(kinds)
        return self._get("/v1/recall", params)

    def recent_thoughts(self, limit: int = 20) -> dict[str, Any]:
        return self._get("/v1/thoughts/recent", {"limit": limit})

    def forget_thought(self, thought_id: str, reason: str) -> dict[str, Any]:
        return self._post(f"/v1/thoughts/{thought_id}/forget", {"reason": reason})

    def forget_fact(self, fact_id: str, reason: str) -> dict[str, Any]:
        return self._post(f"/v1/facts/{fact_id}/forget", {"reason": reason})
