# TASK-RF-001 part 2 — 人工真机正向烧写 — 2026-07-21 15:46 — SUCCESS

- Change:CHG-2026-020-dayu200-real-flash / Task:TASK-RF-001(part 2,RF-REALFLASH-001)
- 执行:2026-07-21 15:46–15:59 CST,维护者 lvye(fuhanfeng)本人;host macOS 26.5.2
  arm64;物理 DAYU200 + USB。Agent 零设备命令(正向 crib 起草 + 事后核验 + 本记录)。
- Evidence class:realHardware **success record**(controlledHumanCapture;realHardware
  classification of record 见 hardware-evidence/matrix,不自升 conformance)。
- Final status:**SUCCESS**。九个 PD-002 mapped 分区经 Loader 态 `wlx` 正向全部写入成功,
  `rd` 复位后设备重启进正常系统,postcheck 重现 `Connected`。**RF-REALFLASH-001 PASS**;
  正向烧写产品化管线真机可行。
- 附:脱敏 transcript `transcript-forward-2026-07-21.txt`(SHA-256 `3a078a2828c3c00d…`;
  home-mask;connect key/serial 留仓库外 out-dir)。

## 执行(按 `images-tar-contract.md` §4 命令面 = 正向 crib `flash-forward.sh`)

- 首验镜像:本次未设 `ARKDECK_IMAGES_TAR`,默认用已验证 pinned 包(CHG-2026-003
  `fc7637f3…5280` 的 materials/,17 成员逐文件 hash MATCH)——契约 §1 首验形态,烧其九
  mapped 分区;
- 身份门:工具 `038a8a0e`/`ver 1.32`、成员 17/17 hash MATCH(contract §1);
- 进态 → mode-gate `0x350a` Loader → **W1 条件跳过**(ld=Loader)→ 写前 `ppt` **15/15
  精确 match** FA-001 §2 → **W2 条件跳过**(gpt);
- **W3 `wlx` 九分区全部成功**(`Write LBA from file (100%)`/exit 0):uboot/resource/
  boot_linux/ramdisk/system/vendor/updater/chip_ckm/userdata(userdata 经操作者逐字
  `ERASE-USERDATA` 显式强确认,REQ-FLASH-007);
- **禁写面零触碰**(contract §2):chip_prod/sys_prod(orphan)、6 无成员分区、两处扇区
  空洞;
- `rd` → `Reset Device OK.` → 设备重启进系统;
- **postcheck**:`capture complete: 2 commands, self-check PASSED`;verbose stdout 58B
  `USB Connected localhost`、plain 33B(32-hex key);connect key/serial 留仓库外。

## 认领 AC disposition(DAYU200 real-flash 真机面)

| AC | 结论 |
| --- | --- |
| `AC-FLASH-003-01`(镜像 hash/exact plan) | PASS(真机面)— 17 成员 hash MATCH 后方写;禁写面按契约零触碰;写序按 §1.B |
| `AC-FLASH-014-01`(hardware evidence) | **observed 行**(见 hardware-matrix.md `EVD-RF001-DAYU200-20260721-001`);完整 `supported` 行须全部 required hardware AC,含 RF-002 的 Provider AC(007/008/012/013),故本 task 只确立 observed 真机事实 |
| `AC-FLASH-015-01/02`(Agent/CI 边界) | PASS(真机面)— 真机 flash 由**人类维护者亲手执行**,Agent installed-HDC/device/destructive dispatch `0/0/0`;`userdata` erase 经显式强确认 |
| `RF-REALFLASH-001`(change-local) | **PASS** — 全流程逐命令 argv/输出/判定、hash 校验、destructive 确认、postflight Connected、operator/窗口/恢复路径在案 |

## 与恢复演练的关系 + 版本后果

- 命令面与 CHG-2026-016 attempt #5 逐字同构(Loader `wlx` over 既有分区表);本次是**正向
  烧写**(用 pinned 包),证明"契约 + Profile + 命令面"的产品化管线真机可行;
- 版本后果:设备运行 pinned 7.0.0.33 参考态(design §6);`userdata` 已清;
- postcheck manifest 的 `change` 字段为 capture instrument 的 M0B 常量(硬编码,先例
  #155),不改变本 evidence 归属。

## 边界

本记录不翻转任何状态(RF-001 `done` 另用独立状态 PR,part 1 + part 2 齐)。不构成 DAYU200
以外设备、hardware support(完整 supported 行待 RF-002)、兼容性或 release 声明;simulated
永不进 hardware matrix。
