# Linux 4.19 SELinux 实现路线决策

> 历史说明：本文是旧基线面向正式发布时的设计决策。本轮目标缩小为设备
> 所有者的 TEST-ONLY 首次实验测试，已经恢复非事务的 legacy in-place
> policydb 修改，同时保持 enforcing、禁止 `ksu` permissive 和 wildcard
> allow。本文的发布级建议与风险分析仍有效，但不代表当前代码仍为
> `unsupported`。

## 决策状态与范围

本文只记录架构选择和源码审计，不实现任何 SELinux 运行时代码。本轮继续
保持以下状态：Linux 4.19 的 `apply_kernelsu_rules()` 不修改策略，动态
`handle_sepolicy()` 返回 `-EOPNOTSUPP`，`selinux_hide` unsupported，SELinux
保持 enforcing。本文不批准整个 `ksu` 域 permissive、通配
`allow ksu * * *` 或任何未经 AVC 证明的权限。

审计基于以下固定输入：

- LineageOS kernel `4238ee49a84bd418c8515c297563bb29f95ab40b`；
- SukiSU-Ultra `0ca744a88835144c58d8256ebb32c279edabfcde`；
- 现有 [`SELINUX_4_19_AUDIT.md`](SELINUX_4_19_AUDIT.md) 的调用链、锁和
  内存分配审计。

目标内核的关键源码是
[`security/selinux/ss/services.c`](https://github.com/LineageOS/android_kernel_oneplus_sm8250/blob/4238ee49a84bd418c8515c297563bb29f95ab40b/security/selinux/ss/services.c)、
[`services.h`](https://github.com/LineageOS/android_kernel_oneplus_sm8250/blob/4238ee49a84bd418c8515c297563bb29f95ab40b/security/selinux/ss/services.h)
和
[`sidtab.c`](https://github.com/LineageOS/android_kernel_oneplus_sm8250/blob/4238ee49a84bd418c8515c297563bb29f95ab40b/security/selinux/ss/sidtab.c)。

## 方案摘要

| 方案 | 决策 | 安全性与适用目标 |
|---|---|---|
| A. ROM 构建时静态集成 sepolicy | recommended when a full ROM build is allowed | 沿 Android 标准策略编译/验证链，最容易保持 enforcing 并用 AVC 收敛权限。 |
| B. Linux 4.19 内核运行时事务式策略替换 | research only; required for a ROM-independent Image/ZIP goal | 理论上满足只换内核，但实现和验证成本最高，当前没有可直接采用的验证实现。 |
| C. 就地修改活动 policydb | rejected | 锁、失败原子性和对象生命周期均不成立。 |
| D. 复用已有 Android 域 | research only; not a shortcut | 会混淆信任边界并扩大既有域权限，不能把 Root 留在通用域。 |

## 方案 A：ROM 构建时静态集成 sepolicy

### 需要加入的策略对象

应在 LineageOS 23.2 的 device/vendor/system sepolicy 源树中定义专用的
`ksu` domain 和 `ksu_file` file type。若进程通过一个明确的可执行文件
进入 `ksu`，还需要一个专用 exec type（例如概念上的 `ksu_exec`）；其实际
名称、所属分区和 attribute 必须由该 ROM 的文件安装位置决定，不能从内核
仓库猜测。

完整设计至少包括：

1. `ksu` 的 domain type 及 Android 构建所需的最小 domain attributes；
2. `ksu_file` 的 file type，以及仅覆盖实际 KSU 私有文件路径的
   `file_contexts`；
3. 若使用 exec transition，给实际入口文件单独标记 exec type；
4. 从经过验证的窄调用方到 `ksu` 的 domain transition；
5. 启动、IPC、文件、进程、binder、网络等权限逐条由真实 enforcing AVC
   denial 和对应功能测试驱动。

这里只确定对象和边界，不给出宽泛 allow。`init` 是否为 transition 来源、
哪些分区 attribute 合法、`ksu_file` 具体覆盖哪些路径，以及每一条权限都
是 **未验证**，直到 ROM 安装路径、启动调用链、AVC 和功能结果相互对应。
不能为了先启动而让 `ksu` permissive，也不能给所有 domain 开放
`ksu_file`。

### 构建和发布影响

新增 type、context、transition 和权限后必须重新编译完整 Android SELinux
policy，实际工程中通常意味着至少重建相关 sepolicy/ROM 产物，并最终用
匹配的 boot/vendor/system 分区组合验证。内核不需要在运行时解析、修改或
替换 `policydb`：Android 在构建期合并 public/private、device 和 vendor
策略，策略编译器完成 type/class/attribute/neverallow 等一致性检查，启动
时内核只加载已经包含 `ksu` 对象的完整二进制策略。

影响如下：

- OTA 必须同时携带兼容的 ROM policy 和内核，版本关系可由 ROM 构建与 OTA
  流程管理；只更新内核而回退 policy 可能再次丢失 `ksu` context。
- 单独的通用内核 ZIP 无法给任意未修改 ROM 增加这些策略对象，因此通用性
  降低；用户安装方式变为完整 ROM/配套 OTA，而不是独立内核 ZIP。
- enforcing 全程保持开启。测试设备上逐功能采集真实 AVC denial，只在确认
  调用方、目标对象、class/permission 和预期操作后加入最小规则；每次新增
  权限都要运行 policy compile、neverallow、启动与负向访问测试。

与运行时修改相比，方案 A 使用 Android 已有的策略语言、编译器、兼容性和
OTA 工具链，不需要维护一套内核私有事务机制，因此安全边界更清晰、长期
维护成本更低。

## 方案 B：Linux 4.19 内核运行时事务式策略替换

### 目标内核原生 `security_load_policy()` 流程

目标 4.19 没有新版 `struct selinux_policy` 包装。活动对象是
`state->ss->policydb`、`state->ss->sidtab` 和 `state->ss->map`，由自旋型
`policy_rwlock` 保护。已初始化后的原生重载流程是：

1. 用 `kcalloc` 分配保存旧/新 `policydb` 的容器，并用 `kmalloc` 分配
   `newsidtab`；
2. 对传入的完整 binary policy 调用 `policydb_read(newpolicydb, fp)`，在锁外
   重新解析和验证私有 `policydb`；这不是对活动 struct 做浅复制；
3. `policydb_load_isids()` 为新策略创建 initial SID table；
4. `selinux_set_mapping()` 从内核 `secclass_map` 和新策略的字符串定义建立
   class/permission mapping；未知 class/permission 按策略标志拒绝或记录；
5. `security_preserve_bools()` 按名称保留旧策略 boolean 值；
6. `sidtab_convert()` 按 user/role/type 名和 MLS 规则把旧 sidtab context 转换
   到新策略。它临时启用 live conversion，使转换期间新分配的 SID 也进入
   `newsidtab`，并拒绝并发 policy load；
7. 把活动 `policydb` 的旧内容保存到私有容器；
8. 进入 `write_lock_irq(policy_rwlock)` 的短临界区，同时发布新 policydb、
   sidtab 和 mapping，加载 policy capabilities，并递增
   `latest_granting` 得到本次 policy sequence number；
9. 解锁后销毁旧 policydb、旧 sidtab 和旧 mapping；
10. 用同一 sequence number 执行 `avc_ss_reset()`，再依次发送
    `selnl_notify_policyload()`、status page policy-load update、NetLabel cache
    invalidation 和 XFRM policy-load notification。

首次策略加载是另一条路径：直接解析尚未初始化的活动 policydb，建立
mapping/isids，加载 capabilities，标记 initialized，增加
`latest_granting`，完成 deferred superblock 初始化，然后 reset AVC 并发送
同类通知。KSU 后续事务不能假装自己是首次加载。

### 私有副本的来源与构造

运行时方案必须从一个一致的完整策略快照开始。可研究的来源有：

- 持有真实读锁，通过目标内核 `security_read_policy()` / `policydb_write()`
  序列化活动策略，然后用 `policydb_read()` 重新解析为私有对象；或
- 从受信任的原始完整 binary policy 重新解析，但必须证明它与当前活动
  policy、booleans、SID context 和 Android 加载时变体完全匹配。

不允许 `memcpy` 深层指针后在副本上修改。无论来源如何，新增 type、
attribute、avtab、filename transition、bitmap、索引数组和约束必须只发生
在私有 policydb 上，并检查每一步返回值。修改完成后还要执行等价于完整
policy load 的一致性验证，重新建立 sidtab 和 mapping，再进入发布阶段。

### 必须纳入同一事务的状态

- **policydb：**完整解析或可证明正确的深复制；所有 symbol table、flex
  array、avtab、constraint、ocontext、filename transition 和 bitmap 都归
  私有副本所有。
- **sidtab：**不能复用旧 context 数值。必须建立 initial SIDs，并按 type
  名称等把全部活动 SID 转换/重建；转换期间的新 SID 也要一致处理。
- **class/permission mapping：**必须针对新 policydb 重建，不能保留指向旧
  policy 数值的 mapping。
- **booleans 与 conditional policy：**按名称保存当前值并重新计算条件规则。
- **latest_granting / sequence：**只在成功发布时递增一次；所有新的
  `av_decision.seqno`、AVC reset 和用户空间通知使用同一值。失败不得推进。
- **policy capabilities：**从新 policydb 更新 `state->policycap` 和 Android
  netlink capability 状态；不能留下旧 capability 快照。
- **AVC 与通知：**成功交换后 reset AVC，并完成 netlink、status page、
  NetLabel、XFRM 通知；失败不能 reset 或发送“已加载”事件。

### 锁和旧对象生命周期

所有可睡眠分配、解析、规则应用、sidtab 转换和 mapping 构建都必须在
`policy_rwlock` 外完成。临界区只发布已经完整验证的 policydb、sidtab、
mapping、capabilities 和 sequence；不得在其中使用 `GFP_KERNEL` 或
`cond_resched()`。

目标原生实现依靠 `policy_rwlock` 提供读者生命周期保证，而不是针对这些
对象使用 RCU：写锁成功取得时，之前持读锁的 SELinux 查询都已经退出；交换
后新读者只能看到整套新对象，所以解锁后可销毁旧对象。任何新路径若让读者
在释放读锁后缓存 policydb/sidtab/mapping 指针，就破坏了这个保证；这种路径
必须改为始终在真实读锁下使用对象，或另行设计、证明并实现 RCU/refcount
生命周期。仅在 KSU 一侧加私有 mutex 没有作用。

### 失败原子性与分配失败点

必须显式覆盖至少以下失败类别：

1. 策略快照/序列化缓冲区分配和写出；
2. old/new policy 容器及新 sidtab 分配；
3. `policydb_read()` 内所有 symtab、hashtab、flex array、avtab、ebitmap、
   ocontext、constraint 和 filename transition 分配/解析；
4. initial SID 建立和 context/string/hash 分配；
5. class/permission mapping 数组分配和未知项校验；
6. boolean 保存及 conditional policy 重新计算；
7. sidtab tree 预分配、每个 context 的 user/role/type/MLS 转换、invalid
   context 字符串保存和转换期间 live SID 插入；
8. 私有 KSU type/attribute/index array/avtab/xperm/transition/bitmap 的每次
   分配和插入；
9. 发布前的最终结构校验。

每个失败出口只能销毁本次事务拥有的 snapshot、newpolicydb、newsidtab、
new mapping 和规则对象；活动 policydb/sidtab/mapping、sequence、AVC 和通知
状态必须完全不变。规则批次要么全部成功，要么不发布，不能忽略单条 helper
失败。交换点之前不得把任何新指针写入活动状态，交换点内也不得存在可以
返回失败的工作，这样才不会发布部分规则。

### 验证计划

在考虑设备使用前，需要在专用内核测试构建中启用相应 fault-injection、
KASAN、lockdep 等诊断，并完成：

- 对上面每个可分配调用点做 fail-Nth/failslab/fail_page_alloc 注入；每次
  失败后比较 active policy sequence、context 查询、AVC 决策与事务前一致，
  同时检查无泄漏、UAF、double free 和 sleeping-in-atomic；
- 并发循环执行 `security_compute_av()`、SID/context 双向转换、transition、
  文件/进程/binder/网络访问查询，同时反复执行成功和注入失败的策略事务；
- 压测 policy reload 与 SID 新建的竞态，验证 `sidtab_convert` live conversion
  和并发 load 拒绝路径；
- 对每次成功事务验证 sequence 只增加一次、AVC 全量失效、所有 policy-load
  通知一致；对失败事务验证这些状态均不改变；
- 在 enforcing 真机上进行长时间并发压力和功能/负向权限测试，再依据真实
  AVC 收敛规则。

目标内核的 `selinux_set_mapping()`、`security_load_policycaps()` 等关键逻辑
位于 SELinux 内部，部分函数是 `static`。一个可维护的实现很可能必须修改
目标内核 SELinux 子系统，增加一个窄的“构造并提交完整策略”内部接口；若
要从模块调用，还涉及受控导出。直接导出活动 policydb 或大量低层 helper
会扩大不安全 API 面，不建议采用。

因此方案 B 不是把新版 `struct selinux_policy` 复制到 4.19 就能完成。4.19
的数据布局、flex array、sidtab live conversion、mapping、capability、锁和
通知协议必须作为一个整体移植、实现和验证。

## 方案 C：继续就地修改活动 policydb

**决策：rejected。**

- KSU 私有 mutex 不被 SELinux 读者持有，不能保护读取活动 policydb、sidtab
  或 mapping 的路径。
- 真实 `policy_rwlock` 是自旋型 rwlock；其写临界区内不能调用会睡眠的
  `GFP_KERNEL` 分配，也不能执行 `cond_resched()`。现有 avtab/hashtab/type
  helper 会这样做。
- 若把分配放在锁外、仍逐步改活动对象，读者会观察到 type 已插入但索引、
  attribute、constraint 或 avtab 尚未完成的半状态。
- 多步 helper 失败后没有完整 undo log，前面已经发布的修改无法回滚。
- Linux 4.19 的 type 索引使用 flex array。锁外替换并释放旧对象可能造成
  UAF；为避免 UAF 而永不释放则造成永久泄漏。

RCU read lock、私有 mutex 或“只在启动早期调用”都不能修复上述事务和真实
读者同步问题。本方案不得恢复。

## 方案 D：复用已有 Android SELinux 域

此方案只可研究，不能作为免实现的替代方案。现有 domain 的权限集合代表
该 domain 中 **所有进程** 的信任边界。如果为了 Root 功能扩大一个已有域，
该域内原有进程会一并获得权限；反过来，KSU 进程也会继承与其用途无关的
既有权限。这样会造成调用方身份混淆、AVC 归因困难、binder/service 边界
混用、文件 label 归属不清和 OTA 策略变化风险。

尤其不得把 Root 进程留在：

- `untrusted_app`：它是第三方应用沙箱，混入 Root 会破坏应用 UID/domain
  隔离和整个调用方信任模型；
- `shell`：adb shell 的调试边界不等于持久 Root 服务，扩权会把所有 shell
  会话一起提升；
- `init`：Android 最高信任启动域承载大量系统职责，把长期 Root 工作负载留
  在其中会放大任何 KSU 缺陷并失去独立审计边界。

研究其他已有域前，必须列出该域全部现有入口、所有可进入的调用方、当前
allow/neverallow/MLS/binder 权限、文件 context、OTA 稳定性和负向测试，证明
域复用不会扩大原进程或 KSU 的权限。当前没有此类证据；“设备上已经存在该
域”不等于安全或可跨 ROM 使用。

## 架构建议与下一轮

1. **若产品目标严格是只发布内核 Image/ZIP，是否只能采用 B？** 在 A–D
   中，如果还要求不改 ROM policy、使用独立 `ksu`/`ksu_file` domain 并保持
   enforcing，只有 B 有能力由内核产物改变完整策略状态。A 需要配套 ROM；
   C 已拒绝；D 不是安全替代。也可以改变产品目标，发布配套 ROM/policy，
   而不是强行实现 B。当前 B 未实现，因此 Image-only Root 目标是 blocked。
2. **若允许编译完整 LineageOS ROM，A 是否更安全且维护成本更低？** 是。
   A 使用 Android 标准 policy 编译、neverallow、OTA 和 AVC 工作流，不引入
   内核运行时策略事务，是当前推荐路线。
3. **是否有可直接采用、经过验证的 Linux 4.19 SukiSU/KernelSU 事务实现？**
   在已审计的 SukiSU、KernelSU 历史 4.19 实现和目标内核中没有。历史实现
   是活动 policydb 就地修改，不满足真实锁、回滚、sidtab/mapping/AVC 和最小
   权限要求，不能作为验证实现。
4. **是否可以假定已有实现？** 不可以。在完整代码、故障注入、并发压力和
   enforcing 设备证据出现前，必须明确标记为不存在/未验证。
5. **下一轮最小可执行任务：** 先由产品目标选择路线，不在同一轮顺手写
   运行时代码。推荐接受完整 ROM 目标并执行方案 A 的第一小步：审计
   LineageOS 23.2 实际安装路径和 device/vendor/system sepolicy 分层，提交
   只包含专用 type、精确 file context 和受控 transition 的最小 policy
   skeleton，通过 policy compile/neverallow；所有 allow 先保持未验证，随后
   才在 enforcing 测试设备上按真实 AVC 逐条收敛。若仍坚持 Image-only，
   下一轮应只产出方案 B 的内部 API/事务不变量与 fault-injection 测试设计，
   未通过评审前仍不实现或启用 KSU 规则。

本轮不在 A 与 B 之间替用户改变产品目标，也不开始实现任一方案。
