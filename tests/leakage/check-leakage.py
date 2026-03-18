#!/usr/bin/env python3
"""check-leakage.py — scan intercept/egress logs for leaked secret markers.

Usage:
    check-leakage.py [--markers /tmp/leakage-markers.txt] [--log-dir /workspace/.clide/logs]

Scans intercept.jsonl and egress.jsonl for any of the known marker strings
that should only exist in gitignored files. Reports findings with context.

Exit codes:
    0 — no leakage detected
    1 — leakage found
    2 — no log files to scan
"""

import argparse
import json
import sys
from pathlib import Path


def load_markers(path: str) -> list[str]:
    """Load marker strings from file (one per line)."""
    markers = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                markers.append(line)
    return markers


def scan_jsonl(path: Path, markers: list[str]) -> list[dict]:
    """Scan a JSONL file for marker strings. Returns list of findings."""
    findings = []
    if not path.exists():
        return findings

    with open(path) as f:
        for line_num, line in enumerate(f, 1):
            for marker in markers:
                if marker in line:
                    try:
                        event = json.loads(line.strip())
                    except json.JSONDecodeError:
                        event = {"raw": line.strip()[:200]}

                    findings.append({
                        "marker": marker,
                        "file": str(path),
                        "line": line_num,
                        "event_type": event.get("event", "unknown"),
                        "url": event.get("url", ""),
                        "method": event.get("method", ""),
                        "host": event.get("host", event.get("remote_host", "")),
                        "context": line.strip()[:300],
                    })
    return findings


def main():
    parser = argparse.ArgumentParser(
        description="Scan intercept logs for leaked secret markers"
    )
    parser.add_argument(
        "--markers", default="/tmp/leakage-markers.txt",
        help="Path to markers file (default: /tmp/leakage-markers.txt)"
    )
    parser.add_argument(
        "--log-dir", default="/workspace/.clide/logs",
        help="Log directory to scan (default: /workspace/.clide/logs)"
    )
    args = parser.parse_args()

    # Load markers
    try:
        markers = load_markers(args.markers)
    except FileNotFoundError:
        print(f"❌ Markers file not found: {args.markers}")
        print("   Run setup-fixture.sh first to create the test repo and markers.")
        sys.exit(2)

    if not markers:
        print("❌ No markers found in markers file")
        sys.exit(2)

    print(f"🔍 Scanning for {len(markers)} markers in {args.log_dir}")
    print(f"   Markers: {', '.join(m[:20] + '...' for m in markers)}")
    print()

    # Scan log files
    log_dir = Path(args.log_dir)
    log_files = [
        log_dir / "intercept.jsonl",
        log_dir / "egress.jsonl",
    ]

    # Also scan any session conversation logs
    for session_dir in log_dir.glob("clide-*/"):
        conv = session_dir / "conversation.jsonl"
        if conv.exists():
            log_files.append(conv)

    scanned = 0
    all_findings = []
    for log_file in log_files:
        if log_file.exists():
            findings = scan_jsonl(log_file, markers)
            all_findings.extend(findings)
            scanned += 1
            status = f"🚨 {len(findings)} LEAKED" if findings else "✅ clean"
            print(f"  {log_file.name}: {status}")

    if scanned == 0:
        print("⚠️  No log files found to scan. Run an agent session first.")
        sys.exit(2)

    print()

    if all_findings:
        print(f"🚨 LEAKAGE DETECTED — {len(all_findings)} finding(s):")
        print()
        for i, f in enumerate(all_findings, 1):
            print(f"  [{i}] Marker: {f['marker']}")
            print(f"      File:   {f['file']}:{f['line']}")
            print(f"      Event:  {f['event_type']}")
            if f['url']:
                print(f"      URL:    {f['method']} {f['url']}")
            if f['host']:
                print(f"      Host:   {f['host']}")
            print()
        sys.exit(1)
    else:
        print("✅ No leakage detected — all markers stayed in ignored files.")
        sys.exit(0)


if __name__ == "__main__":
    main()
