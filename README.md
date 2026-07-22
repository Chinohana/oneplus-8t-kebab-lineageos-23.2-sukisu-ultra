# OnePlus 8T (kebab) LineageOS 23.2 + SukiSU-Ultra

本仓库为 OnePlus 8T（`kebab`）构建 LineageOS 23.2 的 Linux 4.19
内核，并把固定版本的 SukiSU-Ultra core 编译进原始 ARM64 `Image`。
当前基线的目标是可审计的 **Image-only 编译**，不是可刷写或 Root 可用的发布。

## 当前边界

- 当前工作流只生成原始 ARM64 `Image` 和审计文件；不会生成 AnyKernel3 ZIP。
- 当前没有批准的刷机 ZIP，也没有完成真机启动验证、Root 功能验证或发布验证。
- KPM 关闭；SUSFS 未包含。
- Linux 4.19 的动态 sepolicy 接口 `handle_sepolicy()` 返回 `-EOPNOTSUPP`。
- `selinux_hide` 在 Linux 4.19 上不受支持。
- 启动时 `apply_kernelsu_rules()` 不应用规则，只报告 unsupported。
- 当前 Android SELinux policy 不包含 `u:r:ksu:s0` 和
  `u:object_r:ksu_file:s0`。这两个 context 无法解析，因此当前 `Image`
  **不应被视为可用的 SukiSU Root 内核**，尤其不能宣称 enforcing 模式下
  Root 可用。
- 历史 GitHub Actions `#29940784150` 中的 ZIP 是未批准历史产物，不应刷入设备。

## 功能状态

| 功能 | 状态 | 说明 |
|---|---|---|
| Kernel compilation | completed | GitHub Actions 编译原始 ARM64 `Image`。 |
| Manager signature | completed | 固定 SukiSU 源码中的 Manager 签名校验路径已编译；此项不代表 Manager 或 Root 已通过真机验证。 |
| KSU core compiled | completed | `.config` 要求 `CONFIG_KSU=y` 和 `CONFIG_KSU_MANUAL_SU=y`。 |
| Root domain | blocked | ROM policy 中没有 `ksu` / `ksu_file` context，无法建立所需 SID。 |
| Dynamic sepolicy | unsupported | Linux 4.19 路径返回 `-EOPNOTSUPP`。 |
| selinux_hide | unsupported | Linux 4.19 不注册该功能处理器。 |
| KPM | disabled | 稳定配置要求 `# CONFIG_KPM is not set`。 |
| SUSFS | disabled | 源码补丁和配置均未包含 SUSFS。 |
| AnyKernel3 package | disabled | Image 工作流与打包锁和脚本完全分离；未批准占位工作流明确失败。 |
| Device boot test | unverified | 本基线未进行真机刷写或启动测试。 |
| Root functional test | blocked | SELinux Root 域缺失，且未进行真机功能测试。 |
| Release status | blocked | 没有可刷包、真机证据或已验证 Root，禁止发布。 |

`completed` 只描述对应的编译/静态集成步骤完成，不把设备行为推断为成功。

## 锁定输入

- Device: OnePlus 8T（`kebab`）
- ROM base: LineageOS 23.2
- Kernel: `LineageOS/android_kernel_oneplus_sm8250`，Linux 4.19
- SukiSU-Ultra: 固定的 v4.1.3 提交，built-in non-GKI
- Toolchain: 固定的 Android 16 Clang 提交

`build.lock` 只包含 Image 编译真正使用的 kernel、SukiSU 和 toolchain
提交。未来若明确批准 AnyKernel3 打包，打包脚本会单独读取
`packaging/anykernel.lock`；当前 Image 工作流不会读取 `packaging/`。

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

当前产物没有获批的安装路径，**不能刷机**。不要把外层 Actions Artifact
误认为刷机包，也不要安装历史 AnyKernel3 ZIP。有关 Linux 4.19 SELinux
后续路线见 [`docs/SELINUX_4_19_DESIGN_OPTIONS.md`](docs/SELINUX_4_19_DESIGN_OPTIONS.md)。

## 上游项目

- [LineageOS OnePlus sm8250 kernel](https://github.com/LineageOS/android_kernel_oneplus_sm8250)
- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)（仅保留未批准的独立打包输入）
