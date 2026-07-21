#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="${KERNEL_DIR:-${ROOT_DIR}/kernel}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${ROOT_DIR}/dist"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${ROOT_DIR}/toolchain}"
SUKISU_DIR="${KERNEL_DIR}/SukiSU-Ultra"

: "${CLANG_VERSION:=clang-r563880c}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/build.lock"

for lock_var in KERNEL_COMMIT SUKISU_COMMIT ANYKERNEL3_COMMIT TOOLCHAIN_COMMIT; do
  lock_value="${!lock_var}"
  [[ "${lock_value}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid ${lock_var}: ${lock_value}" >&2
    exit 1
  }
done

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=github

mkdir -p "${OUT_DIR}" "${DIST_DIR}"

echo "Fetching locked SukiSU-Ultra ${SUKISU_COMMIT}"
git init "${SUKISU_DIR}"
git -C "${SUKISU_DIR}" remote add origin \
  https://github.com/SukiSU-Ultra/SukiSU-Ultra.git
git -C "${SUKISU_DIR}" fetch --depth=1 origin "${SUKISU_COMMIT}"
git -C "${SUKISU_DIR}" checkout --detach FETCH_HEAD
test "$(git -C "${SUKISU_DIR}" rev-parse HEAD)" = "${SUKISU_COMMIT}"

test ! -e "${KERNEL_DIR}/drivers/kernelsu"
ln -s ../SukiSU-Ultra/kernel "${KERNEL_DIR}/drivers/kernelsu"

integration_patch="${ROOT_DIR}/patches/kernel-lineage-23.2/0001-build-integrate-SukiSU-through-drivers-Kconfig.patch"
git -C "${KERNEL_DIR}" apply --check "${integration_patch}"
git -C "${KERNEL_DIR}" apply "${integration_patch}"

echo "Backporting path_umount for Linux 4.19"
if ! grep -q '^int path_umount(struct path \*path, int flags)' \
  "${KERNEL_DIR}/fs/namespace.c"; then
  git -C "${KERNEL_DIR}" apply "${ROOT_DIR}/patches/path-umount-4.19.patch"
fi

echo "Applying the Linux 4.19 access_ok compatibility shim for SukiSU-Ultra KPM"
if ! grep -q '^static inline bool sukisu_access_ok_compat' \
  "${SUKISU_DIR}/kernel/kpm/kpm.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-kpm-access-ok-4.19.patch"
fi

echo "Backporting MODULE_IMPORT_NS compatibility for SukiSU-Ultra"
if ! grep -q '^#define MODULE_IMPORT_NS(ns)' \
  "${SUKISU_DIR}/kernel/core/init.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-module-import-ns-4.19.patch"
fi

echo "Disabling unavailable VFS wrapper methods on Linux 4.19"
if ! grep -q '^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)$' \
  "${SUKISU_DIR}/kernel/infra/file_wrapper.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-file-wrapper-4.19.patch"
fi

echo "Backporting the native seccomp syscall count for Linux 4.19"
if ! grep -q '^#define SECCOMP_ARCH_NATIVE_NR __NR_syscalls' \
  "${SUKISU_DIR}/kernel/infra/seccomp_cache.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-seccomp-nr-4.19.patch"
fi

echo "Using the Linux 4.19 mount header layout for SukiSU-Ultra"
if grep -q '^#include <uapi/linux/mount.h>' \
  "${SUKISU_DIR}/kernel/infra/su_mount_ns.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-mount-header-4.19.patch"
fi

echo "Backporting the Linux 4.19 fsnotify observer callback"
if ! grep -q '^static int ksu_handle_event(struct fsnotify_group' \
  "${SUKISU_DIR}/kernel/manager/pkg_observer.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-fsnotify-4.19.patch"
fi

echo "Backporting the Linux 4.19 task_work API for SukiSU-Ultra"
if ! grep -q '^#define KSU_TWA_RESUME true' \
  "${SUKISU_DIR}/kernel/policy/allowlist.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-task-work-4.19.patch"
fi

echo "Gating the newer seccomp filter counter on Linux 4.19"
if ! grep -q '^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)$' \
  "${SUKISU_DIR}/kernel/policy/app_profile.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-seccomp-filter-count-4.19.patch"
fi

echo "Backporting the Linux 4.19 SELinux policy layout for SukiSU-Ultra"
if ! grep -q '^static DEFINE_MUTEX(ksu_rules);' \
  "${SUKISU_DIR}/kernel/selinux/rules.c"; then
  git -C "${SUKISU_DIR}" apply \
    "${ROOT_DIR}/patches/sukisu-selinux-policy-4.19.patch"
fi

echo "Using the Linux 4.19 SELinux policydb implementation"
cp "${ROOT_DIR}/compat/sukisu/sepolicy-4.19.c" \
  "${SUKISU_DIR}/kernel/selinux/sepolicy.c"

make_args=(
  -C "${KERNEL_DIR}"
  O="${OUT_DIR}"
  ARCH=arm64
  LLVM=1
  LLVM_IAS=1
  CC=clang
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  STRIP=llvm-strip
  HOSTCC=clang
  HOSTCXX=clang++
  DTC_EXT=dtc
  BRAND_SHOW_FLAG=oneplus
)

echo "Generating the LineageOS kernel configuration"
cp "${KERNEL_DIR}/arch/arm64/configs/vendor/kona-perf_defconfig" "${OUT_DIR}/.config"
make "${make_args[@]}" olddefconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" \
  "${KERNEL_DIR}/arch/arm64/configs/vendor/oplus.config"
make "${make_args[@]}" olddefconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" \
  "${ROOT_DIR}/configs/sukisu-ultra.config"
make "${make_args[@]}" olddefconfig

for required in \
  CONFIG_KSU=y \
  CONFIG_KSU_MANUAL_SU=y \
  CONFIG_KPM=y \
  CONFIG_KPROBES=y \
  CONFIG_KRETPROBES=y \
  CONFIG_HAVE_SYSCALL_TRACEPOINTS=y \
  CONFIG_KALLSYMS=y \
  CONFIG_KALLSYMS_ALL=y \
  CONFIG_EXT4_FS=y \
  CONFIG_OVERLAY_FS=y; do
  grep -qx "${required}" "${OUT_DIR}/.config" || {
    echo "Required setting is missing after olddefconfig: ${required}" >&2
    exit 1
  }
done

echo "Building Image"
make -j"$(nproc)" "${make_args[@]}" Image

image_path="${OUT_DIR}/arch/arm64/boot/Image"
test -s "${image_path}"
cp "${image_path}" "${DIST_DIR}/Image"
cp "${OUT_DIR}/.config" "${DIST_DIR}/kernel.config"

kernel_sha="$(git -C "${KERNEL_DIR}" rev-parse HEAD)"
sukisu_sha="$(git -C "${SUKISU_DIR}" rev-parse HEAD)"
kernel_release="$(make -s "${make_args[@]}" kernelrelease)"

cat > "${DIST_DIR}/build-info.txt" <<EOF
device=kebab
rom=lineage-23.2
kernel_repository=https://github.com/LineageOS/android_kernel_oneplus_sm8250
kernel_ref=${KERNEL_COMMIT}
kernel_commit=${kernel_sha}
kernel_release=${kernel_release}
sukisu_repository=https://github.com/SukiSU-Ultra/SukiSU-Ultra
sukisu_ref=${SUKISU_COMMIT}
sukisu_commit=${sukisu_sha}
anykernel3_commit=${ANYKERNEL3_COMMIT}
toolchain_commit=${TOOLCHAIN_COMMIT}
clang_version=${CLANG_VERSION}
compiler=$(clang --version | head -n 1)
EOF

echo "KERNEL_SHA=${kernel_sha}" >> "${GITHUB_ENV}"
echo "SUKISU_SHA=${sukisu_sha}" >> "${GITHUB_ENV}"
echo "KERNEL_RELEASE=${kernel_release}" >> "${GITHUB_ENV}"
