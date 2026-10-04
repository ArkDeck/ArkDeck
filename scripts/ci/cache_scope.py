#!/usr/bin/env python3
"""Separate successful agent-push build caches from trusted main entries."""
import argparse
import hashlib
import os
from pathlib import Path


def scope(kind: str, event: str, ref: str) -> dict[str, str]:
    if kind not in ("swiftpm", "xcode"):
        raise ValueError("unsupported build cache kind")
    prefix = f"arkdeck-{kind}-v2"
    save = event == "push" and ref == "refs/heads/main"
    if event == "push" and ref.startswith("refs/heads/agent/"):
        branch = hashlib.sha256(ref.encode()).hexdigest()
        prefix = f"arkdeck-{kind}-candidate-v1-{branch}"
        save = True
    return {"prefix": prefix, "can-save": str(save).lower()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("swiftpm", "xcode"), required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    outputs = scope(args.kind, os.environ.get("GITHUB_EVENT_NAME", ""),
                    os.environ.get("GITHUB_REF", ""))
    with args.github_output.open("a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
