# TASK-UDR-002 run — 组件树按文件型产物交付(2026-07-31)

## 结论

- UDR-AC-5、AC-6、AC-7:**PASS**(contract 面,880 tests / 1 skipped / 0 failures)
- UDR-AC-8(真机):**PASS** —— 提案预期它是 pending-hardware,实际在实现同日
  就跑通了,故如实记 PASS 而非 pending

## 真机执行

| 项 | 值 |
| --- | --- |
| 设备 | DAYU200,`TGT-958780b2ffb7`,hdc 3.2.0f |
| 入口 | `arkdeck agent run --operation capture.diagnostics@1`(executor=agent) |
| Inputs | `durationSeconds: 3`、`uiDump: true`、**`uiComponentTree: true`** |
| Job | `job-cdeb06b644bafa16ee65c3cdacb9d9be`,`succeeded`,`actualEffect: E1`,`humanActions: []` |

逐步判定:

```text
verified capture-ui-tree     ["remoteByteCount"]
verified receive-ui-tree     ["byteCount", "localArtifact", "sha256"]
artifact ui-tree.json -> ART-a8f56d6b34dff551f8bda26fea302013
verified cleanup-ui-tree-temp ["cleaned"]
```

产物:

| Artifact | 状态 | 字节 |
| --- | --- | --- |
| `hilog.txt` | published | 861,321 |
| `ui-dump.json`(窗口清单,腿未变) | published | 1,691 |
| **`ui-tree.json`** | **published** | **26,143** |
| `trace.htrace` | missing | 0(本次未请求 trace,如实标注) |

`ui-tree.json` 读回后可解析为 `{attributes, children}`,**42 个节点**,根节点
`bounds = [0,0][720,1280]`。窗口结束时设备 `/data/local/tmp` 无 `arkdeck-*` 残留。

## 与提案的差异

提案把 UDR-AC-8 定为 pending-hardware(按 UDR-AC-4 先例)。实际实现当天设备在线,
一次跑通,故直接记 PASS。**没有**因此放宽任何判据:三步的 verified 均来自
readback/落地文件,不是退出码。

## 本记录**不**证明的事

- 不声称 `DHA-HW-*` 类 AC 通过(hardware-evidence contract 仍编码不了 Agent
  executor,与前几次窗口同一条理由);
- 只覆盖整屏 windowId-free 形态;`-w <windowId>` 的窗口级深层 dump 仍是 out of scope;
- 只在 hdc 3.2.0f / OH 3.2 上验证过一次,未覆盖其他版本或多显示屏设备。
