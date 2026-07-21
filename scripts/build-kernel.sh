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

apply_patch_series() {
  local repo="$1"
  local series_dir="$2"
  local patch_name patch_path

  test -f "${series_dir}/series"
  while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
    [[ -z "${patch_name}" || "${patch_name}" == \#* ]] && continue
    [[ "${patch_name}" != */* && "${patch_name}" != *\\* ]] || {
      echo "Invalid patch name in ${series_dir}/series: ${patch_name}" >&2
      exit 1
    }
    patch_path="${series_dir}/${patch_name}"
    test -f "${patch_path}"
    echo "Applying ${patch_path}"
    git -C "${repo}" apply --check "${patch_path}"
    git -C "${repo}" apply "${patch_path}"
  done < "${series_dir}/series"
}

apply_patch_series "${KERNEL_DIR}" \
  "${ROOT_DIR}/patches/kernel-lineage-23.2"
apply_patch_series "${SUKISU_DIR}" \
  "${ROOT_DIR}/patches/sukisu-v4.1.3-linux-4.19"
git -C "${KERNEL_DIR}" diff --check
git -C "${SUKISU_DIR}" diff --check

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
