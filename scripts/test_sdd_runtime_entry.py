"""TASK-SDR-001 host contract suite — shared SDD runtime discovery entry.

stdlib-only。用临时仓库与 fake 可执行 argv 目标穷举 design §4 矩阵:
explicit/worktree/shared/PATH 优先级(含真实 git linked-worktree 拓扑)、
Git 不可用回退、路径含空格、缺 executable/缺 module/版本漂移/坏 pin、
坏高优先级候选阻断降级、pip/venv/network canary 零调用、bootstrap argv
与目标选择,以及 shared-discovery removal red canary(全绿套件单独不作
机制证据)。零下载、零真实安装;唯一触真实仓库的是 linked-worktree
integration(临时 worktree,teardown 清理)。
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REAL_CHECKER = REPO_ROOT / "scripts" / "check-sdd.sh"
REAL_BOOTSTRAP = REPO_ROOT / "scripts" / "bootstrap-sdd.sh"

PIN_VERSION = "6.0.3"
SHARED_BEGIN = "# --- TASK-SDR-001 shared discovery begin ---"
SHARED_END = "# --- TASK-SDR-001 shared discovery end ---"

STUB_CHECK_SDD = "import sys\nprint('STUB-CHECK-SDD ' + sys.executable)\n"


def _make_executable(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def write_fake_python(path: Path, log: Path, mode: str, version: str = PIN_VERSION) -> Path:
    """生成模拟解释器。mode: ok | missing | wrongver | silent | broken。

    协议:`-c <program>` 一律视为 preflight,按 mode 应答 check-sdd.sh 的
    marker 行;其余 argv 视为 checker 执行,记录后退出 0。全部调用逐行落
    log,供优先级/降级/canary 断言。
    """
    if mode == "ok":
        preflight = "printf 'SDD-YAML %s\\n' '{v}'".format(v=version)
    elif mode == "wrongver":
        preflight = "printf 'SDD-YAML %s\\n' '{v}'".format(v=version)
    elif mode == "missing":
        preflight = "printf 'SDD-YAML-MISSING\\n'"
    elif mode == "silent":
        preflight = ":"
    elif mode == "broken":
        preflight = "exit 127"
    else:  # pragma: no cover - harness misuse
        raise ValueError(mode)
    text = (
        "#!/bin/sh\n"
        'printf \'CALL %s\\n\' "$*" >> "{log}"\n'
        'case "${{1:-}}" in\n'
        "  -c)\n"
        "    {preflight}\n"
        "    ;;\n"
        "  *)\n"
        '    printf \'RAN-CHECKER %s\\n\' "$*" >> "{log}"\n'
        "    exit 0\n"
        "    ;;\n"
        "esac\n"
    ).format(log=log, preflight=preflight)
    return _make_executable(path, text)


def write_canary(path: Path, log: Path) -> Path:
    return _make_executable(
        path,
        "#!/bin/sh\nprintf 'CANARY %s\\n' \"$*\" >> \"{log}\"\nexit 1\n".format(log=log),
    )


class _Harness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="sdr-entry-")
        self.tmp = Path(self._tmp.name).resolve()
        self.logs = self.tmp / "logs-outside-fixture"
        self.logs.mkdir()
        self.fakebin = self.tmp / "fakebin"
        self.fakebin.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    # ---- env / process helpers ----

    def base_env(self, path_dirs=None):
        env = {
            "PATH": ":".join([str(d) for d in (path_dirs or [])] + ["/usr/bin", "/bin"]),
            "HOME": str(self.tmp),
            "LC_ALL": "C",
            # 防止临时目录的上层意外命中真实仓库。
            "GIT_CEILING_DIRECTORIES": str(self.tmp.parent),
        }
        return env

    def run_script(self, script: Path, cwd: Path, env, args=()):
        return subprocess.run(
            [str(script), *args],
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def log_lines(self, log: Path):
        if not log.exists():
            return []
        return [l for l in log.read_text().splitlines() if l]

    # ---- fixture builders ----

    def make_fixture(self, root: Path, requirements="PyYAML==" + PIN_VERSION + "\n"):
        scripts = root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        checker = scripts / "check-sdd.sh"
        shutil.copy(REAL_CHECKER, checker)
        checker.chmod(checker.stat().st_mode | stat.S_IXUSR)
        shutil.copy(REAL_BOOTSTRAP, scripts / "bootstrap-sdd.sh")
        (scripts / "bootstrap-sdd.sh").chmod(0o755)
        (scripts / "check_sdd.py").write_text(STUB_CHECK_SDD)
        if requirements is not None:
            (scripts / "requirements-sdd.txt").write_text(requirements)
        return root

    def git(self, cwd: Path, *args):
        return subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True,
            text=True,
            check=True,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.tmp), "LC_ALL": "C",
                 "GIT_CEILING_DIRECTORIES": str(self.tmp.parent)},
        )

    def make_git_topology(self, name="primary checkout"):
        """真实 git 拓扑:primary(含 fixture 提交)+ linked worktree。"""
        primary = self.tmp / name
        self.make_fixture(primary)
        subprocess.run(
            ["git", "-c", "init.defaultBranch=main", "init", str(primary)],
            capture_output=True, text=True, check=True,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.tmp), "LC_ALL": "C"},
        )
        self.git(primary, "add", "-A")
        self.git(
            primary,
            "-c", "user.email=sdr@test", "-c", "user.name=sdr",
            "commit", "-q", "-m", "fixture",
        )
        linked = self.tmp / (name + " linked wt"
                             )
        self.git(primary, "worktree", "add", "--detach", str(linked))
        return primary, linked


class ResolverPrecedenceTests(_Harness):
    def test_explicit_beats_worktree_venv(self):
        fix = self.make_fixture(self.tmp / "fix")
        vlog, elog = self.logs / "venv.log", self.logs / "explicit.log"
        write_fake_python(fix / ".venv-sdd" / "bin" / "python", vlog, "ok")
        explicit = write_fake_python(self.tmp / "explicit dir" / "python ok", elog, "ok")
        env = self.base_env()
        env["ARKDECK_PYTHON"] = str(explicit)
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(elog)))
        self.assertEqual(self.log_lines(vlog), [])

    def test_explicit_bare_name_resolves_via_path(self):
        # CI 形态:ARKDECK_PYTHON=python(裸名、无斜杠)。
        fix = self.make_fixture(self.tmp / "fix")
        plog = self.logs / "pathpython.log"
        write_fake_python(self.fakebin / "python", plog, "ok")
        env = self.base_env([self.fakebin])
        env["ARKDECK_PYTHON"] = "python"
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(plog)))

    def test_worktree_venv_beats_shared_and_path(self):
        primary, linked = self.make_git_topology()
        llog, plog, pathlog = (self.logs / n for n in ("local.log", "primary.log", "path.log"))
        write_fake_python(linked / ".venv-sdd" / "bin" / "python", llog, "ok")
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(llog)))
        self.assertEqual(self.log_lines(plog), [])
        self.assertEqual(self.log_lines(pathlog), [])

    def test_shared_discovery_from_linked_worktree(self):
        primary, linked = self.make_git_topology()
        plog, pathlog = self.logs / "primary.log", self.logs / "path.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(plog)))
        self.assertEqual(self.log_lines(pathlog), [])

    def test_primary_checkout_prefers_its_own_venv_over_shared_level(self):
        primary, _ = self.make_git_topology()
        plog = self.logs / "primary.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        r = self.run_script(primary / "scripts" / "check-sdd.sh", primary, self.base_env())
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = [l for l in self.log_lines(plog) if l.startswith("CALL")]
        self.assertEqual(len(calls), 2, calls)  # preflight + checker,无二次解析

    def test_path_fallback_without_any_venv(self):
        fix = self.make_fixture(self.tmp / "fix")
        pathlog = self.logs / "path.log"
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(pathlog)))

    def test_git_binary_unavailable_falls_back_to_path(self):
        primary, linked = self.make_git_topology()
        plog, pathlog = self.logs / "primary.log", self.logs / "path.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        _make_executable(self.fakebin / "git", "#!/bin/sh\nexit 127\n")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.log_lines(plog), [])  # 无 git ⇒ 不做路径猜测
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(pathlog)))

    def test_source_tree_without_git_metadata_falls_back_to_path(self):
        fix = self.make_fixture(self.tmp / "no repo here")
        pathlog = self.logs / "path.log"
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(pathlog)))

    def test_spaced_paths_stay_single_tokens(self):
        primary, linked = self.make_git_topology(name="pri mary with  spaces")
        plog = self.logs / "primary.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env())
        self.assertEqual(r.returncode, 0, r.stderr)
        ran = [l for l in self.log_lines(plog) if l.startswith("RAN-CHECKER")]
        self.assertEqual(len(ran), 1, ran)
        self.assertIn("check_sdd.py", ran[0])


class FailClosedTests(_Harness):
    def _assert_fail(self, r, source, reason_fragment):
        self.assertEqual(r.returncode, 2, (r.returncode, r.stdout, r.stderr))
        self.assertIn("check-sdd: preflight failed", r.stderr)
        self.assertIn("interpreter (%s)" % source, r.stderr)
        self.assertIn(reason_fragment, r.stderr)
        self.assertIn("bootstrap-sdd.sh", r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertNotIn("Traceback", r.stdout)

    def test_explicit_broken_blocks_healthy_lower_candidates(self):
        fix = self.make_fixture(self.tmp / "fix")
        vlog, elog = self.logs / "venv.log", self.logs / "explicit.log"
        write_fake_python(fix / ".venv-sdd" / "bin" / "python", vlog, "ok")
        explicit = write_fake_python(self.tmp / "explicit" / "python", elog, "broken")
        env = self.base_env()
        env["ARKDECK_PYTHON"] = str(explicit)
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, env)
        self._assert_fail(r, "explicit", "failed to start")
        self.assertEqual(self.log_lines(vlog), [])  # 零静默降级

    def test_explicit_missing_path_is_stable_error(self):
        fix = self.make_fixture(self.tmp / "fix")
        env = self.base_env()
        env["ARKDECK_PYTHON"] = str(self.tmp / "not" / "there" / "python")
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, env)
        self._assert_fail(r, "explicit", "no executable interpreter at this path")

    def test_missing_path_python3_is_stable_error(self):
        fix = self.make_fixture(self.tmp / "fix")
        env = self.base_env()  # fakebin 不在 PATH,真实 /usr/bin/python3 存在 ⇒ 用空 PATH 目录屏蔽
        env["PATH"] = str(self.fakebin)  # 只有 fakebin:无 python3,也无 git/sed…
        # 上面会连 sed/grep 都失去 ⇒ 用带工具的受控目录代替:链接必需工具。
        for tool in ("sed", "grep", "wc", "tr", "dirname", "git"):
            src = shutil.which(tool, path="/usr/bin:/bin")
            if src:
                dst = self.fakebin / tool
                if not dst.exists():
                    dst.symlink_to(src)
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, env)
        self._assert_fail(r, "PATH", "no executable interpreter with this name on PATH")

    def test_worktree_venv_missing_module_blocks_healthy_shared(self):
        primary, linked = self.make_git_topology()
        llog, plog = self.logs / "local.log", self.logs / "primary.log"
        write_fake_python(linked / ".venv-sdd" / "bin" / "python", llog, "missing")
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env())
        self._assert_fail(r, "worktree", "PyYAML is not importable")
        self.assertEqual(self.log_lines(plog), [])

    def test_shared_version_drift_blocks_healthy_path(self):
        primary, linked = self.make_git_topology()
        plog, pathlog = self.logs / "primary.log", self.logs / "path.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "wrongver", version="6.0.99")
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        self._assert_fail(r, "shared", "version drift: found 6.0.99, pinned " + PIN_VERSION)
        self.assertEqual(self.log_lines(pathlog), [])

    def test_silent_interpreter_is_stable_error(self):
        fix = self.make_fixture(self.tmp / "fix")
        pathlog = self.logs / "path.log"
        write_fake_python(self.fakebin / "python3", pathlog, "silent")
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, self.base_env([self.fakebin]))
        self._assert_fail(r, "PATH", "did not complete the dependency preflight")


class PinContractTests(_Harness):
    def _run_with_requirements(self, requirements):
        fix = self.make_fixture(self.tmp / "fix", requirements=requirements)
        if requirements is None:
            req = fix / "scripts" / "requirements-sdd.txt"
            if req.exists():
                req.unlink()
        pathlog = self.logs / "path.log"
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        return self.run_script(fix / "scripts" / "check-sdd.sh", fix, self.base_env([self.fakebin])), pathlog

    def test_missing_pin_file(self):
        r, _ = self._run_with_requirements(None)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("dependency pin file is missing", r.stderr)

    def test_missing_pyyaml_entry(self):
        r, _ = self._run_with_requirements("# only comments\notherdep==1.0\n")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("no PyYAML pin found", r.stderr)

    def test_duplicated_pyyaml_entries(self):
        r, _ = self._run_with_requirements("PyYAML==6.0.3\nPyYAML==6.0.2\n")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("duplicated PyYAML entries", r.stderr)

    def test_non_exact_pin_is_malformed(self):
        r, _ = self._run_with_requirements("PyYAML>=6.0\n")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("malformed PyYAML entry", r.stderr)

    def test_empty_version_is_malformed(self):
        r, _ = self._run_with_requirements("PyYAML==\n")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("malformed PyYAML entry", r.stderr)

    def test_comments_and_unrelated_deps_do_not_disturb_pin(self):
        r, pathlog = self._run_with_requirements(
            "# PyYAML==9.9.9 in a comment stays a comment\n"
            "otherdep==1.0\n"
            "  PyYAML==6.0.3  \n"
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any("RAN-CHECKER" in l for l in self.log_lines(pathlog)))


class ReadOnlyAndCanaryTests(_Harness):
    def test_checker_never_calls_pip_venv_or_network_and_writes_nothing(self):
        primary, linked = self.make_git_topology()
        plog = self.logs / "primary.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        canary_log = self.logs / "canary.log"
        for tool in ("pip", "pip3", "venv", "curl", "wget"):
            write_canary(self.fakebin / tool, canary_log)
        before = sorted(str(p.relative_to(self.tmp)) for p in linked.rglob("*"))
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        after = sorted(str(p.relative_to(self.tmp)) for p in linked.rglob("*"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.log_lines(canary_log), [])  # pip/venv/network 调用数 = 0
        self.assertEqual(before, after)  # 零工作树写入

    def test_exec_uses_same_interpreter_without_second_resolution(self):
        fix = self.make_fixture(self.tmp / "fix")
        pathlog = self.logs / "path.log"
        write_fake_python(self.fakebin / "python3", pathlog, "ok")
        r = self.run_script(fix / "scripts" / "check-sdd.sh", fix, self.base_env([self.fakebin]))
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = [l for l in self.log_lines(pathlog) if l.startswith("CALL")]
        self.assertEqual(len(calls), 2, calls)
        self.assertIn("-c", calls[0])
        self.assertIn("check_sdd.py", calls[1])


class SharedDiscoveryRedCanaryTests(_Harness):
    def test_removing_shared_discovery_breaks_linked_worktree_case(self):
        text = REAL_CHECKER.read_text()
        self.assertEqual(text.count(SHARED_BEGIN), 1)
        self.assertEqual(text.count(SHARED_END), 1)
        head, rest = text.split(SHARED_BEGIN, 1)
        _removed, tail = rest.split(SHARED_END, 1)
        variant_text = head + "# (shared discovery removed by red canary)" + tail

        primary, linked = self.make_git_topology()
        plog, pathlog = self.logs / "primary.log", self.logs / "path.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "ok")
        write_fake_python(self.fakebin / "python3", pathlog, "missing")

        real = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env([self.fakebin]))
        self.assertEqual(real.returncode, 0, real.stderr)  # 机制在 ⇒ 绿

        variant = linked / "scripts" / "check-sdd-variant.sh"
        _make_executable(variant, variant_text)
        red = self.run_script(variant, linked, self.base_env([self.fakebin]))
        self.assertEqual(red.returncode, 2, red.stdout + red.stderr)  # 机制移除 ⇒ 红
        self.assertIn("PyYAML is not importable", red.stderr)
        self.assertIn("(PATH)", red.stderr)


class BootstrapContractTests(_Harness):
    def _base_python(self, log: Path, venv_python_text: str, create_exit=0):
        template = self.tmp / "venv-python-template"
        template.write_text(venv_python_text)
        text = (
            "#!/bin/sh\n"
            'printf \'CALL %s\\n\' "$*" >> "{log}"\n'
            'if [ "${{1:-}}" = "-m" ] && [ "${{2:-}}" = "venv" ]; then\n'
            "  if [ {create_exit} -ne 0 ]; then exit {create_exit}; fi\n"
            '  mkdir -p "${{3:?}}/bin"\n'
            '  cp "{template}" "${{3}}/bin/python"\n'
            '  chmod +x "${{3}}/bin/python"\n'
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        ).format(log=log, template=template, create_exit=create_exit)
        return _make_executable(self.tmp / "base bin" / "python-base", text)

    def _venv_python_text(self, log: Path, pip_exit=0, verify_version=PIN_VERSION):
        return (
            "#!/bin/sh\n"
            'printf \'CALL %s\\n\' "$*" >> "{log}"\n'
            'if [ "${{1:-}}" = "-m" ] && [ "${{2:-}}" = "pip" ]; then\n'
            '  printf \'PIP %s\\n\' "$*" >> "{log}"\n'
            "  exit {pip_exit}\n"
            "fi\n"
            'if [ "${{1:-}}" = "-c" ]; then printf \'{version}\\n\'; exit 0; fi\n'
            "exit 1\n"
        ).format(log=log, pip_exit=pip_exit, version=verify_version)

    def _run_bootstrap(self, cwd: Path, base_python: Path):
        env = self.base_env()
        env["ARKDECK_BOOTSTRAP_PYTHON"] = str(base_python)
        return self.run_script(cwd / "scripts" / "bootstrap-sdd.sh", cwd, env)

    def test_bootstrap_targets_primary_venv_from_linked_worktree(self):
        primary, linked = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        base = self._base_python(blog, self._venv_python_text(blog))
        r = self._run_bootstrap(linked, base)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((primary / ".venv-sdd" / "bin" / "python").exists())
        self.assertFalse((linked / ".venv-sdd").exists())  # 目标唯一 = primary
        pip_lines = [l for l in self.log_lines(blog) if l.startswith("PIP")]
        self.assertEqual(len(pip_lines), 1, pip_lines)
        self.assertIn("--require-virtualenv", pip_lines[0])
        self.assertIn("-r", pip_lines[0])
        self.assertIn("requirements-sdd.txt", pip_lines[0])
        self.assertNotIn("--break-system-packages", pip_lines[0])
        self.assertIn("bootstrap-sdd: OK", r.stdout)
        self.assertFalse((primary / ".venv-sdd.bootstrap-lock").exists())  # 锁已释放

    def test_bootstrap_requires_git_working_tree(self):
        fix = self.make_fixture(self.tmp / "plain")
        blog = self.logs / "bootstrap.log"
        base = self._base_python(blog, self._venv_python_text(blog))
        r = self._run_bootstrap(fix, base)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("requires a Git working tree", r.stderr)

    def test_bootstrap_keeps_existing_env_and_still_installs(self):
        primary, _ = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        venv_bin = primary / ".venv-sdd" / "bin"
        venv_bin.mkdir(parents=True)
        sentinel = primary / ".venv-sdd" / "sentinel-existing-env"
        sentinel.write_text("keep me\n")
        _make_executable(venv_bin / "python", self._venv_python_text(blog))
        base = self._base_python(blog, self._venv_python_text(blog))
        r = self._run_bootstrap(primary, base)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(sentinel.exists())  # 不删除既有环境
        venv_calls = [l for l in self.log_lines(blog) if " venv " in l]
        self.assertEqual(venv_calls, [])  # 已存在 ⇒ 不重建

    def test_bootstrap_venv_create_failure_is_visible(self):
        primary, _ = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        base = self._base_python(blog, self._venv_python_text(blog), create_exit=1)
        r = self._run_bootstrap(primary, base)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("venv creation failed", r.stderr)

    def test_bootstrap_pip_failure_is_visible(self):
        primary, _ = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        base = self._base_python(blog, self._venv_python_text(blog, pip_exit=1))
        r = self._run_bootstrap(primary, base)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("pip install failed", r.stderr)

    def test_bootstrap_post_install_version_drift_not_reported_as_success(self):
        primary, _ = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        base = self._base_python(blog, self._venv_python_text(blog, verify_version="6.0.98"))
        r = self._run_bootstrap(primary, base)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("post-install verification failed", r.stderr)
        self.assertNotIn("bootstrap-sdd: OK", r.stdout)

    def test_bootstrap_concurrent_lock_fails_visibly(self):
        primary, _ = self.make_git_topology()
        blog = self.logs / "bootstrap.log"
        (primary / ".venv-sdd.bootstrap-lock").mkdir()
        base = self._base_python(blog, self._venv_python_text(blog))
        r = self._run_bootstrap(primary, base)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("another bootstrap appears to be running", r.stderr)

    def test_checker_rejects_partial_bootstrap_result(self):
        # bootstrap 半成品(venv python 无 yaml)⇒ checker 继续 fail closed。
        primary, linked = self.make_git_topology()
        plog = self.logs / "primary.log"
        write_fake_python(primary / ".venv-sdd" / "bin" / "python", plog, "missing")
        r = self.run_script(linked / "scripts" / "check-sdd.sh", linked, self.base_env())
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("PyYAML is not importable", r.stderr)


def _machine_shared_venv_python():
    """本机可用的 pinned venv:先看本 checkout,再经 common-dir 推导 primary。"""
    local = REPO_ROOT / ".venv-sdd" / "bin" / "python"
    if local.exists():
        return local
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    common = Path(out)
    if not common.is_absolute():
        common = REPO_ROOT / common
    try:
        common = common.resolve()
    except OSError:
        return None
    cand = common.parent / ".venv-sdd" / "bin" / "python"
    return cand if cand.exists() else None


@unittest.skipUnless(
    _machine_shared_venv_python() is not None,
    "no bootstrapped .venv-sdd reachable from this checkout on this machine",
)
class CurrentRepositoryIntegrationTests(unittest.TestCase):
    def test_plain_checker_from_temp_linked_worktree_of_this_repo(self):
        tmp = Path(tempfile.mkdtemp(prefix="sdr-int-", dir="/tmp")).resolve()
        wt = tmp / "sdr integration wt"
        try:
            subprocess.run(
                ["git", "-C", str(REPO_ROOT), "worktree", "add", "--detach", str(wt)],
                check=True, capture_output=True, text=True,
            )
            self.assertFalse((wt / ".venv-sdd").exists())
            # 被测对象 = 当前(可能未提交的)入口脚本;其余树保持 HEAD。
            shutil.copy(REAL_CHECKER, wt / "scripts" / "check-sdd.sh")
            (wt / "scripts" / "check-sdd.sh").chmod(0o755)
            env = {k: v for k, v in os.environ.items()
                   if k not in ("ARKDECK_PYTHON", "ARKDECK_BOOTSTRAP_PYTHON")}
            r = subprocess.run(
                [str(wt / "scripts" / "check-sdd.sh")],
                cwd=str(wt), env=env, capture_output=True, text=True, timeout=600,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("0 error(s)", r.stdout)
        finally:
            subprocess.run(
                ["git", "-C", str(REPO_ROOT), "worktree", "remove", "--force", str(wt)],
                capture_output=True, text=True,
            )
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
