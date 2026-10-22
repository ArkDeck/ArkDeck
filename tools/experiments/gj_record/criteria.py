"""Criteria bookkeeping shared by every Journey.

A criterion either holds on a value the Runtime published, fails on that value
(the raw value is kept), or cannot be judged because the step that would
publish it was not captured. The Journey's state follows mechanically:

- every criterion holds                      -> REAL_DEVICE_PASS
- the first failure is a Runtime value        -> BLOCKED_BY_PRODUCT_DEFECT
- the first failure is a step not captured    -> IMPLEMENTING
- nothing of the Journey was captured         -> NOT_STARTED
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .run import Run, Step

PASS = "REAL_DEVICE_PASS"
DEFECT = "BLOCKED_BY_PRODUCT_DEFECT"
INCOMPLETE = "IMPLEMENTING"
NOT_STARTED = "NOT_STARTED"


@dataclass
class Check:
    criterion: str
    holds: bool
    raw: object
    sources: list[str]
    missing: bool = False

    def document(self) -> dict:
        return {"criterion": self.criterion, "holds": self.holds, "sources": self.sources}


@dataclass
class Judge:
    run: Run
    checks: list[Check] = field(default_factory=list)

    def missing(self, criterion: str, what: str) -> None:
        self.checks.append(Check(criterion, False, f"not captured: {what}", [], missing=True))

    def expect(self, criterion: str, actual, expected, *steps: Step | None) -> bool:
        return self.that(criterion, actual == expected, actual, *steps)

    def that(self, criterion: str, holds: bool, raw, *steps: Step | None) -> bool:
        sources = sorted({s.file for s in steps if s is not None})
        self.checks.append(Check(criterion, bool(holds), raw, sources))
        return bool(holds)

    def state(self) -> tuple[str, dict | None]:
        for check in self.checks:
            if not check.holds:
                return (INCOMPLETE if check.missing else DEFECT), {
                    "criterion": check.criterion,
                    "raw": check.raw,
                    "sources": check.sources,
                }
        if not self.checks:
            return NOT_STARTED, None
        return PASS, None
