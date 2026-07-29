# ADR-0005: arkdeck-agentd 本地控制平面(UDS + 版本化 JSON 行协议)

- Status: accepted(CHG-2026-047,2026-07-29)
- Deciders: lvye(merge 即批准)
- Context: ADR-0004 确立两平面分离后,Device Agent Runtime 需要唯一
  composition root。此前 App/CLI 各自直接持有执行栈(HDC facade /
  RockchipFlashExecutionHost),无跨客户端共享的 job/session 视图,也无
  跨进程单实例约束。

## Decision

1. **Unix domain socket,零网络**。socket 位于用户私有状态目录
   (目录 0700、socket 0600),不监听任何 TCP/UDP 面;本用户可达即
   授权边界(MVP),更强的对端校验(peer credential)留作后续硬化。
2. **版本化 JSON 行协议**。每行一帧;请求
   `{protocolVersion, id, method, params}`,响应 `{id, ok, result|error}`;
   方法表封闭,未知 method、未知协议主版本、畸形帧一律结构化拒绝;
   次版本前向兼容。协议面**不存在** argv/shell/executable 载体——注入
   防御是结构性的。
3. **transport 与 handler 分离**。`RuntimeControlPlaneHandler` 无传输
   依赖,内存帧即可契约测试;Windows named pipe / Linux socket 端口只需
   替换 transport 层。
4. **single-instance**。flock + instance 文档;第二实例启动返回既有
   实例信息(pid/socket/协议版本),不抢占、不双写。
5. **daemon 结构性无 GitHub 面**。二进制不链接任何 git/GitHub 客户端,
   runtime job 无法产生 PR/task——"日常设备运行零 Git 依赖"由链接面
   保证,而非纪律保证。

## Consequences

- App/CLI/AI 收敛为客户端(`ArkDeckAgentClient`);daemon 重启后
  job/result 仍可查询(durable journal + job record)。
- MU-2 生产组装的 dispatcher 显式拒绝设备 dispatch(fail-closed),
  真实 dispatch 随 MU-3 walking skeleton 绑定 descriptor 校验执行器。
- 协议演进走 catalog/OpenSpec(新 method = Repo Plane 决策)。

## Alternatives considered

- **XPC**:macOS 专属、App 沙盒纠缠;UDS 保持 Foundation-neutral 且可
  直接映射到 Linux。
- **TCP localhost**:引入网络监听面与端口占用/防火墙问题,违背零网络
  原则。
- **每客户端内嵌引擎**:无法保证单设备互斥与统一 journal,正是本 change
  要消除的形态。
