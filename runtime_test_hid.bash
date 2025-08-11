#!/bin/bash

#
# HID keyboard runtime test.
#
# Usage: runtime_test_hid.bash <socket_path>
#

set -o pipefail

# Check for socket path argument or use default
if [ $# -eq 0 ]; then
  MONITOR_SOCKET="/tmp/qemu-monitor-rtt-hid-$$"
elif [ $# -eq 1 ]; then
  MONITOR_SOCKET="$1"
else
  echo "Usage: $0 [socket_path]"
  echo "  socket_path: Path to UNIX socket for QEMU monitor communication (optional)"
  echo "    Default: /tmp/qemu-monitor-rtt-hid-\$\$"
  exit 1
fi

NUM_CORES=3
CPU_MODEL=qemu64
CPU_FEATURES=+fsgsbase,+avx,+avx2,+xsave,+xsaveopt
TIMEOUT=80
TMPFILE=$(mktemp)

# HID-specific success indicators
HID_HEYSTACKS=(
  "HID Keyboard detected - Interface"
  "Key pressed: 0x04"
  "Key pressed: 0x05"
  "Key pressed: 0x2C"
)

function check_hid_success() {
  ret=0

  for needle in "${HID_HEYSTACKS[@]}"; do
    if ! grep -qF -- "$needle" "$TMPFILE"; then
      echo "[ERROR] Missing HID functionality: '$needle'"
      ret=1
    fi
  done

  return $ret
}

function cleanup() {
  rm -f "$TMPFILE" "$MONITOR_SOCKET"
  set +o pipefail
}

function send_key() {
  local key="$1"
  echo "[+] Sending key: $key"
  echo "sendkey $key" | socat - UNIX-CONNECT:"$MONITOR_SOCKET"
}

function quit() {
  echo "[+] Quitting QEMU..."
  echo "quit" | socat - UNIX-CONNECT:"$MONITOR_SOCKET"
}

function wait_for_usb_initialization() {
  echo "[+] Waiting for USB initialization..."
  local max_wait=20
  local wait_count=0

  # USB initialization indicators to look for
  local usb_init_indicators=(
    "Ready to accept inputs."
  )

  while [ $wait_count -lt $max_wait ]; do
    # Check if any USB initialization indicator is present
    for indicator in "${usb_init_indicators[@]}"; do
      if grep -qF "$indicator" "$TMPFILE" 2>/dev/null; then
        echo "[+] USB initialization detected: '$indicator'"
        return 0
      fi
    done

    sleep 1
    ((wait_count++))

    # Show progress every 5 seconds
    if [ $((wait_count % 5)) -eq 0 ]; then
      echo "[+] Still waiting for USB initialization... (${wait_count}s)"
    fi
  done

  echo "[ERROR] USB initialization not detected within ${max_wait} seconds"
  return 1
}

echo "[+] Using monitor socket: $MONITOR_SOCKET"
echo "[+] stdout/stderr will be saved to $TMPFILE"

echo "[+] QEMU version:"
qemu-system-x86_64 --version

echo "[+] Running Norn on QEMU with HID keyboard..."
timeout --foreground $TIMEOUT \
qemu-system-x86_64 \
  -m 512M \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=fat:rw:zig-out/img,format=raw \
  -device nec-usb-xhci,id=xhci \
  -device usb-kbd,bus=xhci.0 \
  -nographic \
  -serial mon:stdio \
  -monitor unix:"$MONITOR_SOCKET",server,nowait \
  -no-reboot \
  -cpu $CPU_MODEL,$CPU_FEATURES \
  -smp $NUM_CORES \
  -device isa-debug-exit,iobase=0xF0,iosize=0x01 \
  -d guest_errors \
  2>&1 | tee "$TMPFILE" &

QEMU_PID=$!

# Wait for USB initialization to complete
if ! wait_for_usb_initialization; then
  echo "[ERROR] USB initialization failed or timed out"
  cleanup
  exit 1
fi

# Test HID keyboard functionality
if [ -S "$MONITOR_SOCKET" ]; then
  echo "[+] Testing HID keyboard input via monitor socket..."

  # Send test key sequence
  send_key "a"
  sleep 0.5
  send_key "b"
  sleep 0.5
  send_key "spc"
  sleep 0.5

  # Allow time for processing
  sleep 1

  # Shutdown
  quit
else
  echo "[ERROR] Monitor socket not available. Cannot test HID keyboard."
  cleanup
  exit 1
fi

# Wait for QEMU to finish
wait $QEMU_PID 2>/dev/null || true
ret=$?

echo ""

if [ $ret -eq 124 ]; then
  echo "[-] Timeout."
  cleanup
  exit 1
fi

if [ $((ret >> 1 << 1)) -ne 0 ]; then
  echo "[ERROR] QEMU exited with error code $((ret >> 1))."
  cleanup
  exit 1
fi

echo "[+] QEMU exited with code 0."

echo "[+] Checking HID keyboard functionality..."
if ! check_hid_success; then
  echo "[ERROR] HID keyboard test failed."
  echo "[+] Output analysis:"
  echo "USB HID messages:"
  grep -i "hid\|usb.*keyboard" "$TMPFILE" | head -5 || echo "  (none found)"
  echo "Key events:"
  grep -i "key.*pressed\|key.*released" "$TMPFILE" | head -5 || echo "  (none found)"
  cleanup
  exit 1
fi

echo "[+] HID keyboard functionality verified."
echo "[+] Key events detected:"
grep -i "key.*pressed\|key.*released" "$TMPFILE" | head -5

cleanup