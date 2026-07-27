"""Instance and protocol constants for the host loop (TASK-DEC-002).

Every value here is one of two things: a *protocol* constant that appears on
the wire or in persisted state, or an *instance* parameter that names this
deployment. Both kinds were previously spelled out at their point of use,
several of them in more than one module, so a rename in one place could drift
from its twin silently.

Two rules keep this module trustworthy:

* **Data only.** No logic, no I/O, no imports of other host_loop modules.
  Consumers compile their own regexes and build their own strings from these
  pieces; nothing here can fail, so nothing here needs a failure mode.
* **Changing a value here changes the wire.** The lease schema is written into
  live lease commits, the cursor markers delimit the machine block on the live
  navigation Issue, and the environment variable names are how the process
  finds its credential. `test_instance_contract.py` freezes each value against
  an independently written copy for exactly that reason: when this task moved
  them, eight of them could be corrupted without a single test noticing.
"""

from __future__ import annotations


# --- refs and namespaces ------------------------------------------------
# The worker writes only under `refs/heads/agent/host-loop/**`; the Deploy Key
# and the repository ruleset are both scoped to that prefix.
REF_HEADS_PREFIX = "refs/heads/"
AGENT_NAMESPACE = "agent/host-loop"
LEASE_NAMESPACE = f"{AGENT_NAMESPACE}/leases"
TASK_NAMESPACE = f"{AGENT_NAMESPACE}/tasks"
PROBE_NAMESPACE = f"{AGENT_NAMESPACE}/probes"
# The three reserved second-level segments, in the order the transport's
# reserved-ref pattern lists them.
RESERVED_NAMESPACE_SEGMENTS = ("tasks", "leases", "probes")

LEASE_REF_PREFIX = f"{REF_HEADS_PREFIX}{LEASE_NAMESPACE}/"
TASK_BRANCH_PREFIX = f"{REF_HEADS_PREFIX}{TASK_NAMESPACE}/"

# The only branch the worker may open a pull request against.
BASE_BRANCH = "main"


# --- protocol identifiers written to the wire or to persisted state ------
LEASE_SCHEMA = "arkdeck-host-loop-lease/v1"
CURSOR_SCHEMA = "arkdeck-host-loop-cursor/v1"
CURSOR_OPEN_MARKER = "<!-- arkdeck-host-loop-cursor:v1 -->"
CURSOR_CLOSE_MARKER = "<!-- /arkdeck-host-loop-cursor -->"
ENVELOPE_OPEN_MARKER = "<!-- arkdeck-pr-envelope:v1 -->"
ENVELOPE_CLOSE_MARKER = "<!-- /arkdeck-pr-envelope -->"
ENVELOPE_RUNTIME_ID = "host-loop/1"

# The task-id grammar. `check_pr_paths.py` carries the fourth copy of this
# text; it sits outside this package and `test_token_parity.py` guards the two
# against drift.
TASK_TOKEN_TEXT = r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?"


# --- attributable identity of everything this loop writes ----------------
GIT_AUTHOR_NAME = "arkdeck-host-loop"
GIT_AUTHOR_EMAIL = "host-loop@arkdeck.invalid"
GIT_COMMITTER_NAME = GIT_AUTHOR_NAME
GIT_COMMITTER_EMAIL = GIT_AUTHOR_EMAIL
USER_AGENT = "arkdeck-host-loop/1"


# --- deployment instance -------------------------------------------------
API_ROOT = "https://api.github.com"
DEFAULT_OWNER = "ArkDeck"
DEFAULT_REPO = "ArkDeck"
DEFAULT_OWNER_RUN = "host-loop/worker"

ENV_TOKEN = "ARKDECK_HOST_LOOP_TOKEN"
ENV_TOKEN_FILE = "ARKDECK_HOST_LOOP_TOKEN_FILE"
ENV_REPO_DIR = "ARKDECK_REPO"
ENV_CURSOR_ISSUE = "ARKDECK_HOST_LOOP_CURSOR_ISSUE"
ENV_OWNER_RUN = "ARKDECK_HOST_LOOP_OWNER"


# --- timing --------------------------------------------------------------
GIT_TIMEOUT_SECONDS = 120
HTTP_TIMEOUT_SECONDS = 60
# Must exceed the longest single external write the lease gate protects
# (HTTP_TIMEOUT_SECONDS), with slack for the round trip.
LEASE_WRITE_MARGIN_SECONDS = 90
DEFAULT_LEASE_TTL_SECONDS = 900


# --- rendered text the remote sees ---------------------------------------
# Templates, not sentences: the `{task_id}` field is the only substitution.
TASK_BRANCH_COMMIT_SUBJECT = "chore({task_id}): host-loop task branch"
DISPATCH_PULL_TITLE = "{task_id}: host-loop dispatch"
