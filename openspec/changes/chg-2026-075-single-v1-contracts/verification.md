# Verification — CHG-2026-075

> Change:CHG-2026-075-single-v1-contracts@r1
> Status:planned

本计划没有执行结果。下面的PASS都是验收目标，不能在任务描述或PR合并时视为已通过。
每个实现Task先完成自己的host/contract/App构建验证；SVC-005负责已发布实现的真实验收。

## Acceptance matrix

| ID | Observable result | Method and failure paths | Owner / evidence |
| --- | --- | --- | --- |
| SVC-AC-01 one control contract | 精确1.0.0、一个方法注册表，无版本协商/降级/业务版本分流 | CLI/App/Executor与同一daemon；wrong version/duplicate key/oversize/id mismatch/unknown method负向；新→旧、旧→新、health后peer更换均零mutation dispatch | SVC-001；methods.md、wire/transport测试 |
| SVC-AC-02 capability parity | 扫描到的所有仍有用途方法和App功能有唯一入口 | Job/Artifact/import/Device/adopt/Workspace/HDC/Flash/Debug/Trace/cleanup；typed params/result + facade回归；XPC禁用方法、ownership/kind/target越权仍拒绝 | SVC-001；完整method处置表与caller→test |
| SVC-AC-03 CLI semantics | 渲染不选择协议，--wait与单client保持现有产品行为 | human/JSON/JSONL业务请求一致；等待/取消/deadline/recovered；超时/断线/丢响应不自动重新dispatch，不滥报zero-dispatch proof | SVC-001；CLI/process/fake daemon测试 |
| SVC-AC-04 strict current requests | 所有decode入口只接受当前完整v1，不忽略旧authority | codec、直接JSONDecoder、durable Job load；错/缺版本、历史campaign/standing/chat权限字段拒绝，无新Job/dispatch | SVC-001/002；三入口正负矩阵 |
| SVC-AC-05 current durable formats | Journal/Manifest/JobState/capability/SQLite保留当前完整语义，只有一种v1布局 | 正常/Flash/recovery写相同schema；round-trip、索引/事务、ledger预算/checkpoint、幂等、取消与export；旧v1布局负向 | SVC-002；store/Journal/Manifest tests |
| SVC-AC-06 old state and recovery | 不重置权威状态，不重放unknown，旧v1不碰撞成新v1 | old1/old2/new1、torn tail/ENOSPC/busy/kill windows；不可读未决记录仍阻断；缺/错/漂移proof零dispatch；合法独立recovery保留原unknown并产生supersession | SVC-002；fault matrix、raw hash比较 |
| SVC-AC-07 evidence integrity | 当前完整evidence为v1，旧raw不变 | readOnly/capability/recovery投影与schema；缺digest/step/target/reservation/coverage/supersession拒绝；legacy authority不能出有效当前证据 | SVC-003；fixture tests与当前真实Runtime引用分列 |
| SVC-AC-08 internal formats | debug permit/document和bound Provider descriptor只剩当前v1 | writer/reader/工具脚本一致；digest/golden与bound identity校验；retired unbound/direct flash拒绝；外部版本未误改 | SVC-003；debug/descriptor contract tests |
| SVC-AC-09 current configuration | Runtime-owned偏好、bundle和当前Keychain形态正常，旧配置不自动迁移 | 首次/已有当前配置、取消、generation冲突、丢响应read-back、旧key忽略/拒绝；自定义材料保持，无自动secret删除；隔离测试与App assertions | SVC-004；settings/install/signing/UI tests |
| SVC-AC-10 complete delivery | 生成物一致、旧兼容残留有结论、产品功能实际可用 | 每Task统一闸；更新当前docs；残留逐项归属；已发布实现GJ-1..5 headless及受影响App呈现检查，当前Catalog真实证据 | SVC-004/005；residual-audit.md和真实run记录 |

## Commands and environment

开发反馈可针对上表的suite运行；最终在仓库根执行：

~~~bash
python3 scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
~~~

修改控制面时另执行以下实际入口；这些并非planner公共检查直接包含的项目：

~~~bash
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check
python3 -m unittest discover -s scripts/bench -t scripts -p 'test_*.py'
~~~

生成物需要修复时先读对应generator的参数，不手写其输出；
CLI机器契约fixture按现有CLIMachineContractTests的生成/比对入口处理。
App UI assertions使用现有封装，Suite取改动对应的实际suite名：

~~~bash
sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>
~~~

仅在安静机器单独执行；首次bootstrap timeout最多重试一次。
App build-for-testing不等于UI assertions，也不等于真机验收。
真机只使用已合入main且发布的arkdeck agent run/resume及当前typed inputs；
记录实际Catalog、target/binding、工具事实和Runtime生成的evidence，不复用旧PASS。
本change不要求另开设备Git Task/PR或聊天authority；人工动作只消费Runtime给出的resume。

## Residual audit

通过rg搜索自有production源码、契约、generator、工具与活动测试中的
protocolVersion、schemaVersion、legacyVersion、targetVersion、requiredMajor、
supportedExactVersions、V2/V6、legacy/fallback/migration。匹配结果由调用链分类，
不能以全仓字符串清零作为完成标准。

- 当前生产协议/格式：单一v1，类型文件去高版本后缀，无历史版本分支。
- 当前业务状态：generation/row version、binding恢复、deadline/read-back继续保留。
- 外部版本：ArkTrace/ArkForge/HDC/SDK/Source Map/SQLite API/ABI等保持。
- 历史记录和负向测试：保留原始历史bytes及unsupported version测试输入。
- 生产未调用的历史reader/adapter删除；当前测试不依赖旧change draft作为新格式正本。
- 不添加通用“禁止数字2”的lint；静态清单只补足行为测试，不能代替它。

## Result gate

- [ ] SVC-001..004的实现、测试、生成物、文档均同车完成且统一闸通过
- [ ] method/caller映射无遗漏，XPC能力范围与最新Runtime语义保持
- [ ] old-v1碰撞、混合构建、旧authority和unknown-state负向已实测
- [ ] raw Artifact/evidence不变；没有重置ledger/target lane的路径
- [ ] SVC-005有当前Catalog上真实Runtime记录，受影响App呈现已检查
- [ ] 每项未执行/失败/偏差如实登记，未自行标verified/平台支持
