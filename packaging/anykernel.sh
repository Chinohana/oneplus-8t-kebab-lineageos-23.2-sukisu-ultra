#!/bin/sh

properties() { '
kernel.string=LineageOS 23.2 + SukiSU-Ultra for OnePlus 8T
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=kebab
supported.versions=16
supported.patchlevels=
'; }

block=/dev/block/bootdevice/by-name/boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

. tools/ak3-core.sh

split_boot
flash_boot
