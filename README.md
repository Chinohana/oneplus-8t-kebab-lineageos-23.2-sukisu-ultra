# OnePlus 8T (kebab) LineageOS 23.2 + KernelSU-Next

This repository builds the official LineageOS 23.2 kernel for the OnePlus 8T (`kebab`) with KernelSU-Next entirely in GitHub Actions.

## Compatibility

- Device: OnePlus 8T (`kebab`)
- ROM base: LineageOS 23.2
- Kernel source: `LineageOS/android_kernel_oneplus_sm8250`, branch `lineage-23.2`
- Kernel: Linux 4.19
- KernelSU-Next: `v1.1.1` by default

KernelSU-Next `v3.0.1` removed legacy Linux 4.x support. Do not select a 3.x ref for this 4.19 kernel unless upstream restores compatibility and you have verified it yourself.

## Build with GitHub Actions

1. Open **Actions**.
2. Select **Build kebab kernel with KernelSU-Next**.
3. Choose **Run workflow**.
4. Keep the defaults for an official LineageOS 23.2 build, or provide explicit source refs.
5. Download the build artifact after the job succeeds.

Every artifact contains:

- `Image`: raw arm64 kernel image
- `kebab-lineage-23.2-kernelsu-next-*.zip`: AnyKernel3 flashable package
- `build-info.txt`: resolved kernel and KernelSU-Next commit SHAs, compiler version, and kernel release
- `.config`: final build configuration

## Flashing warning

Unlocking the bootloader and flashing a custom kernel can erase data or make the device unbootable. Back up the current `boot` partition and keep a known-good LineageOS 23.2 boot image available. The ZIP is restricted to `kebab`, but you are responsible for matching it to your installed LineageOS build. Test booting or keep fastboot recovery access before relying on the kernel.

Install the KernelSU-Next manager version compatible with the kernel after flashing.

## Reproducibility

The workflow defaults are intentionally pinned where compatibility matters. The LineageOS branch is resolved to an exact commit at build time, and the artifact records that SHA. KernelSU-Next defaults to the last known 4.x-compatible release rather than the latest release.

## Upstream projects

- [LineageOS OnePlus sm8250 kernel](https://github.com/LineageOS/android_kernel_oneplus_sm8250)
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
