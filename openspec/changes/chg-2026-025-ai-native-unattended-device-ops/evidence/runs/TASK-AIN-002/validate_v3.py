#!/usr/bin/env python3
"""TASK-AIN-002 / AIN-SCHEMA-001:hardware-evidence 3.0.0 封闭断言集校验器。

stdlib only(readiness r1 钉定:`.venv-sdd` 无 jsonschema,不装包、不联网)。
断言集与 `contracts/hardware-evidence.schema.v3-draft.json` 逐条对应;本脚本
不是通用 JSON Schema 实现,schema 若修改须同步本断言集(二者同 PR 演进)。

用法:
  validate_v3.py <instance.json>      # accept → exit 0;reject → exit 1 并列出原因
  validate_v3.py --cases <dir>        # pos-*.json 必须 accept、neg-*.json 必须 reject
"""

import json
import re
import sys
from pathlib import Path

EVIDENCE_ID_RE = re.compile(r"^EVD-[A-Z0-9._-]+$")
ACCEPTANCE_ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-[A-Z0-9-]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"
)

TOP_REQUIRED = (
    "schemaVersion", "evidenceId", "executor", "physicalTargetConfirmation",
    "device", "toolchain", "transport", "provider", "stepKinds",
    "acceptanceIds", "executedAt", "artifacts",
)
TOP_ALLOWED = set(TOP_REQUIRED) | {"validUntil", "deviations", "notes"}


def _check_obj(errors, obj, where, required, allowed):
    if not isinstance(obj, dict):
        errors.append(f"{where}: 必须是 object")
        return False
    for key in required:
        if key not in obj:
            errors.append(f"{where}: 缺 required 字段 {key!r}")
    for key in obj:
        if key not in allowed:
            errors.append(f"{where}: 非法字段 {key!r}(additionalProperties=false)")
    return True


def _check_str(errors, value, where, pattern=None, enum=None):
    if not isinstance(value, str) or not value:
        errors.append(f"{where}: 必须是非空字符串")
        return
    if pattern is not None and not pattern.match(value):
        errors.append(f"{where}: 不匹配 pattern({value!r})")
    if enum is not None and value not in enum:
        errors.append(f"{where}: 非法枚举值 {value!r}(允许:{sorted(enum)})")


def validate(doc):
    errors = []
    if not _check_obj(errors, doc, "$", TOP_REQUIRED, TOP_ALLOWED):
        return errors

    if doc.get("schemaVersion") != "3.0.0":
        errors.append(f"schemaVersion: 必须为 const \"3.0.0\"(得到 {doc.get('schemaVersion')!r})")
    if "evidenceId" in doc:
        _check_str(errors, doc["evidenceId"], "evidenceId", pattern=EVIDENCE_ID_RE)

    executor = doc.get("executor")
    if executor is not None and _check_obj(
        errors, executor, "executor", ("kind", "id"), {"kind", "id", "authorizationRef"}
    ):
        _check_str(errors, executor.get("kind"), "executor.kind", enum={"human", "agent"})
        _check_str(errors, executor.get("id"), "executor.id")
        if executor.get("kind") == "agent":
            ref = executor.get("authorizationRef")
            if not isinstance(ref, str) or not ref:
                errors.append("executor: kind=agent 时 authorizationRef 必填(条件 required)")
        elif "authorizationRef" in executor:
            _check_str(errors, executor["authorizationRef"], "executor.authorizationRef")

    ptc = doc.get("physicalTargetConfirmation")
    if ptc is not None and _check_obj(
        errors, ptc, "physicalTargetConfirmation",
        ("confirmedDeviceIdentity", "confirmedAt", "method"),
        {"confirmedDeviceIdentity", "confirmedAt", "method"},
    ):
        _check_str(errors, ptc.get("confirmedDeviceIdentity"),
                   "physicalTargetConfirmation.confirmedDeviceIdentity")
        _check_str(errors, ptc.get("confirmedAt"),
                   "physicalTargetConfirmation.confirmedAt", pattern=DATETIME_RE)
        _check_str(errors, ptc.get("method"), "physicalTargetConfirmation.method",
                   enum={"humanVisual", "machineReadback"})

    device = doc.get("device")
    if device is not None and _check_obj(
        errors, device, "device", ("model", "serial", "firmware"),
        {"model", "serial", "firmware", "bindingRevision"},
    ):
        for key in ("model", "serial", "firmware"):
            _check_str(errors, device.get(key), f"device.{key}")
        if "bindingRevision" in device:
            rev = device["bindingRevision"]
            if not isinstance(rev, int) or isinstance(rev, bool) or rev < 0:
                errors.append("device.bindingRevision: 必须是 >=0 的整数")

    toolchain = doc.get("toolchain")
    if toolchain is not None and _check_obj(
        errors, toolchain, "toolchain", ("hdcVersion",),
        {"hdcVersion", "hdcPath", "other"},
    ):
        _check_str(errors, toolchain.get("hdcVersion"), "toolchain.hdcVersion")
        if "other" in toolchain and not isinstance(toolchain["other"], dict):
            errors.append("toolchain.other: 必须是 object")

    if "transport" in doc:
        _check_str(errors, doc["transport"], "transport", enum={"usb", "tcp", "uart"})
    if "provider" in doc:
        _check_str(errors, doc["provider"], "provider")

    steps = doc.get("stepKinds")
    if steps is not None:
        if not isinstance(steps, list) or not steps:
            errors.append("stepKinds: 必须是非空数组")
        else:
            for i, item in enumerate(steps):
                _check_str(errors, item, f"stepKinds[{i}]")

    acs = doc.get("acceptanceIds")
    if acs is not None:
        if not isinstance(acs, list) or not acs:
            errors.append("acceptanceIds: 必须是非空数组")
        else:
            for i, item in enumerate(acs):
                _check_str(errors, item, f"acceptanceIds[{i}]", pattern=ACCEPTANCE_ID_RE)

    for key in ("executedAt", "validUntil"):
        if key in doc:
            _check_str(errors, doc[key], key, pattern=DATETIME_RE)

    artifacts = doc.get("artifacts")
    if artifacts is not None:
        if not isinstance(artifacts, list):
            errors.append("artifacts: 必须是数组")
        else:
            for i, art in enumerate(artifacts):
                if _check_obj(errors, art, f"artifacts[{i}]", ("path", "sha256"),
                              {"path", "sha256", "note"}):
                    _check_str(errors, art.get("path"), f"artifacts[{i}].path")
                    _check_str(errors, art.get("sha256"), f"artifacts[{i}].sha256",
                               pattern=SHA256_RE)

    if "deviations" in doc:
        dev = doc["deviations"]
        if not isinstance(dev, list) or any(not isinstance(x, str) for x in dev):
            errors.append("deviations: 必须是字符串数组")
    if "notes" in doc and not isinstance(doc["notes"], str):
        errors.append("notes: 必须是字符串")

    return errors


def run_cases(cases_dir):
    ok = True
    for path in sorted(Path(cases_dir).glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        errors = validate(doc)
        expect_reject = path.name.startswith("neg-")
        accepted = not errors
        matched = accepted != expect_reject
        verdict = "accept" if accepted else "reject"
        expected = "reject" if expect_reject else "accept"
        print(f"{'PASS' if matched else 'FAIL'} {path.name}: {verdict} (期望 {expected})")
        if not matched:
            ok = False
        if errors and (expect_reject and matched):
            print(f"     └ 拒绝原因:{errors[0]}" + (f"(+{len(errors)-1})" if len(errors) > 1 else ""))
        elif errors:
            for err in errors:
                print(f"     └ {err}")
    print("AIN-SCHEMA-001:" + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv):
    if len(argv) == 3 and argv[1] == "--cases":
        return run_cases(argv[2])
    if len(argv) == 2:
        doc = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
        errors = validate(doc)
        for err in errors:
            print(f"reject: {err}")
        return 1 if errors else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
