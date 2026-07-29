# ADR-0006: 首次设备接管的独立 E0 admission 路径

- Status: accepted(CHG-2026-048,2026-07-29)
- Deciders: lvye(merge 即批准)
- Context: 正常 runtime 要求 durable target + confirmed binding 才允许
  任何设备步骤;但 binding 本身要靠观察设备才能建立——这构成启动死锁。
  历史上的解法是"临时关闭校验",那会在最脆弱的时刻打开最大的口子。

## Decision

1. **独立 admission,不是绕行**。`DeviceBootstrapMachine` 是与
   `RuntimeJobEngine` 平行的第二条入口,只做 adopt;普通 runtime 的
   binding/capability 校验一行不改、一次不放宽。
2. **结构性 E0**。bootstrap 的动作词表是
   `BootstrapObservationAction` 四例封闭枚举(observeTool/observeServer/
   listCandidates/observeDevice),类型面不存在 mutation 构造点——
   "bootstrap 不能改设备"由编译器保证,而非纪律保证;测试再钉一层
   (每例 effect ≤ readOnly)。
3. **人工信任是显式停点**。unauthorized/offline 候选 →
   `waitingForHuman(prompt)`,提示写明物理动作;信任完成后同一调用
   自动续行。Agent 不模拟、不重试、不代按。
4. **多候选必须显式选择**。>1 候选返回候选列表,零自动挑选——防止在
   多设备台面上绑错机器(与刷机期"新出现的第一个 USB 设备"同族风险)。
5. **身份基于稳定物理身份**。target 以 serial 归一化 SHA-256 为键
   (与 Core `stablePhysicalIdentitySha256` 同构),无 serial 即
   fail-closed;同一身份重复 adopt 幂等返回原记录。

## Consequences

- 干净机器上 `arkdeck device adopt` 即可从零建立 binding,无需预置
  fixture 或手工写配置。
- bootstrap 与 runtime 的边界清晰:前者只产出 target,后者只消费 target。
- 生产 dispatch 首次接线(descriptor 绑定)后,唯一还缺的是真机
  evidence——按设备窗口模型补记,不由代码面自证。

## Alternatives considered

- **runtime 内加"首次例外"开关**:被否——例外开关是最容易被后续代码
  误用的形态,且难以在类型面证明其只在首次生效。
- **要求人工预写 binding 文件**:被否——正是本次改造要消灭的手工步骤。
- **自动选择第一个候选**:被否——多设备台面误绑代价过高。
