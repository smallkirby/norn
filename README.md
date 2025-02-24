# Norn

![Zig](https://shields.io/badge/Zig-v0%2E13%2E0-blue?logo=zig&color=F7A41D&style=for-the-badge)

![Lint](https://github.com/smallkirby/norn/actions/workflows/lint.yml/badge.svg)
![Unit Tests](https://github.com/smallkirby/norn/actions/workflows/unittest.yml/badge.svg)
![Runtime Tests](https://github.com/smallkirby/norn/actions/workflows/runtimetest.yml/badge.svg)

## Development

```bash
# Run on QEMU
zig build run -Dlog_level=debug --summary all -Druntime_test -Doptimize=Debug
# Unit Test
zig build test --summary all -Druntime_test=true
```

### Options

| Option | Type | Description |
|---|---|---|
| `optimize` | String: `Debug`, `ReleaseFast`, `ReleaseSmall` | Optimization level. |
| `log_level` | String: `debug`, `info`, `warn`, `error` | Logging level. Output under the logging level is suppressed. |
| `runtime_test` | Flag | Run runtime tests. |
| `wait_qemu` | Flag | Make QEMU wait for being attached by GDB. |
| `debug_intr` | Flag | Print all interrupts and exceptions for debugging. |
| `debug_exit` | Flag | Add `isa-debug-exit` device. When enabled, Norn can terminate QEMU with arbitrary exit code. |

## LICENSE

[Licnesed under the MIT License](LICENSE) unless otherwise specified.
