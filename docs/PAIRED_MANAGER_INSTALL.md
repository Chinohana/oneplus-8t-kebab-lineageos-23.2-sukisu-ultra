# PAIRED Manager + kernel 安装说明

这个 Artifact 是一次构建生成的成对测试包：

- `SukiSU-...-PAIRED-....apk` 修复了 libsu RootService 加载可写
  `main.jar` 时被 Android 拒绝的问题。
- `kebab-...-TEST-ONLY-....zip` 内核同时信任 SukiSU 官方管理器签名和
  本次 APK 的临时签名。

二者必须来自同一个 Actions Artifact。临时私钥不会上传或保留，因此不要把
不同 run 的 APK 与内核 ZIP 混用。

## 安装顺序

1. 保留当前官方 SukiSU-Ultra 管理器，先在 Recovery 中刷入本 Artifact 的
   内层 `TEST-ONLY` AnyKernel3 ZIP。
2. 启动系统。此时官方管理器仍受内核信任，可用于确认内核已正常启动。
3. 记录当前授权应用，然后卸载官方管理器。由于 APK 签名不同，Android 不允许
   直接覆盖安装；卸载会清除管理器应用自身的数据和设置。
4. 安装同一 Artifact 中的 `PAIRED` APK。
5. 打开管理器，确认状态为“工作中”，再重新授权需要 Root 的应用并测试。

不要上传或公开分发该测试包。若无法启动，按设备测试计划恢复先前可用的
`boot` 镜像。
