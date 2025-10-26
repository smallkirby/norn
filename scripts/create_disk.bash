#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/lib/util.bash"

if [ "$#" -ne 4 ]; then
  echo_error "Usage: $0 <copy src> <output> <start MiB> <size MiB>"
  exit 1
fi

SECTOR_SIZE=512
MiB=$((1024 * 1024))
GiB=$((1024 * MiB))

cpsrc=$1
out=$2
start_mib=$3
size_mib=$4

if [ ! -f "$out" ]; then
  echo_normal "Creating disk image: $out"
  block_size=1024
  dd \
    if=/dev/zero \
    of="$out" \
    bs=$block_size \
    count=$((2 * GiB / block_size))
fi

function copy()
{
  if [ "$#" -ne 2 ]; then
    echo_error "copy() requires 2 arguments"
    exit 1
  fi

  local src=$1
  local dst=$2

  # explicitly allow globbing
  mcopy \
    -i "$out"@@$((start_mib * MiB)) \
    -o \
    -s \
    $src \
    "::${dst#/}"
}

echo_normal "Creating EFI System Partition"
parted -s "$out" mklabel gpt
parted -s "$out" mkpart EFI FAT32 ${start_mib}MiB ${size_mib}MiB
parted -s "$out" set 1 esp on

echo_normal "Formatting FAT32 filesystem"
mkfs.vfat \
  -F 32 \
  -n "EFI" \
  --offset=$((start_mib * MiB / SECTOR_SIZE)) \
  "$out" \
  1>/dev/null

echo_normal "Setting up contents"
copy "$cpsrc/*" /

echo_normal "Done"
