#!/usr/bin/env python3
"""Inspect and activate the repository's two-slot ephemeral Linux CI pool.

Runner provisioning stays outside job VMs. This command uses the operator's
existing gh authentication; workflows never receive runner administration keys.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime

REPOSITORY = "ArkDeck/ArkDeck"
VARIABLE = "ARKDECK_LINUX_LIGHT_RUNNER"
POOL_LABEL = "arkdeck-linux-light"
NAME_PREFIX = POOL_LABEL + "-"
HOSTED = "ubuntu-latest"
API_VERSION = "2026-03-10"
MINIMUM_IDLE = 2
WORKFLOW = "linux-runner-pool-smoke.yml"


class PoolError(RuntimeError):
    pass


class GitHub:
    def __init__(self, repository: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise PoolError("repository must be owner/name")
        self.root = f"repos/{repository}/actions"

    def api(self, path: str, *, method: str = "GET", payload=None, paginate=False):
        arguments = ["gh", "api", "--method", method,
                     "-H", f"X-GitHub-Api-Version: {API_VERSION}", path]
        if paginate:
            arguments.extend(["--paginate", "--slurp"])
        if payload is not None:
            arguments.extend(["--input", "-"])
        result = subprocess.run(arguments, input=json.dumps(payload) if payload is not None else None,
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            # API bodies and CLI stderr are deliberately not copied into logs.
            raise PoolError(f"GitHub {method} request failed for {path}")
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except json.JSONDecodeError as error:
            raise PoolError("GitHub response was not JSON") from error

    def collection(self, name: str) -> list[dict]:
        pages = self.api(f"{self.root}/{name}?per_page=100", paginate=True)
        if not isinstance(pages, list) or not pages:
            raise PoolError("GitHub collection has no pages")
        records = []
        for page in pages:
            if not isinstance(page, dict) or not isinstance(page.get(name), list):
                raise PoolError("GitHub collection page is malformed")
            records.extend(page[name])
        count = pages[0].get("total_count")
        if type(count) is not int or len(records) != count:
            raise PoolError("GitHub collection is incomplete or changed during pagination")
        if any(not isinstance(record, dict) for record in records):
            raise PoolError("GitHub collection record is malformed")
        return records

    def route(self) -> str | None:
        matches = [record for record in self.collection("variables") if record.get("name") == VARIABLE]
        if len(matches) > 1 or (matches and not isinstance(matches[0].get("value"), str)):
            raise PoolError("runner routing variable is malformed")
        return matches[0]["value"] if matches else None

    def set_route(self, previous: str | None, value: str | None):
        path = f"{self.root}/variables"
        if value is None:
            if previous is not None:
                self.api(f"{path}/{VARIABLE}", method="DELETE")
        else:
            self.api(path if previous is None else f"{path}/{VARIABLE}",
                     method="POST" if previous is None else "PATCH",
                     payload={"name": VARIABLE, "value": value})


def inspect_pool(runners: list[dict]) -> dict:
    eligible = []
    matching = []
    ids = set()
    names = set()
    for runner in runners:
        labels = runner.get("labels")
        if not isinstance(labels, list) or any(not isinstance(label, dict) for label in labels):
            raise PoolError("runner labels are malformed")
        label_names = {label.get("name") for label in labels if isinstance(label.get("name"), str)}
        if POOL_LABEL not in label_names:
            continue
        identity = runner.get("id")
        name = runner.get("name")
        if type(identity) is not int or identity <= 0 or identity in ids:
            raise PoolError("pool runner IDs are missing or duplicated")
        if not isinstance(name, str) or not name.startswith(NAME_PREFIX) or name in names:
            raise PoolError("pool runner names do not identify distinct managed guests")
        ids.add(identity)
        names.add(name)
        if runner.get("ephemeral") is not True:
            raise PoolError("pool contains a persistent runner or lacks ephemeral facts")
        operating_system = runner.get("os")
        if not isinstance(operating_system, str) or operating_system.lower() != "linux" or not {"self-hosted", "Linux", "X64"}.issubset(label_names):
            raise PoolError("pool contains a runner outside the Linux x64 guest profile")
        if runner.get("status") not in ("online", "offline") or type(runner.get("busy")) is not bool:
            raise PoolError("pool runner availability facts are malformed")
        matching.append(identity)
        if runner["status"] == "online" and runner["busy"] is False:
            eligible.append(identity)
    return {"label": POOL_LABEL, "matchingRunnerIds": matching, "idleRunnerIds": eligible,
            "ready": len(eligible) >= MINIMUM_IDLE}


def verified_smoke(github: GitHub, state: dict) -> int:
    main = github.api(github.root.removesuffix("/actions") + "/git/ref/heads/main")
    revision = main.get("object") if isinstance(main, dict) else None
    sha = revision.get("sha") if isinstance(revision, dict) else None
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PoolError("protected main revision is unavailable")
    response = github.api(f"{github.root}/workflows/{WORKFLOW}/runs?event=workflow_dispatch&branch=main&per_page=1")
    runs = response.get("workflow_runs") if isinstance(response, dict) else None
    if not isinstance(runs, list) or not runs:
        raise PoolError("a successful pool smoke on current protected main is required")
    run = runs[0]
    if (not isinstance(run, dict) or run.get("head_sha") != sha or run.get("head_branch") != "main" or
            run.get("event") != "workflow_dispatch" or run.get("status") != "completed" or
            run.get("conclusion") != "success" or type(run.get("id")) is not int or run["id"] <= 0):
        raise PoolError("pool smoke is stale, unfinished or unsuccessful")
    response = github.api(f"{github.root}/runs/{run['id']}/jobs?per_page=100")
    jobs = response.get("jobs") if isinstance(response, dict) else None
    expected = {"Linux pool smoke (plan)", "Linux pool smoke (guard)"}
    if (not isinstance(jobs, list) or len(jobs) != 2 or
            any(not isinstance(job, dict) for job in jobs) or
            response.get("total_count") != 2 or
            {job.get("name") for job in jobs} != expected or
            any(job.get("status") != "completed" or job.get("conclusion") != "success" for job in jobs)):
        raise PoolError("both actual smoke suites must complete successfully")
    consumed = [job.get("runner_id") for job in jobs]
    if any(type(identity) is not int or identity <= 0 for identity in consumed) or len(set(consumed)) != 2:
        raise PoolError("smoke suites must consume two distinct guests")
    try:
        starts = [datetime.fromisoformat(job["started_at"].replace("Z", "+00:00")) for job in jobs]
        ends = [datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00")) for job in jobs]
        if any(start.tzinfo is None or end.tzinfo is None or start >= end for start, end in zip(starts, ends)):
            raise PoolError("smoke execution times are invalid")
        if max(starts) >= min(ends):
            raise PoolError("smoke suites did not run concurrently")
    except (KeyError, TypeError, ValueError) as error:
        raise PoolError("smoke execution times are unavailable") from error
    if set(consumed).intersection(state["matchingRunnerIds"]):
        raise PoolError("consumed guest registrations have not been replaced")
    return run["id"]


def switch_route(github: GitHub, *, activate: bool) -> dict:
    previous = github.route()
    if previous not in (None, HOSTED, POOL_LABEL):
        raise PoolError("routing is managed elsewhere; refusing to overwrite it")
    state = inspect_pool(github.collection("runners")) if activate else None
    if activate and not state["ready"]:
        raise PoolError("two distinct online idle ephemeral Linux guests are required before activation")
    smoke_run = verified_smoke(github, state) if activate else None
    desired = POOL_LABEL if activate else HOSTED
    if previous != desired:
        github.set_route(previous, desired)
    try:
        if github.route() != desired:
            raise PoolError("routing read-back did not match the requested value")
    except (PoolError, OSError, subprocess.SubprocessError):
        # Restore only our own value; preserve a concurrent operator's change.
        if previous != desired and github.route() == desired:
            github.set_route(desired, previous)
        raise
    return {"route": desired, "pool": state, "smokeRunId": smoke_run}


def check_suite(suite: str):
    """Run the real lightweight commands inside a disposable smoke guest."""
    root = Path(__file__).resolve().parents[2]
    if suite == "plan":
        commands = [
            ["python3", "scripts/ci/test_event_checkout.py"],
            ["python3", "scripts/ci/test_plan.py"],
            ["python3", "scripts/ci/test_linux_runner_pool.py"],
            ["python3", "scripts/ci/test_cache_scope.py"],
            ["python3", "rust/scripts/test_run_cargo.py"],
            ["python3", "scripts/test_agent_pr_workflow.py"],
            ["python3", "scripts/release/release_version.py", "check"],
        ]
    elif suite == "guard":
        # Dependency setup matches sdd-guard.yml; no runner administration
        # credential or gh authentication is read by this guest-only command.
        import os
        dependency_root = Path(os.environ["RUNNER_TEMP"]) / "arkdeck-sdd-deps"
        subprocess.run(["python3", "-m", "pip", "install", "--disable-pip-version-check",
                        "--target", str(dependency_root), "-r", "scripts/requirements-sdd.txt"],
                       cwd=root, check=True)
        os.environ["PYTHONPATH"] = str(dependency_root)
        os.environ["ARKDECK_PYTHON"] = "python3"
        commands = [
            ["sh", "scripts/check-sdd.sh"],
            ["python3", "scripts/test_check_sdd.py"],
            ["python3", "scripts/test_agent_pr_identity.py"],
            ["python3", "scripts/ci/test_agent_pr.py"],
            ["python3", "-m", "unittest", "discover", "-s", "scripts/host_loop", "-t", "scripts"],
            ["python3", "-m", "unittest", "discover", "-s", "scripts/gj_record", "-t", "scripts"],
            ["node", "docs/design/arkdeck-ds/scripts/check-tokens.mjs"],
        ]
    else:
        raise PoolError("unknown smoke suite")
    for command in commands:
        subprocess.run(command, cwd=root, check=True)
    if suite == "plan":
        # The interaction suite must work in the clean image even if a smoke
        # on main itself has no changed inputs to select it.
        subprocess.run(["npm", "--prefix", "docs/design/arkdeck-ds", "ci"], cwd=root, check=True)
        subprocess.run(["npm", "--prefix", "docs/design/arkdeck-ds", "test"], cwd=root, check=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "activate", "deactivate", "smoke", "check-suite"))
    parser.add_argument("suite", nargs="?", choices=("plan", "guard"))
    parser.add_argument("--repository", default=REPOSITORY)
    parser.add_argument("--ref", default="main", choices=("main",))
    options = parser.parse_args(argv)
    try:
        if options.command == "check-suite":
            if options.suite is None:
                raise PoolError("check-suite requires plan or guard")
            check_suite(options.suite)
            return 0
        if options.suite is not None:
            raise PoolError("suite is only valid for check-suite")
        github = GitHub(options.repository)
        if options.command == "status":
            route = github.route()
            result = {"route": route if route in (None, HOSTED, POOL_LABEL) else "managed-elsewhere",
                      "pool": inspect_pool(github.collection("runners"))}
        elif options.command == "smoke":
            state = inspect_pool(github.collection("runners"))
            if not state["ready"]:
                raise PoolError("two ready guests are required before dispatching smoke")
            github.api(f"{github.root}/workflows/{WORKFLOW}/dispatches", method="POST",
                       payload={"ref": options.ref})
            result = {"smokeDispatched": True, "ref": options.ref, "pool": state}
        else:
            result = switch_route(github, activate=options.command == "activate")
        print(json.dumps(result, indent=2))
        return 0
    except (PoolError, OSError, subprocess.SubprocessError) as error:
        print(f"linux-runner-pool: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
