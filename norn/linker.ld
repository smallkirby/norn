KERNEL_VADDR_BASE = 0xFFFFFFFF80000000;
KERNEL_VADDR_TEXT = 0xFFFFFFFF80100000;

STACK_SIZE = 0x5000;

PHDRS {
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
    percpu PT_LOAD FLAGS(6);
    bss PT_LOAD;

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
        *(.text)
        *(.ltext)
    } :text

    .rodata ALIGN(4K) : AT (ADDR(.rodata) - KERNEL_VADDR_BASE) {
        *(.rodata)
    } :rodata

    .data ALIGN(4K) : AT (ADDR(.data) - KERNEL_VADDR_BASE) {
        *(.data)
        *(.ldata)
    } :data

    .bss ALIGN(4K) : AT (ADDR(.bss) - KERNEL_VADDR_BASE) {
        *(COMMON)
        *(.bss)
        *(.lbss)
    } :bss

    __early_stack ALIGN(4K) (NOLOAD) : AT (ADDR(__early_stack) - KERNEL_VADDR_BASE) {
        . += STACK_SIZE;
    } :__early_stack
    __early_stack_bottom  = .;
}
