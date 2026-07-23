#!/bin/sh

properties() { '
kernel.string=LineageOS 23.2 + SukiSU-Ultra for OnePlus 8T
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=kebab
supported.versions=16
supported.patchlevels=
'; }

BLOCK=/dev/block/bootdevice/by-name/boot
IS_SLOT_DEVICE=1
SLOT_SELECT=active
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=0
NO_MAGISK_CHECK=1

. tools/ak3-core.sh

# Read the active slot's current boot image, replace only its kernel, and let
# magiskboot repack against the original image. No ramdisk tree is unpacked,
# and no replacement dtb/dtbo is shipped, so the original ramdisk, embedded
# DTB, boot header fields, and AVBv2 flags remain the repack inputs.
split_boot
flash_boot
