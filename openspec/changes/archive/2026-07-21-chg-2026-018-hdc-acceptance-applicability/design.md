# CHG-2026-018 Design:integration-conditional applicability

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.0.0 → 目标 CORE-2.1.0(minor)

## 备选方案与裁决

- **A. 改写两条 Scenario 原文**(把 unsupported 展示写进 THEN):否决。这是对 ratified
  CORE-2.0.0 语义的原地弱化——AC 的 GIVEN 前提被替换成实现现状,未来 registry 一旦支持
  对应 family,被弱化的 Scenario 无法自动恢复原义,历史 evidence 语义也被污染。
- **B. conformance manifest 条件化适用性(本设计)**:采纳。Scenario 原文一字不动,义务
  保持「目标义务」;排除条件绑定到 maintainer-accepted 的 registry unsupported 事实,且
  fail-closed(沉默不构成排除);registry 翻 supported 即自动恢复义务并触发
  needsReverification。这与 registry 自身的 fail-closed 语义互为镜像。
- **C. 立即登记两个 probe family 为 supported**:被一手 provenance 否决——
  `keyAccessDiagnostics` 无任何被授权的 key locator(host 采集实测 key material 缺席,
  `REQ-HDC-006` 禁止 Core 硬编码路径);`subserverCapability` 经上游源码审读证明目标
  revision 不存在零副作用观察命令。未来若事实变化(如设备授权流程产生 key material、
  上游新增安全命令),按 registry 既有流程走新 integration change,即本机制的 reactivation
  路径,无须再动 Core。

## core-conformance.yaml 目标形态(实现 PR 落地,此处为 normative 草案)

```yaml
suite: CORE-CONFORMANCE-2.1.0        # 2.0.0 → 2.1.0,唯一语义 delta 见下
applicability:
  default_platforms: [macos, windows, linux]
  platform_overrides: []
  rule: >-
    (原文保留)… Any applicability change requires a Core change and a new
    conformance-suite version. …(追加)Entries under integration_conditional are
    the only sanctioned conditional exclusions; absence of a registry, a missing
    family, a hash mismatch, or untraceable provenance never establishes an
    exclusion — the acceptance ID then stays applicable and unmet.
  integration_conditional:
    - acceptance_id: AC-HDC-006-01
      family: keyAccessDiagnostics
      registry: openspec/integrations/openharmony/readonly-probes.yaml
      excluded_while: >-
        The pinned OPENHARMONY-TOOLS readonly-probes registry explicitly marks the
        family unsupported with maintainer-accepted provenance. The conforming
        platform result is then the registered fail-closed unsupported diagnostic
        with zero key-path read/repair dispatch.
      reactivation: >-
        A future approved integration change marking the family supported makes
        this acceptance ID immediately applicable again; any verified or
        conformance conclusion that relied on the exclusion becomes
        needsReverification.
    - acceptance_id: AC-HDC-009-01
      family: subserverCapability
      registry: openspec/integrations/openharmony/readonly-probes.yaml
      excluded_while: >-
        Same registry condition; the conforming platform result is the registered
        unsupported presentation with zero spawn-sub, killall-sub and
        device-migration dispatch.
      reactivation: >-
        Same reactivation rule as AC-HDC-006-01.
shared_inputs:
  integration_profiles:
    # 0.2.0 Golden 条目保留;additive 补记:
    - id: OPENHARMONY-TOOLS
      version: 0.3.0
      path: openspec/integrations/openharmony/profile.md
  # readonly-probes registry 与 INTEGRATION-PROFILES-0.4.0 lock 同步补记(路径+版本;
  # V2 不逐文件 hash pin,历史对比用 git)
```

acceptance_index/acceptance_cases 的 path/count(111)与全部条目零变更。

## 波及分析

- **CHG-2026-002 Gate 算术**:Gate 原文「全部 62 个 Core AC…有可复查证据」经 2.1.0 suite
  解读为 60 条无条件 + 2 条 integration-conditional(排除成立期间以 registered unsupported
  事实闭合);该解读进入 CHG-002 账本须另行 governance ledger PR(先例 #193),verify 结论
  仍由维护者在 verify PR 中确认。
- **macOS platform**:`conformance_status: notStarted` 不变,不产生 needsReverification——
  排除是收窄而非放宽,109 条未受影响 AC 的既有 evidence 不重判。
- **TASK-M1-006**:缺口 ②③ 由本 change 化解后,任务仍因缺口 ①(production participant
  inventory feed)保持 `blocked`;其解除须独立立项。
- **安全不变量**:POL-HDC-001 与 REQ-HDC-006/009 的禁令面(零 key 变更、零 subserver/
  device-migration dispatch)不依赖本机制——它们已由 M1-006 合入版的仪表化 contract 直接
  证明,与适用性排除无关。

## Baseline 机制

`openspec/baselines/CORE-2.1.0.yaml`:supersedes CORE-2.0.0,change 指向本 change,
core_change_level minor,scope 措辞 = 继承 CORE-2.0.0 全部未变 scope + 本 manifest delta;
ratification = 维护者 review/merge archive PR(V2 规则,与 CORE-2.0.0 记录一致)。
