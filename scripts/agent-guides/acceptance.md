# 真机与 App 呈现验收

适用：验收已发布 operation 的真实设备行为，或验收 App 呈现。
本指南由 [AGENTS.md](../../AGENTS.md) 按需引用；普通代码验证使用根文件的统一入口。

真机验收已发布 operation 时使用 `arkdeck agent run`，人工动作后消费对应
`arkdeck agent resume`。headless 路径缺失或失败时修复产品路径并报告
`BLOCKED_BY_PRODUCT_DEFECT`，不让维护者代跑或靠 UI 点击替代同一验收。

仅当验收目标涉及 App 呈现时运行 UI assertions（不属于 merge gate），在仓库根目录执行：

```bash
sh scripts/ci/run-ui-tests.sh -only-testing:ArkDeckHDCUITests/<Suite>
```

使用该封装处理签名、独立 DerivedData 和 runner 清理，在安静机器上单独运行；首次
bootstrap timeout 可重试一次。未执行检查及原因如实写入交付说明。
