/******************************************
 * Norn kernel's linker script.
 ******************************************/

KERNEL_PADDR_BASE   = 0x0000000000100000;
KERNEL_VADDR_BASE   = 0xFFFFFFFF80000000;
KERNEL_VADDR_PCPU   = 0x0000000000000000;

STACK_SIZE          = 0x5000;

PHDRS {
    percpu          PT_LOAD FLAGS(4); /* R-- */
    text            PT_LOAD FLAGS(5); /* R-X */
    rodata          PT_LOAD FLAGS(4); /* R-- */
    data            PT_LOAD FLAGS(6); /* RW- */
    bss             PT_LOAD FLAGS(6); /* RW- */
    __early_stack   PT_LOAD FLAGS(6); /* RW- */
}

SECTIONS {
    . = KERNEL_VADDR_BASE;

    /*
     * Per-CPU variable placeholder.
     *
     * Variables in this section is copied to each CPU's private data area after boot.
     * The virtual address must be 0 (relative to GS).
     */
    __per_cpu_start = .;
    .data..percpu KERNEL_VADDR_PCPU : AT (KERNEL_PADDR_BASE) {
        KEEP(*(.data..percpu))
    } :percpu
    __per_cpu_end = __per_cpu_start + SIZEOF(.data..percpu);
    . = __per_cpu_end;

    /*
     * Normal sections.
     *
     * These sections contain the main kernel code and data.
     * Virtual address starts at KERNEL_VADDR_BASE.
     * Physical address is (ADDR(section) - KERNEL_VADDR_BASE) + KERNEL_PADDR_BASE.
     */
    .text ALIGN(4K) : AT (ADDR(.text) - KERNEL_VADDR_BASE + KERNEL_PADDR_BASE) {
        __norn_text_start = .;
        *(.text)
        *(.ltext)
        __norn_text_end = .;
    } :text

    .rodata ALIGN(4K) : AT (ADDR(.rodata) - KERNEL_VADDR_BASE + KERNEL_PADDR_BASE) {
        __norn_rodata_start = .;

        *(.rodata)

        . = ALIGN(0x10);
        __module_init_start = .;
        KEEP(*(.module.init))
        __module_init_end = .;

        __norn_rodata_end = .;
    } :rodata

    .data ALIGN(4K) : AT (ADDR(.data) - KERNEL_VADDR_BASE + KERNEL_PADDR_BASE) {
        __norn_data_start = .;
        *(.data)
        *(.ldata)
        __norn_data_end = .;
    } :data

    .bss ALIGN(4K) : AT (ADDR(.bss) - KERNEL_VADDR_BASE + KERNEL_PADDR_BASE) {
        __norn_bss_start = .;
        *(COMMON)
        *(.bss)
        *(.lbss)
        __norn_bss_end = .;
    } :bss

    /*
     * Stack used during early boot.
     */
    __early_stack ALIGN(4K) (NOLOAD) : AT (ADDR(__early_stack) - KERNEL_VADDR_BASE + KERNEL_PADDR_BASE) {
        . += STACK_SIZE;
    } :__early_stack
    __early_stack_bottom  = .;
}
