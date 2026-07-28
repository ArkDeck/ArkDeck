#!/usr/bin/env python3
"""ArkDeck SDD 只读一致性校验(V2 git-native 治理)。

只做发现问题,不承担授权语义(批准 = 维护者 PR review)。检查:
  1. openspec/ 下所有 YAML/JSON 可解析,YAML 拒绝重复 key;
  2. specs:REQ/AC ID 全局唯一;每个 Requirement 至少一个 Scenario;
     AC 编号前缀与所属 Requirement 匹配;
  3. acceptance-cases.yaml / acceptance-index.txt / specs 三方 AC 集合精确一致,
     expected_source 的文件与锚点可解析;
  4. capability-registry:capability 与 specs 目录 1:1;release class 合法;
     requires 闭包无未知项、无环;
  5. changes:必需 artifact 存在;proposal front matter 的 status/class 合法;
     tasks.md 的任务状态行合法;
  6. 含 scope.yaml 的 change 中,每个 acceptance ID 均被 tasks.md 的
     Requirements/AC 认领面精确认领;
  7. active changes 的 proposal/acceptance/verification revision 保持同步,
     archive/** 豁免;
  8. active changes 中精确 `yaml pins` fenced block 使用封闭 schema 与
     完整 40/64-hex digest,其他 info string 与 archive/** 不扫描;
  9. integration registry 与 fixture pack 内不出现整条仓内 change 路径
     (归档即失效),仅显式 deferred 登记表内的文件按登记次数豁免,多于或
     少于登记值同样 fail;
 10. platform/integration lock 与 core-conformance 引用的路径存在,
     safety_coverage 引用的 AC 存在。

退出码:0 = 通过(允许 warning);1 = 存在 error。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
OPENSPEC = REPO / "openspec"

errors: list[str] = []
warnings: list[str] = []


def err(path, msg):
    errors.append(f"ERROR {rel(path)}: {msg}")


def warn(path, msg):
    warnings.append(f"WARN  {rel(path)}: {msg}")


def rel(path):
    try:
        return str(Path(path).relative_to(REPO))
    except ValueError:
        return str(path)


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys."""


def _strict_map(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.YAMLError(f"duplicate mapping key: {key!r}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _strict_map
)


def load_yaml(path, *, empty_is_error=False):
    """Parse a YAML file. `empty_is_error` refuses a document that is null.

    An empty file, a comments-only file and a literal `null` all parse to None
    without raising, so every caller that wrote `if not data: return` skipped
    its entire check in silence — a truncated governance file read exactly like
    a clean one. Callers that own a required document now pass
    empty_is_error=True and get a reported failure instead of a skipped check.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=StrictLoader)
    except Exception as exc:  # noqa: BLE001 - report every parse failure
        err(path, f"YAML parse failed: {exc}")
        return None
    if data is None and empty_is_error:
        err(path, "document is empty or null; a required document may not be blank")
    return data


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:  # noqa: BLE001
        err(path, f"JSON parse failed: {exc}")
        return None


def front_matter(path):
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        err(path, "unterminated front matter")
        return None
    try:
        return yaml.load(text[4:end], Loader=StrictLoader)
    except Exception as exc:  # noqa: BLE001
        err(path, f"front matter parse failed: {exc}")
        return None


# ---------------------------------------------------------------- 1. parse all
def check_parse_all():
    for path in sorted(OPENSPEC.rglob("*")):
        if path.is_dir():
            continue
        if path.suffix in (".yaml", ".yml"):
            load_yaml(path)
        elif path.suffix == ".json":
            load_json(path)


# ---------------------------------------------------------------- 2. spec lint
REQ_RE = re.compile(r"^### Requirement: (REQ-[A-Z0-9]+-\d+)\b")
SCEN_RE = re.compile(r"^#### Scenario: (AC-[A-Z0-9]+-\d+-\d+)\b")


def check_specs():
    req_owner: dict[str, Path] = {}
    ac_owner: dict[str, Path] = {}
    spec_acs: set[str] = set()
    for spec in sorted((OPENSPEC / "specs").glob("*/spec.md")):
        current_req = None
        current_scenarios = 0
        pending: list[tuple[str, int]] = []

        def close_req(path=spec):
            nonlocal current_req, current_scenarios
            if current_req is not None and current_scenarios == 0:
                err(path, f"{current_req} has no Scenario")
            current_req, current_scenarios = None, 0

        for lineno, line in enumerate(
            spec.read_text(encoding="utf-8").splitlines(), 1
        ):
            m = REQ_RE.match(line)
            if m:
                close_req()
                req = m.group(1)
                if req in req_owner:
                    err(spec, f"duplicate {req} (also in {rel(req_owner[req])})")
                req_owner[req] = spec
                current_req = req
                continue
            m = SCEN_RE.match(line)
            if m:
                ac = m.group(1)
                if ac in ac_owner:
                    err(spec, f"duplicate {ac} (also in {rel(ac_owner[ac])})")
                ac_owner[ac] = spec
                spec_acs.add(ac)
                if current_req is None:
                    err(spec, f"{ac} appears before any Requirement (line {lineno})")
                else:
                    current_scenarios += 1
                    if not ac.startswith("AC-" + current_req[len("REQ-"):] + "-"):
                        err(spec, f"{ac} does not match enclosing {current_req}")
        close_req()
    return spec_acs


# ------------------------------------------------- 3. acceptance registry sync
def check_acceptance(spec_acs):
    index_path = OPENSPEC / "verification" / "acceptance-index.txt"
    cases_path = OPENSPEC / "verification" / "acceptance-cases.yaml"

    index_ids = [
        line.strip()
        for line in index_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    index_set = set(index_ids)
    if len(index_ids) != len(index_set):
        err(index_path, "duplicate IDs in acceptance index")
    if index_ids != sorted(index_ids):
        err(index_path, "acceptance index is not sorted")

    if not index_path.is_file():
        err(index_path, "acceptance index is missing")
        return
    cases = load_yaml(cases_path, empty_is_error=True)
    if not isinstance(cases, dict):
        cases = {}
    case_ids = set()
    for case in cases.get("cases") or []:
        if not isinstance(case, dict):
            err(cases_path, "each acceptance case must be a mapping")
            continue
        ac = case.get("acceptance_id")
        if not isinstance(ac, str) or not ac:
            err(cases_path, "acceptance case is missing a string acceptance_id")
            continue
        if ac in case_ids:
            err(cases_path, f"duplicate case {ac}")
        case_ids.add(ac)
        src = case.get("expected_source", "")
        if "#" in src:
            file_part, anchor = src.split("#", 1)
            src_path = REPO / file_part
            if not src_path.is_file():
                err(cases_path, f"{ac}: expected_source file missing: {file_part}")
            elif anchor not in src_path.read_text(encoding="utf-8"):
                err(cases_path, f"{ac}: anchor {anchor} not found in {file_part}")
        else:
            err(cases_path, f"{ac}: expected_source lacks #anchor: {src!r}")

    for label, left, right in (
        ("specs vs index", spec_acs, index_set),
        ("cases vs index", case_ids, index_set),
    ):
        missing, extra = right - left, left - right
        if missing:
            err(cases_path, f"{label}: missing {sorted(missing)[:5]}…({len(missing)})"
                if len(missing) > 5 else f"{label}: missing {sorted(missing)}")
        if extra:
            err(cases_path, f"{label}: extra {sorted(extra)[:5]}…({len(extra)})"
                if len(extra) > 5 else f"{label}: extra {sorted(extra)}")


# ---------------------------------------------------- 4. capability registry
def check_capability_registry():
    path = OPENSPEC / "contracts" / "capability-registry.yaml"
    data = load_yaml(path, empty_is_error=True)
    if not isinstance(data, dict):
        if data is not None:
            err(path, "capability registry must be a mapping")
        return
    entries = data.get("capabilities") or []
    if not isinstance(entries, list):
        err(path, "capabilities must be a list")
        return
    caps: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            err(path, "each capability must be a mapping")
            continue
        cid = entry.get("id")
        # A dict comprehension silently kept the last entry, so a duplicate id
        # meant the first entry's release class and requires were never checked
        # and the 1:1 comparison against spec dirs could not see the collision.
        # StrictLoader's duplicate-key rejection does not apply here: these are
        # list items, not mapping keys.
        if cid in caps:
            err(path, f"duplicate capability id {cid!r}")
            continue
        caps[cid] = entry
    spec_dirs = {p.parent.name for p in (OPENSPEC / "specs").glob("*/spec.md")}
    if set(caps) != spec_dirs:
        err(path, f"capabilities != spec dirs; only-registry={sorted(set(caps)-spec_dirs)} only-specs={sorted(spec_dirs-set(caps))}")
    for cid, cap in caps.items():
        if cap.get("release") not in ("required", "optional"):
            err(path, f"{cid}: illegal release class {cap.get('release')!r}")
        for dep in cap.get("requires") or []:
            if dep not in caps:
                err(path, f"{cid}: unknown dependency {dep}")
    # cycle check
    seen, stack = set(), set()

    def visit(cid):
        if cid in stack:
            err(path, f"dependency cycle at {cid}")
            return
        if cid in seen or cid not in caps:
            return
        stack.add(cid)
        for dep in caps[cid].get("requires") or []:
            visit(dep)
        stack.discard(cid)
        seen.add(cid)

    for cid in caps:
        visit(cid)


# --------------------------------------------------------------- 5. changes
CHANGE_STATUSES = {"proposed", "approved", "implementing", "verified", "archived", "rejected"}
CHANGE_CLASSES = {"core", "capability", "integration", "platform", "implementation-only"}
# `[::]` was two ASCII colons, so the intended full-width tolerance never
# existed; `[:：]` is what the sibling guard in check_pr_paths.py accepts.
# The trailing boundary is what stops `- Status:readyish` and
# `- Status:done_later` from counting as legal status lines.
TASK_STATUS_RE = re.compile(
    r"^- Status[:：][ \t]*(ready|in_progress|done|blocked)(?![A-Za-z0-9_-])")
REQUIREMENTS_AC_PREFIX = "- Requirements/AC:"
# A claim surface ends at the next top-level bullet OR at any heading.
_CLAIM_SURFACE_END_RE = re.compile(r"^(?:- |#{1,6}[ \t])")
IDENTIFIER_BOUNDARY_CHARS = r"A-Za-z0-9_-"
VERIFICATION_REVISION_RE = re.compile(
    r"^> Change:[A-Za-z0-9][A-Za-z0-9-]*@r(?P<revision>[1-9][0-9]*)\s*$"
)


def check_changes():
    changes_dir = OPENSPEC / "changes"
    # Anything that is neither a chg-* directory, the archive, nor the README
    # was silently unvalidated — including a directory whose name differs only
    # in case, which this glob does not match on a case-sensitive filesystem.
    if not changes_dir.is_dir():
        err(changes_dir, "changes directory is missing")
        return
    for entry in sorted(changes_dir.iterdir()):
        if entry.name in ("archive", "README.md") or entry.name.startswith("chg-"):
            continue
        err(changes_dir, f"unexpected entry {entry.name!r} under changes/")
    for change in sorted(changes_dir.glob("chg-*")):
        if not change.is_dir():
            continue
        for required in ("proposal.md", "tasks.md", "verification.md"):
            if not (change / required).is_file():
                err(change, f"missing required artifact {required}")
        proposal = change / "proposal.md"
        if proposal.is_file():
            fm = front_matter(proposal)
            if fm is None:
                err(proposal, "missing front matter")
            elif not isinstance(fm, dict):
                # `--- \n just a string \n ---` parsed to a str, and the
                # `.get` below raised AttributeError, aborting the run.
                err(proposal, "front matter must be a mapping")
            else:
                if fm.get("status") not in CHANGE_STATUSES:
                    err(proposal, f"illegal status {fm.get('status')!r}")
                if fm.get("class") not in CHANGE_CLASSES:
                    err(proposal, f"illegal class {fm.get('class')!r}")
                if not fm.get("id"):
                    err(proposal, "missing id")
        tasks = change / "tasks.md"
        if tasks.is_file():
            # Counted per task, not in aggregate. Comparing two totals meant a
            # task carrying two status-looking lines paid for a task carrying
            # none, so a task with no declared status could pass.
            sections: list[tuple[str, int]] = []
            for line in tasks.read_text(encoding="utf-8").splitlines():
                if line.startswith("## TASK-"):
                    sections.append((line.strip(), 0))
                elif sections and TASK_STATUS_RE.match(line):
                    heading, count = sections[-1]
                    sections[-1] = (heading, count + 1)
            if not sections:
                warn(tasks, "no tasks defined")
            for heading, count in sections:
                if count != 1:
                    err(tasks, f"{heading[:60]} has {count} legal Status lines, expected 1")


# -------------------------------------------- 6. change revision consistency
def _display_revision(value) -> str:
    if isinstance(value, str) and value.startswith("<"):
        return value
    return repr(value)


def _is_revision(value) -> bool:
    return type(value) is int and value > 0


def check_change_revision_consistency(changes_dir: Path | None = None):
    """Require active change revision carriers to agree; archive is not scanned."""
    changes_dir = changes_dir or OPENSPEC / "changes"
    for change in sorted(changes_dir.glob("chg-*")):
        if not change.is_dir():
            continue

        proposal = change / "proposal.md"
        proposal_data = front_matter(proposal) if proposal.is_file() else None
        if isinstance(proposal_data, dict):
            proposal_revision = proposal_data.get("revision", "<missing>")
        else:
            proposal_revision = "<unparseable>"

        acceptance = change / "acceptance-cases.yaml"
        acceptance_present = acceptance.is_file()
        if acceptance_present:
            acceptance_data = load_yaml(acceptance)
            if isinstance(acceptance_data, dict):
                acceptance_revision = acceptance_data.get(
                    "change_revision", "<missing>"
                )
            else:
                acceptance_revision = "<unparseable>"
        else:
            acceptance_revision = "<not-present>"

        verification = change / "verification.md"
        verification_revision: int | str = "<missing>"
        if verification.is_file():
            header_lines = [
                line
                for line in verification.read_text(encoding="utf-8").splitlines()
                if line.startswith("> Change:")
            ]
            if len(header_lines) == 1:
                match = VERIFICATION_REVISION_RE.fullmatch(header_lines[0])
                verification_revision = (
                    int(match.group("revision"))
                    if match is not None
                    else "<unparseable>"
                )
            elif len(header_lines) > 1:
                verification_revision = "<ambiguous>"

        compared = [proposal_revision, verification_revision]
        if acceptance_present:
            compared.append(acceptance_revision)
        if all(_is_revision(value) for value in compared) and len(set(compared)) == 1:
            continue

        err(
            change,
            "revision consistency failed: "
            f"proposal revision={_display_revision(proposal_revision)}; "
            "acceptance change_revision="
            f"{_display_revision(acceptance_revision)}; "
            f"verification @r={_display_revision(verification_revision)}",
        )


# ----------------------------------------------------- 7. change scope coverage
def requirements_ac_claim_surfaces(tasks_text: str) -> list[str]:
    """Return top-level Requirements/AC bullets and their indented continuations."""
    lines = tasks_text.splitlines()
    surfaces: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not line.startswith(REQUIREMENTS_AC_PREFIX):
            index += 1
            continue

        surface = [line]
        index += 1
        # A heading ends the claim, as does the next top-level bullet. Only the
        # bullet used to stop the scan, so non-bullet lines were skipped over
        # rather than terminating it: an indented line under a LATER `## TASK-`
        # heading was still appended to the previous task's claim surface, and
        # an acceptance ID mentioned in that task's prose counted as claimed by
        # the one before it. This check is the one the governance model leans on
        # hardest, so its surface must end where the task does.
        while index < len(lines) and not _CLAIM_SURFACE_END_RE.match(lines[index]):
            continuation = lines[index]
            if continuation.startswith((" ", "\t")):
                surface.append(continuation)
            index += 1
        surfaces.append("\n".join(surface))
    return surfaces


def claimed_acceptance_ids(
    scope_ids: set[str], tasks_text: str
) -> set[str]:
    """Match opaque scope IDs exactly within Requirements/AC claim surfaces."""
    claim_text = "\n".join(requirements_ac_claim_surfaces(tasks_text))
    claimed = set()
    for acceptance_id in scope_ids:
        pattern = re.compile(
            rf"(?<![{IDENTIFIER_BOUNDARY_CHARS}])"
            rf"{re.escape(acceptance_id)}"
            rf"(?![{IDENTIFIER_BOUNDARY_CHARS}])"
        )
        if pattern.search(claim_text):
            claimed.add(acceptance_id)
    return claimed


def check_change_scope_coverage(changes_dir: Path | None = None):
    """Require each scoped acceptance ID to have an exact task claim."""
    changes_dir = changes_dir or OPENSPEC / "changes"
    for change in sorted(changes_dir.glob("chg-*")):
        if not change.is_dir():
            continue
        scope = change / "scope.yaml"
        if not scope.is_file():
            continue

        data = load_yaml(scope, empty_is_error=True)
        if data is None:
            # Already reported by load_yaml. Previously this branch returned
            # silently, so an emptied scope.yaml disabled the coverage check for
            # its whole change while the run still exited 0.
            continue
        if not isinstance(data, dict):
            err(scope, "scope document must be a mapping")
            continue
        raw_ids = data.get("acceptance")
        if not isinstance(raw_ids, list):
            err(scope, "acceptance must be a list of non-empty strings")
            continue

        scope_ids: set[str] = set()
        invalid_ids = False
        for acceptance_id in raw_ids:
            if not isinstance(acceptance_id, str) or not acceptance_id:
                invalid_ids = True
                continue
            scope_ids.add(acceptance_id)
        if invalid_ids:
            err(scope, "acceptance must contain only non-empty strings")

        tasks = change / "tasks.md"
        if not tasks.is_file():
            # check_changes already reports the missing required artifact.
            continue
        claimed = claimed_acceptance_ids(
            scope_ids, tasks.read_text(encoding="utf-8")
        )
        for acceptance_id in sorted(scope_ids - claimed):
            err(
                scope,
                f"scope acceptance {acceptance_id} "
                "未被任何任务 Requirements/AC 行认领",
            )


# ---------------------------------------------------- 8. structured pins
PINS_OPENING = "```yaml pins"
PINS_CLOSING = "```"
PINS_ALLOWED_KEYS = {"path", "artifact", "blob", "commit", "sha256"}
PINS_DIGEST_LENGTHS = {"blob": 40, "commit": 40, "sha256": 64}
PINS_HEX_RE = {
    key: re.compile(rf"[0-9A-Fa-f]{{{length}}}")
    for key, length in PINS_DIGEST_LENGTHS.items()
}


def _pins_block_reasons(block_text: str) -> list[str]:
    """Return stable schema failures for one real pins carrier."""
    try:
        data = yaml.load(block_text, Loader=StrictLoader)
    except Exception as exc:  # noqa: BLE001 - collapse one bad block to one err
        detail = " ".join(str(exc).split())
        return [f"YAML parse failed: {detail}"]

    if not isinstance(data, list) or not data:
        return ["top-level must be a non-empty sequence"]

    reasons: list[str] = []
    for index, item in enumerate(data, 1):
        if not isinstance(item, dict):
            reasons.append(f"item {index} must be a mapping")
            continue

        for key in item:
            if key not in PINS_ALLOWED_KEYS:
                reasons.append(f"item {index} has unknown key {key!r}")

        if not any(key in item for key in PINS_DIGEST_LENGTHS):
            reasons.append(f"item {index} must contain a digest key")

        for key in ("path", "artifact"):
            if key in item and (
                not isinstance(item[key], str) or not item[key].strip()
            ):
                reasons.append(f"item {index} {key} must be a non-empty string")

        for key, length in PINS_DIGEST_LENGTHS.items():
            if key not in item:
                continue
            value = item[key]
            if not isinstance(value, str) or PINS_HEX_RE[key].fullmatch(value) is None:
                reasons.append(
                    f"item {index} {key} must be a {length}-hex string"
                )

    return sorted(set(reasons))


def check_structured_pins(changes_dir: Path | None = None):
    """Validate exact `yaml pins` carriers in active change Markdown files."""
    changes_dir = changes_dir or OPENSPEC / "changes"
    for change in sorted(changes_dir.glob("chg-*")):
        if not change.is_dir():
            continue
        for path in sorted(change.rglob("*.md")):
            lines = path.read_text(encoding="utf-8").splitlines()
            index = 0
            while index < len(lines):
                if lines[index].strip() != PINS_OPENING:
                    index += 1
                    continue

                opening_line = index + 1
                index += 1
                body: list[str] = []
                while index < len(lines) and lines[index].strip() != PINS_CLOSING:
                    body.append(lines[index])
                    index += 1

                if index == len(lines):
                    reasons = ["unterminated fence"]
                else:
                    reasons = _pins_block_reasons("\n".join(body))
                    index += 1

                if reasons:
                    err(
                        path,
                        f"pins block at opening line {opening_line} invalid: "
                        + "; ".join(reasons),
                    )


# --------------------------------- 9b. registry provenance change paths
CHANGE_PATH_LITERAL = "openspec/changes/"

# Where provenance data lives: integration registries and the bundled fixture
# packs the contract tests read. Every decodable file under these roots is
# scanned, which is deliberately a superset of "registry/resource/receipt" -
# a new provenance file must not be able to slip in under a name nobody
# thought to enumerate.
REGISTRY_SURFACE_ROOTS = (
    Path("openspec") / "integrations",
    Path("Packages") / "ArkDeckKit" / "Tests" / "ArkDeckContractTests" / "Fixtures",
)

_READONLY_PIN = (
    "content hash pinned by Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift "
    "and consumed at runtime; migrating needs a change owning Sources/**"
)
_TRACE_PIN = (
    "content hash pinned by Sources/ArkDeckOpenHarmony/TraceProbeAdapter.swift; "
    "migrating needs a change owning Sources/**"
)
_FIXTURES = "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0"

# Files still allowed to name a whole in-repo change path, with the exact
# number of occurrences each may keep and why. Such a path breaks the moment
# its change is archived, so the register is a debt ledger, not an exemption:
# every entry is a file whose bytes cannot be rewritten inside a change that
# does not own `Sources/**` (CHG-2026-041 r3/r5). The count is checked in both
# directions - more occurrences means new debt smuggled in behind the
# exemption, fewer means the debt was paid without updating the ledger.
DEFERRED_CHANGE_PATH_REGISTER: dict[str, tuple[int, str]] = {
    "openspec/integrations/openharmony/readonly-probes.yaml": (4, _READONLY_PIN),
    "openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml": (3, _TRACE_PIN),
    f"{_FIXTURES}/registry.yaml": (4, _READONLY_PIN),
    f"{_FIXTURES}/receipts/key-access-diagnostics.json": (1, _READONLY_PIN),
    f"{_FIXTURES}/receipts/selected-device-authorization-binding.json": (1, _READONLY_PIN),
    f"{_FIXTURES}/receipts/server-identity-generation.json": (1, _READONLY_PIN),
    f"{_FIXTURES}/receipts/subserver-capability.json": (1, _READONLY_PIN),
}


def check_registry_change_paths(repo_root: Path | None = None, register=None):
    """Forbid whole in-repo change paths inside registry/fixture provenance.

    Provenance that spells out `openspec/changes/<id>/...` stops resolving the
    moment that change is archived. The archive-stable form names the change
    and a change-relative path and resolves active-or-archive at read time.
    """
    repo_root = repo_root or REPO
    register = DEFERRED_CHANGE_PATH_REGISTER if register is None else register
    observed: dict[str, int] = {}

    for root in REGISTRY_SURFACE_ROOTS:
        for path in sorted((repo_root / root).rglob("*")):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, ValueError):
                continue  # binary fixture: no textual provenance to carry
            relative = path.relative_to(repo_root).as_posix()
            count = text.count(CHANGE_PATH_LITERAL)
            if count:
                observed[relative] = count
            if relative in register:
                continue
            for number, line in enumerate(text.splitlines(), start=1):
                if CHANGE_PATH_LITERAL in line:
                    err(relative, f"line {number} names a whole in-repo change path; "
                                  f"use the change id plus a change-relative path so the "
                                  f"reference survives archiving")

    for relative, (expected, reason) in sorted(register.items()):
        count = observed.get(relative, 0)
        if not (repo_root / relative).is_file():
            err(relative, "is registered as deferred but does not exist; "
                          "remove the entry from DEFERRED_CHANGE_PATH_REGISTER")
        elif count > expected:
            err(relative, f"carries {count} in-repo change paths but only {expected} "
                          f"are registered as deferred ({reason}); the extra ones are "
                          f"new debt and must use the archive-stable form")
        elif count < expected:
            err(relative, f"carries {count} in-repo change paths but {expected} are "
                          f"registered as deferred; update "
                          f"DEFERRED_CHANGE_PATH_REGISTER to match")


# ------------------------------------------------ 9. locks and conformance
def check_locks_and_conformance(spec_acs):
    for lock_path, keys in (
        (OPENSPEC / "platforms" / "PLATFORM-PROFILES.lock.yaml",
         ("profile_path", "verification_path", "case_manifest_path")),
        (OPENSPEC / "integrations" / "INTEGRATION-PROFILES.lock.yaml", ("path",)),
    ):
        data = load_yaml(lock_path, empty_is_error=True)
        if not isinstance(data, dict):
            if data is not None:
                err(lock_path, "lock document must be a mapping")
            continue
        # `data.get(k, [])` returns None for a key that is PRESENT with a null
        # value, and `None + []` is a TypeError that aborted the whole run.
        entries = (data.get("profiles") or []) + (data.get("catalogs") or [])
        for entry in entries:
            for key in keys:
                value = entry.get(key)
                if value and not (REPO / value).is_file():
                    err(lock_path, f"referenced file missing: {value}")

    conf_path = OPENSPEC / "verification" / "core-conformance.yaml"
    conf = load_yaml(conf_path, empty_is_error=True)
    if isinstance(conf, dict):
        for section in ("acceptance_index", "acceptance_cases"):
            meta = conf.get(section) or {}
            p = meta.get("path")
            if p and not (REPO / p).is_file():
                err(conf_path, f"{section}.path missing: {p}")
        declared = (conf.get("acceptance_index") or {}).get("count")
        if declared is not None and declared != len(spec_acs):
            err(conf_path, f"acceptance count {declared} != actual {len(spec_acs)}")
        for block in conf.get("safety_coverage") or []:
            for phase in ("normal", "refusal_or_failure", "recovery_or_restart"):
                acs = block.get(phase)
                if isinstance(acs, list):
                    for ac in acs:
                        if ac not in spec_acs:
                            err(conf_path, f"safety_coverage references unknown {ac}")
        shared = conf.get("shared_inputs") or {}
        for group in shared.values():
            items = group if isinstance(group, list) else [group]
            for item in items:
                if isinstance(item, dict) and item.get("path"):
                    if not (REPO / item["path"]).is_file():
                        err(conf_path, f"shared input missing: {item['path']}")


def main():
    check_parse_all()
    spec_acs = check_specs()
    check_acceptance(spec_acs)
    check_capability_registry()
    check_changes()
    check_change_revision_consistency()
    check_change_scope_coverage()
    check_structured_pins()
    check_registry_change_paths()
    check_locks_and_conformance(spec_acs)

    for w in warnings:
        print(w)
    for e in errors:
        print(e)
    print(f"check_sdd: {len(errors)} error(s), {len(warnings)} warning(s), "
          f"{len(spec_acs)} acceptance IDs")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
