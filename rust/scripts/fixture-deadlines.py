#!/usr/bin/env python3
"""Retention deadlines of a recorded Artifact store, moved past the startup sweep.

The Swift oracles' Artifact stores keep the deadlines their recording gave
them: a week after publication for the default class, 2026-09-21 for the
analyzer oracles. A harness seeds such a store into real daemons, and both
sweep expired Artifacts once at startup with the real clock (Swift's
`collectGarbage`, the Rust `collect_expired_artifacts`). Once a recorded
deadline has passed, the sweep reclaims the recorded sources before the first
request, and every answer that reads them changes.

So a harness seeds each index with every deadline moved forward by the same
whole number of days, computed once per run over every index it seeds: the
earliest lands at least a week after the run starts, as a fresh publication's
would, and the rows keep their order. Only each deadline's text changes, at
its recorded length, so a seeded store's file sizes stay as recorded. No
lease resolution, plan digest or recorded answer reads a deadline. The
recorded fixtures stay as Swift wrote them. The check scripts load this module
by file name, as they load one another.
"""
from __future__ import annotations

import datetime
import math
from pathlib import Path
import re

DEADLINE = re.compile(rb'("deadlineUTC"\s*:\s*")(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)(")')
ANY_DEADLINE = re.compile(rb'"deadlineUTC"\s*:\s*"')
FORMAT = '%Y-%m-%dT%H:%M:%SZ'
MARGIN = datetime.timedelta(days=7)
DAY = datetime.timedelta(days=1)


def _parse(text: bytes) -> datetime.datetime:
    return datetime.datetime.strptime(text.decode(), FORMAT).replace(tzinfo=datetime.timezone.utc)


def _deadlines(data: bytes) -> list[datetime.datetime]:
    found = [_parse(match.group(2)) for match in DEADLINE.finditer(data)]
    if len(found) != len(ANY_DEADLINE.findall(data)):
        raise ValueError('a recorded deadline is not spelled YYYY-MM-DDTHH:MM:SSZ')
    return found


def shift(indices: list[Path], now: datetime.datetime | None = None) -> datetime.timedelta:
    """Whole days that move the earliest deadline the `indices` record at
    least a week past `now`, the real clock by default; none when it already
    is, or when they record none."""
    deadlines = [deadline for index in indices for deadline in _deadlines(index.read_bytes())]
    if not deadlines:
        return datetime.timedelta(0)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return max(0, math.ceil((now + MARGIN - min(deadlines)) / DAY)) * DAY


def moved(data: bytes, by: datetime.timedelta) -> bytes:
    """An index document's bytes with each recorded deadline moved `by`."""
    _deadlines(data)
    result = DEADLINE.sub(
        lambda match: match.group(1) + (_parse(match.group(2)) + by).strftime(FORMAT).encode()
        + match.group(3), data)
    if len(result) != len(data):
        raise ValueError('a moved deadline changed its length')
    return result


def copy(source: Path, destination: Path, by: datetime.timedelta) -> None:
    """`source` copied to `destination`, its deadlines moved `by` if it is an
    Artifact index."""
    data = source.read_bytes()
    destination.write_bytes(moved(data, by) if source.name == 'index.json' else data)
