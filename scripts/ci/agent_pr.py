#!/usr/bin/env python3
"""Open bot PRs on their direct dependency and register native GitHub stacks.

No branch, existing PR base, review, or merge is changed here. A Stack-Base
commit trailer overrides ancestry inference only when opening a new PR.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_pr_identity import (  # noqa: E402
    IdentityError, FULL_OID_RE, commit_task_declaration,
    validate_pull_request_identity,
)


class GitHub:
    def __init__(self, repository: str):
        self.root = f"/repos/{repository}"

    def request(self, path: str, payload: dict | None = None):
        args = ["gh", "api", "--method", "POST" if payload is not None else "GET",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10", self.root + path]
        if payload is not None:
            args += ["--input", "-"]
        result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                                text=True, encoding="utf-8", capture_output=True, check=True)
        return json.loads(result.stdout)

    def pages(self, path: str) -> list[dict]:
        items = []
        for page in range(1, 101):
            batch = self.request(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            if not isinstance(batch, list):
                raise IdentityError(f"expected an array from {path}")
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise IdentityError(f"pagination limit reached for {path}")


class Repository:
    def __init__(self, root: Path):
        self.root = root

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], text=True, encoding="utf-8",
                              capture_output=True, check=True).stdout.strip()

    def ancestor(self, base: str, head: str) -> bool:
        result = subprocess.run(["git", "-C", str(self.root), "merge-base", "--is-ancestor",
                                 base, head], capture_output=True)
        if result.returncode not in (0, 1):
            raise IdentityError(f"cannot establish ancestry of {base} and {head}")
        return result.returncode == 0

    def ensure_commit(self, oid: str):
        if not isinstance(oid, str) or not FULL_OID_RE.fullmatch(oid):
            raise IdentityError("PR head must be a full commit SHA")
        try:
            self.git("cat-file", "-e", f"{oid}^{{commit}}")
        except subprocess.CalledProcessError:
            self.git("fetch", "--no-tags", "origin", oid)

    def valid_branch(self, branch: str):
        if branch != "main" and not branch.startswith("agent/"):
            raise IdentityError("stack bases must be main or agent/** in this repository")
        self.git("check-ref-format", f"refs/heads/{branch}")

    def trailer(self, oid: str) -> str | None:
        # Read from every line of the body, not only Git's trailer block: a
        # tool that appends a paragraph after the author's trailers (an
        # attribution footer added at commit time) leaves `Stack-Base` out of
        # the last paragraph, where `%(trailers)` would no longer see it.
        body = self.git("show", "-s", "--format=%B", oid).splitlines()[1:]
        values = [match.group(1) for line in body
                  if (match := STACK_BASE_RE.fullmatch(line.strip()))]
        if len(values) > 1:
            raise IdentityError("use exactly one Stack-Base trailer")
        return values[0] if values else None


STACK_BASE_RE = re.compile(r"Stack-Base:\s*(\S+)")


def by_branch(pulls: list[dict], repository: str, branch: str) -> dict | None:
    matches = [p for p in pulls if p["head"]["ref"] == branch
               and (p["head"].get("repo") or {}).get("full_name") == repository]
    if len(matches) > 1:
        raise IdentityError(f"multiple open PRs for {branch}")
    return matches[0] if matches else None


def choose_base(repo: Repository, pulls: list[dict], repository: str,
                branch: str, sha: str, existing: dict | None) -> str:
    if existing:
        base = existing["base"]["ref"]
    elif (explicit := repo.trailer(sha)) is not None:
        base = explicit
    else:
        main = repo.git("rev-parse", "refs/remotes/origin/main")
        candidates = []
        for pull in pulls:
            head = pull["head"]
            if (head.get("repo") or {}).get("full_name") != repository or head["ref"] == branch:
                continue
            if not head["ref"].startswith("agent/"):
                continue
            repo.ensure_commit(head["sha"])
            if repo.ancestor(head["sha"], sha) and not repo.ancestor(head["sha"], main):
                candidates.append(pull)
        nearest = [p for p in candidates if not any(
            p is not other and repo.ancestor(p["head"]["sha"], other["head"]["sha"])
            for other in candidates)]
        if len(nearest) != 1 and candidates:
            raise IdentityError("ambiguous dependency; set a Stack-Base commit trailer")
        base = nearest[0]["head"]["ref"] if nearest else "main"
    repo.valid_branch(base)
    if base == branch:
        raise IdentityError("a PR cannot depend on itself")
    if base != "main" and by_branch(pulls, repository, base) is None:
        raise IdentityError(f"no open same-repository parent PR for {base}; refresh the stack")
    return base


def chain_for(pull: dict, pulls: list[dict], repository: str) -> list[int]:
    chain = []
    while True:
        number = pull["number"]
        if number in chain or len(chain) >= 64:
            raise IdentityError("cyclic or oversized PR dependency chain")
        if any((pull[end].get("repo") or {}).get("full_name") != repository for end in ("base", "head")):
            raise IdentityError("native stacks cannot cross repositories")
        chain.append(number)
        base = pull["base"]["ref"]
        if base == "main":
            return list(reversed(chain))
        pull = by_branch(pulls, repository, base)
        if pull is None:
            raise IdentityError(f"parent PR for {base} is missing")


def register_stack(api: GitHub, chain: list[int]) -> int | None:
    if len(chain) < 2:
        return None
    # Re-read after each write, including failed/unknown responses. Never
    # replace a stack or append on top of a different concurrent child.
    last_error = None
    for attempt in range(3):
        stacks = api.pages("/stacks")
        overlaps = []
        for stack in stacks:
            members = [p["number"] for p in stack["pull_requests"]
                       if p.get("state") == "open"]
            if set(chain) & set(members):
                overlaps.append((stack, members))
        if len(overlaps) > 1:
            raise IdentityError("dependency chain spans multiple native stacks")
        if overlaps:
            stack, members = overlaps[0]
            if members[:len(chain)] == chain:
                return stack["number"]
            if chain[:len(members)] != members:
                raise IdentityError("native stack has a different order or child; restack first")
            path = f"/stacks/{stack['number']}/add"
            payload = {"pull_requests": chain[len(members):]}
        else:
            path, payload = "/stacks", {"pull_requests": chain}
        if attempt == 2:
            break
        try:
            api.request(path, payload)
        except subprocess.CalledProcessError as error:
            last_error = error
    raise IdentityError(f"native stack registration did not read back: {last_error}")


def open_pull(repo: Repository, api: GitHub, repository: str, branch: str, sha: str) -> tuple[int, int | None]:
    repo.valid_branch(branch)
    if not branch.startswith("agent/") or not FULL_OID_RE.fullmatch(sha):
        raise IdentityError("expected an agent branch and exact event SHA")
    if repo.git("rev-parse", "HEAD") != sha:
        raise IdentityError("checkout does not match event SHA")
    pulls = api.pages("/pulls?state=open")
    existing = by_branch(pulls, repository, branch)
    if existing:
        existing = api.request(f"/pulls/{existing['number']}")
        validate_pull_request_identity(
            existing, expected_repository=repository, expected_number=existing["number"],
            expected_base_ref=existing["base"]["ref"], expected_head_ref=branch,
            expected_head_oid=sha, expected_author="github-actions[bot]",
        )
    base = choose_base(repo, pulls, repository, branch, sha, existing)
    if existing is None:
        task = commit_task_declaration(repo.root, sha)
        body = f"Task: {task}\n\n" if task else ""
        body += (f"Agent-drafted change from `{branch}`.\n\n"
                 "Review by the human CODEOWNER is required before merging. "
                 "Required checks validate each pushed head.\n")
        if base != "main":
            body += f"\nDepends on #{by_branch(pulls, repository, base)['number']}.\n"
        try:
            api.request("/pulls", {"head": branch, "base": base,
                                  "title": repo.git("show", "-s", "--format=%s", sha), "body": body})
        except subprocess.CalledProcessError:
            # Creation may have succeeded even if its response was lost.
            if by_branch(api.pages("/pulls?state=open"), repository, branch) is None:
                raise
    pulls = api.pages("/pulls?state=open")
    selected = by_branch(pulls, repository, branch)
    if selected is None:
        raise IdentityError("created PR did not read back")
    number = selected["number"]
    pull = api.request(f"/pulls/{number}")
    validate_pull_request_identity(
        pull, expected_repository=repository, expected_number=number,
        expected_base_ref=base, expected_head_ref=branch,
        expected_head_oid=sha, expected_author="github-actions[bot]",
    )
    return number, register_stack(api, chain_for(pull, pulls, repository))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--repository", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    try:
        number, stack = open_pull(Repository(args.repo_root), GitHub(args.repository),
                                  args.repository, args.branch, args.head_sha)
        with args.github_output.open("a") as output:
            output.write(f"pr-number={number}\nstack-number={stack or ''}\n")
        print(f"Validated PR #{number}; native stack: {stack or 'independent PR'}")
    except (IdentityError, subprocess.CalledProcessError, KeyError, TypeError) as error:
        print(f"agent-pr: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
