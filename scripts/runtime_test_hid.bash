#!/bin/bash

######################################
#
# HID keyboard runtime test.
#
######################################

set -euo pipefail

source "$(dirname "$0")/lib/qemu.bash"
source "$(dirname "$0")/lib/util.bash"

TIMEOUT=60
TMPFILE=$(mktemp)

if [ $# -eq 0 ]; then
  MONITOR_SOCKET="/tmp/qemu-monitor-rtt-hid-$$"
elif [ $# -eq 1 ]; then
  MONITOR_SOCKET="$1"
else
  echo_error "Usage: $0 [socket_path]"
  echo_error "  socket_path: Path to UNIX socket for QEMU monitor communication (optional)"
  echo_error "    Default: /tmp/qemu-monitor-rtt-hid-\$\$"
  exit 1
fi

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
      echo_error "Missing: '$needle'"
      ret=1
    fi
  done

  return $ret
}

_terminated=0
function cleanup() {
  if [ $_terminated -eq 1 ]; then
    return
  fi
  _terminated=1

  echo ""
  echo_normal "Cleaning up..."

  if [ -n "${QEMU_PID:-}" ] ; then
    qemu_exit
  fi
  rm -f "$TMPFILE" "$MONITOR_SOCKET"

  echo_normal "Cleanup done."
}
trap cleanup EXIT INT

function wait_for_usb_initialization() {
  echo_normal "Waiting for USB initialization..."
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
        echo_normal "USB initialization detected: '$indicator'"
        return 0
      fi
    done

    sleep 1
    ((wait_count++))

    # Show progress every 5 seconds
    if [ $((wait_count % 5)) -eq 0 ]; then
      echo_normal "Still waiting for USB initialization... (${wait_count}s)"
    fi
  done

  echo_error "USB initialization not detected within ${max_wait} seconds"
  return 1
}

function main()
{
  qemu_print_version

  qemu_start \
    "$(pwd)/zig-out/img" \
    "$MONITOR_SOCKET" \
    "$TMPFILE" \
    "$TIMEOUT"

  # Wait for USB initialization to complete
  if ! wait_for_usb_initialization; then
    echo_error "USB initialization failed or timed out"
    exit 1
  fi

  # Test HID keyboard functionality
  if [ -S "$MONITOR_SOCKET" ]; then
    echo_normal "Testing HID keyboard input via monitor socket..."

    qemu_sendkey "a"
    sleep 0.5
    qemu_sendkey "b"
    sleep 0.5
    qemu_sendkey "spc"
    sleep 0.5

    sleep 1
    qemu_exit
  else
    echo_error "Monitor socket not available. Cannot test HID keyboard."
    exit 1
  fi

  qemu_wait

  echo ""

  if [ "$QEMU_RETVAL" -eq 124 ]; then
    echo_error "Timeout."
    exit 1
  fi
  local ret=$((QEMU_RETVAL >> 1))
  if [ $((ret << 1)) -ne 0 ]; then
    echo_error "QEMU exited with error code $ret."
    exit 1
  fi

  echo_normal "Checking HID keyboard functionality..."
  if ! check_hid_success; then
    echo_error "HID keyboard test failed."
    echo_error "USB HID messages ---"
    grep -i "hid\|usb.*keyboard" "$TMPFILE" | head -5 || echo "  (none found)"
    echo_error "Key events ---"
    grep -i "key.*pressed\|key.*released" "$TMPFILE" | head -5 || echo "  (none found)"
    exit 1
  fi

  echo_normal "HID keyboard functionality verified."
  echo_normal "Key events detected ---"
  grep -i "key.*pressed\|key.*released" "$TMPFILE" | head -5
}

main "$@"
