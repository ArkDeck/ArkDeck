# BlueTool 3.3.0 RK 刷机实现分析

> 证据类别：本地主机静态分析。未运行 Windows 程序，未连接/读取/修改真实设备，
> destructive dispatch = 0。本文只记录行为事实，不授予第三方二进制的复制或分发权。

## 1. 样本与封装

| 项 | 观察 |
| --- | --- |
| 主程序 | Windows x86-64 PE，12,258,397 bytes，SHA-256 `eb47ab3ddfb4618301aec39a9b31a84891e35cc31836fb48b2ab7744fa4f91ff` |
| RK 工具 | bundled Windows x86 `resource/upgrade_tool.exe`，1,319,424 bytes，SHA-256 `4d6ec7d286d22e74bf1b9a6952bb0f4c2636a6b308436b4422fff4c5bdf12ba4` |
| 打包形态 | PyInstaller one-dir；cookie 声明 Python 3.8 (`python38.dll`)，入口 `main`，PYZ 含 1,905 个模块 |
| UI | PySide2/Qt；版本文本 `V3.3.0` |
| 其他工具链 | 同包还含 `CmdDloader.exe`、UNISOC DLL/PAC 资源；它与 RK3568 流程是另一条刷机实现 |

分析通过 PyInstaller CArchive/PYZ 目录、Python 3.8 marshal code object 和对应 opcode
反汇编完成。关键模块为 `main`、`utils.task` 和 `pages.tab_widget.upgrade`。

## 2. RK 设备枚举

`QTask.list_rk3568_devices()` 调用：

```text
"<bundled>/resource/upgrade_tool.exe" LD
```

随后逐行选择 `DevNo` 开头的记录，并使用下面的正则提取字段：

```text
Vid=0x(?P<vid>\S+),Pid=0x(?P<pid>\S+),LocationID=(?P<locationid>\d+)\tMode=(?P<mode>\S+)
```

每台设备被保存为 `device` 原文、`VID_xxxx&PID_xxxx`、`locationid` 和 `mode`。整个
函数由宽泛异常处理包围；解析或工具错误直接退化为空列表，没有可诊断错误分类。

UI 点击刷新时还运行 `hdc list targets` 并通过
`hdc -t <target> shell param get ohos.boot.hardware` 识别 `uis7885`，用于另一条
dayu600/PAC 流程。RK3568 Flash 页要求恰好一台 RK 设备，未提供多设备显式选定和
dispatch-time 身份复核。

## 3. 进入 Loader 的方式

- 如果 `LD` 已报告 `Mode=Loader`，直接使用当前 `LocationID`。
- 否则通过 Windows WMI `Win32_PnPEntity`，找第一个名称含 `HDC Device` 且
  `DeviceID` 含原 `VID_xxxx&PID_xxxx` 的项；取 `DeviceID` 最后一个反斜杠分量的小写值
  作为 HDC target。
- 然后执行 `hdc -t <sn> shell reboot loader`。函数级 timeout 为 20 秒，命令返回后固定
  等待 5 秒，再次 `LD`；没有 bounded polling/retry。
- 只有重启后列表恰好一台且为 Loader 才返回其 `LocationID`。

该流程未建立 normal-mode HDC identity 与重枚举后 RockUSB identity 的 durable
binding，也未证明返回的唯一 Loader 就是原设备。它也不检查 HDC return code/语义；无法
取得 SN 时仍会构造命令。ArkDeck 可借鉴软件进态目标，但不能沿用这些身份与执行假设。
逐项借鉴/替换矩阵见 `loader-entry-alignment.md`。

## 4. 镜像输入与写入顺序

UI 接受本地 `.tar.gz`，也能从 PR/issue/direct HTTP 链接寻找或下载镜像。解压后按固定
列表处理十个文件：

1. `MiniLoaderAll.bin`
2. `parameter.txt`
3. `uboot.img`
4. `resource.img`
5. `boot_linux.img`
6. `ramdisk.img`
7. `system.img`
8. `vendor.img`
9. `updater.img`
10. `userdata.img`

命令序列为：

```text
upgrade_tool.exe -s <location> UL <MiniLoaderAll.bin> -noreset
upgrade_tool.exe -s <location> DI -p <parameter.txt>
upgrade_tool.exe -s <location> DI -uboot <uboot.img> <parameter.txt>
upgrade_tool.exe -s <location> DI -<partition-key> <image>
upgrade_tool.exe -s <location> RD
```

`sys_prod`/`chip_prod` 分区名会把下划线改为连字符。用户勾选“8G uboot”后，工具用 bundled
`resource/uboot.img` 覆盖镜像中的 `uboot.img`，仅以警告框提示非 8G 设备可能变砖。

前三个控制文件缺失会抛错；其余镜像缺失只记录“文件缺失”并继续，最终仍可能显示“镜像
文件烧录完成”。不存在 ArkDeck Profile 所要求的 archive/member hash、size、允许分区、
完整集合和精确计划校验。

## 5. 成功、进度与线程

- PySide `QThread` 串行执行任务，signal 把阶段和 console 文本追加到 UI。
- 下载进度按 HTTP 字节计算；刷机进度主要是“开始/成功”阶段文本，不是可靠总量。
- `UL` 仅检查 stdout 包含 `Upgrade loader ok`；parameter 检查 `Write gpt ok`；其余
  `DI` 检查 `Download image ok`。
- `RD` 的返回值未作语义判定；没有设备回连、版本/固件匹配或 postflight gate。
- 外部命令实现是 `subprocess.run(cmd_str, capture_output=True, shell=True, ...)`；
  `upgrade_tool` 路径、选择器、参数和镜像路径先拼成字符串。该做法违反 ArkDeck
  `POL-WORKFLOW-001`，也扩大了引号/元字符和错误 shell 解释风险。
- 没有 durable intent/outcome journal、critical write 取消边界、outcomeUnknown、
  device lane、storage/power coordinator 或可复查 Session/manifest。

## 6. 可借鉴与不可复用

可借鉴的 UX：

- 明确的刷新设备入口；
- 设备数量/模式可见；
- 本地镜像选择；
- 单一开始按钮；
- 阶段日志与危险 uboot 提示。
- 已在 Loader 时跳过无意义重启；正常系统可达时尝试软件进入 Loader；失败则在写入前停止。

ArkDeck 必须替换的实现：

- 用已验证的 DAYU200 `rkdeveloptool ld/ppt/wlx/rd` Provider/Profile，不能引入
  `upgrade_tool UL/DI` 第二套协议；
- 用 executable descriptor + `[String]` argv，不能使用 shell；
- 多设备显式选择并绑定 identity，不能以“重启后唯一一台”为同一设备证明；
- `enterUpdater` 使用 durable HDC binding + typed `reboot loader` argv，随后 bounded poll 和
  Core rebind；HDC 不可用/能力未知时保留物理按键向导；
- 镜像必须流式 hash 且与 pinned Profile 完全匹配，不能跳过缺失分区继续；
- UI 的“一键”必须进入 typed Job/Journal/Session，不能绕过 prerequisites、精确计划、
  destructive confirmation、safe cancellation、postflight 和 RecoveryGuide；
- 第三方 Windows 二进制/镜像许可证与供应链身份未知，不进入 ArkDeck 源码或发行物。

## 7. ArkDeck 当前缺口

已有：`RockchipRockUSBFlashProvider`、`RockchipFlashProfile`、archive summary/validation、
typed plan、manual/standing authorization gate、CLI plan/handoff、outcome/recovery contract、
DAYU200 hardware evidence。

缺少：真实 `rkdeveloptool` discovery parser/adapter、signed Sandbox 非提权 USB access 证据、
DAYU200 `hdc shell reboot loader` E1 capability evidence、normal→Loader rebind adapter、安全解包
到 owned Session 的实现、Provider step executor、完整 journal orchestration、Flash application
facade/SwiftUI、物理按键 fallback presentation、全局 Job UI 和 UI 产品路径真机 evidence。
