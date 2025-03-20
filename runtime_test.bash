#!/bin/bash

set -o pipefail

NUM_CORES=3
CPU_MODEL=qemu64
CPU_FEATURES=fsgsbase

TIMEOUT=60
TMPFILE=$(mktemp)

SUCCESS_HEYSTACKS=(
  "Unhandled syscall (nr=18446744073709551615)"
  "[1]=0000000000000000 [2]=0000000000000001"
  "[3]=0000000000000002 [4]=0000000000000003"
)

function check_success()
{
  ret=0

  for needle in "${SUCCESS_HEYSTACKS[@]}"; do
    if ! grep -qF "$needle" "$TMPFILE"; then
      echo "[-] Missing: $needle"
      ret=1
    fi
  done

  return $ret
}

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
  -cpu $CPU_MODEL,+$CPU_FEATURES \
  -smp $NUM_CORES \
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

echo "[+] Checking output..."
if ! check_success; then
  echo "[-] Output does not contain expected strings."
  cleanup
  exit 1
fi
echo "[+] All expected strings found."

cleanup
