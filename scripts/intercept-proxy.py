#!/usr/bin/env python3
"""Intercepting proxy addon for mitmproxy — logs all HTTP(S) traffic to JSONL.

Captures request/response metadata (not full bodies by default) and writes
structured events to a JSONL file for audit and research.

Usage:
    mitmdump --listen-port 8080 -s intercept-proxy.py

Output:
    $CLIDE_LOG_DIR/intercept.jsonl (default: /workspace/.clide/logs/intercept.jsonl)

Environment:
    CLIDE_LOG_DIR           Log directory
    CLIDE_INTERCEPT_BODIES  Set to '1' to capture request/response bodies (large!)
"""

import json
import os
import time
from pathlib import Path

from mitmproxy import http


# Prefer per-session dir if available, fall back to global log dir
_SESSION_DIR = os.environ.get("CLIDE_SESSION_DIR", "")
LOG_DIR = _SESSION_DIR or os.environ.get("CLIDE_LOG_DIR", "/workspace/.clide/logs")
LOG_FILE = Path(LOG_DIR) / "intercept.jsonl"
CAPTURE_BODIES = os.environ.get("CLIDE_INTERCEPT_BODIES", "0") == "1"

# Ensure log dir exists
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

# Secret patterns to redact from logged content
SECRET_PATTERNS = [
    "sk-ant-",       # Anthropic API keys
    "sk-",           # OpenAI API keys
    "ghp_",          # GitHub PATs
    "github_pat_",   # GitHub fine-grained PATs
    "glpat-",        # GitLab PATs
    "Bearer ",       # Auth headers
]


def _redact(text: str) -> str:
    """Redact known secret patterns from text."""
    for pat in SECRET_PATTERNS:
        if pat in text:
            # Find the secret value and redact it
            idx = text.find(pat)
            # Redact until whitespace, quote, or end of string
            end = idx + len(pat)
            while end < len(text) and text[end] not in (' ', '"', "'", '\n', '\r', ',', '}'):
                end += 1
            text = text[:idx] + f"[REDACTED:{pat.rstrip()}...]" + text[end:]
    return text


def _safe_headers(headers) -> dict:
    """Extract headers as dict, redacting sensitive values."""
    result = {}
    sensitive_keys = {"authorization", "x-api-key", "cookie", "set-cookie",
                      "proxy-authorization", "x-forwarded-for"}
    for key, val in headers.items():
        if key.lower() in sensitive_keys:
            result[key] = _redact(val)
        else:
            result[key] = val
    return result


def response(flow: http.HTTPFlow) -> None:
    """Called when a response is received — log the full request/response pair."""
    req = flow.request
    resp = flow.response

    event = {
        "event": "intercept_request",
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "method": req.method,
        "url": req.pretty_url,
        "host": req.host,
        "port": req.port,
        "path": req.path,
        "request_headers": _safe_headers(req.headers),
        "request_size": len(req.content) if req.content else 0,
        "status_code": resp.status_code if resp else None,
        "response_headers": _safe_headers(resp.headers) if resp else {},
        "response_size": len(resp.content) if resp and resp.content else 0,
        "duration_ms": int((flow.response.timestamp_end - flow.request.timestamp_start) * 1000)
            if resp and hasattr(resp, 'timestamp_end') else None,
    }

    # Optionally capture bodies (can be very large)
    if CAPTURE_BODIES:
        if req.content:
            try:
                event["request_body"] = _redact(req.content.decode("utf-8", errors="replace")[:10000])
            except Exception:
                event["request_body"] = f"[binary, {len(req.content)} bytes]"
        if resp and resp.content:
            try:
                event["response_body"] = resp.content.decode("utf-8", errors="replace")[:10000]
            except Exception:
                event["response_body"] = f"[binary, {len(resp.content)} bytes]"

    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(event) + "\n")
