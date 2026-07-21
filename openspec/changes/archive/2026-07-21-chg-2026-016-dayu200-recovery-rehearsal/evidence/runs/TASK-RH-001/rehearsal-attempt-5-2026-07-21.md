# TASK-RH-001 恢复演练 attempt #5 — 2026-07-21 14:36 — SUCCESS(RECOVERY-001 首次达成)

- Change:CHG-2026-016-dayu200-recovery-rehearsal@r4 / Task:TASK-RH-001
- 执行:2026-07-21 14:36–14:46 CST,维护者 lvye(fuhanfeng)本人;host macOS 26.5.2
  arm64;物理 DAYU200 + USB。Agent 零设备命令(crib 起草 + 事后核验 + 本记录)。
- Evidence class:realHardware **success record**(controlledHumanCapture;postcheck
  manifest boundary 明确:realHardware classification of record 须由人工 attested
  hardware-evidence 记录构成——本记录只作 observed 恢复达成,不自升 conformance)。
- Final status:**SUCCESS**。九个 PD-002 mapped 分区经 Loader 态 `wlx` 全部写入成功,
  `rd` 复位后设备重启进正常系统,postcheck 重现 `Connected`。**RECOVERY-001 首次 PASS**,
  连续四窗口(#173/#213/#215/#217)攻坚闭环。
- 附:脱敏 transcript `transcript-2026-07-21-attempt5.txt`(SHA-256
  `81a40e5ef0bad25f…`;home-mask,无序列号;postcheck connect key/serial 留仓库外
  out-dir)。

## 执行结果(逐阶段)

- 身份门:工具 `038a8a0e…`/`ver 1.32`、物料 17/17 MATCH、FA-001 在位 — PASS;
- 进态序列第五次稳定:pre-entry `0x5000 Maskrom` → 序列后 `0x350a Loader`(两次 `ld`);
- **W1 条件跳过**(`ld=Loader` → db 跳过);**W2 条件跳过**(写前 `ppt` **15/15 精确
  match** FA-001 §2,自动命中 → gpt 跳过);
- **W3 `wlx` 九分区全部成功**(`Write LBA from file (100%)` / exit 0):
  uboot、resource、boot_linux、ramdisk、system、vendor、updater、chip_ckm、userdata
  (userdata 经操作者逐字 `ERASE-USERDATA` 显式确认);
- 明确未写:`chip_prod`/`sys_prod`(orphan)、6 个无成员分区、两处扇区空洞 — 零触碰;
- **W4** `rd` → `Reset Device OK.` → 设备重启进正常系统;
- **postcheck**:首跑因 crib 参数缺陷(`capture.py` 缺 `--hdc`、`--out` 应为 `--out-dir`)
  未跑成——纯脚本层,已修;补跑(修正参数)`capture complete: 1 commands, self-check
  PASSED`,stdout **58 bytes / 5 列 tab / `USB  Connected  localhost`** / exit 0 /
  stderr 0,redacted-manifest `keyMaterialFound=false`。设备恢复后 hdc 可见、Connected。

## 决定性技术结论(印证 #218 研究)

板上 U-Boot 的 Loader 升级态 rockusb gadget **支持 `wlx` 按现有分区表写数据**(九分区
全成功),同时拒绝 `db`/`gpt`(改分区表类,MaskRom/miniloader 阶段命令)。这与 #218
loader-vs-maskrom 研究的预判一致:恢复无需进真 MaskRom——设备分区表已在(四窗口 `ppt`
15/15 稳定),`wlx` 直接按名写数据即完成恢复。**DAYU200 macOS 恢复主路径 = Loader 态
`wlx`(经既有分区表)**,rkdeveloptool RockUSB 可行,无需 hdc/flashd、无需硬件强制 MaskRom。

## 四 Test ID disposition(本 attempt)

| Test ID | 结论 |
| --- | --- |
| **RH-DAYU200-RECOVERY-001** | **PASS(首次)** — 进态→W1/W2 条件跳过→九分区 `wlx` 全成功→`rd` OK→设备重启进系统→postcheck 58B `USB Connected localhost`;逐命令 argv/输出/判定在案 |
| RH-DAYU200-MODE-001 | observed(第五次稳定 `0x350a Loader`;`0x5000 Maskrom` pre-entry 形态在案);无新信息 |
| RH-DAYU200-TABLE-001 | 写前 `ppt` 15/15 精确 match(第五次,逐字节一致);`wlx` 写分区数据不改分区表、W2 跳过 gpt(无表写入动作),故分区表最终态 = 写前 15/15,基线与设备表一致 |
| RH-DAYU200-SAFETY-001 | PASS — 全部命令属封闭面、pinned hash 复核、零现场手算、userdata 经显式 `ERASE-USERDATA` 确认、orphan/无成员分区/空洞零写入、`rd` 后正常启动、序列号零入仓;crib 参数缺陷仅脚本层(postcheck 补跑合规) |

## 版本后果与边界

- 版本后果:演练后设备运行 pinned 7.0.0.33 build(design §6 参考态);`userdata` 已清。
- postcheck manifest 的 `change` 字段为 capture instrument 的 M0B 常量
  (`CHG-2026-006`,硬编码;先例 #155 harness manifest 同型),不改变本 evidence 归属。
- 本记录不翻转任何状态(RH-001 `ready→done` 另用独立状态 PR);gap 关闭登记与 DEC-002
  input 登记按 verification Gate 走独立 governance PR(先例 #146);不构成 ArkDeck 产品
  flash 能力、兼容性、hardware support 或 release 声明;hardware matrix 只可新增
  observed 行。
