#!/usr/bin/env python3
"""Prepare the pinned ArkTrace package's SDK and fixed ArkDeck bundle inputs."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def physical(path):
    require(path.is_absolute() and not any(p.is_symlink() for p in (path, *path.parents)),
            "physical absolute build path required")


def source_revision(workspace):
    resolved = json.loads((workspace / "apple/Packages/ArkDeckKit/Package.resolved").read_text())
    pins = [row for row in resolved["pins"] if row["identity"].lower() == "arktrace"]
    require(len(pins) == 1, "one pinned ArkTrace dependency required")
    revision = pins[0]["state"]["revision"]
    require(isinstance(revision, str) and len(revision) == 40
            and all(c in "0123456789abcdef" for c in revision), "exact ArkTrace revision required")
    return revision


def find_source(source_packages, revision):
    checkouts = source_packages / "checkouts"
    physical(checkouts)
    matches = [path for path in checkouts.iterdir() if (path / "sources/ArkTraceAppSupport").is_dir()]
    require(len(matches) == 1, "one resolved ArkTrace checkout required")
    source = matches[0]
    physical(source)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    require(head == revision, "resolved ArkTrace source revision mismatch")
    require(not subprocess.check_output(["git", "diff", "HEAD", "--name-only"], cwd=source),
            "resolved ArkTrace tracked source drift")
    return source


def copy_parser(source, target, regular):
    regular(source)
    physical(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        regular(target)
        if target.read_bytes() == source.read_bytes():
            return
        target.unlink()
    shutil.copyfile(source, target)
    target.chmod(0o555)


def materialize(repo, workspace):
    """Keep UI/release builds outside source, using the normal runner's inputs."""
    for path in (repo, workspace):
        physical(path)
    require(not workspace.is_relative_to(repo), "external App workspace required")
    workspace.mkdir(parents=True, exist_ok=True)
    ignored = subprocess.check_output(
        ["git", "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
        cwd=repo)
    with tempfile.NamedTemporaryFile() as exclusions:
        exclusions.write(b"".join(b"/" + path + b"\0" for path in ignored.split(b"\0") if path))
        exclusions.flush()
        subprocess.run(["/usr/bin/rsync", "-ac", "--no-times", "--delete", "--delete-excluded",
                        "--from0", "--exclude=.git", "--exclude-from=" + exclusions.name,
                        str(repo) + "/", str(workspace) + "/"], check=True)


def resolve(workspace, source_packages, xcodebuild):
    environment = dict(os.environ)
    environment.pop("ARKTRACE_RUST_XCFRAMEWORK", None)
    environment.pop("ARKTRACE_RUST_SDK_FIXTURES", None)
    subprocess.run([xcodebuild, "-project", str(workspace / "apple/ArkDeck.xcodeproj"),
                    "-scheme", "ArkDeck", "-clonedSourcePackagesDirPath", str(source_packages),
                    "-onlyUsePackageVersionsFromResolvedFile", "-resolvePackageDependencies"],
                   env=environment, check=True, stdout=sys.stderr)



def prepare_sdk(repo, workspace, source_packages, sdk):
    for path in (repo, workspace, source_packages):
        physical(path)
    require(not workspace.is_relative_to(repo), "external cache-owned package required")
    revision = source_revision(workspace)
    source = find_source(source_packages, revision)
    sys.path.insert(0, str(source / "hack"))
    from stage_macos_rust_sdk import stage
    return {"relativeSDK": stage(sdk, source, False, repo), "sourceRevision": revision,
            "source": str(source)}


def prepare(repo, workspace, source_packages, sdk=None, signing_identity=None, inputs=None):
    for path in (repo, workspace, source_packages):
        physical(path)
    require(repo.is_dir() and workspace.is_dir() and not workspace.is_relative_to(repo),
            "external cache-owned App workspace required")
    revision = source_revision(workspace)
    source = find_source(source_packages, revision)
    sys.path.insert(0, str(source / "hack"))
    from prepare_macos_native_app import prepare as shared_prepare, regular, sha, validate_inputs

    parser = repo / "apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = source / "third_party/trace-streamer/macx/manifest.json"
    for path in (parser, manifest):
        regular(path)
    expected = json.loads(manifest.read_text())["binarySHA256"]
    require(sha(parser) == expected, "ArkDeck parser differs from the pinned ArkTrace manifest")
    copy_parser(parser, source / "third_party/trace-streamer/macx/trace_streamer", regular)
    copy_parser(parser, workspace / "apple/Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer", regular)
    if inputs is None:
        result = shared_prepare(source, sdk, signing_identity, "arkdeck", repo)
    else:
        # Reuse an admitted immutable build artifact without starting another
        # Cargo owner or changing the registered source of an existing owner.
        require(sdk is not None, "prepared inputs require an explicit matching SDK")
        physical(inputs)
        admitted = validate_inputs(inputs, "arkdeck")
        from stage_macos_rust_sdk import stage, verified_receipt
        sdk_receipt, _ = verified_receipt(sdk, False)
        require(admitted["inputs"]["contractSHA256"] == sdk_receipt["contractSHA256"]
                and admitted["inputs"]["unsignedParserSHA256"] == expected
                and admitted["inputs"]["parserManifestSHA256"] == sha(manifest),
                "prepared inputs differ from the pinned source/SDK contract")
        result = {"relativeSDK": stage(sdk, source, False, repo), "inputs": str(inputs),
                  "runtimeUsable": admitted["runtimeUsable"], "releaseAcceptance": False}
    artifact = Path(result["inputs"])
    staged = workspace / "apple/.arktrace-native/AppInputs"
    physical(staged)
    staged.parent.mkdir(mode=0o700, exist_ok=True)
    if staged.exists():
        validate_inputs(staged, "arkdeck")
        if (staged / "receipt.json").read_bytes() != (artifact / "receipt.json").read_bytes():
            shutil.rmtree(staged)
    if not staged.exists():
        shutil.copytree(artifact, staged)
    validate_inputs(staged, "arkdeck")
    return {**result, "sourceRevision": revision, "source": str(source),
            "stagedAppInputs": str(staged), "appAcceptance": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--source-packages", type=Path, required=True)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--sdk-only", action="store_true")
    parser.add_argument("--signing-identity")
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--materialize", action="store_true")
    parser.add_argument("--resolve", action="store_true")
    parser.add_argument("--xcodebuild", default="xcodebuild")
    parser.add_argument("--require-runtime", action="store_true")
    args = parser.parse_args()
    try:
        if args.materialize:
            materialize(args.repo, args.workspace)
        if args.resolve:
            resolve(args.workspace, args.source_packages, args.xcodebuild)
        if args.sdk_only:
            require(args.sdk is not None and not args.require_runtime, "SDK-only preparation requires an explicit SDK")
            result = prepare_sdk(args.repo, args.workspace, args.source_packages, args.sdk)
        else:
            result = prepare(args.repo, args.workspace, args.source_packages,
                             args.sdk, args.signing_identity, args.inputs)
            require(not args.require_runtime or result["runtimeUsable"],
                    "release requires signed native Trace inputs")
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("ArkDeck native Trace preparation: " + str(error))
