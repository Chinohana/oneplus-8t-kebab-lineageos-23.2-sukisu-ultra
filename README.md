# OnePlus 8T (kebab) LineageOS 23.2 + SukiSU-Ultra

本仓库为 OnePlus 8T（`kebab`）构建 LineageOS 23.2 的 Linux 4.19
内核，并把固定版本的 SukiSU-Ultra core 编译进原始 ARM64 `Image`。
当前基线同时提供可审计的 Image-only 编译，以及仅供设备所有者自行承担
风险的 **TEST-ONLY** AnyKernel3 实验包。它不是公开发布版本。

## 当前边界

- 普通 Image 工作流只生成 ARM64 `Image` 和审计文件，不生成 ZIP。
- 独立测试工作流只能人工触发，会重新编译 Image 并生成名称包含
  `TEST-ONLY` 的 AnyKernel3 ZIP；它不创建 GitHub Release。
- 当前仍没有任何真机启动、Root 功能或发布验证。
- KPM 关闭；SUSFS 未包含。
- Linux 4.19 的动态 `handle_sepolicy()` 暂时返回 `-EOPNOTSUPP`；在完成安全
  的 copy-on-write 安装器前，不允许它修改活动策略。
- `selinux_hide` 在 Linux 4.19 上不受支持。
- 每次 SELinux 策略加载时，KSU 在新策略尚未安装、尚无并发读者的阶段创建
  `ksu` 与 `ksu_file` 并应用显式权限；最终切换、SID 转换、AVC 刷新和旧
  策略释放仍由 Linux 4.19 原生 `security_load_policy()` 完成。
- Root 凭据只有在 `u:r:ksu:s0` 成功解析时才会提交，避免 UID 0 长期留在
  原 Android domain。
- 已删除对活动 policydb 的原地修改路径；当前实现仍需设备所有者验证启动、
  SID 解析和 Root 行为，因此仍不是发布级实现。
- 历史 GitHub Actions `#29940784150` 中的 ZIP 是未批准历史产物，不应刷入设备。

## 功能状态

| 功能 | 状态 | 说明 |
|---|---|---|
| Kernel compilation | completed | GitHub Actions 编译原始 ARM64 `Image`。 |
| Manager signature | completed | 固定 SukiSU 源码中的 Manager 签名校验路径已编译；此项不代表 Manager 或 Root 已通过真机验证。 |
| KSU core compiled | completed | `.config` 要求 `CONFIG_KSU=y` 和 `CONFIG_KSU_MANUAL_SU=y`。 |
| Root domain | compiled, device-unverified | 启动规则创建 `ksu` / `ksu_file`；真机 SID 和 domain 切换尚未验证。 |
| Dynamic sepolicy | disabled on Linux 4.19 | 缺少安全 copy-on-write 安装器，返回 `-EOPNOTSUPP`。 |
| selinux_hide | unsupported | Linux 4.19 不注册该功能处理器。 |
| KPM | disabled | 稳定配置要求 `# CONFIG_KPM is not set`。 |
| SUSFS | disabled | 源码补丁和配置均未包含 SUSFS。 |
| AnyKernel3 package | TEST-ONLY | 仅人工测试工作流生成，固定 AnyKernel3 提交，只替换 active slot 的 kernel。 |
| Device boot test | unverified | 本基线未进行真机刷写或启动测试。 |
| Root functional test | unverified | 有可测试代码路径，但没有真机证据。 |
| Release status | not ready | 禁止公开发布或宣称稳定、安全、Root 已验证。 |

`completed` 只描述对应的编译/静态集成步骤完成，不把设备行为推断为成功。

## 锁定输入

- Device: OnePlus 8T（`kebab`）
- ROM base: LineageOS 23.2
- Kernel: `LineageOS/android_kernel_oneplus_sm8250`，Linux 4.19
- SukiSU-Ultra: 固定的 v4.1.3 提交，built-in non-GKI
- Toolchain: 固定的 Android 16 Clang 提交

`build.lock` 只包含 Image 编译使用的 kernel、SukiSU 和 toolchain 提交。
测试打包工作流另外读取 `packaging/anykernel.lock`；普通 Image 工作流
不会执行打包脚本。

Linux 4.19 缺少当前 SukiSU-Ultra mount namespace 清理所需的 `path_umount`
等接口。构建按 `series` 顺序重放受审计的兼容补丁，并把完整补丁清单和
最终差异放入 Artifact。

## GitHub Actions

在 Actions 中手动运行 **Build kebab kernel Image with SukiSU-Ultra**。
成功的 Artifact 至少包含：

- `Image`
- `kernel.config`
- `build-info.txt`
- `SHA256SUMS`
- `kernel-final.diff`
- `sukisu-final-complete.diff`
- `applied-patches.txt`
- `root-readiness.txt`
- `build.log`

Artifact 不包含 `.zip` 刷机包。`root-readiness.txt` 是基于最终配置、补丁
清单和内核版本的静态防误判结果；它不能代替真机启动或 Root 功能验证。

需要测试包时，在 Actions 中人工运行 **Build TEST-ONLY kebab AnyKernel3**。
下载的外层 Artifact ZIP 不是刷机包；解压后，名称包含 `TEST-ONLY` 的内层
AnyKernel3 ZIP 才可由 Lineage Recovery sideload。完整前置条件、首次检查、
日志和回滚见 [`docs/DEVICE_TEST_PLAN.md`](docs/DEVICE_TEST_PLAN.md)。

## 可追踪性与可复现性

需要区分三个层次：

1. **固定源码和工具链输入：** `build.lock` 固定 kernel、SukiSU 和 Clang
   提交；补丁、配置与 Actions action revision 由项目提交固定。
2. **可追踪构建：** Artifact 保存最终配置、补丁清单、完整源码差异、
   构建日志、构建元数据和 SHA256。`build-info.txt` 记录项目/上游提交、
   编译器、配置及补丁 hash。
3. **字节级可复现构建：** 当前未验证。工作流固定
   `SOURCE_DATE_EPOCH`、`KBUILD_BUILD_TIMESTAMP`、
   `KBUILD_BUILD_VERSION`、locale 和 timezone，但 GitHub runner 镜像与 apt
   依赖并未全部按包摘要锁定，也没有用多个独立环境证明 `Image` SHA256
   一致。因此不得把本项目描述为严格的字节级可复现构建。

确定性环境变量不会删除真实源码差异，也不会隐藏内核树的 dirty 状态。

## 安全说明

只有新测试工作流内层、名称包含 `TEST-ONLY` 的 ZIP 可供设备所有者自行
承担风险首次测试。不要把外层 Actions Artifact 当作刷机包，不要安装历史
ZIP。`release_ready=no`、`root_verified_on_device=no` 仍然成立。

## 上游项目

- [LineageOS OnePlus sm8250 kernel](https://github.com/LineageOS/android_kernel_oneplus_sm8250)
- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)（仅保留未批准的独立打包输入）
