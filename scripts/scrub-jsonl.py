#!/usr/bin/env python3
"""Scrub secrets from JSONL files (conversation.jsonl, etc.).

Reads a JSONL file, redacts known secret patterns in string values,
and writes the result back in place.

Usage:
    scrub-jsonl.py /path/to/conversation.jsonl

Environment variables listed in SECRET_NAMES are scrubbed by value.
Additional patterns (API keys, tokens) are caught by regex heuristics.
"""

import json
import os
import re
import sys
from pathlib import Path

# Env var names whose values should be redacted wherever they appear.
SECRET_NAMES = [
    "GH_TOKEN", "GITHUB_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "TTYD_PASS",
    "CLEM_WEB_SECRET",
    "SUPERVISOR_SECRET",
    "TEDDY_API_KEY", "TEDDY_WEB_PASSWORD",
    "GITLAB_TOKEN",
    "HA_TOKEN",
]

# Regex patterns for secrets that may not be in env vars.
SECRET_PATTERNS = [
    (re.compile(r"sk-ant-api\d+-[A-Za-z0-9_-]{20,}"), "[REDACTED:anthropic_key]"),
    (re.compile(r"sk-ant-oat\d+-[A-Za-z0-9_-]{20,}"), "[REDACTED:oauth_token]"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "[REDACTED:openai_key]"),
    (re.compile(r"ghp_[A-Za-z0-9]{36,}"), "[REDACTED:github_pat]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "[REDACTED:github_pat]"),
    (re.compile(r"glpat-[A-Za-z0-9_-]{20,}"), "[REDACTED:gitlab_pat]"),
    (re.compile(r"gho_[A-Za-z0-9]{36,}"), "[REDACTED:github_oauth]"),
    (re.compile(r"xoxb-[A-Za-z0-9-]{20,}"), "[REDACTED:slack_token]"),
]


def _build_secret_values() -> list[tuple[str, str]]:
    """Collect secret env var values for literal replacement."""
    pairs = []
    for name in SECRET_NAMES:
        val = os.environ.get(name, "")
        if len(val) >= 4:
            pairs.append((val, f"[REDACTED:{name}]"))
    return pairs


def scrub_string(text: str, secret_values: list[tuple[str, str]]) -> str:
    """Scrub secrets from a string."""
    # Literal value replacement (highest priority — exact match)
    for val, replacement in secret_values:
        text = text.replace(val, replacement)

    # Regex pattern replacement
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)

    return text


def scrub_value(obj: object, secret_values: list[tuple[str, str]]) -> object:
    """Recursively scrub secrets from JSON values."""
    if isinstance(obj, str):
        return scrub_string(obj, secret_values)
    elif isinstance(obj, dict):
        return {k: scrub_value(v, secret_values) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [scrub_value(item, secret_values) for item in obj]
    return obj


def scrub_file(path: str) -> int:
    """Scrub a JSONL file in place. Returns number of lines processed."""
    filepath = Path(path)
    if not filepath.exists():
        return 0

    secret_values = _build_secret_values()
    if not secret_values and not SECRET_PATTERNS:
        return 0

    lines = filepath.read_text().splitlines()
    scrubbed = []
    count = 0

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            obj = scrub_value(obj, secret_values)
            scrubbed.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
            count += 1
        except json.JSONDecodeError:
            # Not valid JSON — scrub as plain text
            scrubbed.append(scrub_string(line, secret_values))
            count += 1

    filepath.write_text("\n".join(scrubbed) + "\n" if scrubbed else "")
    return count


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <file.jsonl>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    n = scrub_file(path)
    print(f"scrubbed {n} lines in {path}", file=sys.stderr)
