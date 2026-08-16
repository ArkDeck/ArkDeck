# DAYU200 的读域：一段被删掉的代码留下的事实

> 索引文档。CHG-2026-059 把 Rockchip 的写入与读回移交给 `arkforged` 时，
> 删掉了 `characterizeMediumReadDomain` 及其判定逻辑。删掉一段代码等于删掉写它的人
> 当时知道的东西，除非那件事被写在别处 —— 这里就是别处。

## 事实

DAYU200 的 RockUSB 读面与写面**不对称**：

- `rl` 的读窗自扇区 **65536**（32 MiB）起是结构性盲区，窗口外**恒定返回 uniform `0xCC`**；
- `wlx` 的写面**全盘可达**；
- 被擦除的介质**也**读作 `0xCC`。

因此在读窗之外，「读回全是 `0xCC`」**不能**推出「没写进去」。这两件事在那条链路上
不可区分。

## 它造成过什么

2026-08-04，九次 flash 被判为「写入未落盘」。九次**全是冤案**：数据其实写进去了，
板子后来正常启动到了写入的那个版本。判定依据是读窗外的 uniform filler，
而那正是这块板子在窗外恒定返回的东西。

## 证据

| 条目 | 内容 |
|---|---|
| ArkForge AD-006 | 读写面不对称定案（GJ-4 真机 campaign ECAMP-96EFFF15 / ECAMP-31E041BC） |
| ArkForge AD-019 | 2026-08-15 用一条**完全不同的代码路径**独立复现同一读窗：sector 1 读到真实数据、sector 19955712 读到 uniform `0xCC`；九个目标三态判定为 1 Verified / 2 Failed / 6 TypedSkip，边界落在扇区 40960 与 237568 之间，与 AD-006 记录的 65536 相容 |
| ArkForge AD-009 | 跨 enter-loader 转换的独立复现；读取时板子正由 `system`/`vendor` 启动运行 7.0.0.37，故窗外 `0xCC` 在现场就被证明不等于「未写入」 |

三条都在 ArkForge 仓 `docs/evidence/ledger.md`。

## 现在这条判定在哪里

在 `arkforged`。读域**每次执行实测**，不是 Profile 里的常量；判定是三态而不是两态：

- `Verified` —— 在读窗内读到并比对通过；
- `Failed` —— 在读窗内读到且不符；
- `TypedSkip` —— 在读窗外，带 `skipped-lba-read-window` 与 `readDomainDetail`。

**`TypedSkip` 不计入任何 verified 强度。** 一次没有被验证的写入不会因为它落在盲区里
而变成「已验证」。最终判定交给 `rebind-and-verify-build`：设备启动后自报的
`const.ohos.fullname` 才是那次写入是否落地的证据（ArkForge AD-016）。

## 为什么这份索引必须留着

删掉的那段代码里有一条注释，记录的是花了一整轮 campaign 才换来的教训。
代码可以移交，教训不能跟着消失 —— 下一个看到「读回全 `0xCC`」的人，
需要在得出「没写进去」之前先读到这一页。
