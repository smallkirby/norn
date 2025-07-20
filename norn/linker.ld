KERNEL_VADDR_BASE = 0xFFFFFFFF80000000;
KERNEL_VADDR_TEXT = 0xFFFFFFFF80100000;

STACK_SIZE = 0x5000;

PHDRS {
    text PT_LOAD FLAGS(3);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
    percpu PT_LOAD FLAGS(4);
    bss PT_LOAD FLAGS(6);

    __early_stack PT_LOAD FLAGS(6);
}

SECTIONS {
    . = KERNEL_VADDR_TEXT;

    __per_cpu_start = .;
    .data..percpu 0 : AT (__per_cpu_start - KERNEL_VADDR_BASE) {
        KEEP(*(.data..percpu))
    } :percpu
    __per_cpu_end = __per_cpu_start + SIZEOF(.data..percpu);
    . = __per_cpu_end;

    .text ALIGN(4K) : AT (ADDR(.text) - KERNEL_VADDR_BASE) {
        __norn_text_start = .;
        *(.text)
        *(.ltext)
        __norn_text_end = .;
    } :text

    .rodata ALIGN(4K) : AT (ADDR(.rodata) - KERNEL_VADDR_BASE) {
        __norn_rodata_start = .;

        *(.rodata)

        . = ALIGN(0x10);
        __module_init_start = .;
        KEEP(*(.module.init))
        __module_init_end = .;

        __norn_rodata_end = .;
    } :rodata

    .data ALIGN(4K) : AT (ADDR(.data) - KERNEL_VADDR_BASE) {
        __norn_data_start = .;
        *(.data)
        *(.ldata)
        __norn_data_end = .;
    } :data

    .bss ALIGN(4K) : AT (ADDR(.bss) - KERNEL_VADDR_BASE) {
        __norn_bss_start = .;
        *(COMMON)
        *(.bss)
        *(.lbss)
        __norn_bss_end = .;
    } :bss

    __early_stack ALIGN(4K) (NOLOAD) : AT (ADDR(__early_stack) - KERNEL_VADDR_BASE) {
        . += STACK_SIZE;
    } :__early_stack
    __early_stack_bottom  = .;
}
