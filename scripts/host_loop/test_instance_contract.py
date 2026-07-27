"""TASK-DEC-002: the consolidated constants are frozen, and consolidated once.

Two properties, and the reason each one needs a test.

**Frozen.** These values go on the wire or into persisted state — the lease
schema is written into live lease commits, the cursor markers delimit the
machine block on the live navigation Issue, the environment variable names are
how the process finds its credential. Before this task moved them, eight of
them could be corrupted without a single test in the suite going red, measured
one at a time. A move is exactly the operation that can change a byte by
accident, so each value is compared against a copy written out independently
below. Importing the constant and asserting it equals itself would be the
tautology this repository has already recorded more than five times.

**Consolidated once.** The point of the move is that a rename cannot drift
from its twin, which only holds while there is one definition. The census
walks the AST rather than the source text: a `grep` for a literal also matches
the comment above it, and this repository has already shipped a test that
stayed green through a defect for precisely that reason. Comments are absent
from an AST by construction; docstrings are excluded explicitly.
"""

from __future__ import annotations

import ast
import pathlib
import sys
import unittest

HOST_LOOP_DIR = pathlib.Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import instance  # noqa: E402


# Written out by hand, not derived from the module under test. Any edit to
# `instance.py` that changes a byte has to be made here too, deliberately.
FROZEN_VALUES: dict[str, object] = {
    "REF_HEADS_PREFIX": "refs/heads/",
    "AGENT_NAMESPACE": "agent/host-loop",
    "LEASE_NAMESPACE": "agent/host-loop/leases",
    "TASK_NAMESPACE": "agent/host-loop/tasks",
    "PROBE_NAMESPACE": "agent/host-loop/probes",
    "RESERVED_NAMESPACE_SEGMENTS": ("tasks", "leases", "probes"),
    "LEASE_REF_PREFIX": "refs/heads/agent/host-loop/leases/",
    "TASK_BRANCH_PREFIX": "refs/heads/agent/host-loop/tasks/",
    "BASE_BRANCH": "main",
    "LEASE_SCHEMA": "arkdeck-host-loop-lease/v1",
    "CURSOR_SCHEMA": "arkdeck-host-loop-cursor/v1",
    "CURSOR_OPEN_MARKER": "<!-- arkdeck-host-loop-cursor:v1 -->",
    "CURSOR_CLOSE_MARKER": "<!-- /arkdeck-host-loop-cursor -->",
    "ENVELOPE_OPEN_MARKER": "<!-- arkdeck-pr-envelope:v1 -->",
    "ENVELOPE_CLOSE_MARKER": "<!-- /arkdeck-pr-envelope -->",
    "ENVELOPE_RUNTIME_ID": "host-loop/1",
    "TASK_TOKEN_TEXT": r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?",
    "GIT_AUTHOR_NAME": "arkdeck-host-loop",
    "GIT_AUTHOR_EMAIL": "host-loop@arkdeck.invalid",
    "GIT_COMMITTER_NAME": "arkdeck-host-loop",
    "GIT_COMMITTER_EMAIL": "host-loop@arkdeck.invalid",
    "USER_AGENT": "arkdeck-host-loop/1",
    "API_ROOT": "https://api.github.com",
    "DEFAULT_OWNER": "ArkDeck",
    "DEFAULT_REPO": "ArkDeck",
    "DEFAULT_OWNER_RUN": "host-loop/worker",
    "ENV_TOKEN": "ARKDECK_HOST_LOOP_TOKEN",
    "ENV_TOKEN_FILE": "ARKDECK_HOST_LOOP_TOKEN_FILE",
    "ENV_REPO_DIR": "ARKDECK_REPO",
    "ENV_CURSOR_ISSUE": "ARKDECK_HOST_LOOP_CURSOR_ISSUE",
    "ENV_OWNER_RUN": "ARKDECK_HOST_LOOP_OWNER",
    "GIT_TIMEOUT_SECONDS": 120,
    "HTTP_TIMEOUT_SECONDS": 60,
    "LEASE_WRITE_MARGIN_SECONDS": 90,
    "DEFAULT_LEASE_TTL_SECONDS": 900,
    "TASK_BRANCH_COMMIT_SUBJECT": "chore({task_id}): host-loop task branch",
    "DISPATCH_PULL_TITLE": "{task_id}: host-loop dispatch",
}

# Literals whose single remaining definition is `instance.py`. The match mode
# is per literal because a re-spelling does not have to be a whole string:
# `f"agent/host-loop/tasks/{task}"` stores the constant chunk
# `"agent/host-loop/tasks/"`, one slash away from the namespace, and an
# equality check walks straight past it — measured, this exact mutation
# survived the first census. Structured values are therefore matched as
# substrings. `main` is the exception: as a substring it appears inside
# `__main__`, `remaining` and any prose containing the word, so it is matched
# whole.
# Value is (match mode, modules allowed to contain it anyway, with the reason
# stated in the entry).
SINGLE_DEFINITION_LITERALS: dict[str, tuple[str, tuple[str, ...]]] = {
    "main": ("exact", ()),
    "agent/host-loop": ("substring", ()),
    "refs/heads/agent/host-loop": ("substring", ()),
    "arkdeck-host-loop-lease/v1": ("substring", ()),
    "arkdeck-host-loop-cursor/v1": ("substring", ()),
    "<!-- arkdeck-host-loop-cursor": ("substring", ()),
    "<!-- arkdeck-pr-envelope": ("substring", ()),
    "host-loop/1": ("substring", ()),
    "arkdeck-host-loop": ("substring", ()),
    "host-loop@arkdeck.invalid": ("substring", ()),
    "https://api.github.com": ("substring", ()),
    "ARKDECK_HOST_LOOP_TOKEN": ("substring", ()),
    "ARKDECK_HOST_LOOP_OWNER": ("substring", ()),
    "ARKDECK_HOST_LOOP_CURSOR_ISSUE": ("substring", ()),
    "ARKDECK_REPO": ("substring", ()),
    "host-loop/worker": ("substring", ()),
    # backends.py renders "none: host-loop dispatch carries no evidence
    # file" as envelope prose; the phrase collides with the title
    # template without being a second spelling of it.
    "host-loop dispatch": ("substring", ("backends.py",)),
    "host-loop task branch": ("substring", ()),
    r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?": ("substring", ()),
}

PRODUCTION_MODULES = (
    "__init__.py",
    "__main__.py",
    "backends.py",
    "cursor.py",
    "identity.py",
    "instance.py",
    "lease.py",
    "pr_envelope.py",
    "recovery.py",
    "reviewer.py",
    "transport.py",
    "worker.py",
)


def _docstring_nodes(tree: ast.AST) -> set[int]:
    """Every string node that is a docstring, by identity.

    Docstrings are the one place a value may legitimately be spelled out
    again — prose describing the constant is not a second definition.
    """
    marked: set[int] = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            marked.add(id(first.value))
    return marked


def _string_literals(path: pathlib.Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    skip = _docstring_nodes(tree)
    return [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and id(node) not in skip
    ]


class ConsolidatedValuesAreFrozen(unittest.TestCase):
    def test_every_value_matches_its_independently_written_copy(self):
        for name, expected in sorted(FROZEN_VALUES.items()):
            with self.subTest(constant=name):
                self.assertEqual(getattr(instance, name), expected)

    def test_the_frozen_set_covers_every_public_constant(self):
        """A new constant must be frozen too, or this test says so."""
        public = {
            name
            for name in vars(instance)
            if name.isupper() and not name.startswith("_")
        }
        self.assertEqual(public, set(FROZEN_VALUES))

    def test_derived_prefixes_agree_with_their_parts(self):
        self.assertEqual(
            instance.LEASE_REF_PREFIX,
            f"{instance.REF_HEADS_PREFIX}{instance.LEASE_NAMESPACE}/",
        )
        self.assertEqual(
            instance.TASK_BRANCH_PREFIX,
            f"{instance.REF_HEADS_PREFIX}{instance.TASK_NAMESPACE}/",
        )
        self.assertEqual(instance.GIT_COMMITTER_NAME, instance.GIT_AUTHOR_NAME)
        self.assertEqual(instance.GIT_COMMITTER_EMAIL, instance.GIT_AUTHOR_EMAIL)

    def test_the_lease_margin_still_exceeds_the_write_it_protects(self):
        self.assertGreater(
            instance.LEASE_WRITE_MARGIN_SECONDS, instance.HTTP_TIMEOUT_SECONDS
        )


class InstanceIsDataOnly(unittest.TestCase):
    """No logic, no I/O, no host_loop imports — so it cannot fail at import."""

    def test_the_module_only_assigns_literals_and_joins_them(self):
        tree = ast.parse((HOST_LOOP_DIR / "instance.py").read_text(encoding="utf-8"))
        for node in tree.body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                continue  # module docstring
            if isinstance(node, ast.ImportFrom) and node.module == "__future__":
                continue
            self.assertIsInstance(
                node, (ast.Assign, ast.AnnAssign), f"unexpected statement: {node}"
            )
        for node in ast.walk(tree):
            self.assertNotIsInstance(
                node,
                (ast.Call, ast.Import, ast.FunctionDef, ast.ClassDef,
                 ast.AsyncFunctionDef, ast.With, ast.Try),
                f"instance.py must stay data-only, found {type(node).__name__}",
            )


class EachFamilyHasOneDefinition(unittest.TestCase):
    def test_no_production_module_respells_a_consolidated_literal(self):
        for literal, (mode, allowed) in sorted(SINGLE_DEFINITION_LITERALS.items()):
            for module in PRODUCTION_MODULES:
                if module == "instance.py" or module in allowed:
                    continue
                found = _string_literals(HOST_LOOP_DIR / module)
                offenders = [
                    value
                    for value in found
                    if (value == literal if mode == "exact" else literal in value)
                ]
                with self.subTest(literal=literal, module=module):
                    self.assertEqual(
                        offenders,
                        [],
                        f"{module} respells a literal that instance.py owns",
                    )

    def test_the_census_reads_the_ast_and_not_the_comments(self):
        """The scan must not be satisfiable by prose.

        A grep-based census would match this very sentence. Feeding the
        scanner a module whose only occurrence is a comment must yield
        nothing, and moving that same text into an assignment must yield it.
        """
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            probe = pathlib.Path(directory) / "probe.py"
            probe.write_text(
                '"""A docstring mentioning main and agent/host-loop."""\n'
                "# a comment mentioning main and agent/host-loop\n"
                "OTHER = 1\n",
                encoding="utf-8",
            )
            self.assertEqual(_string_literals(probe), [])
            probe.write_text('VALUE = "agent/host-loop"\n', encoding="utf-8")
            self.assertEqual(_string_literals(probe), ["agent/host-loop"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
