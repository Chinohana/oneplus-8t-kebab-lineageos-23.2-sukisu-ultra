#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_DIR="${ROOT_DIR}/AnyKernel3"

if [[ "${ANYKERNEL3_PACKAGING_APPROVED:-no}" != yes ]]; then
  echo "AnyKernel3 packaging is not approved; refusing to create a ZIP" >&2
  exit 1
fi

PROJECT_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
SHORT_SHA="${PROJECT_SHA:0:7}"
ZIP_NAME="kebab-lineage-23.2-sukisu-ultra-TEST-ONLY-${SHORT_SHA}.zip"
WARNING_FILE="${ROOT_DIR}/packaging/TEST-ONLY-NOT-FOR-RELEASE.txt"
TEST_PLAN="${ROOT_DIR}/docs/DEVICE_TEST_PLAN.md"

test -s "${DIST_DIR}/Image"
test -s "${DIST_DIR}/kernel.config"
test -s "${DIST_DIR}/build-info.txt"
test -s "${DIST_DIR}/applied-patches.txt"
test -s "${DIST_DIR}/root-readiness.txt"
test -s "${DIST_DIR}/build.log"
test -s "${WARNING_FILE}"
test -s "${TEST_PLAN}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/packaging/anykernel.lock"

[[ "${ANYKERNEL3_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Invalid ANYKERNEL3_COMMIT: ${ANYKERNEL3_COMMIT}" >&2
  exit 1
}

git init "${PACKAGE_DIR}"
git -C "${PACKAGE_DIR}" remote add origin https://github.com/osm0sis/AnyKernel3.git
git -C "${PACKAGE_DIR}" fetch --depth=1 origin "${ANYKERNEL3_COMMIT}"
git -C "${PACKAGE_DIR}" checkout --detach FETCH_HEAD
test "$(git -C "${PACKAGE_DIR}" rev-parse HEAD)" = "${ANYKERNEL3_COMMIT}"

rm -rf \
  "${PACKAGE_DIR}/.git" \
  "${PACKAGE_DIR}/.github" \
  "${PACKAGE_DIR}/modules" \
  "${PACKAGE_DIR}/patch" \
  "${PACKAGE_DIR}/ramdisk"
rm -f "${PACKAGE_DIR}/README.md"
cp "${ROOT_DIR}/packaging/anykernel.sh" "${PACKAGE_DIR}/anykernel.sh"
cp "${DIST_DIR}/Image" "${PACKAGE_DIR}/Image"
cp "${DIST_DIR}/build-info.txt" "${PACKAGE_DIR}/build-info.txt"
cp "${WARNING_FILE}" "${PACKAGE_DIR}/TEST-ONLY-NOT-FOR-RELEASE.txt"

grep -Fqx 'device.name1=kebab' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'supported.versions=16' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'IS_SLOT_DEVICE=1' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'SLOT_SELECT=active' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'PATCH_VBMETA_FLAG=0' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'NO_MAGISK_CHECK=1' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'split_boot' "${PACKAGE_DIR}/anykernel.sh"
grep -Fqx 'flash_boot' "${PACKAGE_DIR}/anykernel.sh"

if find "${PACKAGE_DIR}" -maxdepth 1 -type f \
  \( -iname 'dtb' -o -iname 'dtb.img' -o -iname 'dtbo' -o -iname 'dtbo.img' \
     -o -iname 'vbmeta*' -o -iname 'boot.img' \) | grep -q .; then
  echo "AnyKernel3 package contains a forbidden replacement image" >&2
  exit 1
fi

(
  cd "${PACKAGE_DIR}"
  zip -r9 "${DIST_DIR}/${ZIP_NAME}" . \
    -x '*.git*' '*placeholder'
)

unzip -t "${DIST_DIR}/${ZIP_NAME}"
unzip -Z1 "${DIST_DIR}/${ZIP_NAME}" | LC_ALL=C sort > "${DIST_DIR}/anykernel-zip-contents.txt"

for required_entry in \
  Image \
  anykernel.sh \
  build-info.txt \
  TEST-ONLY-NOT-FOR-RELEASE.txt \
  META-INF/com/google/android/update-binary \
  tools/ak3-core.sh \
  tools/magiskboot; do
  grep -Fqx "${required_entry}" "${DIST_DIR}/anykernel-zip-contents.txt" || {
    echo "AnyKernel3 ZIP is missing ${required_entry}" >&2
    exit 1
  }
done

if grep -Eiq '(^|/)(dtb|dtb\.img|dtbo|dtbo\.img|vbmeta[^/]*|boot\.img)$' \
  "${DIST_DIR}/anykernel-zip-contents.txt"; then
  echo "AnyKernel3 ZIP contains a forbidden replacement image" >&2
  exit 1
fi

cp "${WARNING_FILE}" "${DIST_DIR}/TEST-ONLY-NOT-FOR-RELEASE.txt"
cp "${TEST_PLAN}" "${DIST_DIR}/DEVICE_TEST_PLAN.md"

sed -i \
  -e 's/^flashable_package=no$/flashable_package=yes/' \
  -e 's/^ready_for_owner_device_experimental_test=no$/ready_for_owner_device_experimental_test=yes/' \
  "${DIST_DIR}/root-readiness.txt"

(
  cd "${DIST_DIR}"
  sha256sum \
    Image \
    "${ZIP_NAME}" > SHA256SUMS
)

echo "TEST_ZIP_NAME=${ZIP_NAME}" >> "${GITHUB_ENV}"
echo "PROJECT_SHA=${PROJECT_SHA}" >> "${GITHUB_ENV}"
echo "PROJECT_SHORT_SHA=${SHORT_SHA}" >> "${GITHUB_ENV}"
