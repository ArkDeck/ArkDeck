# TASK-CA-001 Run — conformance manifest 条件化适用性修订

- Date:2026-07-21
- Base revision:`63fb615`(= readiness PR #196 squash;readiness pins 复核基准
  `f2bde7b` 之后 main 仅前进了 #196 本身,四组 pinned hash 零漂移,readiness 有效)
- Environment:macOS 仓库工作树;`/private/tmp/arkdeck-sdd-python` PyYAML 6.0.3;
  无设备、无网络、无签名要求;零 Swift/代码变更。

## Inputs(执行时逐项复核,与 readiness 块相同)

| Input | SHA-256 / 状态 |
| --- | --- |
| `readonly-probes.yaml`(排除条件唯一事实源) | `9014c480c3df61b5a6db7e54e52f29e89d7c93431e91d0856cf5710c22466b9d`,与 proposal/design/readiness 引用逐字一致 |
| `INTEGRATION-PROFILES.lock.yaml`(0.4.0) | `9f007455204bcbc8a0309413cbeb9c6882e45afdc0dc9def0bab4dd948d2acb0` |
| openharmony `profile.md`(0.3.0) | `48ad9ecc31cad2fbb9a05bb3bb552153ad0ade3a629de5280ce8eef06165401a` |
| `core-conformance.yaml` 修订前 | `5009f1cd43e17f2b752945ce46e0c842d4249052b0546c4389d2253ec3f63487`(与 TASK-M1-006 run.md addendum 15 锁定输入一致) |

Registry unsupported reason 逐字引用(provenance 链 #141/#155/#156/#159/#163):

- `keyAccessDiagnostics`:"No configured or user-approved HDC key locator was
  identified; the captured conventional-path absence cannot grant production path
  authority."
- `subserverCapability`:"The reviewed upstream source is 3.2.0b rather than the
  exact 3.2.0d target and proves no client-local, zero-lifecycle/device-migration
  observation command for the target revision."

## Delta 与 design.md normative 草案逐项对照

| Design 草案条目 | 落地 | 一致性 |
| --- | --- | --- |
| `suite: CORE-CONFORMANCE-2.1.0` | 已落地;status 注释改指 CORE-2.1.0 baseline,`core_baseline: CORE-2.1.0` | 一致 |
| applicability rule 追加 fail-closed 句 | 追加原文 "Entries under integration_conditional are the only sanctioned conditional exclusions; absence of a registry, a missing family, a hash mismatch, or untraceable provenance never establishes an exclusion — the acceptance ID then stays applicable and unmet." | 逐字一致 |
| `integration_conditional` 恰两条 | `AC-HDC-006-01`(family keyAccessDiagnostics)与 `AC-HDC-009-01`(family subserverCapability),各含 registry 路径、excluded_while、reactivation | 一致;无第三条 |
| excluded_while / reactivation 文本 | 与 design 草案逐字一致(009 条目用 "Same …" 指代形式,同草案) | 一致 |
| shared_inputs:0.2.0 条目保留 + 0.3.0 additive + registry + 0.4.0 lock currency | integration_profiles 含 0.2.0 与 0.3.0 两条;新增 registries 组(OPENHARMONY-HDC-READONLY-PROBES@1.0.0);integration_lock id 改 0.4.0(路径不变) | 一致 |
| `CORE-2.1.0.yaml` baseline 草案 | 新建,`status: draft`/`ratified_at: null`(archive PR 翻 ratified),supersedes CORE-2.0.0,core_change_level minor,scope/notes 如实描述 additive delta 与义务保留 | 一致(草案性质如实标注) |

## 不弱化不变量证明

- `acceptance-index.txt` 与 canonical `acceptance-cases.yaml` 零字节变更
  (`git status` 不含两文件);111 计数由 guard 复核。
- `AC-HDC-006-01`/`AC-HDC-009-01` 仍在 index(grep 计数 2)——未删除任何 acceptance ID。
- `openspec/specs/**` 零变更;REQ-HDC-006/REQ-HDC-009 义务原文未触碰。
- 改动面 = `core-conformance.yaml` + 新建 `CORE-2.1.0.yaml` + 本 evidence + tasks.md
  candidate 注记,全部 ⊆ TASK-CA-001 allowed paths;forbidden paths 零触碰。

## Commands

| Command / check | Result |
| --- | --- |
| `./scripts/check-sdd.sh` | pass,0 error / 0 warning / 111 acceptance IDs(含 CHG-2026-017 scope-coverage guard 与 shared_inputs 路径存在性校验——新增 registries 组与 0.4.0 lock id 均通过) |
| `git diff --check` | pass |
| `git diff --stat` | 改动面仅 allowed paths(见上) |

## Binary conclusions

| Evidence ID | 结论 | Evidence class |
| --- | --- | --- |
| `CA-HDC-APPLICABILITY-001` | PASS — delta 与 design 草案逐项一致(上表);排除条件逐字可追溯至 registry unsupported reason 与 provenance 链 | documentReview |
| `CA-HDC-APPLICABILITY-002` | PASS — canonical 111 零变更、两 AC 仍在 index、specs 零改动、guard 0/0/111、改动面 ⊆ allowed paths | documentReview + guard |

## Boundaries

本 run 不构成 ratification(archive PR 另行)、不翻转 TASK-M1-006 状态(缺口 ① 仍在)、
不构成 CHG-2026-002 verified、platform conformance、hardware/support 或 release claim;
macOS `conformance_status` 保持 `notStarted`。`done` 翻转须独立状态 PR。
