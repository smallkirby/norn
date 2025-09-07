#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/lib/qemu.bash"
source "$(dirname "$0")/lib/util.bash"

TIMEOUT=60
TMPFILE=$(mktemp)
MONITOR_SOCKET="/tmp/qemu-monitor-rtt-hid-$$"

# Success indicator for the default init binary.
DEFAULT_INIT_HEYSTACK=(
  "info(user): Hello, from userland!"
  "error(user): PANIC: Reached end of main. panic"
  "[DEBUG] syscall | exit_group(): status=99"
)
# Success indicator for "/bin/busybox ls -la".
BUSYBOX_LS_HEYSTACK=(
  "1 0        0               30 Jan  1 00:00 .gitignore"
  "1 0        0                1 Jan  1 00:00 bin"
  "1 0        0                2 Jan  1 00:00 dir1"
  "1 0        0               13 Jan  1 00:00 hello.txt"
  "1 0        0                2 Jan  1 00:00 sbin"
)

# Check the num of arguments
if [ $# -gt 2 ]; then
  echo_err "Usage: $0 <init binary name>"
  exit 1
fi
if [ $# -eq 1 ]; then
  INIT_BINARY=$1
else
  INIT_BINARY="/sbin/init"
fi
echo_normal "Using init binary: $INIT_BINARY"

# Check if the init binary is available.
case $INIT_BINARY in
  "/sbin/init")
    SUCCESS_HEYSTACKS=("${DEFAULT_INIT_HEYSTACK[@]}")
    ;;
  "/bin/busybox")
    SUCCESS_HEYSTACKS=("${BUSYBOX_LS_HEYSTACK[@]}")
    ;;
  *)
    echo_error "Unknown init binary: $INIT_BINARY"
    exit 1
    ;;
esac

# Check the output for expected strings.
function check_success()
{
  ret=0

  for needle in "${SUCCESS_HEYSTACKS[@]}"; do
    if ! (sed -e 's/\x1b\[[0-9;]*m//g' "$TMPFILE" | grep -qF -- "$needle"); then
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

function main()
{
  qemu_print_version

  qemu_start \
    "$(pwd)/zig-out/img" \
    "$MONITOR_SOCKET" \
    "$TMPFILE" \
    "$TIMEOUT"
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

  echo_normal "Checking output..."
  if ! check_success; then
    echo_error "Output does not contain expected strings."
    exit 1
  fi
  echo_normal "All expected strings found."
}

main "$@"
