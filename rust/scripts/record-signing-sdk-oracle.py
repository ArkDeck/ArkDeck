#!/usr/bin/env python3
"""Record SDK signing CLI relative-path refusals before owner/Keychain access."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-cli', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    executable = args.swift_cli.resolve(strict=True)
    cases = []
    for prefix in [['runtime', 'signing'], ['signing']]:
        for mode in [[], ['--output', 'json'], ['--json']]:
            for relative in ['sdk', 'java']:
                argv = prefix + ['install-sdk-release', '--sdk',
                                 'relative-sdk' if relative == 'sdk' else '/fixture/sdk',
                                 '--java', 'relative-java' if relative == 'java' else '/fixture/java',
                                 '--bundle-name', 'com.example.app'] + mode
                with tempfile.TemporaryDirectory(prefix='arkdeck-sdk-oracle-', dir='/private/tmp') as temp:
                    result = subprocess.run([str(executable), *argv], capture_output=True,
                                            stdin=subprocess.DEVNULL,
                                            env={'HOME': temp, 'CFFIXED_USER_HOME': temp},
                                            timeout=20, check=False)
                    expected = f'--{relative} must be an absolute path'.encode()
                    if result.returncode != 64 or result.stdout or expected not in result.stderr:
                        raise RuntimeError('Swift did not take the expected pre-Keychain refusal')
                    if list(Path(temp).iterdir()):
                        raise RuntimeError('Swift changed the fixture home')
                    cases.append({'argv': argv, 'exit': result.returncode,
                                  'stdout': result.stdout.decode(), 'stderr': result.stderr.decode()})
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / 'cases.json').write_text(json.dumps(cases, indent=2, sort_keys=True) + '\n')
    (args.out / 'provenance.json').write_text(json.dumps({
        'producer': 'record-signing-sdk-oracle.py',
        'swiftCliSha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'owners': ['RuntimeCLI.runSigningAsync.install-sdk-release'],
    }, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
