#!/usr/bin/env python3
"""Build a development-only rkdeveloptool and embed it in a local ArkDeck App.

This entry point is intentionally separate from the reproducible release build.
It verifies the same pinned source archives and libusb signature, compiles without
network access, and passes the resulting component plus matching local metadata
to Xcode.  It never launches ArkDeck, rkdeveloptool, HDC, USB, or a device.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import build  # noqa: E402


REPO_ROOT = SCRIPT_DIR.parents[1]
PROJECT_PATH = REPO_ROOT / "ArkDeck.xcodeproj"
COMPONENT_ENTITLEMENTS_PATH = REPO_ROOT / "ArkDeckApp/RockchipComponent.entitlements"
LOCAL_C_STANDARD = "c23"
LOCAL_CXX_STANDARD = build.RKDEVELOPTOOL_CXX_STANDARD
LOCAL_CXX_DISPLAY_NAME = "C++23"
LOCAL_C_DISPLAY_NAME = "C23"
LOCAL_SIGNING_IDENTIFIER = "com.arkdeck.desktop.rkdeveloptool"


class LocalBuildError(RuntimeError):
    """A fail-closed local component or App build failure."""


def _decode(completed: subprocess.CompletedProcess, stream: str = "stdout") -> str:
    value = completed.stdout if stream == "stdout" else completed.stderr
    return value.decode("utf-8", errors="replace")


def _run(
    argv: Sequence[object],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    accepted_exit_codes: frozenset[int] = frozenset({0}),
    capture: bool = True,
) -> subprocess.CompletedProcess:
    arguments = [str(item) for item in argv]
    completed = subprocess.run(
        arguments,
        cwd=str(cwd) if cwd is not None else None,
        env=dict(env) if env is not None else None,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if completed.returncode not in accepted_exit_codes:
        stderr = _decode(completed, "stderr")[-4000:] if capture else ""
        raise LocalBuildError(
            "command failed ({}): {}{}".format(
                completed.returncode,
                " ".join(arguments[:2]),
                "\n{}".format(stderr) if stderr else "",
            )
        )
    return completed


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _augment_local_source_manifest(path: Path) -> None:
    document = json.loads(path.read_text(encoding="utf-8"))
    local_files = (
        "scripts/rockchip_component/LOCAL.md",
        "scripts/rockchip_component/local_app.py",
        "scripts/rockchip_component/test_local_app.py",
    )
    for relative in local_files:
        source = REPO_ROOT / relative
        if not source.is_file():
            raise LocalBuildError(
                "required local build file is missing: {}".format(relative)
            )
        document["buildFiles"].append(
            {
                "gitBlob": build.git_blob_oid(source),
                "path": relative,
                "sha256": _sha256(source),
                "size": source.stat().st_size,
            }
        )
    document["buildFiles"] = sorted(
        document["buildFiles"], key=lambda item: item["path"].encode("utf-8")
    )
    document["developmentOnly"] = True
    build.assert_no_sensitive_values(document)
    build.write_canonical_json(path, document)


def _toolchain_environment(developer_directory: Path, home: Path) -> Dict[str, str]:
    home.mkdir(mode=0o700)
    return {
        "DEVELOPER_DIR": str(developer_directory),
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TZ": "UTC",
    }


def inspect_local_toolchain(
    recipe: Mapping[str, Any], work_root: Path
) -> Dict[str, Any]:
    selected = os.environ.get("DEVELOPER_DIR")
    if selected is None:
        selected = _decode(_run(["/usr/bin/xcode-select", "-p"])).strip()
    developer_directory = Path(selected).resolve()
    if not developer_directory.is_dir():
        raise LocalBuildError("the selected Xcode developer directory is unavailable")
    env = _toolchain_environment(developer_directory, work_root / "toolchain-home")

    architecture = _decode(_run(["/usr/bin/uname", "-m"], env=env)).strip()
    if architecture != recipe["component"]["architecture"]:
        raise LocalBuildError(
            "local Rockchip development builds require an arm64 macOS host"
        )
    os_version = _decode(
        _run(["/usr/bin/sw_vers", "-productVersion"], env=env)
    ).strip()
    os_build = _decode(
        _run(["/usr/bin/sw_vers", "-buildVersion"], env=env)
    ).strip()
    xcode_lines = _decode(
        _run(["/usr/bin/xcodebuild", "-version"], env=env)
    ).splitlines()
    if len(xcode_lines) < 2:
        raise LocalBuildError("xcodebuild returned incomplete version facts")
    sdk_version = _decode(
        _run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
            env=env,
        )
    ).strip()
    sdk_path = Path(
        _decode(
            _run(
                ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                env=env,
            )
        ).strip()
    ).resolve()
    with (sdk_path / "System/Library/CoreServices/SystemVersion.plist").open(
        "rb"
    ) as stream:
        sdk_build = plistlib.load(stream)["ProductBuildVersion"]

    tools: Dict[str, str] = {}
    for name in (
        "ar",
        "clang",
        "clang++",
        "lipo",
        "nm",
        "otool",
        "ranlib",
        "strip",
    ):
        tools[name] = _decode(
            _run(["/usr/bin/xcrun", "--sdk", "macosx", "--find", name], env=env)
        ).strip()

    _run(
        [
            tools["clang"],
            "-std={}".format(LOCAL_C_STANDARD),
            "-x",
            "c",
            "-fsyntax-only",
            "/dev/null",
        ],
        env=env,
    )
    _run(
        [
            tools["clang++"],
            "-std={}".format(LOCAL_CXX_STANDARD),
            "-x",
            "c++",
            "-fsyntax-only",
            "/dev/null",
        ],
        env=env,
    )

    iconv_header = sdk_path / "usr/include/iconv.h"
    iconv_tbd = sdk_path / "usr/lib/libiconv.2.tbd"
    if _sha256(iconv_header) != recipe["inspection"]["sdkIconvHeaderSHA256"]:
        raise LocalBuildError("selected SDK iconv.h differs from the component pin")
    if _sha256(iconv_tbd) != recipe["inspection"]["sdkIconvTbdSHA256"]:
        raise LocalBuildError("selected SDK libiconv.2.tbd differs from the component pin")

    signature_tools: Dict[str, Dict[str, str]] = {}
    for name in ("gpg", "gpgv"):
        pin = recipe["builder"][name]
        tool = Path(pin["absolutePath"])
        if not tool.is_symlink() or not tool.is_file():
            raise LocalBuildError(
                "{} {} is required to verify the pinned libusb source".format(
                    name, pin["version"]
                )
            )
        real_path = tool.resolve()
        if str(real_path) != pin["realPath"]:
            raise LocalBuildError("{} installation path differs from the pin".format(name))
        version = _decode(_run([tool, "--version"], env=env)).splitlines()[0].rsplit(
            None, 1
        )[-1]
        if version != pin["version"]:
            raise LocalBuildError("{} version differs from the pin".format(name))
        signature_tools[name] = {
            "absolutePath": str(tool),
            "realPath": str(real_path),
            "sha256": _sha256(real_path),
            "version": version,
        }

    if not Path("/usr/bin/sandbox-exec").is_file():
        raise LocalBuildError("sandbox-exec is required for the closed compile phase")

    return {
        "architecture": architecture,
        "bash": re.search(
            r"version ([^ -]+)",
            _decode(_run(["/bin/bash", "--version"], env=env)).splitlines()[0],
        ).group(1),
        "clang": _decode(_run([tools["clang"], "--version"], env=env)).splitlines()[0],
        "developerDirectory": str(developer_directory),
        "hostedImage": {
            "imageOS": "local-development",
            "label": "macos-{}-{}".format(os_version.split(".", 1)[0], architecture),
            "version": "untrusted-local-host",
        },
        "make": _decode(_run(["/usr/bin/make", "--version"], env=env)).splitlines()[0],
        "osBuild": os_build,
        "osVersion": os_version,
        "python": "{}.{}.{}".format(*sys.version_info[:3]),
        "sdkBuild": sdk_build,
        "sdkPath": str(sdk_path),
        "sdkVersion": sdk_version,
        "signatureVerifier": {
            "packageProvenance": dict(recipe["builder"]["gnupgBottle"]),
            "tools": signature_tools,
        },
        "tools": tools,
        "xcodeBuild": xcode_lines[1].removeprefix("Build version ").strip(),
        "xcodeVersion": xcode_lines[0].removeprefix("Xcode ").strip(),
    }


def _compile_arguments(
    *,
    compiler: str,
    source: Path,
    output: Path,
    work_root: Path,
    rk_source: Path,
    libusb_source: Path,
    libusb_build: Path,
    generated_config: Path,
    toolchain: Mapping[str, Any],
    recipe: Mapping[str, Any],
) -> list[str]:
    return build.rkdeveloptool_compile_arguments(
        compiler=compiler,
        source=source,
        output=output,
        work_root=work_root,
        rk_source=rk_source,
        libusb_source=libusb_source,
        libusb_build=libusb_build,
        generated_config=generated_config,
        toolchain=toolchain,
        recipe=recipe,
    )


def build_local_component(work_root: Path, output_dir: Path) -> Dict[str, Any]:
    recipe = build.load_recipe()
    build.ensure_fresh_directory(work_root)
    build.ensure_fresh_directory(output_dir)
    os.umask(0o022)

    inputs = work_root / "inputs"
    fetch_receipt = build.fetch_inputs(recipe, inputs)
    toolchain = inspect_local_toolchain(recipe, work_root)
    signature_receipt = build.verify_libusb_signature(
        recipe, inputs, work_root / "gnupg"
    )

    extracted = work_root / "extracted"
    extracted.mkdir()
    rk = recipe["inputs"]["rkdeveloptool"]
    libusb = recipe["inputs"]["libusb"]
    rk_archive = inputs / rk["archive"]["filename"]
    libusb_archive = inputs / libusb["archive"]["filename"]
    build.verify_file_pin(rk_archive, rk["archive"])
    build.verify_file_pin(libusb_archive, libusb["archive"])
    rk_inventory = build.extract_archive(
        rk_archive, rk["archiveRoot"], extracted / "rk"
    )
    libusb_inventory = build.extract_archive(
        libusb_archive, libusb["archiveRoot"], extracted / "libusb"
    )
    rk_source = extracted / "rk" / rk["archiveRoot"]
    libusb_source = extracted / "libusb" / libusb["archiveRoot"]

    build_root = work_root / "build"
    build_root.mkdir()
    env = build._closed_build_environment(work_root, toolchain, recipe)
    env["CFLAGS"] = "{} -std={}".format(env["CFLAGS"], LOCAL_C_STANDARD)
    env["CXXFLAGS"] = "{} -std={}".format(env["CXXFLAGS"], LOCAL_CXX_STANDARD)
    recorder = build.CommandRecorder(
        {
            str(work_root): "$WORK_ROOT",
            str(output_dir): "$OUTPUT_DIR",
            toolchain["developerDirectory"]: "$DEVELOPER_DIR",
            toolchain["sdkPath"]: "$SDKROOT",
        }
    )

    libusb_build = build_root / "libusb"
    libusb_build.mkdir()
    recorder.run(
        [
            "/bin/bash",
            str(libusb_source / "configure"),
            *libusb["configureArguments"],
        ],
        cwd=libusb_build,
        env=env,
    )
    recorder.run(
        ["/usr/bin/make", "-j1", "-C", "libusb", "libusb-1.0.la"],
        cwd=libusb_build,
        env=env,
    )
    libusb_static = libusb_build / "libusb/.libs/libusb-1.0.a"
    if not libusb_static.is_file():
        raise LocalBuildError("libusb static archive was not produced")

    generated_config = build_root / "generated/config.h"
    build._write_generated_config(generated_config, recipe)
    object_dir = build_root / "objects"
    object_dir.mkdir()
    objects: list[Path] = []
    for source_name in rk["sourceFiles"]:
        source = rk_source / source_name
        if source.suffix != ".cpp" or not source.is_file():
            raise LocalBuildError("the pinned rkdeveloptool C++ source set drifted")
        obj = object_dir / "{}.o".format(source.stem)
        recorder.run(
            _compile_arguments(
                compiler=toolchain["tools"]["clang++"],
                source=source,
                output=obj,
                work_root=work_root,
                rk_source=rk_source,
                libusb_source=libusb_source,
                libusb_build=libusb_build,
                generated_config=generated_config,
                toolchain=toolchain,
                recipe=recipe,
            ),
            cwd=build_root,
            env=env,
        )
        objects.append(obj)

    binary = output_dir / recipe["component"]["outputName"]
    recorder.run(
        [
            toolchain["tools"]["clang++"],
            "-target",
            recipe["component"]["targetTriple"],
            "-arch",
            recipe["component"]["architecture"],
            "-mmacosx-version-min=14.0",
            "-isysroot",
            toolchain["sdkPath"],
            "-Wl,-no_adhoc_codesign",
            "-Wl,-dead_strip",
            *[str(item) for item in objects],
            str(libusb_static),
            "-liconv",
            "-lobjc",
            "-framework",
            "IOKit",
            "-framework",
            "CoreFoundation",
            "-framework",
            "Security",
            "-o",
            str(binary),
        ],
        cwd=build_root,
        env=env,
    )
    artifact = build.inspect_artifact(binary, recorder, env, toolchain, recipe)

    notices = output_dir / "THIRD-PARTY-NOTICES.txt"
    build.generate_notices(notices, rk_source, libusb_source, recipe)
    sbom = output_dir / "sbom.spdx.json"
    build.generate_spdx(sbom, rk_inventory, rk_source, artifact, recipe)
    source_manifest = output_dir / "source-distribution-manifest.json"
    build.generate_source_manifest(source_manifest, notices, sbom, recipe)
    _augment_local_source_manifest(source_manifest)
    registry = output_dir / "registry.yaml"
    build.generate_registry(
        registry,
        artifact,
        toolchain,
        recorder.digest(),
        notices,
        sbom,
        source_manifest,
        recipe,
    )
    registry_value = json.loads(registry.read_text(encoding="utf-8"))
    registry_value["build"]["developmentOnly"] = True
    registry_value["build"]["cLanguageStandard"] = LOCAL_C_DISPLAY_NAME
    registry_value["build"]["cxxLanguageStandard"] = LOCAL_CXX_DISPLAY_NAME
    registry_value["registeredBy"] = "local-development-only"
    build.write_canonical_json(registry, registry_value)
    shutil.copyfile(build.RECIPE_PATH, output_dir / "recipe.json")
    build.validate_spdx(sbom)
    build.validate_registry(registry, recipe)

    receipt = {
        "artifact": artifact,
        "commands": recorder.commands,
        "effectCounters": {
            "appLaunch": 0,
            "componentLaunch": 0,
            "device": 0,
            "deviceMutation": 0,
            "hdc": 0,
            "usb": 0,
        },
        "fetch": fetch_receipt,
        "inputInventory": {
            "libusbFileCount": len(libusb_inventory),
            "rkdeveloptoolFileCount": len(rk_inventory),
        },
        "language": {
            "libusb": LOCAL_C_DISPLAY_NAME,
            "rkdeveloptool": LOCAL_CXX_DISPLAY_NAME,
        },
        "recipeSHA256": build.sha256_file(build.RECIPE_PATH),
        "schemaVersion": "1.0.0",
        "signatureVerification": signature_receipt,
        "trust": "local-development-only-not-release-evidence",
        "verdict": "PASS",
    }
    build.assert_no_sensitive_values(receipt)
    build.write_canonical_json(output_dir / "local-build-receipt.json", receipt)
    return receipt


def _xcodebuild_arguments(
    *, work_root: Path, component: Path, metadata_root: Path
) -> list[str]:
    return [
        "/usr/bin/xcodebuild",
        "-project",
        str(PROJECT_PATH),
        "-scheme",
        "ArkDeck",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(work_root / "DerivedData"),
        "-clonedSourcePackagesDirPath",
        str(work_root / "SourcePackages"),
        "build",
        "ROCKCHIP_COMPONENT_INPUT={}".format(component),
        "ROCKCHIP_COMPONENT_METADATA_ROOT={}".format(metadata_root),
        "EXCLUDED_SOURCE_FILE_NAMES=",
    ]


def _stage_component(unsigned_component: Path, stage: Path) -> None:
    stage.parent.mkdir(mode=0o700)
    shutil.copyfile(unsigned_component, stage, follow_symlinks=False)
    os.chmod(stage, 0o755)
    if _sha256(stage) != _sha256(unsigned_component):
        raise LocalBuildError("component changed while entering the local signing stage")
    _run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--identifier",
            LOCAL_SIGNING_IDENTIFIER,
            "--options",
            "runtime",
            "--entitlements",
            COMPONENT_ENTITLEMENTS_PATH,
            stage,
        ],
        cwd=stage.parent,
    )


def _verify_local_app(app: Path, metadata_root: Path) -> Dict[str, Any]:
    component = app / "Contents/MacOS/rkdeveloptool"
    metadata = app / "Contents/Resources/RockchipComponent/1.0.0"
    try:
        component_stat = component.lstat()
    except OSError as error:
        raise LocalBuildError("the Debug App does not contain rkdeveloptool") from error
    if stat.S_ISLNK(component_stat.st_mode) or not stat.S_ISREG(component_stat.st_mode):
        raise LocalBuildError("the embedded rkdeveloptool is not a canonical regular file")
    if component_stat.st_mode & 0o111 == 0:
        raise LocalBuildError("the embedded rkdeveloptool is not executable")
    architecture = _decode(
        _run(["/usr/bin/lipo", "-archs", component], cwd=app)
    ).strip()
    if architecture != "arm64":
        raise LocalBuildError("the embedded rkdeveloptool is not arm64")
    signature = _decode(
        _run(["/usr/bin/codesign", "-dv", "--verbose=4", component], cwd=app),
        "stderr",
    )
    if "Identifier={}".format(LOCAL_SIGNING_IDENTIFIER) not in signature:
        raise LocalBuildError("the embedded rkdeveloptool signing identifier drifted")
    _run(["/usr/bin/codesign", "--verify", "--strict", component], cwd=app)
    _run(["/usr/bin/codesign", "--verify", "--strict", app], cwd=app.parent)
    for name in (
        "THIRD-PARTY-NOTICES.txt",
        "recipe.json",
        "registry.yaml",
        "sbom.spdx.json",
        "source-distribution-manifest.json",
    ):
        if (metadata / name).read_bytes() != (metadata_root / name).read_bytes():
            raise LocalBuildError("local component metadata was not embedded: {}".format(name))
    return {
        "app": str(app),
        "component": str(component),
        "componentArchitecture": architecture,
        "componentSHA256": _sha256(component),
        "componentSignature": "ad-hoc-development-only",
        "language": {
            "libusb": LOCAL_C_DISPLAY_NAME,
            "rkdeveloptool": LOCAL_CXX_DISPLAY_NAME,
        },
        "runtimeTrust": "production resolver intentionally rejects local ad-hoc signature",
        "schemaVersion": "1.0.0",
        "verdict": "PASS",
    }


def _parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--work-root",
        type=Path,
        help="Fresh output root; defaults to a unique directory under .build/rockchip-local.",
    )
    return parser.parse_args(argv)


def _allocate_work_root(requested: Optional[Path]) -> Path:
    if requested is not None:
        root = requested.resolve()
        build.ensure_fresh_directory(root)
        return root
    parent = REPO_ROOT / ".build/rockchip-local"
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="build-", dir=parent)).resolve()


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parse_args(argv)
    try:
        work_root = _allocate_work_root(args.work_root)
        component_work = work_root / "component-work"
        component_output = work_root / "component-output"
        receipt = build_local_component(component_work, component_output)
        staged_component = work_root / "stage/rkdeveloptool"
        _stage_component(component_output / "rkdeveloptool", staged_component)
        _run(
            _xcodebuild_arguments(
                work_root=work_root,
                component=staged_component,
                metadata_root=component_output,
            ),
            cwd=REPO_ROOT,
            capture=False,
        )
        app = work_root / "DerivedData/Build/Products/Debug/ArkDeck.app"
        app_receipt = _verify_local_app(app, component_output)
        app_receipt["unsignedComponentSHA256"] = receipt["artifact"]["sha256"]
        build.write_canonical_json(work_root / "local-app-receipt.json", app_receipt)
    except (
        LocalBuildError,
        build.BuildError,
        OSError,
        subprocess.SubprocessError,
        ValueError,
        KeyError,
    ) as error:
        print("rockchip-local-app: FAIL: {}".format(error), file=sys.stderr)
        return 1
    print("rockchip-local-app: PASS")
    print("App: {}".format(app))
    print("Receipt: {}".format(work_root / "local-app-receipt.json"))
    print(
        "Trust: development-only ad-hoc component; production Rockchip execution remains fail-closed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
