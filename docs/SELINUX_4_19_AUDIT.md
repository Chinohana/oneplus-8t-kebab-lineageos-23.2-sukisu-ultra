# Linux 4.19 SukiSU 启动 SELinux 规则审计

> 历史说明：本文记录的是旧 `unsupported` 基线的发布级风险审计。本轮已
> 在明确标记 TEST-ONLY、设备所有者自行承担风险的边界下恢复上游实践过的
> legacy in-place 路径；该路径仍非事务、无回滚，本文列出的并发与失败原子
> 风险仍是当前已知风险，但不再作为阻止首次个人实验测试的理由。

## 结论

本轮不启用 Linux 4.19 的 `apply_kernelsu_rules()`。

目标内核的活动策略由 `selinux_state.ss->policy_rwlock` 保护；该锁是
`rwlock_t`，原生写路径使用 `write_lock_irq()`。SukiSU v4.1.3 的规则辅助
函数及目标内核的 `avtab`/`hashtab` 插入路径包含 `GFP_KERNEL` 分配和
`cond_resched()`。这些操作不能放在持有该锁的临界区中。

若在锁外直接修改活动 `policydb`，SELinux 读线程可能看到一半完成的
`type`、`avtab`、bitmap 或索引数组；若只使用 SukiSU 私有 mutex，则无法
与目标内核的 SELinux 读路径同步。当前 4.19 也没有经过验证的完整
`policydb + sidtab + map + AVC` 深复制、校验和原子替换实现。

因此已经触发本项目的高风险停止条件：

- 真实策略锁内需要执行可能睡眠的分配；
- 多步规则修改无法回滚，失败会留下部分策略；
- 新类型需要扩展 Linux 4.19 的 flex array，无法在不阻塞读线程的情况下
  就地安全替换；
- sidtab、policydb 和 AVC 的一致更新无法由现有接口保证；
- 上游固定规则包含整个 `ksu` 域 permissive 和大范围 allow，违反本项目
  的最小权限要求。

当前安全状态保持不变：Linux 4.19 的 `apply_kernelsu_rules()` 只报告
unsupported，`handle_sepolicy()` 返回 `-EOPNOTSUPP`，`selinux_hide` 仍报告
unsupported。

## 审计输入

| 来源 | 仓库 | 固定提交 | 文件 |
|---|---|---|---|
| 目标内核 | `LineageOS/android_kernel_oneplus_sm8250` | `4238ee49a84bd418c8515c297563bb29f95ab40b` | `security/selinux/include/security.h`, `security/selinux/ss/services.h`, `security/selinux/ss/services.c`, `security/selinux/ss/policydb.[ch]`, `security/selinux/ss/avtab.c`, `security/selinux/ss/hashtab.c`, `security/selinux/ss/ebitmap.c` |
| 目标 SukiSU | `SukiSU-Ultra/SukiSU-Ultra` | `0ca744a88835144c58d8256ebb32c279edabfcde` | `kernel/core/init.c`, `kernel/hook/syscall_event_bridge.c`, `kernel/runtime/ksud_integration.c`, `kernel/selinux/rules.c`, `kernel/selinux/sepolicy.c`, `kernel/selinux/selinux.c` |
| 历史 4.19 实现 | `tiann/KernelSU` | `0e0a812a9c37078aab856d233bdef4fcc25bab7b` | `kernel/selinux/rules.c`, `apply_kernelsu_rules()`；`kernel/selinux/sepolicy.c`, `add_type()`/`add_typeattribute_raw()` |

历史提交由 GitHub API 核验，提交标题为 `kernel: backport to 4.19 (#36)`：
<https://github.com/tiann/KernelSU/commit/0e0a812a9c37078aab856d233bdef4fcc25bab7b>。
它只作为旧版 API 行为证据，不作为安全实现模板。

## 1. 调用时机与上下文

### 普通内置内核路径

`kernel/hook/syscall_event_bridge.c:ksu_hook_execve()` 在 `execve` 系统调用
路径中调用 `ksu_execve_hook_ksud()`；后者调用
`kernel/runtime/ksud_integration.c:ksu_handle_execveat_ksud()`。当 PID 1
执行 `/system/bin/init second_stage` 时，该函数依次执行：

1. `ksu_selinux_hide_handle_second_stage()`；
2. `apply_kernelsu_rules()`；
3. `cache_sid()`；
4. `setup_ksu_cred()`。

这是进程上下文，不是中断上下文；同一 `execve` 路径稍后明确使用
`GFP_KERNEL`，所以调用点本身允许睡眠。Android init second stage 按设计
位于第一阶段加载 SELinux 策略之后，但 SukiSU 调用点没有执行
`selinux_initialized()` 检查。实现若将来恢复，必须显式检查初始化状态，
不能只依赖路径名称。

该路径使用无锁的静态布尔值 `init_second_stage_executed` 防止重复调用。
PID 1 的正常启动序列预期是单调用，但该变量本身不构成并发同步，也不能
保护活动 policydb。

### 晚加载模块路径

`kernel/core/init.c:kernelsu_init()` 在模块构建且 `current->pid != 1` 时设置
`ksu_late_loaded`，随后直接调用 `apply_kernelsu_rules()`。模块初始化发生在
进程上下文并允许睡眠；它发生在已运行系统的已加载策略上。模块初始化
通常只运行一次，但调用函数本身仍没有与 SELinux 策略重载建立互斥关系。

两条路径由 `ksu_late_loaded` 分开，正常配置不应同时执行；这并不能替代
SELinux 自己的策略锁。

## 2. 活动策略及真实锁

目标内核 `security/selinux/include/security.h` 中的 `struct selinux_state`
持有 `struct selinux_ss *ss`。`security/selinux/ss/services.h` 中：

```c
struct selinux_ss {
    struct sidtab *sidtab;
    struct policydb policydb;
    rwlock_t policy_rwlock;
    ...
};
```

因此活动策略为 `selinux_state.ss->policydb`，真实锁为
`selinux_state.ss->policy_rwlock`。

`security/selinux/ss/services.c` 的访问方式证明了锁语义：

- `security_compute_av()`、`security_compute_xperms_decision()`、
  SID/context 转换、transition 验证等读取路径使用 `read_lock()`；
- `security_set_bools()` 使用 `write_lock_irq()`；
- `security_load_policy()` 在锁外构造并验证新 policydb、sidtab 和 mapping，
  只在 `write_lock_irq()` 的短临界区内同时替换这些对象；
- 解锁后才销毁旧 policydb/sidtab、重置 AVC 并发送策略加载通知。

这把 `rwlock_t` 是自旋型锁。持有 `write_lock_irq()` 时不得睡眠，也不得
调用可能调度的代码。

## 3. 内存分配与数据结构修改

### SukiSU v4.1.3 辅助函数

| 操作 | 修改对象 | 分配/调度行为 | 失败行为 |
|---|---|---|---|
| `ksu_type()` / `add_type()` | type symtab、type 数量、type-to-struct、name 和 attribute map | `kzalloc(GFP_KERNEL)`, `kstrdup(GFP_KERNEL)`, `kvmalloc`/realloc；`hashtab_insert()` | 若中途失败，已增加的 `nprim`、已插入的 type/key 或先前替换的数组没有统一回滚；部分路径泄漏已分配对象 |
| `ksu_typeattribute()` | type attribute bitmap 和 constraint name bitmap | 多次 `ebitmap_set_bit()` | 底层可返回 `-ENOMEM`，但 `add_typeattribute_raw()` 为 `void` 并忽略结果，外层仍返回成功 |
| `ksu_allow()` / `ksu_allowxperm()` | `te_avtab` | `avtab_insert_nonunique()`；xperm 另有 `kzalloc(GFP_KERNEL)` | 单次失败可能返回 false/void，但 `apply_kernelsu_rules()` 忽略所有返回值；已经插入的前序规则不回滚 |
| `ksu_permissive()` | `permissive_map` | `ebitmap_set_bit()` | 可报告 false，但固定规则调用忽略结果 |
| `ksu_type_transition(..., obj)` | filename transition hashtab 与 source-type bitmap | `kcalloc(GFP_KERNEL)`, `kzalloc(GFP_KERNEL)`, `kstrdup(GFP_KERNEL)`, `hashtab_insert()`, `ebitmap_set_bit()` | 分配结果在部分路径未逐一检查；插入失败没有完整清理/回滚 |
| `ksu_dup_sepolicy()`（5.10+ 路径） | 完整策略副本 | `vmalloc`, `kmemdup(GFP_KERNEL)`, `policydb_read()` | 在私有副本上失败可销毁；但目标 4.19 没有等价的完整 `selinux_policy` 复制/交换接口 |

### 目标 Linux 4.19 底层行为

- `security/selinux/ss/avtab.c:avtab_insert_node()` 使用
  `kmem_cache_zalloc(..., GFP_KERNEL)`，并可能调用
  `flex_array_put_ptr(..., GFP_KERNEL | __GFP_ZERO)`；
- `security/selinux/ss/hashtab.c:hashtab_insert()` 先调用 `cond_resched()`，
  再使用 `kmem_cache_zalloc(..., GFP_KERNEL)`；
- `security/selinux/ss/ebitmap.c:ebitmap_set_bit()` 使用 `GFP_ATOMIC`，本身可在
  自旋锁下使用，但调用者必须处理 `-ENOMEM`；
- `security/selinux/ss/policydb.h` 的 `sym_val_to_name`、
  `type_val_to_struct_array` 和 `type_attr_map_array` 在此内核中是
  `struct flex_array *`，不是新版内核的普通可重分配数组。

结论是：仅把整个规则函数包进 `write_lock_irq()` 会在锁内调用
`GFP_KERNEL`/`cond_resched()`，属于明确错误；把分配移到锁外后再逐项修改，
又会让读线程看到中间状态。

## 4. 规则操作影响面

- 增加 type：`ksu_type()` 与 `ksu_attribute()`；
- 扩展/更新 flex array：4.19 中任何新增 type 都必须更新
  `type_val_to_struct_array`、`sym_val_to_name[SYM_TYPES]` 和
  `type_attr_map_array`；SukiSU v4.1.3 的新版数组扩展代码不能直接用于该
  布局；
- 修改 avtab：`ksu_allow()`、deny/audit variants、xperm、无 filename 的
  type transition/change/member；
- 修改 permissive map：`ksu_permissive()` / `ksu_enforce()`；
- 修改 filename transition：带 object 参数的 `ksu_type_transition()`；
- 修改 constraint bitmap：`ksu_typeattribute()`。

固定 `apply_kernelsu_rules()` 当前不调用 filename transition，但通用动态
接口会调用。动态接口在 4.19 保持 `-EOPNOTSUPP`。

## 5. 失败原子性与旧对象生命周期

SukiSU v4.1.3 的 5.10+ 实现先复制完整策略，在副本上修改，再经 policy
mutex 和 RCU 替换。即便如此，固定规则调用仍未逐项检查返回值；它可能
发布只应用了一部分规则的副本。

此前本项目的 4.19 基线兼容补丁曾使用私有 `DEFINE_MUTEX(ksu_rules)` 并
就地修改 `selinux_state.ss->policydb`。后续安全补丁已正确禁用这条路径。
私有 mutex 不被 SELinux 读取路径持有，不能防止并发读取。

新 type 是一个多对象事务：symtab、`nprim`、多个 flex array、attribute
bitmap、role bitmap 和 constraint bitmap 必须一致。当前辅助函数在完成
全部操作前就会改变计数或插入对象；任何后续分配失败都不能恢复原状态。

若采用“分配新 flex array、替换指针、立即释放旧数组”的做法，未使用真实
读锁的 SELinux 读线程可能继续访问旧数组，造成 use-after-free。若为了规避
而永久不释放旧数组，则形成项目明确禁止的永久泄漏。目标内核原生
`security_load_policy()` 通过完整新策略和 sidtab 的构建、锁内短交换、锁外
销毁以及 AVC reset 处理此生命周期；当前 SukiSU 4.19 代码没有等价事务。

## 6. 历史 Linux 4.19 实现的意义与限制

官方 KernelSU 历史提交
`0e0a812a9c37078aab856d233bdef4fcc25bab7b` 的
`kernel/selinux/rules.c:apply_kernelsu_rules()`：

- 通过 `selinux_state.ss->policydb` 取得 4.19 活动策略；
- 只持有 `rcu_read_lock()`，未持有 `policy_rwlock`；
- 直接修改活动 policydb；
- 不检查每条规则的返回值；
- 将整个 `su` 域设置 permissive，并添加大范围 allow。

同一提交的 `kernel/selinux/sepolicy.c:add_type()` 在 4.19 直接返回 false，
`add_typeattribute_raw()` 只适配了 `flex_array_get()`。这说明该历史 backport
确认了 4.19 的 API/布局差异，但没有解决新增 type、真实锁、失败回滚或最小
权限问题。因此它不能满足本项目的安全标准，也不能复制使用。

## 7. 上游固定规则清单与最小性判断

下表中的“调用方”均为 `apply_kernelsu_rules()`；用途来自相邻源码注释和
实际后续调用。没有设备 AVC 拒绝记录或端到端测试能够证明的权限，一律不
标记为启动必需。

| 规则 | 用途/缺少时的具体后果 | 启动必需 | 可推迟 |
|---|---|---:|---:|
| create `ksu` type + `domain` attribute | `cache_sid()` 和 `setup_ksu_cred()` 需要解析 `u:r:ksu:s0`；缺少时 SID/凭据域设置失败 | 是（但当前 4.19 无安全 type 事务） | 否 |
| make `ksu` permissive | 绕过该域全部拒绝；不是一条最小权限规则 | 禁止 | — |
| add `mlstrustedsubject` | 放宽 MLS 约束；缺少时的启动后果未由调用链证明 | 未证明 | 是 |
| add `netdomain` | 网络域能力集合；Manager 识别/ksud 启动无直接依赖证据 | 否 | 是 |
| add `bluetoothdomain` | 蓝牙域能力集合；无启动依赖证据 | 否 | 是 |
| create `ksu_file` type + `file_type` | `cache_sid()` 解析 `u:object_r:ksu_file:s0`；缺少时文件 SID 缓存为 0 | 可能需要，但具体启动后果未证明 | 是，直到文件标记路径被审计 |
| add `mlstrustedobject` to `ksu_file` | 放宽 MLS 对象约束 | 未证明 | 是 |
| `allow domain ksu_file * *` | 允许所有 domain 对该文件类型的所有访问 | 禁止（过宽） | — |
| `allow ksu * * *` | 允许 `ksu` 域访问所有类型/类别/权限 | 禁止（过宽） | — |
| all-ioctl xperm for blk/fifo/chr/file | 广泛 ioctl 使用 | 未证明；不是 Manager 识别必需 | 是 |
| `allow init ksu * *` | 源码注释为 init 触发 ksud，但类别/权限无边界 | 目的可能必需，表达式过宽，不能采用 | 是，待 AVC 确定最小权限 |
| servicemanager → ksu: dir search/read, file open/read, process getattr | 源码归类为 `suRights` | 未由启动调用链证明 | 是 |
| domain → ksu: process sigchld | 子进程退出通知 | Root shell 生命周期可能需要，但全 domain 源过宽，需实测最小化 | 是 |
| logd → ksu: dir search, file read/open/getattr | 日志访问 | 非 Root 启动必需 | 是 |
| domain → ksu: fd use | dumpsys/fd 传递 | 非启动必需且源过宽 | 是 |
| domain → ksu: fifo_file write/read/open/getattr | 管道通信 | 具体调用方未证明，源过宽 | 是 |
| domain → ksu: unix_stream_socket read/write/connectto/getopt/getattr | socket 通信 | 具体调用方未证明，源过宽 | 是 |
| hwservicemanager → ksu: dir search, file read/open, process getattr | 源码注释为 bootctl | 非 Root 启动必需 | 是 |
| domain → ksu: binder all | 允许所有 binder transaction | 禁止作为最小规则；调用方和权限过宽 | 是 |
| system_server → ksu: process getpgid/sigkill | 终止 su 进程 | 非启动必需 | 是 |

静态源码只能确认 `ksu` type 对 SID/凭据域建立是必要的；不能从源码证明
精确的最小 AV 权限集合。安全收敛需要在保持 enforcing 的测试设备上采集
每个启动阶段的 AVC denial，并把每条权限关联到明确调用方和功能测试。本轮
禁止真机测试，因此不能诚实地产生已验证的最小规则集。

## 8. 十个审计问题的直接回答

1. **何时调用：**普通路径在 PID 1 exec `/system/bin/init second_stage` 时；
   晚加载路径在 `kernelsu_init()` 中。
2. **初始化/上下文/睡眠/并发：**正常 Android second stage 与晚加载都应在
   SELinux 策略加载后、进程上下文、允许睡眠；但调用点没有
   `selinux_initialized()` 强校验。预期各调用一次，无锁布尔值不构成并发
   保证。
3. **活动策略位置：**`selinux_state.ss->policydb`。
4. **真实锁：**`selinux_state.ss->policy_rwlock`。
5. **读取路径锁：**`read_lock(&state->ss->policy_rwlock)`。
6. **会分配的函数：**type 创建、avtab/xperm 插入、filename transition、
   policy duplication；bitmap 增长也可能分配。
7. **GFP：**Suki type/filename/xperm 辅助函数主要使用 `GFP_KERNEL`；目标
   avtab/hashtab 使用 `GFP_KERNEL`，ebitmap 使用 `GFP_ATOMIC`。
8. **结构影响：**type 创建扩展 type/symbol/attribute 索引；allow/xperm 和
   type rules 修改 avtab；permissive 修改 bitmap；带文件名 transition 修改
   filename transition hashtab。
9. **失败能否恢复：**不能。固定规则忽略返回值，就地路径没有事务或回滚。
10. **旧数组并发访问：**存在风险。锁外替换并立即释放会与读线程冲突；
    当前没有可证明安全的 4.19 RCU/深复制交换方案。

## 9. 推荐的后续实现方案

在重新启用固定规则前，需要一个独立的 SELinux 4.19 事务实现，而不是给
现有 helper 外层简单加锁：

1. 在不持有 `policy_rwlock` 时，深复制完整 policydb，并建立匹配的 sidtab
   与 mapping；
2. 在副本上预验证所有 type/class/permission，预分配所有对象；
3. 应用完整批次并检查每一步，任何失败只销毁副本；
4. 调用目标内核已有 policydb 校验/加载路径验证副本；
5. 在 `write_lock_irq()` 的短临界区内原子交换 policydb、sidtab 和 mapping，
   同时更新 `latest_granting`；
6. 解锁后重置 AVC、发送策略加载通知，并在确认没有读者后释放旧对象；
7. 用故障注入覆盖每个分配失败点，用并发 SELinux 查询压力测试验证没有
   UAF、部分策略、锁依赖或 sleeping-in-atomic 报告；
8. 在 enforcing 真机上采集 AVC，并逐条形成最小固定权限列表；禁止整个
   `ksu` 域 permissive 和通配 allow。

在上述深复制、sidtab/AVC 协调、失败原子性和并发测试完成前，继续保持
Linux 4.19 启动规则 disabled 是唯一符合本项目约束的选择。
