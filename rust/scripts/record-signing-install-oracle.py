#!/usr/bin/env python3
"""Record Swift install refusals before any Keychain access or write.

Success cases must use an injected store in library tests. HOME does not
isolate the account Keychain. Every actual CLI case below either rejects a
relative path or lacks a terminal, before credential-owner replacement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-cli", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    executable = args.swift_cli.resolve(strict=True)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--swift-cli must be an executable file")
    cases = []
    for prefix in [["runtime", "signing"], ["signing"]]:
        for mode in [[], ["--output", "json"], ["--json"]]:
            for relative in [False, True]:
                with tempfile.TemporaryDirectory(prefix="arkdeck-signing-install-oracle-") as temp:
                    home = Path(temp).resolve()
                    argv = prefix + ["install", "--java", "relative/java" if relative else "/fixture/java",
                                     "--jar", "/fixture/signer.jar", "--keystore", "/fixture/source.p12",
                                     "--certificate", "/fixture/source.pem", "--profile", "/fixture/source.p7b",
                                     "--key-alias", "release", "--project-ref", "demo-app"] + mode
                    result = subprocess.run([str(executable), *argv], capture_output=True,
                                            stdin=subprocess.DEVNULL,
                                            env={"HOME": str(home), "CFFIXED_USER_HOME": str(home)},
                                            timeout=20, check=False)
                    expected = b"--java must be an absolute path" if relative else b"signing passwords require an interactive TTY"
                    if result.returncode != 64 or result.stdout or expected not in result.stderr:
                        raise RuntimeError("Swift did not take the expected pre-Keychain refusal")
                    if list(home.iterdir()):
                        raise RuntimeError("Swift changed the private home")
                    cases.append({"argv": argv, "exit": result.returncode,
                                  "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
    base = ["runtime", "signing", "install", "--java", "/fixture/java",
            "--jar", "/fixture/signer.jar", "--keystore", "/fixture/source.p12",
            "--certificate", "/fixture/source.pem", "--profile", "/fixture/source.p7b",
            "--key-alias", "release", "--build-profile", "{PROFILE}"]
    profiles = [
        ("{storeFile:'/fixture/source.p12',storePassword:'" + "ab" * 16 +
         "',keyPassword:'" + "cd" * 16 + "',storePassword:'" + "ef" * 16 + "'}",
         b"must contain exactly one storePassword ciphertext"),
        ("{storeFile:'/fixture/source.p12',storePassword:'" + "a" * 33 +
         "',keyPassword:'" + "cd" * 16 + "'}", b"storePassword ciphertext is malformed"),
        ("{storeFile:'/different/source.p12',storePassword:'" + "ab" * 16 +
         "',keyPassword:'" + "cd" * 16 + "'}", b"names a different storeFile"),
    ]
    for contents, expected in profiles:
        for mode in [[], ["--output", "json"]]:
            with tempfile.TemporaryDirectory(prefix="arkdeck-signing-profile-oracle-", dir="/private/tmp") as temp:
                home = Path(temp)
                profile = home / "build-profile.json5"
                profile.write_text(contents)
                profile.chmod(0o600)
                argv = base + mode
                actual = [str(profile).removeprefix("/private") if value == "{PROFILE}" else value for value in argv]
                result = subprocess.run([str(executable), *actual], capture_output=True,
                                        stdin=subprocess.DEVNULL,
                                        env={"HOME": str(home), "CFFIXED_USER_HOME": str(home)},
                                        timeout=20, check=False)
                if result.returncode != 64 or result.stdout or expected not in result.stderr:
                    raise RuntimeError("Swift did not take the expected profile refusal")
                if list(home.iterdir()) != [profile] or profile.read_text() != contents:
                    raise RuntimeError("Swift changed the fixture profile/home")
                cases.append({"argv": argv, "profileContents": contents, "exit": result.returncode,
                              "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "cases.json").write_text(json.dumps(cases, indent=2, sort_keys=True) + "\n")
    (args.out / "provenance.json").write_text(json.dumps({
        "producer": "record-signing-install-oracle.py", "swiftCliSha256":
        hashlib.sha256(executable.read_bytes()).hexdigest(), "owners": [
            "RuntimeCLI.runSigning", "RuntimeCLI.readTTYSecret", "RuntimeCLI.readDevEcoBuildProfileSigningMaterial"]
    }, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
