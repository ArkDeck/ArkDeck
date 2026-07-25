#!/usr/bin/env python3
"""Exhaustive contract for cursor consistency (TASK-HLR-003).

The cursor wedge has now been fixed twice and two paths stayed open, so the
rule is stated once here instead of being patched per symptom.

The distinction the implementation must hold is CORRUPTION versus STALENESS:

  corruption  the Issue body cannot be understood — unparsable, wrong schema,
              missing or unknown fields, a malformed OID. Fatal: refusing is the
              only safe response, because acting on a misread cache is worse
              than stopping.
  staleness   the body is understood but a cached navigation fact no longer
              matches Truth. NEVER fatal. Every such field is re-derived from
              Truth, because cursor.py's own docstring calls this Issue "a
              rebuildable cache" that is "explicitly NOT a single source of
              truth" — and a cache that cannot be rebuilt from Truth IS a
              source of truth.

Why this matters concretely: reconciliation is the first statement of a round
and the cursor is written later, so treating staleness as fatal makes the lane
die before any write. Cursor writes are then 0 for ever and the cache can never
catch up. A single transient 502 on one cursor PATCH, or the process being
killed between a ref write and the matching cursor write, was enough to wedge
the task permanently. The round now advances the lease four to five times, so
that interrupt window occurs several times per round rather than once.

The asymmetry that gave it away: `cursor_main_oid` staleness was deliberately
refreshed with the comment "main advances constantly", while `lease_oid`
staleness — a field the same round rewrites repeatedly — was fatal.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_LOOP_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = HOST_LOOP_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from host_loop import cursor as cursor_mod  # noqa: E402
from host_loop.cursor import (  # noqa: E402
    CURSOR_FIELDS,
    CursorError,
    CursorState,
    Truth,
    parse_machine_block,
    rebuild_and_validate,
)

MAIN = "f" * 40
OTHER_MAIN = "e" * 40
TASK = "TASK-DEMO-001"
LEASE_REF = f"refs/heads/agent/host-loop/leases/{TASK}"


def state(**over) -> CursorState:
    base = dict(cursor_main_oid=MAIN, candidate_task=None, lease_ref=None,
                lease_oid=None, pr_number=None, pr_head=None, review_run=None,
                last_observed_at=1000)
    base.update(over)
    return CursorState(**base)


def truth(**over) -> Truth:
    base = dict(main_oid=MAIN, ready_tasks=frozenset({TASK}),
                open_pr_numbers=frozenset({21}), lease_oid_by_ref={})
    base.update(over)
    return Truth(**base)


class CorruptionIsFatal(unittest.TestCase):
    """Anything that cannot be understood must refuse, not be guessed at."""

    def test_missing_markers(self):
        with self.assertRaises(CursorError):
            parse_machine_block("no machine block")

    def test_duplicated_markers(self):
        with self.assertRaises(CursorError):
            parse_machine_block(state().render() + state().render())

    def test_unparsable_json(self):
        body = (f"{cursor_mod.OPEN_MARKER}\n{{not json\n{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaises(CursorError):
            parse_machine_block(body)

    def test_wrong_schema_even_with_every_field_present(self):
        import json
        payload = {"schema": "arkdeck-host-loop-cursor/v99"}
        payload.update({f: getattr(state(), f) for f in CURSOR_FIELDS})
        body = (f"{cursor_mod.OPEN_MARKER}\n"
                f"{json.dumps(payload, sort_keys=True, separators=(',', ':'))}\n"
                f"{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaisesRegex(CursorError, r"schema"):
            parse_machine_block(body)

    def test_an_unknown_field(self):
        import json
        payload = {"schema": cursor_mod.CURSOR_SCHEMA, "extra": 1}
        payload.update({f: getattr(state(), f) for f in CURSOR_FIELDS})
        body = (f"{cursor_mod.OPEN_MARKER}\n"
                f"{json.dumps(payload, sort_keys=True, separators=(',', ':'))}\n"
                f"{cursor_mod.CLOSE_MARKER}\n")
        with self.assertRaisesRegex(CursorError, r"non-cacheable"):
            parse_machine_block(body)

    def test_a_malformed_oid(self):
        with self.assertRaises(CursorError):
            state(cursor_main_oid="deadbeef").validate()

    def test_a_half_set_lease_pair(self):
        with self.assertRaises(CursorError):
            state(lease_ref=LEASE_REF).validate()


class StalenessIsNeverFatal(unittest.TestCase):
    """Every cached navigation fact is re-derived from Truth."""

    def test_a_stale_main_oid_is_refreshed(self):
        out = rebuild_and_validate(state(cursor_main_oid=OTHER_MAIN), truth())
        self.assertEqual(out.cursor_main_oid, MAIN)

    def test_a_lease_oid_behind_the_ref_is_refreshed_not_fatal(self):
        """The wedge: one dropped cursor write used to be terminal."""
        behind = state(candidate_task=TASK, lease_ref=LEASE_REF, lease_oid="1" * 40)
        out = rebuild_and_validate(
            behind, truth(lease_oid_by_ref={LEASE_REF: "2" * 40}))
        self.assertEqual(out.lease_oid, "2" * 40)

    def test_a_lease_ref_that_no_longer_exists_is_cleared(self):
        gone = state(candidate_task=TASK, lease_ref=LEASE_REF, lease_oid="1" * 40)
        out = rebuild_and_validate(gone, truth(lease_oid_by_ref={}))
        self.assertIsNone(out.lease_ref)
        self.assertIsNone(out.lease_oid)

    def test_a_candidate_that_is_no_longer_ready_is_cleared(self):
        out = rebuild_and_validate(state(candidate_task="TASK-GONE-001"), truth())
        self.assertIsNone(out.candidate_task)

    def test_a_pr_that_is_no_longer_open_is_cleared(self):
        out = rebuild_and_validate(state(pr_number=999, pr_head="a" * 40), truth())
        self.assertIsNone(out.pr_number)

    def test_every_kind_of_staleness_at_once_is_still_recoverable(self):
        wrecked = state(cursor_main_oid=OTHER_MAIN, candidate_task="TASK-GONE-001",
                        lease_ref=LEASE_REF, lease_oid="1" * 40, pr_number=999,
                        pr_head="a" * 40)
        out = rebuild_and_validate(wrecked, truth(lease_oid_by_ref={}))
        self.assertEqual(out.cursor_main_oid, MAIN)
        self.assertIsNone(out.candidate_task)
        self.assertIsNone(out.lease_ref)
        self.assertIsNone(out.pr_number)

    def test_reconciliation_is_idempotent(self):
        once = rebuild_and_validate(
            state(cursor_main_oid=OTHER_MAIN, lease_ref=LEASE_REF,
                  lease_oid="1" * 40),
            truth(lease_oid_by_ref={LEASE_REF: "2" * 40}))
        twice = rebuild_and_validate(once, truth(lease_oid_by_ref={LEASE_REF: "2" * 40}))
        self.assertEqual(once, twice)

    def test_a_consistent_cursor_is_returned_unchanged_except_for_main(self):
        consistent = state(candidate_task=TASK, pr_number=21, pr_head="b" * 40,
                           lease_ref=LEASE_REF, lease_oid="2" * 40)
        out = rebuild_and_validate(
            consistent, truth(lease_oid_by_ref={LEASE_REF: "2" * 40}))
        self.assertEqual(out, consistent)


class SelfHealing(unittest.TestCase):
    """The cursor must never be the reason a round cannot proceed."""

    def test_no_staleness_shape_raises(self):
        shapes = [
            state(cursor_main_oid=OTHER_MAIN),
            state(candidate_task="TASK-GONE-001"),
            state(pr_number=999),
            state(lease_ref=LEASE_REF, lease_oid="1" * 40),
            state(candidate_task="TASK-GONE-001", pr_number=999,
                  lease_ref=LEASE_REF, lease_oid="1" * 40),
        ]
        for index, shape in enumerate(shapes):
            with self.subTest(shape=index):
                rebuild_and_validate(shape, truth(lease_oid_by_ref={}))

    def test_a_foreign_lease_oid_is_reconciled_rather_than_wedging(self):
        """v3 stopped caching a foreign OID; a cursor already holding one must
        still recover, because the fix cannot retroactively clean the Issue."""
        poisoned = state(candidate_task=TASK, lease_ref=LEASE_REF,
                         lease_oid="9" * 40)
        out = rebuild_and_validate(
            poisoned, truth(lease_oid_by_ref={LEASE_REF: "2" * 40}))
        self.assertEqual(out.lease_oid, "2" * 40)

    def test_reconciliation_reports_what_it_corrected(self):
        """Silent correction would hide a real anomaly; it has to be visible."""
        self.assertTrue(hasattr(cursor_mod, "reconcile"),
                        "a reporting form of reconciliation must exist")
        out, corrections = cursor_mod.reconcile(
            state(cursor_main_oid=OTHER_MAIN, pr_number=999), truth())
        self.assertEqual(out.cursor_main_oid, MAIN)
        self.assertTrue(corrections, "corrections must be reported")
        joined = " ".join(corrections)
        self.assertIn("pr_number", joined)

    def test_a_clean_cursor_reports_no_corrections(self):
        _out, corrections = cursor_mod.reconcile(
            state(candidate_task=TASK, pr_number=21), truth())
        self.assertEqual(corrections, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
