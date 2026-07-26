"""Typed GitHub transport for the host-loop worker (TASK-HLR-003 draft).

Design constraints (CHG-2026-030 design §1B, §3, §4, deliverables):

* The only exposed operations are PR lookup/create/update, Issue
  lookup/create/update, and `agent/**` ref read/create/CAS/delete.
* review / merge / auto-merge / branch-update / admin route construction count is
  identically 0. There is no generic request method and no escape hatch: every
  outbound call is built from a frozen positive allowlist of route templates,
  and a defence-in-depth denylist rejects forbidden shapes even if the
  allowlist were mis-edited.
* Two backends, because the D2 identity pins are asymmetric:
    - `ApiPort`  — App installation token, `Contents: read`. PR + Issue only.
    - `RefPort`  — TASK-BAP-003 Deploy Key over SSH. Ref writes only.
  GitHub's `PATCH /git/refs/*` exposes only a `force` boolean and has no
  expected-old-OID parameter, so genuine compare-and-swap is impossible over
  REST. Fenced lease writes therefore go through git with exact
  `--force-with-lease=<ref>:<expected-oid>` semantics.
* The reviewer process never receives the integration credential; that is
  enforced by construction here (reviewer code cannot obtain an `ApiPort`
  carrying a token it did not supply) and asserted by TASK-HLR-004.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from typing import Callable, Literal, NamedTuple, Protocol, Sequence

OID_RE = re.compile(r"^[0-9a-f]{40}$")
AGENT_REF_RE = re.compile(r"^refs/heads/agent/(?!\.\.)[A-Za-z0-9._/-]+$")
RESERVED_REF_RE = re.compile(
    r"^refs/heads/agent/host-loop/(tasks|leases|probes)/[A-Za-z0-9._-]+$"
)


class TransportError(RuntimeError):
    """Any refused construction, ambiguous response, or fence violation."""


class RouteViolation(TransportError):
    """A route outside the typed allowlist was constructed. Never retried."""


class PolicyRefused(TransportError):
    """The server refused a mutation on a *policy* ground, not a precondition.

    A ruleset, branch-protection rule or pre-receive hook declined the write.
    The fence was never contested, so this must NEVER be reported as a lost
    fence: doing so sends operators hunting for a concurrent worker that does
    not exist. It is also not retryable — the policy will decline again.
    """


class Refused(TransportError):
    """The server refused a mutation on an explicit precondition.

    This is a *clean* negative result and the only kind admissible as
    negative-probe or fence-loss evidence. An ambiguous transport failure
    (timeout, 5xx, unparsable response) raises plain TransportError instead:
    the mutation may or may not have landed, so the caller must reconcile with
    a lookup rather than conclude a refusal. Conflating the two would let a
    network fault masquerade as proof that fencing works.
    """


# --------------------------------------------------------------------- routes

class Route(NamedTuple):
    method: Literal["GET", "POST", "PATCH"]
    template: str
    purpose: str


# Frozen positive allowlist. Adding to this set is a governance change: it is
# pinned by the HLR-003 readiness, and its exact CONTENTS are asserted by
# test_backends_cli.NoNewRouteOrEscapeHatch. Previously only the size was pinned
# and the comment credited the route-inventory test, which asserts no such thing
# — so substituting one entry for another (as the check-runs pagination did) was
# invisible to every test in the suite.
ALLOWED_ROUTES: frozenset[tuple[str, str]] = frozenset(
    {
        ("GET", "/repos/{owner}/{repo}/pulls?head&state&per_page"),
        ("GET", "/repos/{owner}/{repo}/pulls/{number}"),
        ("POST", "/repos/{owner}/{repo}/pulls"),
        ("PATCH", "/repos/{owner}/{repo}/pulls/{number}"),
        ("GET", "/repos/{owner}/{repo}/issues/{number}"),
        ("POST", "/repos/{owner}/{repo}/issues"),
        ("PATCH", "/repos/{owner}/{repo}/issues/{number}"),
        ("GET", "/repos/{owner}/{repo}/commits/{oid}/check-runs?per_page&page"),
    }
)

# Defence in depth. Any of these appearing in a constructed path is a hard
# refusal regardless of the allowlist, so a future mis-edit cannot quietly
# introduce approval, merge or administration authority.
FORBIDDEN_PATH_MARKERS: tuple[str, ...] = (
    "/reviews",
    "/requested_reviewers",
    "/merge",
    "/update-branch",
    "/protection",
    "/rulesets",
    "/branches/",
    "/collaborators",
    "/keys",
    "/actions",
    "/secrets",
    "/workflows",
    "/hooks",
    "/teams",
    "/admin",
    "/graphql",
)
FORBIDDEN_METHODS: tuple[str, ...] = ("PUT", "DELETE", "HEAD", "OPTIONS", "TRACE")

# PR body/title are the only mutable PR fields. Anything else (base, state,
# draft, milestone) is refused so a PR can never be retargeted or closed-merged
# through the update path.
SUCCESS_STATUSES: frozenset[int] = frozenset({200, 201})

ALLOWED_PR_PATCH_FIELDS: frozenset[str] = frozenset({"title", "body"})
# `state` is deliberately absent. GitHub's issues endpoint also serves pull
# requests, so PATCH /issues/<pr-number> {state: closed} would close a PR and
# walk straight around the PR-update guard above. Closing the cursor Issue goes
# through close_issue(), which refuses any number that resolves to a PR.
ALLOWED_ISSUE_PATCH_FIELDS: frozenset[str] = frozenset({"title", "body"})


def assert_route_allowed(method: str, path: str) -> None:
    """Positive-allowlist gate plus denylist. Raises RouteViolation on refusal."""
    if method in FORBIDDEN_METHODS:
        raise RouteViolation(f"method {method} is not constructible by this transport")
    lowered = path.lower()
    for marker in FORBIDDEN_PATH_MARKERS:
        if marker in lowered:
            raise RouteViolation(f"forbidden route marker {marker!r} in {path!r}")
    template = _templatize(path)
    if (method, template) not in ALLOWED_ROUTES:
        raise RouteViolation(f"route {method} {template} is not in the typed allowlist")


def _templatize(path: str) -> str:
    """Reduce a concrete path to its allowlist template."""
    base, _, query = path.partition("?")
    if query:
        keys = sorted({item.split("=", 1)[0] for item in query.split("&") if item})
        # Only the pinned lookup shape is expressible; any other key set fails
        # the allowlist rather than being normalised away.
        if keys == ["head", "page", "per_page", "state"]:
            return _templatize(base) + "?head&state&per_page"
        if keys == ["page", "per_page"]:
            return _templatize(base) + "?per_page&page"
        return _templatize(base) + "?" + "&".join(keys)
    parts = path.split("/")
    out: list[str] = []
    for index, part in enumerate(parts):
        if not part:
            out.append(part)
            continue
        previous = parts[index - 1] if index else ""
        if previous == "repos":
            out.append("{owner}")
        elif index >= 2 and parts[index - 2] == "repos":
            out.append("{repo}")
        elif part.isdigit():
            out.append("{number}")
        elif OID_RE.match(part):
            out.append("{oid}")
        else:
            out.append(part)
    return "/".join(out)


# ------------------------------------------------------------------- backends

class Sender(Protocol):
    """Injected HTTP boundary. Tests supply a recording fake."""

    def __call__(self, method: str, path: str, body: dict | None) -> tuple[int, object]:
        ...


class GitRunner(Protocol):
    """Injected git boundary for Deploy-Key ref operations."""

    def __call__(self, argv: Sequence[str]) -> tuple[int, str, str]:
        ...


@dataclass
class ApiPort:
    """PR + Issue operations over the App installation token.

    Holds no ref-write capability: the D2 identity is pinned to Contents: read.
    """

    owner: str
    repo: str
    _send: Sender
    route_log: list[Route] = field(default_factory=list)
    # Mutation targets. `None` means UNBOUND, and unbound refuses every
    # mutation on that object type — the default is deny, not allow. The
    # previous default of None-means-unrestricted put the safety boundary the
    # wrong way round: nothing in production ever set these, so the guard was a
    # no-op outside its own tests. Bind with bound_to_pull()/bound_to_issue()
    # once the fenced lease has established which object this run owns.
    owned_pull: int | None = None
    owned_issue: int | None = None

    def bound_to_pull(self, number: int) -> "ApiPort":
        """A port permitted to mutate exactly this pull request."""
        if not isinstance(number, int) or number < 1:
            raise RouteViolation(f"cannot bind to pull request {number!r}")
        return replace(self, owned_pull=int(number))

    def bound_to_issue(self, number: int) -> "ApiPort":
        """A port permitted to mutate exactly this Issue."""
        if not isinstance(number, int) or number < 1:
            raise RouteViolation(f"cannot bind to Issue {number!r}")
        return replace(self, owned_issue=int(number))

    def _call(self, method: str, path: str, purpose: str, body: dict | None = None):
        assert_route_allowed(method, path)
        self.route_log.append(Route(method, _templatize(path), purpose))
        status, payload = self._send(method, path, body)
        if status in (401, 403):
            raise Refused(f"credential/permission refusal on {purpose}: {status}")
        if status >= 500 or status == 429:
            # Ambiguous: the write may or may not have landed. Callers must
            # reconcile with a lookup, never blind-retry.
            raise TransportError(f"ambiguous transport status {status} on {purpose}")
        if status in (404, 405, 409, 422):
            raise Refused(f"refused {purpose}: HTTP {status}")
        if status >= 400:
            raise TransportError(f"unclassifiable {purpose}: HTTP {status}")
        # Success is an allowlist, not "anything below 400". A 3xx redirect or a
        # 204 is not a completed mutation; treating one as success previously let
        # `{"message": "Moved Permanently"}` read as an applied update.
        if status not in SUCCESS_STATUSES:
            raise TransportError(
                f"unexpected non-success status {status} on {purpose}; "
                "reconcile by lookup before any retry"
            )
        return payload

    # -- pull requests ----------------------------------------------------
    def list_open_pulls_for_head(self, head_branch: str) -> list[dict]:
        """Server-side head filter, fully paginated.

        Filtering a single default page client-side was a duplicate-PR hazard:
        with more than per_page open PRs the target may not be on page 1, the
        lookup would see zero matches, and the round would open a second PR on
        the same head. GitHub's `head=owner:branch` filter exists for this, and
        pagination is followed to exhaustion rather than truncated.
        """
        collected: list[dict] = []
        page = 1
        while True:
            path = (
                f"/repos/{self.owner}/{self.repo}/pulls"
                f"?head={self.owner}:{head_branch}&state=open&per_page=100&page={page}"
            )
            payload = self._call("GET", path, "pr-lookup", None)
            if not isinstance(payload, list):
                raise TransportError("pr-lookup did not return a list")
            collected.extend(payload)
            if len(payload) < 100:
                break
            page += 1
            if page > 20:
                raise TransportError(
                    "pr-lookup pagination cap exceeded; refusing a truncated view"
                )
        for pull in collected:
            if (pull.get("head") or {}).get("ref") != head_branch:
                raise TransportError(
                    "pr-lookup returned a pull request for a different head; "
                    "refusing an unverified result set"
                )
        return [pull for pull in collected if pull.get("state") == "open"]

    def get_pull(self, number: int) -> dict:
        payload = self._call(
            "GET", f"/repos/{self.owner}/{self.repo}/pulls/{int(number)}", "pr-get"
        )
        if not isinstance(payload, dict):
            raise TransportError("pr-get did not return an object")
        return payload

    def create_pull(self, *, head: str, base: str, title: str, body: str) -> dict:
        if base != "main":
            raise TransportError("worker may only open PRs against main")
        payload = self._call(
            "POST",
            f"/repos/{self.owner}/{self.repo}/pulls",
            "pr-create",
            {"head": head, "base": base, "title": title, "body": body},
        )
        if not isinstance(payload, dict) or "number" not in payload:
            raise TransportError("pr-create returned no number; reconcile by lookup")
        return payload

    def update_pull(self, number: int, **fields) -> dict:
        rejected = set(fields) - ALLOWED_PR_PATCH_FIELDS
        if rejected:
            raise RouteViolation(f"PR update may not set {sorted(rejected)}")
        if self.owned_pull is None:
            raise RouteViolation(
                "this port is not bound to a pull request; PR mutation refused. "
                "Bind with bound_to_pull() from the fenced lease first"
            )
        if int(number) != self.owned_pull:
            raise RouteViolation(
                f"PR update confined to #{self.owned_pull}; refusing #{number}"
            )
        payload = self._call(
            "PATCH",
            f"/repos/{self.owner}/{self.repo}/pulls/{int(number)}",
            "pr-update",
            dict(fields),
        )
        if not isinstance(payload, dict):
            raise TransportError("pr-update did not return an object")
        return payload

    # -- issues -----------------------------------------------------------
    def get_issue(self, number: int) -> dict:
        payload = self._call(
            "GET", f"/repos/{self.owner}/{self.repo}/issues/{int(number)}", "issue-get"
        )
        if not isinstance(payload, dict):
            raise TransportError("issue-get did not return an object")
        return payload

    def create_issue(self, *, title: str, body: str) -> dict:
        payload = self._call(
            "POST",
            f"/repos/{self.owner}/{self.repo}/issues",
            "issue-create",
            {"title": title, "body": body},
        )
        if not isinstance(payload, dict) or "number" not in payload:
            raise TransportError("issue-create returned no number; reconcile by lookup")
        return payload

    def update_issue(self, number: int, **fields) -> dict:
        rejected = set(fields) - ALLOWED_ISSUE_PATCH_FIELDS
        if rejected:
            raise RouteViolation(f"Issue update may not set {sorted(rejected)}")
        if self.owned_issue is None:
            raise RouteViolation(
                "this port is not bound to an Issue; Issue mutation refused. "
                "Bind with bound_to_issue() first"
            )
        if int(number) != self.owned_issue:
            raise RouteViolation(
                f"Issue update confined to #{self.owned_issue}; refusing #{number}"
            )
        payload = self._call(
            "PATCH",
            f"/repos/{self.owner}/{self.repo}/issues/{int(number)}",
            "issue-update",
            dict(fields),
        )
        if not isinstance(payload, dict):
            raise TransportError("issue-update did not return an object")
        return payload

    def close_issue(self, number: int) -> dict:
        """Close a real Issue. Refuses anything that is actually a PR.

        GitHub serves pull requests from the issues endpoint, so a state change
        here could close a PR. The target is read first and refused when it
        carries `pull_request`, which no plain Issue does.
        """
        if self.owned_issue is None:
            raise RouteViolation(
                "this port is not bound to an Issue; close refused"
            )
        if int(number) != self.owned_issue:
            raise RouteViolation(
                f"close confined to Issue #{self.owned_issue}; refusing #{number}"
            )
        # Two independent read-then-act checks. Neither is structural — GitHub
        # decides the payload shape — so they are stated as defence in depth, not
        # as a proof that a PR can never be closed here. The binding above is the
        # load-bearing control.
        current = self.get_issue(number)
        if current.get("pull_request") is not None:
            raise RouteViolation(
                f"#{number} is a pull request, not an Issue; refusing to close it "
                "through the issues endpoint"
            )
        url = current.get("html_url")
        if isinstance(url, str) and "/pull/" in url:
            raise RouteViolation(
                f"#{number} has a pull-request html_url; refusing to close it "
                "through the issues endpoint"
            )
        payload = self._call(
            "PATCH", f"/repos/{self.owner}/{self.repo}/issues/{int(number)}",
            "issue-close", {"state": "closed"},
        )
        if not isinstance(payload, dict):
            raise TransportError("issue-close did not return an object")
        return payload

    # -- checks -----------------------------------------------------------
    def list_check_runs(self, oid: str) -> list[dict]:
        if not OID_RE.match(oid):
            raise TransportError("check-runs requires a lowercase full 40-hex OID")
        # Paginated to exhaustion and cross-checked against total_count. The
        # endpoint caps a page at 30, so reading only the first page hid any red
        # check beyond the thirtieth — a false green, and one that compounds
        # with the verdict logic.
        per_page = 100
        collected: list[dict] = []
        total: int | None = None
        page = 1
        while True:
            payload = self._call(
                "GET",
                f"/repos/{self.owner}/{self.repo}/commits/{oid}/check-runs"
                f"?per_page={per_page}&page={page}",
                "checks-lookup",
            )
            if not isinstance(payload, dict):
                raise TransportError("checks-lookup did not return an object")
            runs = payload.get("check_runs")
            if not isinstance(runs, list):
                raise TransportError("checks-lookup payload missing check_runs")
            # total_count is deny-on-unreadable, not best-effort. This endpoint
            # always sends it, and it is the only way to tell a complete view
            # from a truncated one; treating absence as "probably fine" is the
            # shape that once turned a swallowed page into a false ALL PASS.
            count = payload.get("total_count")
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise TransportError(
                    "checks-lookup payload missing a usable total_count; "
                    "refusing a view whose completeness cannot be established"
                )
            if total is None:
                total = count
            elif count != total:
                raise TransportError(
                    f"check-run total_count changed mid-walk {total} -> {count}; "
                    "the view is not a consistent snapshot"
                )
            collected.extend(runs)
            # Short page = last page. This is the loop's real control; without it
            # a full final page is indistinguishable from a middle one.
            if len(runs) < per_page or len(collected) >= total:
                break
            page += 1
            if page > 20:
                raise TransportError(
                    "checks-lookup pagination cap exceeded; refusing a truncated view"
                )
        if len(collected) != total:
            raise TransportError(
                f"incomplete check-run view: total_count={total} "
                f"collected={len(collected)}"
            )
        # Counting alone is not completeness. A page reordered between requests
        # yields a view that repeats one run and drops another, and len ==
        # total_count still holds — so a dropped red check would read as a
        # complete green view. Run ids are distinct per run; a required name
        # legitimately appears several times, so identity is the id, not the name.
        identities = [run.get("id") for run in collected
                      if isinstance(run, dict) and run.get("id") is not None]
        if len(set(identities)) != len(identities):
            raise TransportError(
                "duplicate check-run ids in a paginated view; the pages shifted "
                "mid-walk and the view is not a consistent snapshot"
            )
        return collected


@dataclass
class RefPort:
    """`agent/**` ref read/create/CAS/delete over the BAP-003 Deploy Key.

    Every mutation carries an explicit expected old OID and is executed as a
    single `git push --force-with-lease=<ref>:<expected>` so two workers cannot
    both win the same fence. An empty expectation means "must not exist".
    """

    remote: str
    _run: GitRunner
    ref_log: list[tuple[str, str]] = field(default_factory=list)

    @staticmethod
    def _check_ref(ref: str) -> None:
        if not AGENT_REF_RE.match(ref):
            raise RouteViolation(f"ref {ref!r} is outside the agent/** namespace")
        if not RESERVED_REF_RE.match(ref):
            raise RouteViolation(f"ref {ref!r} is outside the reserved host-loop families")

    def read(self, ref: str) -> str | None:
        """Return the remote OID, or None when absent. Ambiguity raises."""
        self._check_ref(ref)
        self.ref_log.append(("read", ref))
        code, out, err = self._run(["git", "ls-remote", "--exit-code", self.remote, ref])
        if code == 2 or (code == 0 and not out.strip()):
            return None
        if code != 0:
            raise TransportError(f"ambiguous ls-remote for {ref}: {err.strip()[:200]}")
        first = out.split("\n")[0].split()
        if len(first) != 2 or not OID_RE.match(first[0]):
            raise TransportError(f"unparsable ls-remote output for {ref}")
        return first[0]

    def _push(self, ref: str, new_oid: str | None, expected: str | None, op: str) -> None:
        self._check_ref(ref)
        if new_oid is not None and not OID_RE.match(new_oid):
            raise TransportError("new OID must be lowercase full 40-hex")
        if expected is not None and not OID_RE.match(expected):
            raise TransportError("expected OID must be lowercase full 40-hex")
        lease = f"--force-with-lease={ref}:{expected or ''}"
        source = "" if new_oid is None else new_oid
        argv = ["git", "push", "--atomic", lease, self.remote, f"{source}:{ref}"]
        self.ref_log.append((op, ref))
        code, _out, err = self._run(argv)
        if code != 0:
            text = err.lower()
            # Only git's lease-specific wording proves the expected OID was
            # stale. `[remote rejected]` alone does NOT: a ruleset, branch
            # protection or pre-receive hook produces the same phrase while the
            # fence is intact, and calling that a fence loss is exactly the
            # misreport this module promises not to make. git emits these tokens
            # untranslated regardless of locale.
            # Precedence matters, and getting it wrong misdirects the operator
            # in both directions:
            #   1. "stale info" is git's lease-specific wording. Only a rejected
            #      --force-with-lease produces it, so it is definitive even when
            #      some hook also chimed in.
            #   2. Policy markers next. A ruleset rejection whose text happens to
            #      mention a lock must NOT be laundered into a fence loss; that
            #      sends the operator hunting a concurrent worker that does not
            #      exist. This ordering was inverted, so "cannot lock ref"
            #      out-ranked "[remote rejected]".
            #   3. Only then the generic race wordings, which mean someone else
            #      moved the ref but are not lease-specific.
            # git emits these tokens untranslated regardless of locale.
            if "stale info" in text:
                raise Refused(f"fence lost on {op} of {ref}: stale expected OID")
            if ("declined" in text or "protected" in text
                    or "rule violations" in text or "[remote rejected]" in text):
                raise PolicyRefused(
                    f"policy declined {op} of {ref}: {err.strip()[:200]} — the "
                    "fence was not contested; fix the ref policy, do not retry"
                )
            if ("non-fast-forward" in text or "fetch first" in text
                    or "cannot lock ref" in text):
                raise Refused(
                    f"fence lost on {op} of {ref}: the ref moved under us"
                )
            raise TransportError(
                f"ambiguous {op} of {ref}: {err.strip()[:200]} — reconcile by "
                "ls-remote before any retry"
            )

    def create(self, ref: str, oid: str) -> None:
        """Create only. Fails closed if the ref already exists."""
        self._push(ref, oid, None, "create")

    def compare_and_swap(self, ref: str, expected: str, new_oid: str) -> None:
        if expected == new_oid:
            raise TransportError("compare_and_swap requires a changed OID")
        self._push(ref, new_oid, expected, "cas")

    def delete(self, ref: str, expected: str) -> None:
        self._push(ref, None, expected, "delete")


# ------------------------------------------------------- inventory / evidence

def route_inventory(*ports: ApiPort) -> dict[str, int]:
    """Constructed-route census for the HLR-003 negative evidence."""
    census: dict[str, int] = {}
    for port in ports:
        for route in port.route_log:
            key = f"{route.method} {route.template}"
            census[key] = census.get(key, 0) + 1
    return census


FORBIDDEN_CAPABILITIES: tuple[str, ...] = (
    "review",
    "approve",
    "merge",
    "auto_merge",
    "update_branch",
    "protection",
    "ruleset",
    "admin",
)


def forbidden_capability_count(*ports: ApiPort) -> int:
    """Count constructed routes the typed allowlist would not admit.

    The previous implementation only searched route-template strings for words
    like "review" or "merge". That is blind to a forbidden *effect* reached
    through an allowlisted shape — closing a pull request via
    PATCH /issues/<pr-number>, for instance — so it reported 0 while such a call
    had just succeeded. It now re-validates every recorded route, and remains a
    supporting signal only: the field-level and ownership guards, not this
    counter, are what actually confine effects.
    """
    total = 0
    for port in ports:
        for route in port.route_log:
            if (route.method, route.template) not in ALLOWED_ROUTES:
                total += 1
            else:
                lowered = f"{route.method} {route.template}".lower()
                if any(cap in lowered for cap in FORBIDDEN_CAPABILITIES):
                    total += 1
    return total
