#!/bin/bash

set -o pipefail

TIMEOUT=60
TMPFILE=$(mktemp)

function cleanup()
{
  rm -f "$TMPFILE"
  set +o pipefail
}

echo "[+] stdout/stderr will be saved to $TMPFILE"

echo "[+] Running Norn on QEMU..."
timeout --foreground $TIMEOUT  \
qemu-system-x86_64 \
  -m 512M \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=fat:rw:zig-out/img,format=raw \
  -nographic \
  -serial mon:stdio \
  -no-reboot \
  -smp 1 \
  -device isa-debug-exit,iobase=0xF0,iosize=0x01 \
  2>&1 \
| tee "$TMPFILE"

ret=$?

echo ""

if [ $ret -eq 124 ]; then
  echo "[-] Timeout."
  cleanup
  exit 1
fi
if [ $((ret >> 1 << 1)) -ne 0 ]; then
  echo "[-] QEMU exited with error code $((ret >> 1))."
  cleanup
  exit 1
fi

echo "[+] QEMU exited with code 0."
cleanup
