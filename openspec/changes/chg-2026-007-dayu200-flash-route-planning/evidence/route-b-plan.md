# Route-B / Integration 四 gap 关闭路径研究计划(plan-only)

CHG-2026-007 / TASK-RB-001。**本计划不构成任何执行授权**:文中每一项"未来观察/
获取步骤"都必须另行独立立项、经维护者 approve 后方可执行;plan-only 边界内零设备
命令、零工具执行。输入:archived CHG-2026-003 特征化(pinned 镜像 17 成员清单,
分类 rockchipRawImageSet)、M0B observed 事实(EVD-M0B-DAYU200-20260718-001:
OpenHarmony 7.0.0.34 / API 26.0.0、hdc 3.2.0d、USB Connected)。

**硬顺序规则(全局)**:`GAP-DAYU200-RECOVERY-PATH` 必须**先于**其余三个 gap 的
任何 flash 类(写设备)观察关闭;在其关闭前,一切写设备操作(flash/erase/
tmode/分区写入)一律禁止,任何执行型 change 不得申请豁免。只读观察(文档研究、
工具 help/版本探测、镜像成员的仓库外解码)不受此序约束,但仍需各自立项。

来源可信度分级(全文引用):`S1` 设备/工具实测(受控采集)> `S2` 厂商/官方文档
与开源官方仓库 > `S3` 社区文档/第三方教程(仅作线索,不得单独作为关闭依据)。

## GAP-DAYU200-PARTITION-SEMANTICS(分区表语义)

1. **事实定义**:`parameter.txt` 的 mtdparts/CMDLINE 语法被逐字段解读,产出
   分区名→(offset,size,属性)的可复查映射表,且与镜像成员清单逐项对账
   (每个 img 成员对应哪个分区、有无孤儿)。
2. **候选来源**:S2 Rockchip 开源文档(rkbin/rkdeveloptool 仓库、RK3568 平台
   文档)与 OpenHarmony 设备移植文档;S1 受控解码 pinned 镜像内 parameter.txt
   字节(仓库外、只读,沿 CHG-2026-003 受控位置先例);S3 社区烧写教程仅作
   交叉线索。
3. **获取方法(读写分级)**:全部**只读**——文档研读 + 仓库外对 pinned 成员的
   受控解码(不改写字节、不入仓库原文,仓库内只记结构化结论与 hash 引用)。
   无任何设备操作。
4. **安全边界**:不触设备;解码仅针对已 pinned 的 CHG-2026-003 镜像身份,防止
   版本漂移;结论标注"仅对该 pinned 镜像成立"。
5. **evidence 形态**:结构化映射表 + 来源逐条引用 + 解码字节的 hash 引用,
   最低等级 `platform`(文档/受控解码);写入未来执行 change 的 evidence,
   经维护者 review 后登记为 DEC-002 输入。

## GAP-DAYU200-FLASH-ADDRESSES(烧写地址映射)

1. **事实定义**:每个可烧写分区的目标 offset/地址与烧写工具寻址方式(按分区名
   还是按地址)被确证,并与 PARTITION-SEMANTICS 的映射表一致。
2. **候选来源**:S2 rkdeveloptool/upgrade_tool 文档与源码(其 write-by-name/
   write-by-address 语义);S1 未来受控真机观察(工具 dry-run/list 类只读子命令
   输出);S3 教程仅线索。
3. **获取方法(读写分级)**:第一阶段**只读**(文档/源码研读 + 工具 help/list
   输出受控采集,白名单化,沿 m0b_capture 先例扩展工具白名单——扩白名单本身
   须经该执行 change 的 design 审定);第二阶段(若必要)**写设备**验证,仅在
   RECOVERY-PATH 关闭后可立项。**本 change 及第一阶段不从镜像成员字节推导地址**
   (CHG-2026-003 非目标的延续,防未经验证的推导进入 evidence)。
4. **安全边界**:硬顺序规则适用;任何 write 类子命令在 RECOVERY-PATH 关闭前
   禁止出现在白名单。
5. **evidence 形态**:地址映射表 + 工具输出受控采集(hash 引用)+ 与分区表
   对账记录;只读阶段 `platform`,写验证阶段 `realHardware`(人类操作,
   hardware-evidence schema)。

## GAP-DAYU200-FLASH-PROTOCOL(烧写协议)

1. **事实定义**:DAYU200 实际可用的烧写通道被确证:flashd(HDC)/rockusb
   (maskrom/loader)/其它,含进入方式、传输层(USB)、工具链与版本约束。
2. **候选来源**:S2 OpenHarmony flashd 文档与 hdc 源码、Rockchip rockusb 协议
   文档/rkdeveloptool 源码;S1 未来受控观察(候选逐条:`hdc shell getparam` 类
   只读探测【只读】、设备重启进 loader/maskrom 模式的模式确认【**写设备**——
   改变设备运行态,RECOVERY-PATH 先行】、rkdeveloptool 枚举输出【只读,但需
   设备处于特定模式,模式切换本身写设备】)。
3. **获取方法(读写分级)**:如上逐条标注;只读条目可先行立项,凡涉及模式
   切换/重启的条目一律列为写设备类,受硬顺序规则约束。
4. **安全边界**:M0B 教训延续——工具退出码不可信(hidumper --help exit 0
   先例),协议观察的成败判定必须基于输出标记并保留原始字节;GAP-RECOVERY
   未关前不进入任何 flash 会话。
5. **evidence 形态**:协议事实清单(通道×进入方式×工具×版本)+ 受控采集
   hash 引用;只读部分 `platform`,真机模式确认 `realHardware`。

## GAP-DAYU200-RECOVERY-PATH(恢复/救砖路径)——**先行关闭**

1. **事实定义**:烧写中断/失败后的恢复路径被确证并**由人类操作者在真机上演练
   成功至少一次**:maskrom/loader 强制进入方式(硬件按键/短接点)、恢复所用
   工具与镜像、从"不可启动"回到可启动的完整步骤及其前提。
2. **候选来源**:S2 Rockchip RK3568 maskrom/loader 文档、DAYU200 板卡文档
   (按键/短接点位)、OpenHarmony 设备文档;S3 社区救砖教程(线索);S1 真机
   演练(终局确认)。
3. **获取方法(读写分级)**:第一阶段**只读**文档研究,产出书面恢复预案
   (步骤、工具、所需镜像、风险点);第二阶段**写设备**真机演练(先在维护者
   确认可承受变砖风险的窗口执行)——此演练是全链条第一个被允许的写设备操作,
   其执行 change 须含书面恢复预案作为前置 gate。
4. **安全边界**:演练前必须已具备:恢复预案 + 恢复镜像与工具本地就绪 + 维护者
   明示接受设备不可恢复的残余风险;演练本身即最高风险操作,失败即触发预案。
5. **evidence 形态**:恢复预案文档(`platform`)→ 真机演练记录(人类操作,
   hardware-evidence schema,`realHardware`)。演练成功记录合入即视为本 gap
   关闭,解锁其余 gap 的写设备阶段。

## 升级路径与 DEC-002 汇合

- 立项顺序建议:①PARTITION-SEMANTICS 只读解码 change(无设备)→
  ②RECOVERY-PATH 文档预案 change(无设备)→ ③RECOVERY-PATH 真机演练 change
  (写设备,首个)→ ④ADDRESSES/PROTOCOL 的真机确认 change(s)。
- 每步独立立项、独立 approve、独立 evidence;任何一步不得引用本计划作为执行
  授权。四 gap 全关后,DEC-002 以其 required evidence 齐备为由另行决策
  (governance PR),本计划与各执行 evidence 均只是输入。
