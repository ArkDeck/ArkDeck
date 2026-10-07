"""Closed test-only c6/e4 routing; frozen authority is never transplanted.

The source inventory closes additions to tests and target declarations. Mixed
targets use exact libtest names. Receipts require execution of every selected
non-ignored case, rather than accepting a successful empty Cargo invocation.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tomllib

OLD = 'c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036'
CURRENT = 'e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7'
PACKET_SHA = 'd1a2614926275e9e8b38783ca5ac3054b6ea4fa63f051e2aedacfe59d7c937ab'
MANIFEST = 'scripts/catalog-test-views.json'

# These are the existing non-libtest entry points. Their source bytes are
# part of sources; a new harness cannot inherit another entry's protocol.
CUSTOM_HARNESSES = {
    'arkdeck-agentd/arkforged_owner_stop': ('default-summary', ('darwin',)),
    'arkdeck-agentd/windows_workspace_provider_process': ('listed-summary', ('win32',)),
    'arkdeck-agentd/windows_sign_stand_in': ('fixture-entry', ('win32',)),
    'arkdeck-cli/windows_signed_runtime': ('default-rows', ('win32',)),
    'arkdeck-hoststore/windows_workspace_sign_oracle': ('listed-summary', ('win32',)),
    'arkdeck-hoststore/windows_workspace_hvigor': ('listed-summary', ('win32',)),
    'arkdeck-platform/windows_console_restart': ('listed-summary', ('win32',)),
    'arkdeck-platform/windows_tool_dispatch': ('listed-summary', ('win32',)),
    'arkdeck-platform/windows_console_secret': ('default-summary', ('win32',)),
    'arkdeck-platform/windows_pty_exchange': ('listed-summary', ('win32',)),
    'arkdeck-platform/windows_shell_channel': ('listed-summary', ('win32',)),
    'arkdeck-provider-arkforge/lane': ('default-summary', ('darwin', 'win32')),
    'arkdeck-provider-hdc/windows_managed_hdc': ('listed-summary', ('win32',)),
    'arkdeck-provider-hdc/windows_lifecycle': ('listed-summary', ('win32',)),
    'arkdeck-provider-workspace/windows_signing_flow': ('listed-summary', ('win32',)),
}

# Each complete test module (and its support module) is explicitly macOS-only.
# Their full source pins are part of the manifest; zero output alone never
# establishes this exclusion. Other item-level cfg shapes remain unclassified.
MODULE_HOST_PLATFORMS = {
    'arkdeck-cli/' + name: ['darwin'] for name in (
        'device_wait', 'flash_host_facts', 'flash_host_reads',
        'flash_invocation_broker', 'job_wait', 'job_watch', 'loader_binding',
        'operation_validate', 'runtime_health')
}

CHILD_ENTRIES = {
    'arkdeck-hoststore/job_journal_restart': ['journal_restart_child'],
    'arkdeck-hoststore/job_journal_process_death': ['journal_append_process_death_child'],
    'arkdeck-hoststore/crash_window': ['crash_window_child'],
    'arkdeck-hoststore/pointer_input_run': ['pointer_crash_child'],
    'arkdeck-hoststore/device_mutation_reconcile': ['device_mutation_crash_child'],
    'arkdeck-agentd/spawning': ['signed_daemon::the_signed_test_daemon',
                              'account_tool_selection::the_signed_account_daemon'],
}
OPTIONAL_MATERIAL = {
    'arkdeck-hoststore/arktrace_reviewed': {
        'a_reviewed_distribution_passes_production_trust_and_its_own_doctor': ['ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR'],
        'a_reviewed_distribution_summarizes_the_fixture_trace_as_swift_did': ['ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR', 'ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT'],
        'a_reviewed_distribution_analyzes_the_fixture_trace_as_swift_did': ['ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR', 'ARKDECK_REVIEWED_ARKTRACE_ANALYSIS_SWIFT'],
    },
    'arkdeck-agentd/trace_summary_analyzer': {
        'a_reviewed_distribution_summarizes_the_fixture_trace_on_the_daemon_as_swift_did': ['ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR', 'ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT'],
        'a_reviewed_distribution_analyzes_the_fixture_trace_on_the_daemon_as_swift_did': ['ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR', 'ARKDECK_REVIEWED_ARKTRACE_ANALYSIS_SWIFT'],
    },
    'arkdeck-agentd/spawning': {
        'workspace_sign_leaf::the_real_cli_signs_a_hap_with_a_registered_signing_preset': ['ARKDECK_LIVE_DEVECO_ROOT'],
    },
    'arkdeck-cli/windows_signing_leaves': {
        'a_live_deveco_build_profile_decodes_through_its_own_material': ['ARKDECK_LIVE_DEVECO_BUILD_PROFILE'],
    },
}


def custom_harnesses(metadata: dict) -> dict[str, tuple[str, tuple[str, ...]]]:
    members = set(metadata['workspace_members'])
    found = set()
    for package in metadata['packages']:
        if package['id'] in members:
            manifest = tomllib.loads(Path(package['manifest_path']).read_text(encoding='utf-8'))
            found.update(package['name'] + '/' + entry['name'] for entry in manifest.get('test', [])
                         if entry.get('harness') is False)
    if not found.issubset(CUSTOM_HARNESSES):
        raise ValueError('unclassified custom harness')
    return {key: CUSTOM_HARNESSES[key] for key in found}


def generated_catalog(rows: list[dict], digest: str) -> str:
    path = Path(__file__).resolve().parents[2] / 'scripts/catalog_gen/generate.py'
    spec = importlib.util.spec_from_file_location('arkdeck_test_view_catalog_generator', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.generate_rust(rows, digest)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_inventory(rust: Path) -> dict[str, str]:
    # Git's Windows checkout spelling may contain CRLF; only that declared
    # representation is normalized. Every other source byte remains covered.
    files = list(rust.glob('crates/*/tests/**/*.rs'))
    files += [path for path in rust.glob('crates/*/src/**/*.rs')
              if path.relative_to(rust).as_posix() not in (
                  'crates/arkdeck-contract/src/catalog_generated.rs',
                  'crates/arkdeck-contract/src/control_generated.rs')]
    files += list(rust.glob('crates/*/Cargo.toml'))
    files += [path for path in (rust.parent / 'scripts/catalog_gen/generate.py',)
              if path.is_file()]
    return {(path.relative_to(rust).as_posix() if path.is_relative_to(rust)
             else '../' + path.relative_to(rust.parent).as_posix()): sha(path.read_bytes().replace(b'\r\n', b'\n'))
            for path in sorted(files)}


def fixture_inventory(rust: Path) -> dict[str, str]:
    return {path.relative_to(rust).as_posix(): sha(path.read_bytes())
            for path in sorted((rust / 'tests/fixtures').rglob('*')) if path.is_file()}


def catalogs(rust: Path) -> tuple[dict, dict]:
    path = rust / 'tests/fixtures/catalog-lineage-c6-e4/catalogs.json'
    data = path.read_bytes()
    if sha(data) != PACKET_SHA:
        raise ValueError('closed Catalog lineage packet changed')
    value = json.loads(data)
    if value['oldCatalogDigest'] != OLD or value['currentCatalogDigest'] != CURRENT:
        raise ValueError('unknown Catalog lineage')
    def table(rows):
        result = {f"{row['id']}@{row.get('version', 0)}": row for row in rows}
        if len(rows) != 32 or len(result) != 32:
            raise ValueError('complete 32-operation Catalog required')
        return result
    old, current = table(value['historicalOperations']), table(value['currentOperations'])
    if old.keys() != current.keys() or any(old[key] != current[key] for key in old if key != 'deploy.native-library.app-owned@1'):
        raise ValueError('unchanged operation descriptor drift')
    return old, current


def catalog(rust: Path) -> str:
    old, current = catalogs(rust)
    directory = rust.parent / 'Catalog/operations'
    rows = [json.loads(path.read_bytes()) for path in sorted(directory.glob('*.json'))]
    actual = {f"{row['id']}@{row.get('version', 0)}": row for row in rows}
    if len(rows) != 32 or len(actual) != 32:
        raise ValueError('complete actual Catalog source required')
    digest = OLD if actual == old else CURRENT if actual == current else None
    generated = (rust / 'crates/arkdeck-contract/src/catalog_generated.rs').read_text(encoding='utf-8')
    if digest is None or generated != generated_catalog(rows, digest):
        raise ValueError('unknown Catalog or generated source drift')
    return digest


def targets(metadata: dict) -> dict[str, dict]:
    members = set(metadata['workspace_members'])
    rows = {}
    for package in metadata['packages']:
        if package['id'] not in members:
            continue
        for target in package['targets']:
            if target['kind'] == ['test'] and target['test']:
                key = package['name'] + '/' + target['name']
                if key in rows:
                    raise ValueError('duplicate integration target')
                rows[key] = target
    return rows


def load(rust: Path, metadata: dict) -> dict:
    value = json.loads((rust / MANIFEST).read_bytes())
    if set(value) != {'schemaVersion', 'catalogs', 'sources', 'fixtures', 'targets'} or value['schemaVersion'] != 'arkdeck.catalog-test-views/1':
        raise ValueError('unknown test routing manifest')
    if value['catalogs'] != [OLD, CURRENT] or value['sources'] != source_inventory(rust):
        raise ValueError('unclassified test source or manifest drift')
    if value['fixtures'] != fixture_inventory(rust):
        raise ValueError('closed original and versioned fixture inventory drift')
    actual = targets(metadata)
    if set(actual) != set(value['targets']):
        raise ValueError('unclassified integration target')
    custom = custom_harnesses(metadata)
    for key, row in value['targets'].items():
        fields = set(row) - {'platformFunctions', 'customCases', 'childEntries', 'optionalMaterial', 'modulePlatforms'}
        if fields != {'route', 'functions', 'ignored'} or row['route'] not in ('both', 'current', 'historical', 'mixed'):
            raise ValueError('unknown test target route')
        if (row['route'] == 'mixed') != bool(row['functions']):
            raise ValueError('mixed target requires explicit function routes')
        if any(not re.fullmatch(r'[A-Za-z0-9_:]+', name) or route not in ('both', 'current', 'historical') for name, route in row['functions'].items()):
            raise ValueError('unknown test function route')
        if not isinstance(row['ignored'], list) or len(row['ignored']) != len(set(row['ignored'])) or any(
                not re.fullmatch(r'[A-Za-z0-9_:]+', name) for name in row['ignored']):
            raise ValueError('unknown ignored source census')
        if 'platformFunctions' in row:
            if row['route'] != 'mixed' or set(row['platformFunctions']) != {'win32', 'darwin', 'linux'}:
                raise ValueError('unknown mixed-target platform census')
            for names in row['platformFunctions'].values():
                if len(names) != len(set(names)) or not set(names).issubset(row['functions']):
                    raise ValueError('unknown platform function')
        if key in custom:
            protocol, platforms = custom[key]
            if row['ignored']:
                raise ValueError('custom harness has no ignored protocol')
            cases = row.get('customCases')
            if not isinstance(cases, dict) or set(cases) != set(platforms):
                raise ValueError('custom harness requires its complete host case census')
            for names in cases.values():
                if len(names) != len(set(names)) or any(not re.fullmatch(r'[A-Za-z0-9_:-]+', name) for name in names):
                    raise ValueError('invalid custom harness case')
                if (protocol == 'fixture-entry') != (not names):
                    raise ValueError('custom test suite cannot be empty')
        elif 'customCases' in row:
            raise ValueError('libtest target cannot claim custom protocol')
        if row.get('childEntries', []) != CHILD_ENTRIES.get(key, []):
            raise ValueError('unclassified non-substantive child entry')
        if row.get('optionalMaterial', {}) != OPTIONAL_MATERIAL.get(key, {}):
            raise ValueError('unclassified optional material prerequisite')
        if row.get('modulePlatforms', []) != MODULE_HOST_PLATFORMS.get(key, []):
            raise ValueError('unclassified complete-module host cfg')
    catalog(rust)
    return value


def listed(text: str) -> list[str]:
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    result = [line[:-6] for line in text.splitlines() if re.fullmatch(r'[^\s]+: test', line)]
    if len(result) != len(set(result)):
        raise ValueError('duplicate libtest function')
    return sorted(result)


def selected(row: dict, names: list[str], digest: str) -> list[str]:
    if digest not in (OLD, CURRENT):
        raise ValueError('unknown test execution Catalog')
    view = 'historical' if digest == OLD else 'current'
    if row['route'] == 'mixed':
        if set(row['functions']) != set(names):
            raise ValueError('unclassified mixed-target function')
        return [name for name in names if row['functions'][name] in (view, 'both')]
    return names if row['route'] in (view, 'both') else []


def platform_row(row: dict, platform: str) -> dict:
    if platform not in ('win32', 'darwin', 'linux'):
        raise ValueError('unclassified test platform')
    if 'platformFunctions' not in row:
        return row
    return {**row, 'functions': {name: row['functions'][name]
                               for name in row['platformFunctions'][platform]}}


def module_host_cfg_excluded(key: str, row: dict, platform: str) -> bool:
    if platform not in ('win32', 'darwin', 'linux'):
        raise ValueError('unclassified test platform')
    expected = MODULE_HOST_PLATFORMS.get(key, [])
    if row.get('modulePlatforms', []) != expected:
        raise ValueError('unclassified complete-module host cfg')
    return bool(expected) and platform not in expected


def verify_host_cfg_empty(text: str) -> None:
    plain = '\n'.join(re.sub(r'\x1b\[[0-9;]*m', '', text).splitlines())
    if listed(plain) or re.search(r'^test [^\s]+ \.\.\.', plain, re.M):
        raise ValueError('host-excluded module reported a case')
    results = re.findall(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;', plain, re.M)
    if results != [('ok', '0', '0', '0')]:
        raise ValueError('host-excluded module requires one exact zero-case completion')


def verify_execution(text: str, names: list[str], ignored: tuple[str, ...] | list[str] = ()) -> dict:
    plain = '\n'.join(re.sub(r'\x1b\[[0-9;]*m', '', text).splitlines())
    rows = re.findall(r'^test ([^\s]+) \.\.\. (ok|FAILED|ignored(?:,.*)?)$', plain, re.M)
    observed = {name: result for name, result in rows}
    if len(rows) != len(observed) or set(observed) != set(names):
        raise ValueError('selected functions were not each actually reported once')
    if len(ignored) != len(set(ignored)) or not set(ignored).issubset(names):
        raise ValueError('unknown ignored test census')
    if {name for name, result in rows if result.startswith('ignored')} != set(ignored):
        raise ValueError('required case was ignored or an audited ignored case changed')
    results = re.findall(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;', plain, re.M)
    if len(results) != 1:
        raise ValueError('exact one libtest completion required')
    state, passed, failed, ignored = results[0]
    if (int(passed), int(failed), int(ignored)) != (sum(result == 'ok' for result in observed.values()), sum(result == 'FAILED' for result in observed.values()), sum(result.startswith('ignored') for result in observed.values())):
        raise ValueError('libtest execution census mismatch')
    if not int(passed) or state != 'ok' or int(failed):
        raise ValueError('selected target did not execute passing cases')
    return {'functions': names, 'passed': int(passed), 'ignored': int(ignored), 'completed': True}


def verify_audited_ignored_execution(text: str, names: list[str], ignored: list[str], listed_names: list[str]) -> dict:
    """Verify an existing ignored-only receipt without claiming executed coverage."""
    if not names or len(names) != len(set(names)) or len(ignored) != len(set(ignored)) or set(names) != set(ignored):
        raise ValueError('ignored-only selection is not the exact audited census')
    if len(listed_names) != len(set(listed_names)) or not set(names).issubset(listed_names):
        raise ValueError('ignored-only selection differs from the full listed census')
    plain = '\n'.join(re.sub(r'\x1b\[[0-9;]*m', '', text).splitlines())
    lines = plain.splitlines()
    case_lines = [line for line in lines if line.startswith('test ') and not line.startswith('test result:')]
    rows = [re.fullmatch(r'test ([^\s]+) \.\.\. ignored(?:,.*)?', line) for line in case_lines]
    if len(rows) != len(names) or any(row is None for row in rows) or {row[1] for row in rows} != set(names):
        raise ValueError('audited ignored cases were not each reported once')
    summaries = [line for line in lines if line.startswith('test result:')]
    results = [re.fullmatch(r'test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;'
                           r' 0 measured; (\d+) filtered out; finished in (\d+(?:\.\d+)?)s', line) for line in summaries]
    expected = ('ok', '0', '0', str(len(names)), str(len(listed_names) - len(names)))
    if len(results) != 1 or results[0] is None or results[0].groups()[:5] != expected:
        raise ValueError('audited ignored completion census mismatch')
    return {'functions': names, 'passed': 0, 'ignored': len(names), 'completed': False, 'coverage': False}


def verify_custom_execution(text: str, names: list[str], protocol: str) -> dict:
    """The closed existing custom summaries, without inventing libtest output."""
    plain = '\n'.join(re.sub(r'\x1b\[[0-9;]*m', '', text).splitlines())
    rows = re.findall(r'^test ([^\s]+) \.\.\. (ok|FAILED(?:.*)?)$', plain, re.M)
    if len(rows) != len(names) or {name for name, _ in rows} != set(names) or any(result != 'ok' for _, result in rows):
        raise ValueError('custom suite did not report every exact successful case')
    results = re.findall(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed(?:; (\d+) ignored)?[^\n]*$', plain, re.M)
    if protocol == 'default-rows':
        if results or not names:
            raise ValueError('rows-only custom protocol drift')
    elif protocol in ('listed-summary', 'default-summary'):
        if len(results) != 1 or results[0] != ('ok', str(len(names)), '0', results[0][3]) or results[0][3] not in ('', '0') or not names:
            raise ValueError('custom completion census mismatch')
    else:
        raise ValueError('unknown custom execution protocol')
    return {'functions': names, 'passed': len(names), 'ignored': 0, 'completed': True}


def substantive_cases(row: dict, selected: list[str], environment: dict) -> tuple[list[str], list[str]]:
    unavailable = [name for name, keys in row.get('optionalMaterial', {}).items()
                   if name in selected and not all(environment.get(key) for key in keys)]
    children = set(row.get('childEntries', []))
    substantive = sorted(set(selected) - children - set(unavailable) - set(row['ignored']))
    return substantive, sorted(unavailable)
