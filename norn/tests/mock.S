# This file defines a set of mock symbols for unit tests.

# ==============================================
# Required by norn/mem/resource.zig
# ==============================================

.global __norn_data_start
.global __norn_data_end
.global __norn_rodata_start
.global __norn_rodata_end
.global __norn_bss_start
.global __norn_bss_end
.global __norn_text_start
.global __norn_text_end

.section .data
.align 8
__norn_text_start:
__norn_text_end:
__norn_data_start:
__norn_data_end:
__norn_rodata_start:
__norn_rodata_end:
__norn_bss_start:
__norn_bss_end:
  .quad 0
