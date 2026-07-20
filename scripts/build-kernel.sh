#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="${KERNEL_DIR:-${ROOT_DIR}/kernel}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${ROOT_DIR}/dist"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${ROOT_DIR}/toolchain}"

: "${KERNEL_REF:=lineage-23.2}"
: "${SUKISU_REF:=v4.1.3}"
: "${CLANG_VERSION:=clang-r563880c}"

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=github

mkdir -p "${OUT_DIR}" "${DIST_DIR}"

echo "Integrating SukiSU-Ultra ${SUKISU_REF}"
(
  cd "${KERNEL_DIR}"
  curl --fail --location --silent --show-error \
    "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${SUKISU_REF}/kernel/setup.sh" \
    | sh -s "${SUKISU_REF}"
)

echo "Backporting path_umount for Linux 4.19"
if ! grep -q '^int path_umount(struct path \*path, int flags)' \
  "${KERNEL_DIR}/fs/namespace.c"; then
  git -C "${KERNEL_DIR}" apply "${ROOT_DIR}/patches/path-umount-4.19.patch"
fi

echo "Applying the Linux 4.19 access_ok compatibility shim for SukiSU-Ultra KPM"
if ! grep -q '^static inline bool sukisu_access_ok_compat' \
  "${KERNEL_DIR}/KernelSU/kernel/kpm/kpm.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-kpm-access-ok-4.19.patch"
fi

echo "Backporting MODULE_IMPORT_NS compatibility for SukiSU-Ultra"
if ! grep -q '^#define MODULE_IMPORT_NS(ns)' \
  "${KERNEL_DIR}/KernelSU/kernel/core/init.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-module-import-ns-4.19.patch"
fi

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
sukisu_sha="$(git -C "${KERNEL_DIR}/KernelSU" rev-parse HEAD)"
kernel_release="$(make -s "${make_args[@]}" kernelrelease)"

cat > "${DIST_DIR}/build-info.txt" <<EOF
device=kebab
rom=lineage-23.2
kernel_repository=https://github.com/LineageOS/android_kernel_oneplus_sm8250
kernel_ref=${KERNEL_REF}
kernel_commit=${kernel_sha}
kernel_release=${kernel_release}
sukisu_repository=https://github.com/SukiSU-Ultra/SukiSU-Ultra
sukisu_ref=${SUKISU_REF}
sukisu_commit=${sukisu_sha}
clang_version=${CLANG_VERSION}
compiler=$(clang --version | head -n 1)
EOF

echo "KERNEL_SHA=${kernel_sha}" >> "${GITHUB_ENV}"
echo "SUKISU_SHA=${sukisu_sha}" >> "${GITHUB_ENV}"
echo "KERNEL_RELEASE=${kernel_release}" >> "${GITHUB_ENV}"
