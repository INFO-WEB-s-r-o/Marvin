"""Thin client over the Brain MCP HTTP transport at 127.0.0.1:3100/mcp.

Phase-1 scaffold: this only defines the call surface the runners will use.
The transport is already verified live (see PR #3 in INFO-WEB-s-r-o/Marvin-Brain
and 2026-05-28-issues.md). Real implementations land in phase 2.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


DEFAULT_ENDPOINT = "http://127.0.0.1:3100/mcp"


@dataclass(frozen=True)
class BrainConfig:
    endpoint: str = DEFAULT_ENDPOINT
    timeout_seconds: float = 30.0


class BrainClient:
    """Surface the runners need; bodies arrive in phase 2."""

    def __init__(self, config: BrainConfig | None = None) -> None:
        self._config = config or BrainConfig()

    def record_fact(self, fact: str, **metadata: Any) -> str:
        raise NotImplementedError("phase 2")

    def record_thought(self, thought: str, **metadata: Any) -> str:
        raise NotImplementedError("phase 2")

    def recall(self, query: str, *, top_k: int = 5) -> list[dict[str, Any]]:
        raise NotImplementedError("phase 2")

    def forget_fact(self, fact_id: str) -> None:
        raise NotImplementedError("phase 2")
