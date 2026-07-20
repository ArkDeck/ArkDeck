# TASK-FA-001 run — DAYU200 烧写地址映射事实清单(doc-only)

- Change:CHG-2026-012-dayu200-flash-addresses-research / Task:TASK-FA-001
- 执行日期:2026-07-20;执行形态:纯文档研究(web 检索 S2/S3 来源 + 只读引用仓库内
  已合入 TASK-PD-002 fresh platform evidence 与 archived CHG-2026-011 事实清单)。
  **零设备操作、零工具执行、零二进制下载、零镜像字节解码**(doc-only gate 自证:本 PR
  仅新增两个 markdown 文件 + tasks 状态行;网络仅用于文档检索)。
- 交付物:`../../flash-address-facts.md`(五节齐备)。

## 二值结论(per acceptance-cases.yaml,方法=document review)

| Test ID | 结论 | 依据 |
| --- | --- | --- |
| TEST-ADDR-DAYU200-MAPPING-001 | PASS | 五节齐备(§1 各 host 工具寻址语义 · §2 每分区目标地址映射表 · §3 对账方法 · §4 只读观察草案 · §5 S2/S3 分级);§2 全部 15 数值行逐行取自 TASK-PD-002 `partition-mapping.json`(offset/size 扇区列为源编码权威值,零改写),字节列显式标注为 S2 单位语义(×512)的算术派生、非 PD-002 数值;PD-002 未覆盖项(loader IDB 落点、orphan 镜像 `chip_prod.img`/`sys_prod.img` 目标分区、6 个 orphan 分区用途、GPT vs parameter 实际寻址)全部显式 unknown 并标【待真机确证】;零 alias 推断(承 PD-002 mappingRule)、零镜像字节推导;每条结论带 S2/S3 引用,凡 S3/推断结论标【待真机确证】;首段显式不解除 gap、不改 DEC-002、无兼容性声明、非执行授权 |
| TEST-ADDR-DAYU200-OBSERVATION-PLAN-001 | PASS | §4.1 第一阶段候选逐条【只读】+ 前提(rkdeveloptool -v/--help host-only、只读引用 PD-002 已解码 parameter、只读 config.cfg);§4.2 将全部模式切换/写设备候选(进 Maskrom/Loader 态、连线态 `ld`、须已进态的 `ppt`/`rl`/`rid`/`rfi`/`rci`/`rcb` 读类、全部写命令 `db`/`ul`/`wl`/`wlx`/`gpt`/`prm`/`ef`/`rd` 与 `upgrade_tool di -*`/`ul`/`ef`、RKDevTool 写序)逐条标【第二阶段·写设备·RECOVERY 先行】;§4 首段声明草案执行与白名单扩展均属后续独立 change、本文档不构成执行授权;§4.2 末尾明确 §2 地址表在第二阶段仅作真机 `ppt`/GPT dump 的预期比对基线、不作写地址来源 |

## 来源清单(详见 flash-address-facts.md §5)

- **S2 一手/权威:** TASK-PD-002 fresh platform mapping/reconciliation evidence
  (仓库内,hash 锚点见 facts §0);rkdeveloptool 上游源码 `main.cpp` usage + `wlx`
  handler(GPT→parameter 回退、`No found %s partition`);Rockchip opensource
  `wiki_Partitions`(mtdparts 扇区语义、GPT LBA0~63)与 `wiki_Upgradetool`(`ul`→
  `di -*` 写序、maskrom 前提);Radxa RK3568 rkdeveloptool 文档;archived
  CHG-2026-011 `flash-protocol-facts.md`(hash `a012c16a…`)。
- **S3 社区/推断(标【待真机确证】):** Firefly upgrade_tool 序列;RKDevTool config.cfg
  GUI 地址列填充/写序细节;字节列的扇区×512 算术派生;真机 GPT vs parameter 实际
  寻址、GPT per-partition first-LBA、orphan 镜像目标分区、loader IDB 落点、6 个 orphan
  分区是否运行时生成。

## 偏差 / 遗留

- **§3 连续性自检的诚实修正:** parameter 分区连续性不变式 `offset[i]+size[i]==
  offset[i+1]` 成立于 idx 0→12(uboot…eng_chipset),但 PD-002 表存在两处空洞——
  eng_chipset→chip_ckm 空 65536 扇区、chip_ckm→userdata 空 12886016 扇区。初稿曾误
  称"逐行成立至 chip_ckm",已按 PD-002 实际数据修正为如实记录两处空洞并标其用途
  【待真机确证】,不抹平、不推测。此为纯算术自检(只验证 PD-002 表内一致性),不产生
  新地址。
- **orphan 镜像映射的 fail-closed 立场:** `chip_prod.img`/`sys_prod.img` 与分区
  `chip-prod`/`sys-prod` 名字形近(下划线 vs 连字符),但按 PD-002 mappingRule alias
  推断被禁,故不认定映射、目标地址标 unknown。这是保守正确的边界,非缺陷。
- **关键缺席结论(承 CHG-011,DEC-002 输入):** DAYU200 官方烧录仅 Windows RockUSB
  路径;`wlx`/`upgrade_tool di`/GUI 均**不吃字节地址**而靠设备侧已存在的分区表按名
  解析,故 §2 地址表的第二阶段唯一合法用途是**验证**读回分区表,不作写地址来源。
- 不解除 `GAP-DAYU200-FLASH-ADDRESSES`;不改变 DEC-002 状态(仍 open);写设备观察受
  RECOVERY 先行硬序约束。

## Boundary

doc-only:本 PR 仅新增 `flash-address-facts.md` 与本 `run.md`(+ 后续独立状态 PR 的
tasks 翻转);零命令执行记录、零设备/工具/网络-非检索操作;`ready→done` 另用独立状态
PR 经维护者 review/merge。
