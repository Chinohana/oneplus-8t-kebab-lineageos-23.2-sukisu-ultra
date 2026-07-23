#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <project-root> <kernel-dir> <sukisu-dir>" >&2
  exit 2
fi

project_root="$1"
kernel_dir="$2"
sukisu_dir="$3"
rules_file="${sukisu_dir}/kernel/selinux/rules.c"
audit_output="${project_root}/dist/static-audit.txt"

test -s "${rules_file}"
mkdir -p "$(dirname "${audit_output}")"

count_series_entries() {
  local series_file="$1"

  grep -Evc '^[[:space:]]*(#|$)' "${series_file}"
}

kernel_patch_count="$(
  count_series_entries "${project_root}/patches/kernel-lineage-23.2/series"
)"
sukisu_patch_count="$(
  count_series_entries "${project_root}/patches/sukisu-v4.1.3-linux-4.19/series"
)"
total_patch_count=$((kernel_patch_count + sukisu_patch_count))

[[ "${kernel_patch_count}" -eq 3 ]]
[[ "${sukisu_patch_count}" -eq 16 ]]
[[ "${total_patch_count}" -eq 19 ]]

grep -Fq 'db = &selinux_state.ss->policydb;' "${rules_file}"
grep -Fq 'SukiSU-4.19: SELinux boot rule application begin' "${rules_file}"
grep -Fq 'SukiSU-4.19: SELinux boot rule application succeeded' "${rules_file}"
grep -Fq 'SukiSU-4.19: dynamic sepolicy request begin' "${rules_file}"
grep -Fq 'SukiSU-4.19: dynamic sepolicy rejected wildcard allow' "${rules_file}"
grep -Fq 'SukiSU-4.19: dynamic sepolicy rejected permissive request' "${rules_file}"

if grep -Fq 'KernelSU SELinux policy mutation is unsupported on this kernel' \
  "${rules_file}"; then
  echo "Linux 4.19 apply_kernelsu_rules is still an unsupported stub" >&2
  exit 1
fi

if grep -Eq 'ksu_permissive[[:space:]]*\([[:space:]]*db[[:space:]]*,[[:space:]]*KERNEL_SU_DOMAIN' \
  "${rules_file}"; then
  echo "The fixed ksu domain is unexpectedly permissive" >&2
  exit 1
fi

if grep -Eq 'ksu_allow(xperm)?[[:space:]]*\([^;]*(^|[^[:alnum:]_])ALL([^[:alnum:]_]|$)' \
  "${rules_file}"; then
  echo "An unbounded wildcard allow remains in the final SukiSU rules" >&2
  exit 1
fi

if grep -REq \
  'setenforce[[:space:]]*\([[:space:]]*(false|0)[[:space:]]*\)|enforcing[[:space:]]*=[[:space:]]*(false|0)' \
  "${sukisu_dir}/kernel"; then
  echo "An unconditional SELinux permissive path was found" >&2
  exit 1
fi

if git -C "${sukisu_dir}" grep -Eiq '(^|[^[:alnum:]_])susfs([^[:alnum:]_]|$)' -- kernel ||
   git -C "${kernel_dir}" grep -Eiq '(^|[^[:alnum:]_])susfs([^[:alnum:]_]|$)' -- .; then
  echo "Unexpected SUSFS source was found" >&2
  exit 1
fi

cat > "${audit_output}" <<EOF
patch_replay_count=${total_patch_count}
kernel_patch_count=${kernel_patch_count}
sukisu_patch_count=${sukisu_patch_count}
legacy_policydb_path=present
selinux_boot_rule_implementation=present
dynamic_sepolicy_implementation=present
selinux_hide_linux_4_19=unsupported
ksu_domain_permissive=no
unconditional_permissive=no
wildcard_allow=no
susfs=absent
source_audit=passed
EOF
