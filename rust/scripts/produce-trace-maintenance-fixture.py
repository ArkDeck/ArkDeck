#!/usr/bin/env python3
"""Link a bounded fixture producer to the current pinned SwiftPM ArkTrace objects.

Run only in the coordinated native build window. This never modifies a checkout
or a cache: compiler output and fixtures must use a new /private/tmp directory.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--swift-build', type=Path, required=True, help='existing arm64-apple-macosx/debug directory')
p.add_argument('--fixture', type=Path, required=True, help='new /private/tmp fixture root')
a = p.parse_args()
source = ROOT/'rust/tests/fixtures/trace-maintenance/produce-native.swift'
resolved = ROOT/'Packages/ArkDeckKit/Package.resolved'
pin = next(x['state']['revision'] for x in json.loads(resolved.read_bytes())['pins'] if x['identity'] == 'arktrace')
checkout = a.swift_build.parents[1]/'checkouts/ArkTrace'
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if revision != pin:
    raise SystemExit('native ArkTrace checkout does not match the current package pin')
if not a.fixture.is_absolute() or not str(a.fixture).startswith('/private/tmp/') or a.fixture.exists():
    raise SystemExit('fixture must be new and under /private/tmp')
modules = ['ArkTraceCore', 'ArkTraceParser', 'ArkTraceStore', 'ArkTraceRuntime']
objects = [path for name in modules for path in sorted((a.swift_build/f'{name}.build').glob('*.swift.o'))]
if any(not list((a.swift_build/f'{name}.build').glob('*.swift.o')) for name in modules):
    raise SystemExit('current pinned native module objects are unavailable; run the coordinated Swift build first')
with tempfile.TemporaryDirectory(prefix='arkdeck-native-trace-producer-', dir='/private/tmp') as temporary:
    executable = Path(temporary)/'producer'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-package-name','arktrace',
        '-I',str(a.swift_build/'Modules'),str(source),*[str(x) for x in objects],
        '-lsqlite3','-o',str(executable)],check=True)
    subprocess.run([str(executable),'seed',str(a.fixture)],check=True)
    native_sources = sorted((checkout/'Sources').rglob('*.swift'))
    inputs = [x for name in ['rust', 'swift'] for x in sorted((a.fixture/name).rglob('*')) if x.is_file()]
    for path in inputs:
        saved = a.fixture/'raw'/path.relative_to(a.fixture)
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, saved)
    manifest={'pinnedRevision': pin, 'packageResolvedSHA256':hashlib.sha256(resolved.read_bytes()).hexdigest(),
        'producerSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
        'nativeSources':[{'path':str(x.relative_to(checkout)),'sha256':hashlib.sha256(x.read_bytes()).hexdigest()} for x in native_sources],
        'moduleObjects':[{'path':str(x),'sha256':hashlib.sha256(x.read_bytes()).hexdigest()} for x in objects],
        'fixtureFiles':[{'path':str(x.relative_to(a.fixture)),'sha256':hashlib.sha256(x.read_bytes()).hexdigest(),
                         'device':x.stat().st_dev,'inode':x.stat().st_ino} for x in inputs]}
    (a.fixture/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
    subprocess.run([str(executable),'report',str(a.fixture)],check=True)
