# OnePlus 8T `kebab` 首次实验测试计划

## 范围与风险

此测试包仅适用于 OnePlus 8T `kebab`、LineageOS 23.2、Android 16。
它尚未经过任何真机启动、Root 或 SELinux 验证，可能无法启动、造成
bootloop，极端情况下可能导致数据丢失。它不是正式发布版本，不得转发给
普通用户。

GitHub 下载的是外层 Actions Artifact ZIP。先解压这个外层 ZIP；其中名称
包含 `TEST-ONLY` 的 AnyKernel3 ZIP 才是供 Lineage Recovery sideload 的包。
不要把外层 Artifact ZIP 直接交给 recovery。

## 测试前必须确认

逐项确认，任何一项不满足都应停止：

- 设备确实是 OnePlus 8T，代号 `kebab`。
- 当前系统确实是 LineageOS 23.2 / Android 16。
- bootloader 已解锁；若仍显示 `unlocked:no`，立即停止。
- 个人数据已经备份。
- 已保存当前可工作的 boot image，或已保存匹配当前安装版本的完整
  LineageOS 安装包。
- Lineage Recovery 能正常进入。
- `adb devices` 和 `fastboot devices` 能识别设备。
- 已记录当前 slot：`adb shell getprop ro.boot.slot_suffix`。
- 已核对 `SHA256SUMS` 中的 Image 与内层测试 ZIP。
- 接受 bootloop、回滚失败和数据丢失风险。

建议同时记录以下基线：

```text
adb shell getprop ro.product.device
adb shell getprop ro.build.version.release
adb shell getprop ro.lineage.version
adb shell getprop ro.boot.slot_suffix
adb shell cat /proc/version
adb shell getenforce
```

## 推荐安装方式

1. 保持当前 active slot，不切换 slot。
2. 重启到 Lineage Recovery。
3. 选择 `Apply update` → `Apply from ADB`。
4. 在电脑上 sideload 内层测试 ZIP：

```text
adb sideload kebab-lineage-23.2-sukisu-ultra-TEST-ONLY-<sha>.zip
```

5. 完成后正常重启，先不要安装模块或进行额外修改。

AnyKernel3 会读取当前 active slot 的 boot image，只替换 kernel，并以原
boot image 的 ramdisk、内嵌 DTB、header 和 AVBv2 flag 重新打包。测试包不
包含 donor boot、DTB、DTBO、vbmeta 或完整 ROM，也不会写入 inactive slot。

不要执行以下操作：

- 同时覆盖两个 slot；
- 修改或刷写 vbmeta；
- 关闭 AVB 或验证；
- 清除数据；
- 刷写 dtbo；
- 刷写未知来源的 boot image。

## 第一次启动只检查这些项目

1. 设备是否能正常进入系统。
2. 屏幕、触控、USB、存储、Wi-Fi 和移动网络是否基本正常。
3. `adb shell uname -a` 和 `adb shell cat /proc/version` 是否显示预期内核。
4. SukiSU Manager 是否识别内核。
5. Manager 是否能弹出并批准一次 Root 请求。
6. 获得 Root 后执行：

```text
adb shell su -c id
adb shell su -c id -Z
adb shell su -c 'cat /proc/self/status | grep -E "^(Uid|Gid|Cap(Inh|Prm|Eff|Bnd|Amb)):"'
adb shell su -c 'ls -ldZ /data/adb'
adb shell su -c 'test_file=/data/adb/ksu-first-test.txt; echo test > "$test_file"; cat "$test_file"; rm "$test_file"'
```

预期 Root 进程为 UID/GID 0，SELinux domain 为 `u:r:ksu:s0`；若仍是
`untrusted_app`、`shell` 或 `init`，立即停止 Root 功能测试并收集日志。

7. 检查 SELinux 仍为 enforcing，并检查 AVC denial。
8. 检查 kernel panic、Oops、BUG、UAF、sleeping-in-atomic 和明显锁问题。

本轮不要测试 Zygisk、SUSFS、KPM、Play Integrity、Root 隐藏、复杂模块，
也不要在银行、支付或其他重要应用上测试。

## 正常启动后的日志

先创建电脑端目录，再执行：

```text
adb logcat -b all -d > logcat-all.txt
adb shell dmesg > dmesg.txt
adb shell su -c id > su-id.txt
adb shell su -c id -Z > su-id-Z.txt
adb shell su -c 'cat /proc/self/status | grep -E "^(Uid|Gid|Cap(Inh|Prm|Eff|Bnd|Amb)):"' > su-caps.txt
adb shell getenforce > getenforce.txt
adb shell cat /proc/version > proc-version.txt
adb shell dmesg | grep -iE 'SukiSU-4\.19:|avc:|denied|panic|oops|BUG:|KASAN|UAF|sleeping function|atomic|lockdep' > kernel-focus.txt
adb logcat -b all -d | grep -iE 'avc:|denied|sukisu|kernelsu|ksud' > logcat-focus.txt
```

另保存 SukiSU Manager 的版本、内核识别和授权页面截图。日志不要包含密码、
令牌、私钥、个人聊天内容或其他敏感数据。

## 无法启动时的日志

1. 不要反复启动；进入 Lineage Recovery。
2. 连接 USB，确认 `adb devices` 能看到 recovery。
3. 尝试保存 pstore/ramoops：

```text
adb shell ls -la /sys/fs/pstore
adb pull /sys/fs/pstore pstore
adb shell dmesg > recovery-dmesg.txt
adb logcat -b all -d > recovery-logcat.txt
```

如果 `/sys/fs/pstore` 不存在或为空，记录这一事实即可。不要为了取日志而
清除数据。

## 回滚

优先使用与当前 LineageOS 安装版本完全匹配的官方安装包恢复原内核：

1. 进入 Lineage Recovery。
2. 使用 `Apply update` → `Apply from ADB`。
3. sideload 已保存的、与当前版本匹配的完整 LineageOS 安装包。
4. 重启并确认系统恢复。

如果已经保存了当前 active slot 的原始 boot image，也可以在 bootloader
模式下只恢复该 active slot 对应的 boot 分区。先再次确认 slot 和
bootloader 解锁状态；不要同时刷两个 slot，不要刷 dtbo 或 vbmeta。若无法
确定正确 slot 或镜像是否匹配，停止并使用匹配的完整 LineageOS 安装包。
