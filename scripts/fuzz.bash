#!/bin/bash

set -uo pipefail

source "$(dirname "$0")/lib/util.bash"

OPTIMIZE=${OPTIMIZE:-Debug}
BOOTPARAM="${BOOTPARAM:-assets/boot/bootparams}"
HEYSTACK=${HEYSTACK:-"Reached end of main"}
LOGFILE=${LOGFILE:-"/tmp/norn-fuzz.log"}
SHIFT=${SHIFT:-5}
MAX=${MAX:-1000000}

echo_normal "===== Build Information ======="
echo_normal "Optimization    : $OPTIMIZE"
echo_normal "Boot Parameters : $BOOTPARAM"
echo_normal "==============================="

echo_normal "Building binary."
zig build install \
  -Dlog_level=debug \
  -Druntime_test \
  -Doptimize="$OPTIMIZE" \
  -Ddebug_exit=false

echo_normal "Updating boot parameters."
zig build update-bootparams \
  -Dbootparams="$BOOTPARAM"

echo_normal "Starting fuzzing session."

counter=0

while true; do
  counter=$((counter + 1))

  echo_normal "iter: $counter"

  "$QEMU" \
    -m "$MEMORY" \
    -bios "$BIOS" \
    -drive file=zig-out/diskimg,format=raw,if=virtio,media=disk \
    -nographic \
    -serial mon:stdio \
    -no-reboot \
    -cpu "$CPU_MODEL","$(IFS=,; echo "${CPU_FEATURES[*]}")" \
    -smp "$NUM_CORES" \
    -d guest_errors \
    -device nec-usb-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device isa-debug-exit,iobase=0xF0,iosize=0x01 \
    -icount shift="$SHIFT" \
    -s \
  2>&1 | tee "$LOGFILE"

  if ! grep -qF -- "$HEYSTACK" "$LOGFILE"; then
    echo_error "Success indicator NOT found in log. Exiting."
    exit 1
  fi

  if [ "$counter" -ge "$MAX" ]; then
    echo_normal "Reached maximum iteration count ($MAX). Exiting."
    exit 0
  fi
done
