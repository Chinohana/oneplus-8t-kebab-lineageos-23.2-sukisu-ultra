#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="${ROOT_DIR}/kernel"
OUT_DIR="${ROOT_DIR}/out"
DIST_DIR="${ROOT_DIR}/dist"
TOOLCHAIN_DIR="${ROOT_DIR}/toolchain"

: "${KERNEL_REF:=lineage-23.2}"
: "${KSU_REF:=v1.1.1}"
: "${CLANG_VERSION:=clang-r563880c}"

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=github

mkdir -p "${OUT_DIR}" "${DIST_DIR}"

echo "Integrating KernelSU-Next ${KSU_REF}"
(
  cd "${KERNEL_DIR}"
  curl --fail --location --silent --show-error \
    "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/${KSU_REF}/kernel/setup.sh" \
    | sh -s "${KSU_REF}"
)

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
  "${ROOT_DIR}/configs/kernelsu-next.config"
make "${make_args[@]}" olddefconfig

for required in CONFIG_KSU=y CONFIG_KSU_KPROBES_HOOK=y CONFIG_KPROBES=y CONFIG_OVERLAY_FS=y; do
  grep -qx "${required}" "${OUT_DIR}/.config" || {
    echo "Required setting is missing after olddefconfig: ${required}" >&2
    exit 1
  }
done

echo "Building Image and DTBs"
make -j"$(nproc)" "${make_args[@]}" Image dtbs

image_path="${OUT_DIR}/arch/arm64/boot/Image"
test -s "${image_path}"
cp "${image_path}" "${DIST_DIR}/Image"
cp "${OUT_DIR}/.config" "${DIST_DIR}/kernel.config"

mkdir -p "${DIST_DIR}/dtbs"
(
  cd "${OUT_DIR}/arch/arm64/boot/dts"
  find . -type f -name '*.dtb' -exec cp --parents '{}' "${DIST_DIR}/dtbs" \;
)

kernel_sha="$(git -C "${KERNEL_DIR}" rev-parse HEAD)"
ksu_sha="$(git -C "${KERNEL_DIR}/KernelSU-Next" rev-parse HEAD)"
kernel_release="$(make -s "${make_args[@]}" kernelrelease)"

cat > "${DIST_DIR}/build-info.txt" <<EOF
device=kebab
rom=lineage-23.2
kernel_repository=https://github.com/LineageOS/android_kernel_oneplus_sm8250
kernel_ref=${KERNEL_REF}
kernel_commit=${kernel_sha}
kernel_release=${kernel_release}
kernelsu_repository=https://github.com/KernelSU-Next/KernelSU-Next
kernelsu_ref=${KSU_REF}
kernelsu_commit=${ksu_sha}
clang_version=${CLANG_VERSION}
compiler=$(clang --version | head -n 1)
EOF

echo "KERNEL_SHA=${kernel_sha}" >> "${GITHUB_ENV}"
echo "KSU_SHA=${ksu_sha}" >> "${GITHUB_ENV}"
echo "KERNEL_RELEASE=${kernel_release}" >> "${GITHUB_ENV}"
