#!/usr/bin/env python3
"""Parse a Claude Code conversation JSONL and output token/cost summary.

Usage:
    token-cost.py <conversation.jsonl>

Outputs a JSON object with:
    input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
    total_tokens, estimated_cost_usd, model, turns

Pricing (per million tokens, as of 2026-03):
    Claude Sonnet 4:   input $3, output $15, cache_write $3.75, cache_read $0.30
    Claude Opus 4:     input $15, output $75, cache_write $18.75, cache_read $1.50
    Claude Haiku 3.5:  input $0.80, output $4, cache_write $1, cache_read $0.08
"""

import json
import sys
from pathlib import Path

# Pricing per million tokens
PRICING = {
    "claude-sonnet-4-20250514": {
        "input": 3.0, "output": 15.0,
        "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-opus-4-20250514": {
        "input": 15.0, "output": 75.0,
        "cache_write": 18.75, "cache_read": 1.50,
    },
    "claude-haiku-3-5-20241022": {
        "input": 0.80, "output": 4.0,
        "cache_write": 1.0, "cache_read": 0.08,
    },
}

# Default to sonnet pricing if model unknown
DEFAULT_PRICING = PRICING["claude-sonnet-4-20250514"]


def parse_conversation(path: str) -> dict:
    """Parse conversation JSONL and return token/cost summary."""
    input_tokens = 0
    output_tokens = 0
    cache_creation = 0
    cache_read = 0
    model = ""
    turns = 0

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Extract model from summary or first assistant message
            if not model:
                if obj.get("type") == "summary":
                    model = obj.get("model", "")
                elif obj.get("type") == "assistant":
                    model = obj.get("message", {}).get("model", "")

            # Count turns
            if obj.get("type") in ("user", "human"):
                turns += 1

            # Extract usage from assistant messages
            if obj.get("type") == "assistant":
                usage = obj.get("message", {}).get("usage", {})
                if usage:
                    input_tokens += usage.get("input_tokens", 0)
                    output_tokens += usage.get("output_tokens", 0)
                    cache_creation += usage.get("cache_creation_input_tokens", 0)
                    cache_read += usage.get("cache_read_input_tokens", 0)

    # Calculate cost — match model family by keyword
    pricing = DEFAULT_PRICING
    model_lower = model.lower()
    if "opus" in model_lower:
        pricing = PRICING["claude-opus-4-20250514"]
    elif "haiku" in model_lower:
        pricing = PRICING["claude-haiku-3-5-20241022"]
    elif "sonnet" in model_lower:
        pricing = PRICING["claude-sonnet-4-20250514"]

    cost = (
        (input_tokens / 1_000_000) * pricing["input"]
        + (output_tokens / 1_000_000) * pricing["output"]
        + (cache_creation / 1_000_000) * pricing["cache_write"]
        + (cache_read / 1_000_000) * pricing["cache_read"]
    )

    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_tokens": cache_creation,
        "cache_read_tokens": cache_read,
        "total_tokens": input_tokens + output_tokens + cache_creation + cache_read,
        "estimated_cost_usd": round(cost, 6),
        "model": model or "unknown",
        "turns": turns,
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <conversation.jsonl>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    if not Path(path).exists():
        print(json.dumps({"error": f"File not found: {path}"}))
        sys.exit(1)

    result = parse_conversation(path)
    print(json.dumps(result))
