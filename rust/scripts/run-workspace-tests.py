#!/usr/bin/env python3
"""Run every workspace test through Cargo, with two bounded macOS queues.

Cargo builds all default targets first. Only audited integration targets with
unique temporary roots may overlap the conservative queue. New targets stay
in the conservative queue. Cargo still owns test environments, feature
unification, custom harnesses and doctests; no test executable is run directly.

With one worker (the Windows and Linux CI hosts) Cargo is asked for every
default test target except the integration tests whose crate-level
`#![cfg(...)]` is false on this host, which would compile and link to a
harness that runs nothing: 169 of 230 test executables on Windows on
2026-09-30. The exclusion is derived from `cargo metadata` and `rustc --print
cfg` on every run, a predicate this script cannot decide fails the run, and
every selected target must appear in Cargo's own `Running` lines. Clippy
`--all-targets` still compiles every target on every host.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib
import catalog_test_views as catalog_views

RUST = Path(__file__).resolve().parents[1]
BASE = ["cargo", "test", "--workspace", "--no-fail-fast", "--locked"]
# No fixed HDC oracle paths, shared TCP ports, or spawning/descriptor tests.
# Each target creates its own PID/nonce directory and Unix socket, and tears
# down its own children. Keep this list small; additions require that audit.
ISOLATED = frozenset({
    ("arkdeck-agentd", "workspace_tests_process"),
    ("arkdeck-agentd", "workspace_checkpoint_process"),
    ("arkdeck-cli", "maintainer_contracts"),
    # Private random account roots and Unix sockets; their fake Runtime threads
    # are joined and CLI children reaped. No shared HDC oracle or TCP allocator.
    ("arkdeck-cli", "domain_leaves"),
    ("arkdeck-cli", "runtime_service"),
})


def queues(messages: list[dict], metadata: dict) -> list[tuple[str, list[str]]]:
    """Map Cargo's actual default test artifacts to exhaustive native selectors.

    Unsupported target shapes fall back to the original workspace invocation,
    never to a partial test inventory. --workspace is retained in both queues
    so feature unification does not change with the selected test targets.
    """
    if not any(m.get("reason") == "build-finished" and m.get("success") for m in messages):
        raise ValueError("Cargo did not report a successful complete test build")
    members = set(metadata["workspace_members"])
    packages = {p["id"]: p for p in metadata["packages"] if p["id"] in members}
    for package in packages.values():
        manifest = tomllib.loads(Path(package["manifest_path"]).read_text())
        # An un-harnessed bin/example can also be a normal build artifact;
        # avoid inferring test selection from that ambiguous executable.
        entries = [manifest.get("lib", {})]
        entries += [entry for kind in ("bin", "example", "bench") for entry in manifest.get(kind, [])]
        if any(entry.get("harness") is False for entry in entries):
            return [("workspace", BASE)]
        if any("lib" in target["kind"] and not target["test"] for target in package["targets"]):
            return [("workspace", BASE)]
    targets = {}
    for message in messages:
        if message.get("reason") != "compiler-artifact" or message.get("package_id") not in packages:
            continue
        target = message["target"]
        if not message.get("executable") or not (message["profile"]["test"] or target["kind"] == ["test"]):
            continue
        kind = target["kind"]
        if kind == ["test"]:
            flag = "--test"
        elif kind == ["bin"]:
            flag = "--bin"
        elif kind == ["example"]:
            flag = "--example"
        elif "lib" in kind or kind == ["proc-macro"]:
            flag = "--lib"
        else:
            return [("workspace", BASE)]
        package = packages[message["package_id"]]["name"]
        selector = (flag, target["name"] if flag != "--lib" else "")
        targets.setdefault(selector, []).append((package, target["name"]))
    if not targets:
        return [("workspace", BASE)]
    serial, isolated = [], []
    for selector, owners in sorted(targets.items()):
        # A newly added target with the same name in another package must not
        # inherit the audited target's permission to overlap shared resources.
        destination = isolated if selector[0] == "--test" and all(owner in ISOLATED for owner in owners) else serial
        destination.extend(part for part in selector if part)
    return [(name, BASE + flags) for name, flags in (("shared-resources", serial), ("isolated", isolated)) if flags]


# Target cfg keys `rustc --print cfg` settles for the host. `test` is set in
# every libtest integration harness. Anything else (features, profile, custom
# cfgs) is undecidable here.
HOST_CFG_KEYS = frozenset({
    "unix", "windows", "target_os", "target_family", "target_arch", "target_env",
    "target_vendor", "target_pointer_width", "target_endian", "target_abi",
})
# Any of these can change the target or add cfgs, so the host's cfg set is
# not `rustc --print cfg`'s; every default target is then built.
CFG_ENVIRONMENT = ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_RUSTFLAGS", "CARGO_BUILD_TARGET")


class Undecidable(ValueError):
    pass


def host_cfg(cwd: Path) -> set[tuple[str, str | None]]:
    values = set()
    for line in subprocess.check_output(["rustc", "--print", "cfg"], cwd=cwd, text=True).splitlines():
        name, _, value = line.strip().partition("=")
        values.add((name, value.strip('"') if value else None))
    return values


def crate_attributes(text: str) -> list[str]:
    """The crate-level inner attributes: everything before the first item."""
    def line_end(start: int) -> int:
        end = text.find("\n", start)
        return len(text) if end < 0 else end

    position, attributes = 0, []
    if text.startswith("\ufeff"):
        position = 1
    if text.startswith("#!", position) and not text[position + 2:].lstrip().startswith("["):
        position = line_end(position)  # a shebang line
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if text.startswith("//", position):
            position = line_end(position)
        elif text.startswith("/*", position):
            depth, position = 1, position + 2
            while depth:
                if position >= len(text):
                    raise Undecidable("unterminated block comment")
                if text.startswith("/*", position):
                    depth, position = depth + 1, position + 2
                elif text.startswith("*/", position):
                    depth, position = depth - 1, position + 2
                else:
                    position += 1
        elif text.startswith("#!", position):
            start = text.find("[", position)
            if start < 0 or text[position + 2:start].strip():
                raise Undecidable("malformed crate attribute")
            depth, index = 0, start
            while True:
                if index >= len(text):
                    raise Undecidable("unterminated crate attribute")
                character = text[index]
                if character == '"':
                    index += 1
                    while index < len(text) and text[index] != '"':
                        index += 2 if text[index] == "\\" else 1
                elif character == "r" and re.match(r'r#*"', text[index:]) and not re.match(r"\w", text[index - 1]):
                    hashes = re.match(r'r(#*)"', text[index:])[1]
                    end = text.find('"' + hashes, index + len(hashes) + 2)
                    if end < 0:
                        raise Undecidable("unterminated raw string")
                    index = end + len(hashes)
                elif character == "[":
                    depth += 1
                elif character == "]":
                    depth -= 1
                    if not depth:
                        break
                index += 1
            attributes.append(text[start + 1:index].strip())
            position = index + 1
        else:
            return attributes


def cfg_predicate(tokens: list[str], values: set) -> bool | None:
    """Three-valued: True, False, or None when this host cannot decide."""
    name = tokens.pop(0)
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise Undecidable(f"unexpected cfg token {name!r}")
    if tokens and tokens[0] == "(":
        if name not in ("all", "any", "not"):
            raise Undecidable(f"unknown cfg operator {name!r}")
        tokens.pop(0)
        operands = []
        while tokens[0] != ")":
            operands.append(cfg_predicate(tokens, values))
            if tokens[0] == ",":
                tokens.pop(0)
            elif tokens[0] != ")":
                raise Undecidable("malformed cfg list")
        tokens.pop(0)
        if name == "not":
            if len(operands) != 1:
                raise Undecidable("not() takes one predicate")
            return None if operands[0] is None else not operands[0]
        decisive = name == "any"
        if decisive in operands:
            return decisive
        return None if None in operands else not decisive
    value = None
    if tokens and tokens[0] == "=":
        tokens.pop(0)
        literal = tokens.pop(0)
        if not literal.startswith('"'):
            raise Undecidable("cfg value must be a string")
        value = literal[1:-1]
    if name == "test" and value is None:
        return True
    if name in HOST_CFG_KEYS:
        return (name, value) in values
    return None


def crate_cfg(text: str, values: set) -> bool | None:
    """Whether the crate root compiles on this host; None if undecidable."""
    verdicts = []
    for attribute in crate_attributes(text):
        head = re.match(r"(cfg_attr|cfg)\s*(\(|$)", attribute)
        if not head:
            continue
        if head[1] == "cfg_attr":
            raise Undecidable(f"crate-level #![{attribute}]")
        tokens = re.findall(r'"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*|\S', attribute[head.end() - 1:])
        if tokens[:1] != ["("] or tokens[-1:] != [")"]:
            raise Undecidable(f"malformed #![{attribute}]")
        inner = tokens[1:-1]
        try:
            verdict = cfg_predicate(inner, values)
        except IndexError as error:
            raise Undecidable(f"malformed #![{attribute}]") from error
        if inner:
            raise Undecidable(f"malformed #![{attribute}]")
        verdicts.append(verdict)
    if False in verdicts:
        return False
    return None if None in verdicts else True


def host_plan(metadata: dict, values: set) -> dict | None:
    """Every default test target of the workspace, less the cfg-empty ones.

    Returns None for a shape whose default selection explicit flags cannot
    reproduce; the caller then runs the plain workspace invocation.
    """
    members = set(metadata["workspace_members"])
    run, excluded, undecidable = [], [], []
    libraries = bins = doc = False
    for package in metadata["packages"]:
        if package["id"] not in members:
            continue
        manifest = tomllib.loads(Path(package["manifest_path"]).read_text(encoding="utf-8"))
        unharnessed = {entry.get("name") for entry in manifest.get("test", []) if entry.get("harness") is False}
        entries = [manifest.get("lib", {})] + [e for kind in ("bin", "example", "bench") for e in manifest.get(kind, [])]
        if any(entry.get("harness") is False for entry in entries):
            return None
        for target in package["targets"]:
            kind = target["kind"]
            if target.get("required-features"):
                return None
            if kind == ["test"]:
                if not target["test"]:
                    continue
                if target["name"] in unharnessed:
                    run.append((package["name"], target))
                    continue
                source = Path(target["src_path"])
                try:
                    verdict = crate_cfg(source.read_text(encoding="utf-8"), values)
                except Undecidable as error:
                    undecidable.append(f"{package['name']} {target['name']}: {error}")
                    continue
                if verdict is None:
                    undecidable.append(f"{package['name']} {target['name']}: its crate-level cfg")
                elif verdict:
                    run.append((package["name"], target))
                else:
                    excluded.append((package["name"], target))
            elif kind == ["bin"]:
                if not target["test"]:
                    return None
                bins = True
            elif kind == ["example"] or kind == ["bench"]:
                if target["test"]:
                    return None
            elif any(k in ("lib", "rlib", "dylib", "proc-macro") for k in kind):
                if not target["test"]:
                    return None
                libraries = True
                doc = doc or target.get("doctest", False)
            elif kind != ["custom-build"]:
                return None
    if undecidable:
        raise Undecidable("cannot tell whether these test targets compile on this host; make the "
                          "crate-level cfg a target predicate or teach run-workspace-tests.py: "
                          + "; ".join(sorted(undecidable)))
    names = sorted({target["name"] for _, target in run})
    tests = BASE + (["--lib"] if libraries else []) + (["--bins"] if bins else [])
    tests += [part for name in names for part in ("--test", name)]
    commands = [("tests", tests)]
    if doc:
        commands.append(("doctests", BASE + ["--doc"]))
    # Plain `cargo test` also builds every example, outside test mode.
    commands.append(("examples", ["cargo", "build", "--workspace", "--examples", "--locked"]))
    return {"commands": commands, "run": run, "excluded": excluded}


def ran_targets(log: str) -> set[str]:
    """Source paths from Cargo's `Running <path> (<executable>)` lines."""
    plain = re.sub(r"\x1b\[[0-9;]*m", "", log)  # CARGO_TERM_COLOR=always in CI
    return {match[1].replace("\\", "/") for match in re.finditer(r"^\s*Running (?:unittests )?(\S+) \(", plain, re.M)}


def verify_ran(plan: dict, metadata: dict, log: str) -> list[str]:
    """Selected integration targets Cargo did not run: none may be missing."""
    roots = {package["name"]: Path(package["manifest_path"]).parent for package in metadata["packages"]}
    ran = ran_targets(log)
    missing = []
    for package, target in plan["run"]:
        relative = Path(target["src_path"]).relative_to(roots[package]).as_posix()
        if relative not in ran:
            missing.append(f"{package} {target['name']}")
    return missing


def artifact_bindings(messages: list[dict], metadata: dict) -> dict[str, dict]:
    """Bind Cargo's actual built executable to its package and source target."""
    packages = {p['id']: p for p in metadata['packages'] if p['id'] in metadata['workspace_members']}
    result = {}
    if not any(m.get('reason') == 'build-finished' and m.get('success') for m in messages):
        raise ValueError('Cargo did not complete the workspace test build')
    for message in messages:
        if message.get('reason') != 'compiler-artifact' or message.get('package_id') not in packages:
            continue
        if not message.get('executable') or message.get('target', {}).get('kind') != ['test']:
            continue
        package = packages[message['package_id']]
        target = message['target']
        declared = [t for t in package['targets'] if t['kind'] == ['test'] and t['name'] == target['name']]
        if len(declared) != 1 or Path(declared[0]['src_path']) != Path(target['src_path']):
            raise ValueError('Cargo artifact source does not match declared target')
        key = package['name'] + '/' + target['name']
        if key in result:
            raise ValueError('duplicate Cargo test executable binding')
        result[key] = {'source': Path(target['src_path']).relative_to(Path(package['manifest_path']).parent).as_posix(),
                       'executable': message['executable'], 'src_path': target['src_path']}
    return result


def running_sections(log: str, keys: list[str], bindings: dict[str, dict], cwd: Path) -> dict[str, str]:
    """No case receipt is accepted outside its exact Cargo Running section."""
    plain = '\n'.join(re.sub(r'\x1b\[[0-9;]*m', '', log).splitlines())
    rows = list(re.finditer(r'^\s*Running (?:unittests )?(.+?) \((.+)\)\s*$', plain, re.M))
    def executable(path):
        value = Path(path)
        return os.path.normcase(str(value if value.is_absolute() else cwd / value))
    wanted = {}
    for key in keys:
        if key not in bindings:
            raise ValueError(f'{key}: missing compiled Cargo target binding')
        binding = bindings[key]
        identity = (binding['source'], executable(binding['executable']))
        if identity in wanted:
            raise ValueError('ambiguous compiled Cargo target binding')
        wanted[identity] = key
    result = {}
    for index, row in enumerate(rows):
        identity = (row[1].replace('\\', '/'), executable(row[2]))
        if identity not in wanted:
            raise ValueError('Cargo Running source/executable belongs to another target')
        key = wanted[identity]
        if key in result:
            raise ValueError('Cargo ran one selected target twice')
        end = rows[index + 1].start() if index + 1 < len(rows) else len(plain)
        result[key] = plain[row.end():end]
    if set(result) != set(keys):
        raise ValueError('Cargo did not run each exact selected source target')
    return result


def group_filters(names: dict[str, list[str]], selected: dict[str, list[str]]) -> list[str]:
    union = sorted({name for values in selected.values() for name in values})
    for key, values in names.items():
        if set(values).intersection(union) != set(selected[key]):
            raise ValueError('same-name targets have conflicting exact function routes')
    return union


def recorded(argv: list[str], directory: Path, label: str, cwd: Path) -> dict:
    started = time.monotonic()
    log = directory / f"{label}.log"
    print(f"+ [{label}] {' '.join(argv)}", flush=True)
    with log.open("w", encoding="utf-8", newline="\n") as output:
        with subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding="utf-8", errors="strict") as process:
            for line in process.stdout:
                output.write(line)
                output.flush()
                if label == "compile" and line.startswith("{"):
                    diagnostic = json.loads(line).get("message", {}).get("rendered")
                    if diagnostic:
                        print(diagnostic, end="", flush=True)
                    continue
                print(f"[{label}] {line}", end="", flush=True)
            code = process.wait()
    return {"name": label, "argv": argv, "seconds": round(time.monotonic() - started, 3),
            "exitCode": code, "log": str(log)}


def execute(cwd: Path = RUST, workers: int = 1, directory: Path | None = None) -> int:
    if workers not in (1, 2):
        raise ValueError("workspace test workers must be 1 or 2")
    directory = directory or Path(tempfile.mkdtemp(prefix="arkdeck-test-timings-"))
    if workers == 1:
        return host_selected(cwd, directory)
    directory.mkdir(parents=True, exist_ok=True)
    stages = []
    started = time.monotonic()
    report = {"schemaVersion": "arkdeck.workspace-test-timings/1", "workers": workers,
              "workspace": str(cwd), "completed": False, "stages": stages}
    try:
        # --no-run retains compilation of default examples and integration
        # binaries. The JSON inventory includes both libtest and harness=false.
        build = recorded(BASE + ["--no-run", "--message-format=json"], directory, "compile", cwd)
        stages.append(build)
        if build["exitCode"]:
            return build["exitCode"]
        messages = []
        for line in Path(build["log"]).read_text().splitlines():
            if line.startswith("{"):
                messages.append(json.loads(line))
        metadata = json.loads(subprocess.check_output(
            ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"], cwd=cwd, text=True))
        planned = queues(messages, metadata)
        report["queues"] = [{"name": name, "argv": argv} for name, argv in planned]
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(recorded, argv, directory, name, cwd) for name, argv in planned]
            stages.extend(future.result() for future in futures)
        # A fallback runs doctests in the original command already. Otherwise
        # preserve docs even after either queue failed (--no-fail-fast semantics).
        if planned != [("workspace", BASE)]:
            stages.append(recorded(BASE + ["--doc"], directory, "doctests", cwd))
        report["completed"] = True
        return 1 if any(stage["exitCode"] for stage in stages) else 0
    finally:
        report["seconds"] = round(time.monotonic() - started, 3)
        (directory / "timings.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Workspace test timings: {directory / 'timings.json'}", flush=True)


def host_selected(cwd: Path, directory: Path) -> int:
    directory.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"], cwd=cwd, text=True))
    plan = None
    if not any(os.environ.get(name) for name in CFG_ENVIRONMENT):
        plan = host_plan(metadata, host_cfg(cwd))
    if plan is None:
        print("workspace tests: running every default target", flush=True)
        return subprocess.run(BASE, cwd=cwd, check=False).returncode
    print(f"workspace tests: {len(plan['run'])} integration targets run; {len(plan['excluded'])} "
          f"compile to nothing on this host and are not built: "
          + ", ".join(sorted(f"{p}/{t['name']}" for p, t in plan["excluded"])), flush=True)
    stages = [recorded(argv, directory, name, cwd) for name, argv in plan["commands"]]
    code = 1 if any(stage["exitCode"] for stage in stages) else 0
    missing = verify_ran(plan, metadata, Path(stages[0]["log"]).read_text(encoding="utf-8", errors="replace"))
    if not stages[0]["exitCode"] and missing:
        print("workspace tests: Cargo did not run these selected targets: " + ", ".join(missing), file=sys.stderr)
        code = 1
    (directory / "host-selection.json").write_text(json.dumps({
        "schemaVersion": "arkdeck.workspace-host-selection/1",
        "run": sorted(f"{p}/{t['name']}" for p, t in plan["run"]),
        "excluded": sorted(f"{p}/{t['name']}" for p, t in plan["excluded"]),
        "stages": stages,
    }, indent=2) + "\n")
    return code


PARITY_CONSUMERS = frozenset({'arkdeck-contract', 'arkdeck-cli'})


def integration_groups(declared: dict, plan: dict, *, parity_consumers: bool = False) -> dict:
    """A closed parity scope, retaining every same-name workspace sibling."""
    scope = PARITY_CONSUMERS if parity_consumers else {key.split('/')[0] for key in declared}
    selected_names = {target['name'] for package, target in plan['run'] if package in scope}
    return {name: sorted(key for key, target in declared.items() if target['name'] == name)
            for name in sorted(selected_names)}


def catalog_selected(cwd: Path, workers: int, directory: Path, *, parity_consumers: bool = False) -> int:
    """Execute exact source-pinned cases in their declared Catalog view.

    Cargo still owns every environment and executable. Listing is never
    counted as execution, and a skipped historical case is discharged only
    by the separate mandatory historical view's receipt.
    """
    directory.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"], cwd=cwd, text=True))
    manifest = catalog_views.load(cwd, metadata)
    digest = catalog_views.catalog(cwd)
    if any(os.environ.get(name) for name in CFG_ENVIRONMENT):
        raise ValueError("Catalog test views require the native host cfg")
    plan = host_plan(metadata, host_cfg(cwd))
    if plan is None:
        raise ValueError("unclassified custom test harness or default target")
    stages, receipts = [], []
    report = {"schemaVersion": "arkdeck.catalog-test-execution/1", "catalogDigest": digest,
              "manifestSHA256": catalog_views.sha((cwd / catalog_views.MANIFEST).read_bytes()),
              "workers": workers, "completed": False, "stages": stages, "targets": receipts,
              "hostCfgExcluded": sorted(f"{p}/{t['name']}" for p, t in plan['excluded']),
              "integrationPackages": sorted(PARITY_CONSUMERS) if parity_consumers else 'workspace'}
    try:
        # Each view builds its own sibling CLI/daemon images before any
        # process fixture; neither a stale target nor another view may answer.
        built = recorded(["cargo", "build", "--workspace", "--bins", "--locked"], directory, "bins", cwd)
        stages.append(built)
        if built['exitCode']:
            return built['exitCode']
        compile_ = recorded(plan['commands'][0][1] + ["--no-run", "--message-format=json"],
                            directory, "compile", cwd)
        stages.append(compile_)
        if compile_['exitCode']:
            return compile_['exitCode']
        messages = [json.loads(line) for line in Path(compile_['log']).read_text(encoding='utf-8').splitlines()
                    if line.startswith('{')]
        bindings = artifact_bindings(messages, metadata)
        custom = catalog_views.custom_harnesses(metadata)
        declared = catalog_views.targets(metadata)
        groups = integration_groups(declared, plan, parity_consumers=parity_consumers)
        excluded = {f"{p}/{t['name']}" for p, t in plan['excluded']}
        if sys.platform == 'win32' and not re.fullmatch(r'[A-Fa-f0-9]{40}', os.environ.get('ARKDECK_DEV_SIGNER_THUMBPRINT', '')):
            raise ValueError('Windows signed process fixtures require the declared development signer')

        def target_group(name):
            keys = groups[name]
            label = 'target-' + name
            command = BASE + ['--test', name]
            rows = {key: catalog_views.platform_row(manifest['targets'][key], sys.platform) for key in keys}
            protocols = {key: custom[key][0] for key in keys if key in custom}
            # The closed custom names are unique across packages. A collision
            # must be reviewed before it can share any custom command protocol.
            if protocols and len(keys) != 1:
                raise ValueError('custom harness shares a target name with another package')
            local_stages, names = [], {}
            if protocols:
                key = keys[0]
                protocol, platforms = custom[key]
                names[key] = sorted(rows[key]['customCases'].get(sys.platform, []))
                if sys.platform not in platforms or protocol == 'fixture-entry':
                    run = recorded(command, directory, label + '-execute', cwd)
                    local_stages.append(run)
                    sections = running_sections(Path(run['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
                    if run['exitCode'] or catalog_views.listed(sections[key]) or re.search(r'^test .* \.\.\.', sections[key], re.M):
                        raise ValueError('inactive/helper custom entry produced unclassified test output')
                    return local_stages, [{'target': key, 'completed': True, 'passed': 0, 'coverage': False,
                                           'execution': 'fixture-entry' if protocol == 'fixture-entry' else 'host-cfg-excluded',
                                           'cargoTarget': bindings[key]}]
                if protocol == 'listed-summary':
                    listing = recorded(command + ['--', '--list'], directory, label + '-list', cwd)
                    local_stages.append(listing)
                    sections = running_sections(Path(listing['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
                    if listing['exitCode'] or catalog_views.listed(sections[key]) != names[key]:
                        raise ValueError('custom list differs from its closed host census')
            else:
                listing = recorded(command + ['--', '--list'], directory, label + '-list', cwd)
                local_stages.append(listing)
                sections = running_sections(Path(listing['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
                if listing['exitCode']:
                    raise ValueError('libtest listing failed')
                names = {key: catalog_views.listed(sections[key]) for key in keys}
                module_excluded = {key for key in keys if catalog_views.module_host_cfg_excluded(
                    key, rows[key], sys.platform)}
                if module_excluded:
                    if len(keys) != 1 or any(names[key] for key in module_excluded):
                        raise ValueError('host-excluded module changed its target or case census')
                    run = recorded(command, directory, label + '-execute', cwd)
                    local_stages.append(run)
                    sections = running_sections(Path(run['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
                    if run['exitCode']:
                        raise ValueError('host-excluded module execution failed')
                    key = keys[0]
                    catalog_views.verify_host_cfg_empty(sections[key])
                    return local_stages, [{'target': key, 'completed': True, 'passed': 0, 'coverage': False,
                                           'execution': 'host-cfg-excluded', 'listed': [],
                                           'modulePlatforms': rows[key]['modulePlatforms'],
                                           'cargoTarget': bindings[key]}]
                if any(not names[key] and key not in excluded for key in keys):
                    raise ValueError('empty libtest list is not an audited host cfg exclusion')
            selected = {key: catalog_views.selected(rows[key], names[key], digest)
                        if not parity_consumers or key.split('/')[0] in PARITY_CONSUMERS else [] for key in keys}
            known_ignored = {key: sorted(set(rows[key]['ignored']).intersection(names[key])) for key in keys}
            if not protocols:
                ignored_list = recorded(command + ['--', '--list', '--ignored'], directory, label + '-ignored-list', cwd)
                local_stages.append(ignored_list)
                sections = running_sections(Path(ignored_list['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
                if ignored_list['exitCode'] or any(catalog_views.listed(sections[key]) != known_ignored[key] for key in keys):
                    raise ValueError('unclassified ignored function')
            group_receipts = {key: {'target': key, 'listed': names[key], 'selected': selected[key],
                                    'excludedByView': sorted(set(names[key]) - set(selected[key])),
                                    'ignored': known_ignored[key], 'cargoTarget': bindings[key],
                                    'completed': False, 'execution': 'other-view'} for key in keys}
            filters = group_filters(names, selected)
            if not filters:
                return local_stages, list(group_receipts.values())
            if protocols and protocol.startswith('default-'):
                if selected[key] != names[key]:
                    raise ValueError('default-only custom suite cannot be partially filtered')
                arguments = []
            else:
                arguments = ['--', '--exact', *filters]
            run = recorded(command + arguments, directory, label + '-execute', cwd)
            local_stages.append(run)
            sections = running_sections(Path(run['log']).read_text(encoding='utf-8'), keys, bindings, cwd)
            for key in keys:
                receipt = group_receipts[key]
                try:
                    if not selected[key]:
                        # Cargo still runs same-name siblings. They must have
                        # precisely zero selected cases, never borrowed cases.
                        plain = sections[key]
                        if re.search(r'^test [^\s]+ \.\.\.', plain, re.M) or not re.search(
                                r'^test result: ok\. 0 passed; 0 failed; 0 ignored;', plain, re.M):
                            raise ValueError('excluded sibling executed a test')
                        continue
                    if set(selected[key]).issubset(known_ignored[key]):
                        raise ValueError('ignored-only selection cannot discharge coverage')
                    verified = (catalog_views.verify_custom_execution(sections[key], selected[key], protocols[key])
                                if key in protocols else catalog_views.verify_execution(
                                    sections[key], selected[key], sorted(set(selected[key]).intersection(known_ignored[key]))))
                    if run['exitCode']:
                        raise ValueError('Cargo returned failure despite test receipt')
                    substantive, unavailable = catalog_views.substantive_cases(rows[key], selected[key], os.environ)
                    if not substantive and not unavailable:
                        raise ValueError('child/ignored-only selection cannot discharge coverage')
                    receipt.update(verified, execution='actual' if substantive else 'optional-material-unavailable',
                                   coverage=bool(substantive), substantivePassed=len(substantive),
                                   unavailableOptionalCases=unavailable,
                                   childEntries=sorted(set(selected[key]).intersection(rows[key].get('childEntries', []))))
                except ValueError as error:
                    receipt.update(completed=False, execution='failed', error=str(error))
            return local_stages, list(group_receipts.values())

        serial = [name for name, keys in groups.items() if not all(tuple(key.split('/')) in ISOLATED for key in keys)]
        isolated = [name for name, keys in groups.items() if all(tuple(key.split('/')) in ISOLATED for key in keys)]

        def queue(names):
            results = []
            for name in names:
                results.append(target_group(name))
            return results

        if workers == 2:
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(queue, owners) for owners in (serial, isolated)]
                results = [result for future in futures for result in future.result()]
        else:
            results = queue(list(groups))
        for local_stages, group_receipts in results:
            stages.extend(local_stages)
            receipts.extend(group_receipts)
        # Library, bin and documentation harnesses preserve their full default
        # execution. Integration selectors alone are split by Catalog lineage.
        default_flags = [flag for flag in ('--lib', '--bins') if flag in plan['commands'][0][1]]
        if default_flags:
            stages.append(recorded(BASE + default_flags, directory, 'unit-tests', cwd))
        for name, argv in plan['commands'][1:]:
            stages.append(recorded(argv, directory, name, cwd))
        if catalog_views.load(cwd, metadata) != manifest:
            raise ValueError('test source or frozen fixture changed during execution')
        if sorted(receipt['target'] for receipt in receipts) != sorted(key for keys in groups.values() for key in keys):
            raise ValueError('selected integration target receipt missing')
        failed = any(stage['exitCode'] for stage in stages) or any(
            receipt.get('error') for receipt in receipts)
        report['completed'] = not failed
        return 1 if failed else 0
    finally:
        (directory / 'catalog-execution.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(f"Catalog execution receipt: {directory / 'catalog-execution.json'}", flush=True)


def main() -> int:
    if sys.argv[1:] not in ([], ['--parity-consumers']):
        raise ValueError('unknown workspace test scope')
    workers = int(os.environ.get("ARKDECK_RUST_TEST_WORKERS", "1"))
    output = os.environ.get("ARKDECK_RUST_TEST_REPORT_DIR")
    # Checkout / published / candidate use separate reports as well as targets.
    name = os.environ.get("ARKDECK_RUST_TEST_VIEW", "checkout")
    if name not in ("checkout", "published", "candidate", "historical"):
        raise ValueError("invalid Rust test view")
    if workers not in (1, 2):
        raise ValueError('workspace test workers must be 1 or 2')
    directory = Path(output) / name if output else Path(tempfile.mkdtemp(prefix='arkdeck-catalog-tests-'))
    return catalog_selected(RUST, workers, directory, parity_consumers=sys.argv[1:] == ['--parity-consumers'])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"workspace tests: {error}", file=sys.stderr)
        sys.exit(1)
