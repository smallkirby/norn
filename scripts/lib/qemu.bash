#!/bin/bash

[ -n "${H_GUARD_QEMU:-}" ] && return
readonly H_GUARD_QEMU=1

export QEMU_PID
export QEMU_RETVAL

source "$(dirname "$0")/lib/util.bash"

QEMU=qemu-system-x86_64
BIOS=/usr/share/ovmf/OVMF.fd

NUM_CORES=3
CPU_MODEL=qemu64
CPU_FEATURES=(
  "+fsgsbase"
  "+avx"
  "+avx2"
  "+xsave"
  "+xsaveopt"
  "+bmi1"
)
MEMORY=512M

DEVICES=(
  "nec-usb-xhci,id=xhci"
  "usb-kbd,bus=xhci.0"
  "isa-debug-exit,iobase=0xF0,iosize=0x01"
)

declare -g _qemu_monitor_socket

function qemu_print_version
{
  echo_normal "QEMU version: $(qemu-system-x86_64 --version | head -n 1)"
}

# Start QEMU.
#
# QEMU process ID will be stored in the global variable QEMU_PID.
#
# arg1: Path to the directory mounted as the root filesystem by EFI.
# arg2: Path to the UNIX socket for the QEMU monitor.
# arg3: Path to the log file for QEMU output.
# arg4: Timeout in seconds.
function qemu_start()
{
  if [[ $# -ne 4 ]]; then
    echo "Usage: ${FUNCNAME[0]}(): <EFI root dir> <monitor socket> <log file> <timeout>"
    return 1
  fi

  local efi_root_dir="$1"
  _qemu_monitor_socket="$2"
  local log_file="$3"
  local timeout="$4"

  local device_string=""
  for dev in "${DEVICES[@]}"; do
    device_string+=" -device $dev"
  done

  echo_normal "Starting QEMU..."
  echo_normal "  EFI directory  : $efi_root_dir"
  echo_normal "  Monitor socket : $_qemu_monitor_socket"
  echo_normal "  Log file       : $log_file"
  echo_normal "  Timeout        : $timeout seconds"
  echo_normal "  CPU model      : $CPU_MODEL"
  echo_normal "  CPU features   : ${CPU_FEATURES[*]}"

  timeout --foreground "$timeout" \
    "$QEMU" \
      -m "$MEMORY" \
      -bios "$BIOS" \
      -drive file=fat:rw:"$efi_root_dir",format=raw \
      -nographic \
      -serial mon:stdio \
      -monitor unix:"$_qemu_monitor_socket",server,nowait \
      -no-reboot \
      -cpu "$CPU_MODEL","$(IFS=,; echo "${CPU_FEATURES[*]}")" \
      -smp "$NUM_CORES" \
      -d guest_errors \
      $device_string \
    2>&1 | tee "$log_file" &
  QEMU_PID=$!

  sleep 1

  if ! pgrep "qemu" > /dev/null; then
    echo_error "Failed to start QEMU."
    return 1
  fi
}

function qemu_sendkey()
{
  if [[ $# -ne 1 ]]; then
    echo_error "Usage: ${FUNCNAME[0]}(): <key>"
    return 1
  fi

  local key="$1"
  echo_normal "Sending key: $key"
  echo "sendkey $key" | socat - "$_qemu_monitor_socket"
}

# Exit QEMU gracefully.
#
# If QEMU is not running, this function does nothing.
function qemu_exit()
{
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    return
  fi

  echo_normal "Quitting QEMU..."
  echo "quit" | socat - "$_qemu_monitor_socket"
  qemu_wait
}

# Wait for QEMU to finish and capture its exit code.
#
# The exit code will be stored in the global variable QEMU_RETVAL.
function qemu_wait()
{
  wait "$QEMU_PID" || true
  QEMU_RETVAL=$?
}
