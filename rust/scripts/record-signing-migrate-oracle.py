#!/usr/bin/env python3
"""Record Swift migrate-deveco refusals before any Keychain access.

Only relative profile or non-installed daemon paths are used. Never add
successful production maintenance here: HOME does not isolate Keychain.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-cli', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    executable = args.swift_cli.resolve(strict=True)
    cases = []
    for prefix in [['runtime', 'signing'], ['signing']]:
        for mode in [[], ['--output', 'json'], ['--json']]:
            for relative in [True, False]:
                argv = prefix + ['migrate-deveco', '--build-profile',
                                 'relative.json5' if relative else '/fixture/build-profile.json5',
                                 '--daemon', '/fixture/uninstalled-daemon'] + mode
                with tempfile.TemporaryDirectory(prefix='arkdeck-migrate-oracle-', dir='/private/tmp') as temp:
                    home = Path(temp)
                    result = subprocess.run([str(executable), *argv], capture_output=True,
                                            stdin=subprocess.DEVNULL,
                                            env={'HOME': temp, 'CFFIXED_USER_HOME': temp},
                                            timeout=20, check=False)
                    expected = b'requires --build-profile and --daemon absolute paths' if relative else b'--daemon must name the canonical installed LaunchAgent daemon'
                    if result.returncode != 64 or result.stdout or expected not in result.stderr:
                        raise RuntimeError('Swift did not take the expected pre-Keychain refusal')
                    if list(home.iterdir()):
                        raise RuntimeError('Swift changed the fixture home')
                    cases.append({'argv': argv, 'exit': result.returncode,
                                  'stdout': result.stdout.decode(), 'stderr': result.stderr.decode()})
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / 'cases.json').write_text(json.dumps(cases, indent=2, sort_keys=True) + '\n')
    (args.out / 'provenance.json').write_text(json.dumps({
        'producer': 'record-signing-migrate-oracle.py',
        'swiftCliSha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'owners': ['RuntimeCLI.runSigning.migrate-deveco'],
    }, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
