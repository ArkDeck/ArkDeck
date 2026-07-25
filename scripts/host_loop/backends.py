"""Production backends for the host-loop worker (TASK-HLR-003 readiness r2).

r1 delivered the offline contracts with every boundary injected, and nothing
implemented those boundaries: protected main had zero non-test hits for
subprocess, urllib or http. r2 authorises exactly this surface — the real git
runner, the real HTTP sender, the installation-token path and the four worker
callables — confined to `scripts/host_loop/**`.

What this module deliberately does NOT do, because r2 forbids it: add a typed
route, widen a field allowlist, or introduce a generic request method. Every
call still goes through `ApiPort`/`RefPort`, so the frozen route allowlist and
the ownership bindings remain the only way to reach GitHub.

Credential containment matches the TASK-HLR-002 evidence: the private key is
never read into this process — JWT signing is delegated to `sudo openssl`, so
the PEM is only ever read by root — and the installation token exists in
memory only. Neither the token nor the JWT is logged or placed in a child
process argv.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from .pr_envelope import Envelope, render_envelope
from .transport import OID_RE, TransportError

API_ROOT = "https://api.github.com"
GIT_TIMEOUT_SECONDS = 120
HTTP_TIMEOUT_SECONDS = 60

# Environment variable names. The token may also come from a root-only staging
# file, which is preferred on the host because the value never enters the
# scheduler's environment block.
ENV_TOKEN = "ARKDECK_HOST_LOOP_TOKEN"
ENV_TOKEN_FILE = "ARKDECK_HOST_LOOP_TOKEN_FILE"

_SECRET_SHAPES = (
    re.compile(r"gh[psoau]_[A-Za-z0-9]{10,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{10,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."),  # a JWT
)


class BackendError(TransportError):
    """A backend could not be constructed or produced an unusable result."""


def assert_no_secret(text: str, what: str) -> str:
    """Refuse to emit anything that looks like a credential.

    Applied to every string this module returns for logging or receipts. It is a
    backstop, not the primary control: the primary control is that tokens are
    never passed to a child process and the PEM never enters this process.
    """
    for shape in _SECRET_SHAPES:
        if shape.search(text):
            raise BackendError(f"refusing to emit {what}: it contains a secret shape")
    return text


# ------------------------------------------------------------------ git runner

@dataclass
class SubprocessGitRunner:
    """Real `git` boundary for RefPort.

    Returns (returncode, stdout, stderr) verbatim so the transport layer keeps
    sole responsibility for classifying a server refusal (Refused /
    PolicyRefused) apart from an ambiguous transport failure (TransportError).
    This runner never inspects or rewrites stderr, because collapsing those two
    cases here is exactly the misreport the transport docstring forbids.
    """

    repo_dir: str
    timeout: int = GIT_TIMEOUT_SECONDS

    def __call__(self, argv: Sequence[str]) -> tuple[int, str, str]:
        argv = list(argv)
        if not argv or argv[0] != "git":
            raise BackendError(f"git runner refuses a non-git argv: {argv[:1]}")
        # Deny interactive prompting: a hung credential prompt would otherwise
        # look like a timeout and be misread as ambiguity.
        env = dict(os.environ)
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.setdefault("GIT_CONFIG_NOSYSTEM", "1")
        try:
            done = subprocess.run(
                argv, cwd=self.repo_dir, capture_output=True, text=True,
                timeout=self.timeout, env=env,
            )
        except subprocess.TimeoutExpired:
            # A timeout is genuinely ambiguous: the push may or may not have
            # landed. Report it as such rather than as a refusal.
            return 1, "", f"timeout after {self.timeout}s running {' '.join(argv[:3])}"
        return done.returncode, done.stdout, done.stderr


def read_lease_record(repo_dir: str, timeout: int = GIT_TIMEOUT_SECONDS
                      ) -> Callable[[str], str]:
    """Return a reader that yields a lease commit's record text.

    The lease record lives in the commit message, so this is `git log -1
    --format=%B`. Fetching first is the caller's job; a missing object is an
    error rather than an empty record, because an empty record would parse as a
    malformed lease and be reported as corruption instead of as a fetch gap.
    """

    def read(oid: str) -> str:
        if not OID_RE.match(oid):
            raise BackendError("lease record OID must be lowercase full 40-hex")
        done = subprocess.run(
            ["git", "log", "-1", "--format=%B", oid],
            cwd=repo_dir, capture_output=True, text=True, timeout=timeout,
        )
        if done.returncode != 0:
            raise BackendError(
                f"cannot read lease record {oid[:12]}: "
                f"{done.stderr.strip()[:160]} — fetch the ref before reading"
            )
        return done.stdout.strip()

    return read


def commit_writer(repo_dir: str, timeout: int = GIT_TIMEOUT_SECONDS
                  ) -> Callable[[str, str | None], str]:
    """Return a writer that creates a lease commit carrying the record text.

    The commit reuses the parent's tree (or the empty tree at the root) so a
    lease ref never carries file content — the record is the message. Uses
    `commit-tree`, which needs no worktree and no index, so a lease write can
    never disturb a checkout.
    """

    def write(record_text: str, parent_oid: str | None) -> str:
        if parent_oid is not None and not OID_RE.match(parent_oid):
            raise BackendError("lease parent OID must be lowercase full 40-hex")
        if parent_oid is None:
            tree = subprocess.run(
                ["git", "hash-object", "-t", "tree", "-w", "--stdin"],
                cwd=repo_dir, input="", capture_output=True, text=True, timeout=timeout,
            )
            if tree.returncode != 0:
                raise BackendError(f"cannot create empty tree: {tree.stderr.strip()[:160]}")
            tree_oid = tree.stdout.strip()
            argv = ["git", "commit-tree", tree_oid, "-m", record_text]
        else:
            argv = ["git", "commit-tree", f"{parent_oid}^{{tree}}",
                    "-p", parent_oid, "-m", record_text]
        env = dict(os.environ)
        # Deterministic, attributable, and independent of the host's git config.
        env.setdefault("GIT_AUTHOR_NAME", "arkdeck-host-loop")
        env.setdefault("GIT_AUTHOR_EMAIL", "host-loop@arkdeck.invalid")
        env.setdefault("GIT_COMMITTER_NAME", "arkdeck-host-loop")
        env.setdefault("GIT_COMMITTER_EMAIL", "host-loop@arkdeck.invalid")
        done = subprocess.run(argv, cwd=repo_dir, capture_output=True, text=True,
                              timeout=timeout, env=env)
        if done.returncode != 0:
            raise BackendError(f"commit-tree failed: {done.stderr.strip()[:160]}")
        oid = done.stdout.strip()
        if not OID_RE.match(oid):
            raise BackendError(f"commit-tree returned an unusable OID {oid!r}")
        return oid

    return write


# ----------------------------------------------------------------- http sender

@dataclass
class UrllibSender:
    """Real HTTP boundary for ApiPort.

    Deliberately dumb: it performs whatever method and path ApiPort hands it and
    returns (status, payload). It holds no route knowledge of its own, so the
    frozen allowlist in ApiPort stays the single gate. The token is held here and
    never returned, logged, or passed to a child process.
    """

    token: str
    timeout: int = HTTP_TIMEOUT_SECONDS
    user_agent: str = "arkdeck-host-loop/1"

    def __call__(self, method: str, path: str, body: dict | None) -> tuple[int, object]:
        url = path if path.startswith("http") else f"{API_ROOT}{path}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        request.add_header("User-Agent", self.user_agent)
        request.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode()
                return response.status, (json.loads(raw) if raw.strip() else None)
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            try:
                payload = json.loads(raw) if raw.strip() else None
            except ValueError:
                payload = {"message": raw[:300]}
            return error.code, payload
        except Exception as error:  # noqa: BLE001
            # Ambiguous: ApiPort turns a 5xx/429 into TransportError, and a
            # transport-level failure has to reach it the same way rather than
            # being reported as a definite refusal.
            return 599, {"message": f"transport failure: {type(error).__name__}"}


# ------------------------------------------------------- installation token

def read_token(env: dict | None = None) -> str:
    """Token from a root-only file if given, otherwise from the environment.

    The file form is preferred on the host: the value never appears in the
    scheduler's environment block, only its path does.
    """
    env = os.environ if env is None else env
    path = env.get(ENV_TOKEN_FILE)
    if path:
        try:
            value = Path(path).read_text().strip()
        except OSError as error:
            raise BackendError(f"cannot read the token file: {error}") from error
        if not value:
            raise BackendError("the token file is empty")
        return value
    value = env.get(ENV_TOKEN)
    if not value:
        raise BackendError(
            f"no credential: set {ENV_TOKEN_FILE} to a root-only file or "
            f"{ENV_TOKEN} in the environment"
        )
    return value


def mint_installation_token(
    *,
    app_id: int,
    installation_id: int,
    pem_path: str,
    sender_factory: Callable[[str], UrllibSender] | None = None,
    signer: Callable[[bytes, str], bytes] | None = None,
    now: Callable[[], int] = lambda: int(time.time()),
) -> tuple[str, dict]:
    """Mint an installation token, keeping the private key out of this process.

    The JWT is signed by `sudo openssl`, so only root reads the PEM. The
    returned token is not logged and the JWT is discarded immediately after the
    exchange.
    """
    issued = now()
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {"iat": issued - 60, "exp": issued + 540, "iss": str(app_id)}

    def b64(raw: bytes) -> bytes:
        return base64.urlsafe_b64encode(raw).rstrip(b"=")

    signing_input = b".".join((
        b64(json.dumps(header, separators=(",", ":")).encode()),
        b64(json.dumps(claims, separators=(",", ":")).encode()),
    ))
    sign = signer if signer is not None else _openssl_sign
    signature = sign(signing_input, pem_path)
    if not signature:
        raise BackendError("JWT signing produced no signature")
    jwt = (signing_input + b"." + b64(signature)).decode()

    sender = (sender_factory or UrllibSender)(jwt)
    status, payload = sender(
        "POST", f"/app/installations/{int(installation_id)}/access_tokens", None
    )
    del jwt
    if status != 201 or not isinstance(payload, dict) or "token" not in payload:
        raise BackendError(f"installation token mint failed: HTTP {status}")
    meta = {
        "expires_at": payload.get("expires_at"),
        "permissions": payload.get("permissions"),
        "repository_selection": payload.get("repository_selection"),
    }
    return payload["token"], meta


def _openssl_sign(signing_input: bytes, pem_path: str) -> bytes:
    done = subprocess.run(
        ["sudo", "openssl", "dgst", "-sha256", "-sign", pem_path],
        input=signing_input, capture_output=True, timeout=GIT_TIMEOUT_SECONDS,
    )
    if done.returncode != 0:
        raise BackendError(
            "JWT signing failed; is the staged PEM readable by root? "
            f"({done.stderr.decode(errors='replace').strip()[:120]})"
        )
    return done.stdout


# --------------------------------------------------- worker callable factories

def branch_preparer(
    refs, repo_dir: str, *, writer: Callable[[str, str | None], str],
) -> Callable[[object, str], str]:
    """Return `prepare_branch(candidate, base_oid) -> head_oid`.

    The stable task branch carries an empty commit on the frozen base: no file
    content. Generating a task's actual work is NOT part of TASK-HLR-003 — its
    scope is the coordination mechanism — so the PR this produces declares the
    task in its envelope and changes no paths, which MECH-004 accepts. An
    existing branch is adopted rather than recreated, so a resumed round does
    not fork a second head.
    """
    from .lease import task_branch

    def prepare(candidate, base_oid: str) -> str:
        if not OID_RE.match(base_oid):
            raise BackendError("base OID must be lowercase full 40-hex")
        ref = task_branch(candidate.task_id)
        existing = refs.read(ref)
        if existing is not None:
            return existing
        head = writer(
            f"chore({candidate.task_id}): host-loop task branch\n\n"
            f"Empty commit on the frozen base. TASK-HLR-003 delivers the\n"
            f"coordination mechanism; task content is out of its scope.\n",
            base_oid,
        )
        refs.create(ref, head)
        observed = refs.read(ref)
        if observed != head:
            raise BackendError(
                f"task branch read-back {observed} != intended {head}"
            )
        return head

    return prepare


def body_renderer(
    repo_root: str, *, change_id: str, producer: str, run_id: str,
) -> Callable[[object, str, str], str]:
    """Return `render_body(candidate, base_oid, head_oid) -> str`.

    Reuses the merged `pr_envelope.render_envelope`, so the envelope grammar,
    field order and validation stay a single implementation. Evidence is
    declared as an explicit no-evidence reason rather than a path, because this
    phase produces no evidence file.
    """

    def render(candidate, base_oid: str, head_oid: str) -> str:
        envelope = Envelope(
            pr_type="implementation",
            change=change_id,
            task=candidate.task_id,
            base_oid=base_oid,
            head_oid=head_oid,
            decision_grade=candidate.decision_grade,
            depends_on="none",
            evidence=("none — host-loop dispatch carries no evidence file",),
            producer=producer,
            run=run_id,
        )
        return render_envelope(
            envelope, Path(repo_root),
            human_text=(
                "Opened by the host-loop worker. Approval remains the human "
                "CODEOWNER's; green checks are not merge permission."
            ),
        )

    return render
