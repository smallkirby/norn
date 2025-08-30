# Norn

![Zig](https://shields.io/badge/Zig-v0%2E15%2E1-blue?logo=zig&color=F7A41D&style=for-the-badge)

![Lint](https://github.com/smallkirby/norn/actions/workflows/lint.yml/badge.svg)
![Unit Tests](https://github.com/smallkirby/norn/actions/workflows/unittest.yml/badge.svg)
![Runtime Tests (init)](https://github.com/smallkirby/norn/actions/workflows/runtimetest-testinit.yml/badge.svg)
![Runtime Tests (busybox)](https://github.com/smallkirby/norn/actions/workflows/runtimetest-busybox.yml/badge.svg)
![Runtime Tests (USB HID driver)](https://github.com/smallkirby/norn/actions/workflows/runtimetest-hid.yml/badge.svg)

## Development

```bash
# Run on QEMU
zig build run -Dlog_level=debug --summary all -Druntime_test -Doptimize=Debug
# Unit Test
zig build test --summary all -Druntime_test=true
```

### Options

| Option | Type | Description | Default |
|---|---|---|---|
| `debug_exit` | Flag | Add `isa-debug-exit` device. When enabled, Norn can terminate QEMU with arbitrary exit code. | `false` |
| `debug_intr` | Flag | Print all interrupts and exceptions for debugging. | `false` |
| `debug_syscall` | Flag | Print context for the unhandled or ignored syscalls. | `false` |
| `graphics` | Flag | Enable QEMU graphical output. | `false` |
| `init_binary` | String | Path to the init binary within rootfs. | `/sbin/init` |
| `log_level` | String: `debug`, `info`, `warn`, `error` | Logging level. Output under the logging level is suppressed. | `info` |
| `no_kvm` | Flag | Disable KVM. | `false` |
| `optimize` | String: `Debug`, `ReleaseFast`, `ReleaseSmall` | Optimization level. | `Debug` |
| `runtime_test` | Flag | Run runtime tests. | `false` |
| `wait_qemu` | Flag | Make QEMU wait for being attached by GDB. | `false` |

## LICENSE

[Licensed under the MIT License](LICENSE) unless otherwise specified.
