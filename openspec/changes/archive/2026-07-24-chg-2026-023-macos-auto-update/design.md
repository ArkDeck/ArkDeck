# CHG-2026-023 Design:应用内自动更新

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.1.0(零 Core 变更)

## 0. 安全不变量(两条路线共同的硬边界)

1. **验签 fail-closed 双层**:feed/appcast 层(EdDSA 签名,公钥内置 App)+
   下载物层(代码签名链必须验到与 App 相同的 Developer ID Team identity);
   任一层失败 → 零安装动作、零文件替换,只报诚实错误。Sparkle 路线还须
   `SURequireSignedFeed` + `SUVerifyUpdateBeforeExtraction` 同时启用(profile
   既定基线)。
2. **零静默安装**:检查可自动,安装须显式用户同意;用户可关闭自动检查。
3. **隐私最小化**:更新检查请求只含版本比较所需字段(App 版本/OS 版本/arch),
   零设备标识、零用户路径、零遥测(DEC-008 边界);披露文案随实现交付。
4. **私钥隔离**:EdDSA 私钥只存在于维护者发布环境,永不入仓、永不进 CI secret
   (V1 治理事故教训);公钥进 App 资源并被 contract 测试 pin。
5. **entitlement 纪律**:任何 XPC/entitlement 增项须显式过 ADR-0002 声明,
   不得随实现静默出现(测试断言 entitlement 集与声明一致)。

## 1. 候选路线(AU-001 评估对象;本 design 不预判)

| 维度 | Sparkle 2(sandbox/XPC 模式) | 最小自研 |
| --- | --- | --- |
| 安装体验 | 应用内全自动(XPC installer) | 下载+验签后引导用户挂载 DMG 替换 |
| 供应链 | 首个第三方依赖:license(MIT)/SBOM/版本+hash pin/审计 | 零新依赖;自担维护 |
| sandbox 面 | 需内嵌 XPC services + 可能的 entitlement 增项 | 现有 network.client 即可 |
| 验签链 | EdDSA feed + Sparkle 内建验证(须两开关) | EdDSA feed 自验 + SecStaticCode Team 验证 |
| 失败面 | 框架成熟但面大 | 面小但边界情况自负(断点/中断/回滚) |

评估须逐维落 facts(不接受"社区常用"类论据);选型记录 = AU-001 交付物,owner
merge 认可。

## 2. Feed/发布管线(两路线共通)

- appcast/feed:HTTPS 静态托管(GitHub Releases 资产或等价;host 选定属 AU-001
  facts);内容 = 版本、最低系统、DMG URL、EdDSA 签名、发布说明摘要;
- 发布步骤挂 M5 release 流程:构建公证 DMG → EdDSA 签名(维护者本地私钥)→
  发布 feed;规程文档随 AU-002 交付,私钥处理规程逐条可审计。

## 3. 与既有面的接线

- 更新检查触发:手动"检查更新"+ 可开关的启动后台检查;网络失败静默降级为
  "当前版本"不打扰(诚实但不告警);
- 诊断:更新检查/安装事件进 SystemLogger 既有目录的新增事件类(实现时按
  M1-009 封闭目录规则扩,不夹带敏感字段);
- UI:设置面开关 + 版本/检查状态展示(App 面,AU-002)。

## 4. 分期与边界

- AU-001(host-only 文档/评估)→ AU-002(实现+管线);各自 readiness/实现/done
  PR;AU-002 若引入依赖,依赖 pin(版本+hash)与 license notice 随实现 PR 交付;
- change verified = ADR-0002 release gate #3;不构成 release 本身(其余 gates
  独立);Windows/Linux 端口不在本 change(更新机制平台相关,未来端口另立)。
