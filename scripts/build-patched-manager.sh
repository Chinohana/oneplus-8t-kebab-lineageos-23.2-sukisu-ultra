#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
SUKISU_MANAGER_DIR="${SUKISU_MANAGER_DIR:-${RUNNER_TEMP:-/tmp}/sukisu-manager}"
LIBSU_DIR="${LIBSU_DIR:-${RUNNER_TEMP:-/tmp}/libsu-6.0.0}"
DIST_DIR="${ROOT_DIR}/dist"
MANAGER_KEY_ALIAS="owner-paired-key"
KSU_APK_CERT_MAX_LENGTH=1024
MANAGER_VERSION="v4.1.3-owner-libsu-readonly"
LIBSU_PATCH_VERSION="6.0.0-owner-readonly"

# shellcheck disable=SC1091
source "${ROOT_DIR}/build.lock"

for lock_var in SUKISU_COMMIT MANAGER_LIBSU_COMMIT; do
  lock_value="${!lock_var}"
  [[ "${lock_value}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid ${lock_var}: ${lock_value}" >&2
    exit 1
  }
done
[[ "${SUKISU_VERSION_CODE}" =~ ^[0-9]+$ ]] || {
  echo "Invalid SUKISU_VERSION_CODE: ${SUKISU_VERSION_CODE}" >&2
  exit 1
}
grep -Fq "+KSU_VERSION := ${SUKISU_VERSION_CODE}" \
  "${ROOT_DIR}/patches/sukisu-v4.1.3-linux-4.19/0016-build-make-SukiSU-version-metadata-deterministic.patch"

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
    git -C "${repo}" apply --check "${patch_path}"
    git -C "${repo}" apply "${patch_path}"
  done < "${series_dir}/series"
}

fetch_locked_repo() {
  local repo_dir="$1"
  local url="$2"
  local commit="$3"

  test ! -e "${repo_dir}"
  git init "${repo_dir}"
  git -C "${repo_dir}" remote add origin "${url}"
  git -C "${repo_dir}" fetch --depth=1 origin "${commit}"
  git -C "${repo_dir}" checkout --detach FETCH_HEAD
  test "$(git -C "${repo_dir}" rev-parse HEAD)" = "${commit}"
}

mkdir -p "${DIST_DIR}"

fetch_locked_repo \
  "${SUKISU_MANAGER_DIR}" \
  https://github.com/SukiSU-Ultra/SukiSU-Ultra.git \
  "${SUKISU_COMMIT}"
fetch_locked_repo \
  "${LIBSU_DIR}" \
  https://github.com/topjohnwu/libsu.git \
  "${MANAGER_LIBSU_COMMIT}"

apply_patch_series \
  "${SUKISU_MANAGER_DIR}" \
  "${ROOT_DIR}/patches/sukisu-v4.1.3-manager"
apply_patch_series \
  "${LIBSU_DIR}" \
  "${ROOT_DIR}/patches/libsu-6.0.0"

git -C "${SUKISU_MANAGER_DIR}" diff --check
git -C "${LIBSU_DIR}" diff --check

root_service_file="${LIBSU_DIR}/service/src/main/java/com/topjohnwu/superuser/internal/RootServiceManager.java"
grep -Fq 'mainJar.setReadOnly()' "${root_service_file}"
grep -Fq "version = \"${LIBSU_PATCH_VERSION}\"" "${LIBSU_DIR}/build.gradle.kts"
grep -Fq "libsu = \"${LIBSU_PATCH_VERSION}\"" \
  "${SUKISU_MANAGER_DIR}/manager/gradle/libs.versions.toml"
grep -Fq \
  'managerVersionCode by extra(if (ownerPatchedManager) System.getenv("KSU_OWNER_VERSION_CODE").toInt() else getVersionCode())' \
  "${SUKISU_MANAGER_DIR}/manager/build.gradle.kts"
grep -Fq 'let mut command = Command::new("/system/bin/sh");' \
  "${SUKISU_MANAGER_DIR}/userspace/ksud/src/su.rs"

manager_dir="${SUKISU_MANAGER_DIR}/manager"
keystore_file="${manager_dir}/owner-paired-key.jks"
certificate_file="${manager_dir}/owner-paired-cert.der"
keystore_password="$(openssl rand -hex 32)"
key_password="$(openssl rand -hex 32)"

umask 077
keytool -genkeypair \
  -alias "${MANAGER_KEY_ALIAS}" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 3650 \
  -storepass "${keystore_password}" \
  -keypass "${key_password}" \
  -dname "CN=Chinohana OnePlus 8T Owner Paired Manager" \
  -storetype JKS \
  -keystore "${keystore_file}"

keytool -exportcert \
  -alias "${MANAGER_KEY_ALIAS}" \
  -keystore "${keystore_file}" \
  -storepass "${keystore_password}" \
  -file "${certificate_file}"

cert_size_dec="$(stat -c%s "${certificate_file}")"
cert_size_hex="$(printf '0x%04x' "${cert_size_dec}")"
cert_hash="$(sha256sum "${certificate_file}" | awk '{print $1}')"
[[ "${cert_hash}" =~ ^[0-9a-f]{64}$ ]]
if ((cert_size_dec > KSU_APK_CERT_MAX_LENGTH)); then
  echo "Manager certificate is ${cert_size_dec} bytes, but the pinned SukiSU APK verifier accepts at most ${KSU_APK_CERT_MAX_LENGTH}" >&2
  exit 1
fi

{
  printf '\nKEYSTORE_PASSWORD=%s\n' "${keystore_password}"
  printf 'KEY_ALIAS=%s\n' "${MANAGER_KEY_ALIAS}"
  printf 'KEY_PASSWORD=%s\n' "${key_password}"
  printf 'KEYSTORE_FILE=%s\n' "$(basename "${keystore_file}")"
} >> "${manager_dir}/gradle.properties"

echo "Publishing patched libsu modules to Maven Local"
(
  cd "${LIBSU_DIR}"
  ./gradlew --no-daemon \
    :core:publishToMavenLocal \
    :service:publishToMavenLocal \
    :nio:publishToMavenLocal \
    :io:publishToMavenLocal
)

echo "Building patched SukiSU manager"
(
  cd "${manager_dir}"
  KSU_OWNER_PATCHED_MANAGER=1 \
    KSU_OWNER_VERSION_CODE="${SUKISU_VERSION_CODE}" \
    ./gradlew --no-daemon clean assembleRelease
)

echo "Building the pinned arm64 ksud payload"
rustup target add aarch64-linux-android
(
  cd "${SUKISU_MANAGER_DIR}"
  # shellcheck disable=SC1091
  source .github/scripts/setup-rust-build.sh aarch64-linux-android 26
  cargo build \
    --target aarch64-linux-android \
    --release \
    --manifest-path userspace/ksud/Cargo.toml
)

project_short_sha="$(git -C "${ROOT_DIR}" rev-parse --short=7 HEAD)"
manager_output_name="SukiSU-${MANAGER_VERSION}-PAIRED-${project_short_sha}"

echo "Repacking the arm64 manager with its matching ksud"
(
  cd "${SUKISU_MANAGER_DIR}"
  python3 repack_apk.py repack \
    --app-build-type release \
    --ksud-build-type release \
    --arch arm64-v8a \
    --output-name "${manager_output_name}" \
    --keystore-path "${keystore_file}" \
    --key-alias "${MANAGER_KEY_ALIAS}" \
    --keystore-pass "${keystore_password}" \
    --key-pass "${key_password}" \
    --strip
)

manager_apk_source="${SUKISU_MANAGER_DIR}/dist/${manager_output_name}.apk"
manager_apk_name="${manager_output_name}.apk"
manager_apk="${DIST_DIR}/${manager_apk_name}"
test -s "${manager_apk_source}"
cp "${manager_apk_source}" "${manager_apk}"

apksigner_bin="${ANDROID_SDK_ROOT}/build-tools/37.0.0/apksigner"
test -x "${apksigner_bin}"
"${apksigner_bin}" verify --verbose --print-certs "${manager_apk}" \
  > "${DIST_DIR}/patched-manager-signature.txt"
sed -n '1,$p' "${DIST_DIR}/patched-manager-signature.txt"
actual_cert_hash="$(
  awk -F ': ' \
    '/certificate SHA-256 digest:/ { print tolower($NF); exit }' \
    "${DIST_DIR}/patched-manager-signature.txt"
)"
[[ "${actual_cert_hash}" == "${cert_hash}" ]] || {
  echo "Manager certificate mismatch: expected ${cert_hash}, got ${actual_cert_hash:-missing}" >&2
  exit 1
}
unzip -Z1 "${manager_apk}" > "${DIST_DIR}/patched-manager-contents.txt"
grep -Fx 'lib/arm64-v8a/libksud.so' \
  "${DIST_DIR}/patched-manager-contents.txt" > /dev/null

cat > "${DIST_DIR}/patched-manager-build-info.txt" <<EOF
manager_version=${MANAGER_VERSION}
manager_version_code=${SUKISU_VERSION_CODE}
manager_package=com.sukisu.ultra
sukisu_commit=${SUKISU_COMMIT}
libsu_commit=${MANAGER_LIBSU_COMMIT}
libsu_version=${LIBSU_PATCH_VERSION}
libsu_fix=main_jar_read_only_before_app_process
manager_certificate_size=${cert_size_hex}
manager_certificate_sha256=${cert_hash}
manager_certificate_verifier_limit=${KSU_APK_CERT_MAX_LENGTH}
manager_private_key_retained=no
manager_private_key_uploaded=no
paired_project_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)
EOF

cat > "${DIST_DIR}/paired-manager.env" <<EOF
KSU_EXPECTED_SIZE2=${cert_size_hex}
KSU_EXPECTED_HASH2=${cert_hash}
PATCHED_MANAGER_APK=${manager_apk_name}
EOF

(
  cd "${DIST_DIR}"
  sha256sum \
    "${manager_apk_name}" \
    patched-manager-build-info.txt \
    patched-manager-contents.txt \
    patched-manager-signature.txt \
    > PATCHED_MANAGER_SHA256SUMS
)

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "KSU_EXPECTED_SIZE2=${cert_size_hex}"
    echo "KSU_EXPECTED_HASH2=${cert_hash}"
    echo "PATCHED_MANAGER_APK=${manager_apk_name}"
  } >> "${GITHUB_ENV}"
fi

echo "Patched manager: ${manager_apk_name}"
echo "Paired certificate: size=${cert_size_hex} sha256=${cert_hash}"
