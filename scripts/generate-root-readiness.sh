#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <kernel.config> <applied-patches.txt> <kernel-release> <output>" >&2
  exit 2
fi

config_file="$1"
patches_file="$2"
kernel_release="$3"
output_file="$4"

test -s "${config_file}"
test -s "${patches_file}"
test -n "${kernel_release}"

require_config() {
  local setting="$1"

  grep -Fqx "${setting}" "${config_file}" || {
    echo "Root-readiness input is missing required config: ${setting}" >&2
    exit 1
  }
}

require_patch() {
  local patch="$1"

  grep -Fqx "${patch}" "${patches_file}" || {
    echo "Root-readiness input is missing required patch: ${patch}" >&2
    exit 1
  }
}

[[ "${kernel_release}" == 4.19.* ]] || {
  echo "Root-readiness audit only supports the Linux 4.19 baseline: ${kernel_release}" >&2
  exit 1
}

require_config 'CONFIG_KSU=y'
require_config 'CONFIG_KSU_MANUAL_SU=y'
require_config '# CONFIG_KPM is not set'
require_config 'CONFIG_SECURITY_SELINUX=y'
require_patch 'sukisu-v4.1.3-linux-4.19/0014-feature-report-selinux_hide-unsupported-on-Linux-4.1.patch'
require_patch 'sukisu-v4.1.3-linux-4.19/0015-sukisu-restore-experimental-Linux-4.19-SELinux-rules.patch'
require_patch 'sukisu-v4.1.3-linux-4.19/0017-selinux-use-pre-install-policy-hook-on-Linux-4.19.patch'
require_patch 'sukisu-v4.1.3-linux-4.19/0018-arm64-use-build-time-dispatcher-on-Linux-4.19.patch'
require_patch 'sukisu-v4.1.3-linux-4.19/0019-supercall-expose-install-fd-seccomp-exception.patch'
require_patch 'sukisu-v4.1.3-linux-4.19/0020-compat-adapt-ksud-hooks-to-dispatcher-signature.patch'
require_patch 'kernel-lineage-23.2/0004-selinux-inject-KSU-rules-before-policy-install.patch'
require_patch 'kernel-lineage-23.2/0005-arm64-reserve-build-time-SukiSU-dispatcher.patch'
require_patch 'kernel-lineage-23.2/0006-arm64-allow-SukiSU-install-fd-supercall-through-sec.patch'

if grep -Eq '^CONFIG_(KSU_)?SUSFS=y$' "${config_file}" ||
   grep -Eiq '(^|/)susfs([^/]*)(/|$)' "${patches_file}"; then
  echo "Root-readiness audit found an unexpected SUSFS input" >&2
  exit 1
fi

manager_signature_mode=official_only
paired_manager_certificate_size=none
paired_manager_certificate_sha256=none
if [[ -n "${KSU_EXPECTED_SIZE2:-}" || -n "${KSU_EXPECTED_HASH2:-}" ]]; then
  [[ "${KSU_EXPECTED_SIZE2:-}" =~ ^0x[0-9a-fA-F]{4}$ ]] || {
    echo "Invalid paired Manager certificate size: ${KSU_EXPECTED_SIZE2:-unset}" >&2
    exit 1
  }
  if ((KSU_EXPECTED_SIZE2 > 1024)); then
    echo "Paired Manager certificate exceeds the pinned SukiSU verifier's 1024-byte limit" >&2
    exit 1
  fi
  [[ "${KSU_EXPECTED_HASH2:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Invalid paired Manager certificate SHA-256" >&2
    exit 1
  }
  manager_signature_mode=official_plus_paired_ephemeral
  paired_manager_certificate_size="${KSU_EXPECTED_SIZE2}"
  paired_manager_certificate_sha256="${KSU_EXPECTED_HASH2}"
fi

cat > "${output_file}" <<EOF
image_compiled=yes
flashable_package=no
code_restored=yes
compile_checks_passed=yes
device_boot_test=diagnostic_variant_only
root_functional_test=no
root_verified_on_device=no
ready_for_owner_device_experimental_test=yes
selinux_ksu_domain=created_by_code_compile_checked_device_unverified
selinux_ksu_file_context=created_by_code_compile_checked_device_unverified
selinux_boot_rules=restored_compile_checked_device_unverified
dynamic_sepolicy=disabled_on_linux_4_19_pending_safe_copy_on_write
selinux_hide=unsupported
selinux_enforcing=required
ksu_domain_permissive=no
wildcard_allow=no
legacy_policy_mutation=none_active_policy_is_not_modified
kpm=disabled
susfs=absent
manager_signature_mode=${manager_signature_mode}
paired_manager_certificate_size=${paired_manager_certificate_size}
paired_manager_certificate_sha256=${paired_manager_certificate_sha256}
release_ready=no
kernel_release=${kernel_release}
evidence_config=CONFIG_KSU=y,CONFIG_KSU_MANUAL_SU=y,CONFIG_SECURITY_SELINUX=y,CONFIG_KPM=n
evidence_boot_rules=security_load_policy_calls_KSU_on_private_policydb_before_native_locked_install
evidence_dynamic_sepolicy=handle_sepolicy_returns_EOPNOTSUPP_on_Linux_4.19
evidence_syscall_dispatcher=ARM64_slot_244_initialized_at_link_time_no_runtime_table_write
evidence_manager_transport=only_the_exact_install_fd_reboot_magic_bypasses_app_seccomp
risk=Build_time_dispatcher_requires_owner_device_boot_Manager_and_Root_validation
notice=The_no_dispatcher_diagnostic_booted;_the_functional_build_time_dispatcher_still_requires_owner_device_testing.
EOF

test -s "${output_file}"
