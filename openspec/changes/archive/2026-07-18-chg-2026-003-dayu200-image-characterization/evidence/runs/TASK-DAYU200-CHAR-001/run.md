# TASK-DAYU200-CHAR-001 run — DAYU200 镜像只读特征化

## Run identity and classification

- Base revision:`e29462c`(origin/main,`governance: restore TASK-M1-006 readiness (TASK-I5-002) (#43)`)
  之上的 approval commit `ea62e17`(`governance: approve CHG-2026-003`,本执行 PR 的
  stacked base)
- Working branch:`agent/TASK-DAYU200-CHAR-001`(独立 git worktree,与并行的
  TASK-M1-009 / TASK-M1-006 工作树零共享、零 allowed-path 交集)
- Date/timezone:2026-07-18,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;CPython 3.14.6(仓库 `.python-version`
  pinned;Python stdlib only,无第三方依赖)
- Execution classification:read-only offline research。零解包落盘、零成员执行、
  零 shell/子进程、零网络、零 HDC/flashd/vendor-tool、零 USB/UART/TCP、零 device
  mutation;raw 镜像与成员字节不进入仓库。
- 本 run 只产出 fixed-archive-only、非权威特征化 evidence;不构成 change verified、
  DEC-002 结论、M0B、硬件支持或任何 conformance/release claim。

## Fixed input(identity only;locator 按 contract 不记录)

- Raw archive:`732948803` bytes,SHA-256
  `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`
  (与 design.md "Fixed input gate" pinned identity 二值相等;archive 保存在仓库外,
  locator/basename/host 目录按 contract 刻意不写入任何 evidence)

## Commands and results

| Command | Result |
| --- | --- |
| `python3 scripts/archive_characterization/test_scan.py` | 36 tests,OK(0 failures/errors) |
| `python3 scripts/archive_characterization/scan.py --archive <external locator> --out-dir .../evidence` | exit 0,写入 5 个 allowed outputs,耗时 4.3 s |
| `scripts/check-sdd.sh` | 见实现 PR CI/本地记录(0 error) |
| `git diff --check` | 通过(无 whitespace error) |

## Evidence outputs(全部经 closed schema 校验后以 create-only 模式写入)

| File | SHA-256 |
| --- | --- |
| `archive-identity.json` | `7ea6a1bcf0ac9a39bf53fb215facddd925e845aadb086c2c1c07e085e5577e53` |
| `member-inventory.json` | `429763e6fabcaaa2f7323eab862fdb8c65d63ecc88afb441a36073ee5c35818c` |
| `package-classification.json` | `a91c232ed9e74b6173054820532cfbd364aaa6bcde216b3d9b02ea785697b0b1` |
| `process-audit.json` | `b406792b291f9854c0e3c4de33cc7742073adba385f8b201480573d67f2f9a19` |
| `summary.md` | `2afad85772e3f8d1b68d9ee36c5eccd16b8440c59574dbf9ee96d9b84a94a247` |

gaps 清单(partition semantics、flash addresses、flash protocol、recovery path,
均 `unknown`)记录于 `package-classification.json` 的 `gaps[]` 并在 `summary.md`
复述,直接输入 DEC-002 与 Route-B CLI plan-only 工作。

## Scan facts(instrumented)

- Identity gate:observed size/SHA-256 与 pinned identity 二值相等,`identityMatch: true`。
- Inventory:17 个成员,全部 `kind: regular`、root-level、非空;物理 tar-header 序,
  逐成员记录 path、size、SHA-256(3 anchors + 11 个 `.img` + `config.cfg`、
  `daily_build.log`、`manifest_tag.xml`、`updater_binary`;最大成员 `system.img`
  2,147,483,648 bytes)。
- Streaming bound:raw 读取 732,948,803 bytes;解压逻辑字节 4,150,712,320;实测最大
  读取 chunk 1,048,576 bytes(等于配置上限,无越界);open mode 仅 `rb`。
- Hazard suite:16 个合成向量(ARC001..ARC009 全覆盖 + 3 个 precedence 向量)全部
  实测拒绝,observed code == expected code,且每向量 classifier call count 实测为 0
  (写入 `member-inventory.json.hazardSuite[]`,schema 强制 `passed: true` 才可写出)。
- Classification:六条件全真 → `imagePackageFamily: rockchipRawImageSet`;固定轴
  `classificationScope: fixedArchiveOnly`、`authoritative: false`、
  `deviceFlashProvider: unknown`、`targetCompatibility: unknown`、
  `imageProfileReadiness: candidateNonExecutable`、`executableProfile: false`、
  `hardwareSupportClaim: false`。

## Acceptance conclusions(二值)

| Test ID | Method | Evidence class | 结论 |
| --- | --- | --- | --- |
| `TEST-CHAR-M0-DAYU200-IMAGE-001` | streaming scan + hazard-vector rejection suite | platform | passed:pinned identity 相等;物理序 inventory 逐项含 path/regular kind/size/per-member SHA-256;零落盘;9 个 hazard code 的 fixture 全部在任何 classification 之前以固定 code 拒绝 |
| `TEST-CHAR-M0-DAYU200-CLASSIFICATION-001` | closed six-condition rule + branch-complete unit tests | contract | passed:仅当六个有序 path/kind/size 条件全真时判 `rockchipRawImageSet`,否则 `unknown`;每条件均有正/负测试;classifier 输入投影仅 `{path, kind, size}`(shape 由类型与测试双重钉死),不接收 locator/basename/payload/hash/marketing 文本;结果非权威,Provider/compatibility `unknown`、readiness `candidateNonExecutable` |
| `TEST-CHAR-M0-DAYU200-NODISPATCH-001` | process/file audit | contract | passed:archive 仅 `rb` 只读打开;写入仅五个 allowed evidence outputs(choke point 实测 `writesOutsideAllowedOutputs: 0`)与本 run 记录 sidecar;零 subprocess/network/HDC/flashd/vendor-tool/USB/UART/TCP/device-mutation(结构性零:无任何此类代码路径,由 `test_scan.py` 静态 import/AST audit 断言) |

## Measurement provenance(TASK-M1-010/004 准则)

- 实测(instrumented):identity size/hash、成员 inventory 与 hash、读取字节数、
  最大 chunk、hazard 向量 observed code 与 classifier call count、evidence 写入清单
  与 create-only 拒绝。
- 结构性推导(structural):dispatch counters 恒 0——scanner 不存在任何
  subprocess/network/device 代码路径,由静态 import/AST audit(而非分支常量)断言;
  `process-audit.json.counterProvenance` 已按此分类如实标注。

## Deviations and residual risks

- 无 hazard、无 identity deviation;扫描一次通过。
- `summary.md` 由 scan.py 与四个 JSON 同批生成(允许的第五个 output),其推荐段为
  固定非权威文案。
- 残留边界:本 evidence 只约束该 pinned archive;分区语义、烧写地址、协议与恢复
  路径四个 gap 全部 `unknown`,须由后续 Integration change 解决;不得据此选择
  Flash Provider 或宣称任何设备兼容性。
- 任务状态:tasks.md 不在本任务 allowed paths 内;`ready→done` 由后续独立
  status PR 起草,仅在维护者 review/merge 后生效(参照 M1-005 #37/#38 先例)。
