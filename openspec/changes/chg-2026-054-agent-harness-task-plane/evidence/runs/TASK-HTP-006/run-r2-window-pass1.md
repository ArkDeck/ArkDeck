# TASK-HTP-006 run r2 — GJ-5 窗口第一趟(L1 完成,E1 待签发)

- Date:2026-07-31(UTC 06:17–06:20)
- Executor:**agent**,按维护者 2026-07-31 明确指示执行(常规设备窗口由维护者亲手跑;
  本趟为维护者指定 agent 执行,且**只含 E0 与 host 步骤**,零 destructive dispatch)
- Source baseline:`main@2daeff075bccc8ee90574f61c89ab2dc42d32977`
- Device:DAYU200(RK3568),USB,`TGT-958780b2ffb7`,binding revision `1`
- HDC:`3.2.0f`,sha256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
- **Catalog digest(本趟实测)**:`17bd5443d0a660a8d657b5ba9fb15017252f42f88714bc4bc3e4e22ff76bdaff`
- Runtime state:`/private/tmp/arkdeck-gj5-window.Iv1Q6s`,0700(窗口后丢弃)
- Effect:E0(observe)+ hostOnly(import / draft)。**零 E1、零 capability 消耗**

## 1. 结果摘要

| 腿 | 状态 |
|---|---|
| L1 接管 | **成功**,产品自行发现并接管 → `TGT-958780b2ffb7` rev 1 |
| L1 `observe.device@1` | **成功**(真机,E0) |
| HAP 导入 | 成功,lease 落在本 target 上 |
| capability draft | 成功产出,**按设计停住**(未签发即不可安装) |
| L2 `debug.hap@1` / L3 / L4 | **未执行** —— 等维护者合入签发后跑第二趟 |

HTP-AC-18 / AC-19 仍为 `pending-hardware`:本趟只完成 GJ-1 的两条腿,GJ-5 的
`task submit` 收敛尚未发生。

## 2. L1:GJ-1 在当前 digest 上重取(真机 E0)

```text
device adopt → {"outcome":"adopted","targetId":"TGT-958780b2ffb7","bindingRevision":1}

job submit --operation observe.device@1 --expected-binding-revision 1 --wait
job-3b4ce894d2b26dd4407c09ce1b72ee0e | state: succeeded | outcomeUnknown: false
timeline:
  probe-host-tool        verified ["toolVersion"]        → artifact tool-facts.json
  probe-hdc-server       verified ["clientVersion","serverVersion"]
  confirm-evidence-target verified ["deviceIdentitySHA256","state","transport"]
  read-evidence-model    verified ["value"]
  read-evidence-firmware verified ["value"]
                         → artifacts device-facts.json / binding-snapshot.json
  finalize-session → running->finalizing → finalizing->succeeded
outstandingResidueCount: 0 | waitingForHuman: false
```

artifacts:`tool-facts.json` → `ART-44aa0a86a997b67d88c18d007f4d01ba`、
`device-facts.json` → `ART-020e1e9cc5384ab79c620e184215153d`、
`binding-snapshot.json` → `ART-2a3a781f8a544a127732be9f38bce325`。
**无人运行过 HDC 命令**:发现、接管、探测、读取全部由产品执行(本脚本对 hdc 的唯一调用是
`list targets` 数设备台数的可用性探针,不属任何一条腿)。

## 3. HAP 导入与 capability draft(host)

```text
artifact import-hap → entry-default-signed.hap
  byteCount 1512003 | sha256 9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8
  lease lease-v1:input-hap-TGT-958780b2ffb7-r1-9453a396e81d55ab:ART-8d5b85963670977fa1def2734b77fe67
  (与 GJ-2 2026-07-30 窗口同一个 HAP,字节一致)

capability draft --operation debug.hap@1 --validity-seconds 14400 --maximum-uses 1
  capabilityID           CAP-RT-AUTO-20260731T061927Z-DAC082804598
  effectCeiling          deviceMutation
  exactBindingRevision   1
  materializedPlanDigest 62feb1545a4efa0892e2df1c949dd1cb9063e248cd399572d2929cc3163141be
  requestFingerprint     c083fcab5f866bd09ddb6caf45feef737d5871c79e18809bacba2ea5fd674bc1
  issuer.reference       PR#875(落库时改写;draft 出厂值是 PENDING-MAINTAINER-PR,
                         daemon 对该值拒绝安装 —— 合入本 PR 才是签发)
  expiresAtUTC           2026-07-31T10:19:27Z
  inputConstraints       cleanupPolicy=retain / bundle / ability / lease / 5s(逐项 exact)
```

draft 已落到 `evidence/capabilities/CAP-RT-AUTO-20260731T061927Z-DAC082804598.json`。
**签发 = 维护者合入本 PR**(`issuer.reference` 写成本 PR 号;`capability.install` 只接受
`PR#<数字>`,这条拒绝就是「签发不是 agent 的行为」的结构形式)。

## 4. 窗口内抓到并修的两个缺陷

### 4.1 crib 在 macOS 自带 bash 上直接死掉(第一次真跑)

`mapfile` 是 bash 4 的内建,macOS `/bin/bash` 是 **3.2.57**。第一次真跑在设备探针那一行
以 `mapfile: command not found`(exit 127)停下。**为什么自测没抓到**:`--self-test` 当时
跳过了整个探针块,那一行从未被执行过 —— 自测覆盖不到的代码等于没自测。
已改为 bash 3.2 可用的 `parse_targets` / `count_lines` 函数,并让 `--self-test` 用
**fixture** 跑该解析路径(一台 / `[Empty]` / 两台三种情形逐条断言)。同时把两处
`cond && { …; }` 改成显式 `if`,避免 `set -e` 下的边界行为。

### 4.2 产品缺陷:操作员的 flag 形 `job submit` 跑不了任何设备 operation

L1 第一次提交 `observe.device@1` 被拒:

```text
rejected(invalidInput, "target facts cannot materialize the typed plan before authorization:
  failed(\"evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched\")")
```

根因不是设备,是 CLI:flag 形 `job submit --target --operation` **手写**请求 JSON,
`target` 里只有 `targetId`、没有 `expectedBindingRevision`;而设备绑定准入要求 pin 一个
binding revision(HTP-AC-21 的不变量)。仓内每个 operation 都是 `confirmedDevice`,
所以**用法里写着的 flag 形对设备工作从来不可用**,而且失败信息是绕一圈之后的通用
`evidenceIncomplete`,没告诉操作员少了什么。

修法:请求文档改由 `RuntimeOperationRequest.operatorFlagForm(...)` 构造 —— 它按 catalog
descriptor 检查绑定要求,设备绑定却未 pin 时**在提交之前**拒绝并点名
`--expected-binding-revision`;host-only operation 反过来禁止 pin(HTP-AC-20)。CLI 新增
该 flag 并写入 usage。四条回归用例:未 pin 的设备 operation 被拒且信息点名 flag、pin 会随
文档过线、host-only 不带 revision 且 pin 即拒、仓内**每个** `confirmedDevice` operation
在 pin 之后都能被 flag 形构造出来。

修完复跑,`observe.device@1` 一次成功(见上)。

## 5. 下一步(第二趟)

1. 维护者把本 PR 的 `issuer.reference` 定为 `PR#<本 PR 号>` 并**合入** → 即签发;
2. 重跑:`crib-gj5-window-r1.sh --hap <same hap> --capability
   openspec/changes/chg-2026-054-agent-harness-task-plane/evidence/capabilities/CAP-RT-AUTO-20260731T061927Z-DAC082804598.json`
   —— L1 幂等重跑,L2 装包并保留,随后 L3(应用在跑、未 crash → 期望 `succeeded`)、
   L4(复现 WaterFlow crash → 期望 `humanRequired` + `criteriaFailedNoRepairCapability`);
3. **capability 4 小时后过期**(`2026-07-31T10:19:27Z`)。若过期,重跑第一趟再出一份 draft:
   lease 与 plan digest 在 HAP 与 target 不变时逐字相同,只有时间戳与 ID 会变;
4. teardown 的 `cleanupPolicy: uninstall` 是另一组输入,需要**第二份** capability。
