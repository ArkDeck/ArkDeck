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
  7. platform/integration lock 与 core-conformance 引用的路径存在,
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


def load_yaml(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return yaml.load(fh, Loader=StrictLoader)
    except Exception as exc:  # noqa: BLE001 - report every parse failure
        err(path, f"YAML parse failed: {exc}")
        return None


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

    cases = load_yaml(cases_path) or {}
    case_ids = set()
    for case in cases.get("cases", []):
        ac = case.get("acceptance_id")
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
    data = load_yaml(path)
    if not data:
        return
    caps = {c.get("id"): c for c in data.get("capabilities", [])}
    spec_dirs = {p.parent.name for p in (OPENSPEC / "specs").glob("*/spec.md")}
    if set(caps) != spec_dirs:
        err(path, f"capabilities != spec dirs; only-registry={sorted(set(caps)-spec_dirs)} only-specs={sorted(spec_dirs-set(caps))}")
    for cid, cap in caps.items():
        if cap.get("release") not in ("required", "optional"):
            err(path, f"{cid}: illegal release class {cap.get('release')!r}")
        for dep in cap.get("requires", []):
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
        for dep in caps[cid].get("requires", []):
            visit(dep)
        stack.discard(cid)
        seen.add(cid)

    for cid in caps:
        visit(cid)


# --------------------------------------------------------------- 5. changes
CHANGE_STATUSES = {"proposed", "approved", "implementing", "verified", "archived", "rejected"}
CHANGE_CLASSES = {"core", "capability", "integration", "platform", "implementation-only"}
TASK_STATUS_RE = re.compile(r"^- Status[::]\s*(ready|in_progress|done|blocked)")
REQUIREMENTS_AC_PREFIX = "- Requirements/AC:"
IDENTIFIER_BOUNDARY_CHARS = r"A-Za-z0-9_-"


def check_changes():
    changes_dir = OPENSPEC / "changes"
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
            else:
                if fm.get("status") not in CHANGE_STATUSES:
                    err(proposal, f"illegal status {fm.get('status')!r}")
                if fm.get("class") not in CHANGE_CLASSES:
                    err(proposal, f"illegal class {fm.get('class')!r}")
                if not fm.get("id"):
                    err(proposal, "missing id")
        tasks = change / "tasks.md"
        if tasks.is_file():
            task_count, status_count = 0, 0
            for line in tasks.read_text(encoding="utf-8").splitlines():
                if line.startswith("## TASK-"):
                    task_count += 1
                if TASK_STATUS_RE.match(line.replace("(", " (")):
                    status_count += 1
            if task_count == 0:
                warn(tasks, "no tasks defined")
            elif status_count < task_count:
                err(tasks, f"{task_count} tasks but only {status_count} legal Status lines")


# ----------------------------------------------------- 6. change scope coverage
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
        while index < len(lines) and not lines[index].startswith("- "):
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

        data = load_yaml(scope)
        if data is None:
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


# ------------------------------------------------ 7. locks and conformance
def check_locks_and_conformance(spec_acs):
    for lock_path, keys in (
        (OPENSPEC / "platforms" / "PLATFORM-PROFILES.lock.yaml",
         ("profile_path", "verification_path", "case_manifest_path")),
        (OPENSPEC / "integrations" / "INTEGRATION-PROFILES.lock.yaml", ("path",)),
    ):
        data = load_yaml(lock_path)
        if not data:
            continue
        entries = data.get("profiles", []) + data.get("catalogs", [])
        for entry in entries:
            for key in keys:
                value = entry.get(key)
                if value and not (REPO / value).is_file():
                    err(lock_path, f"referenced file missing: {value}")

    conf_path = OPENSPEC / "verification" / "core-conformance.yaml"
    conf = load_yaml(conf_path)
    if conf:
        for section in ("acceptance_index", "acceptance_cases"):
            meta = conf.get(section) or {}
            p = meta.get("path")
            if p and not (REPO / p).is_file():
                err(conf_path, f"{section}.path missing: {p}")
        declared = (conf.get("acceptance_index") or {}).get("count")
        if declared is not None and declared != len(spec_acs):
            err(conf_path, f"acceptance count {declared} != actual {len(spec_acs)}")
        for block in conf.get("safety_coverage", []):
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
    check_change_scope_coverage()
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
