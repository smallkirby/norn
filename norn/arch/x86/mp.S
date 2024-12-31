.global __ap_trampoline
.global __ap_trampoline_end
.global __ap_gdt
.global __ap_gdtr
.global __ap_entry32
.global __ap_entry64
.global __ap_reloc_farjmp32
.global __ap_reloc_farjmp64
.global __ap_reloc_stack
.global __ap_reloc_cr3
.global __ap_reloc_zigentry

.set CR0_PE  , 0x00000001
.set CR0_MP  , 0x00000002
.set CR0_NE  , 0x00000020
.set CR0_WP  , 0x00010000
.set CR0_NW  , 0x20000000
.set CR0_CD  , 0x40000000
.set CR0_PG  , 0x80000000
.set CR4_PAE , 0x00000020
.set CR4_DE  , 0x00000004
.set CR4_MCE , 0x00000040
.set CR4_FXSR, 0x00000200
.set EFER_LME, 0x00000100
.set EFER_NXE, 0x00000800
.set MSR_EFER, 0xC0000080

.set TMP_DS32_INDEX, 0x01
.set TMP_CS32_INDEX, 0x02
.set TMP_DS64_INDEX, 0x03
.set TMP_CS64_INDEX, 0x04

# The value must be replaced by Norn.
.set TO_RELOCATE, 0

.text
.code16

# 16bit real mode entry code for APs.
__ap_trampoline:
  cli

  # CS is set to the vector number of SIPI.
  # We copy the value to DS to access memory.
  movw %cs, %ax
  movw %ax, %ds

  # Load IDT and GDT
  lidt (.Lidtr    - __ap_trampoline)
  lgdt (__ap_gdtr - __ap_trampoline)

  # Enable protected mode
  movl %cr0   , %eax
  orl  $(CR0_PE | CR0_MP | CR0_NE | CR0_WP), %eax
  andl $(~(CR0_PG | CR0_NW | CR0_CD)), %eax
  movl %eax   , %cr0

__ap_reloc_farjmp32:
  # Far jump to the 32-bit entry.
  ljmpl $(TMP_CS32_INDEX << 3), $TO_RELOCATE

.align 32
.code32

__ap_entry32:
  # Set up segment registers
  movw $(TMP_DS32_INDEX << 3), %di
  movw %di, %ds
  movw %di, %es
  movw %di, %fs
  movw %di, %gs
  movw %di, %ss

__ap_reloc_stack:
  # Get temporary stack
  movl $TO_RELOCATE, %esp

  # Enable PAE
  movl %cr4, %eax
  orl  $(CR4_PAE | CR4_DE | CR4_MCE | CR4_FXSR), %eax
  movl %eax, %cr4

  # Enable long mode (LME)
  movl $MSR_EFER, %ecx
  rdmsr
  # Note that NXE bit is mandatory since BSP's page table entries have XD bit.
  # If we don't set NXE bit, accessing a NX page causes a page fault.
  orl  $(EFER_LME | EFER_NXE), %eax
  wrmsr

__ap_reloc_cr3:
  # Load CR3
  movl $TO_RELOCATE, %eax
  movl %eax, %cr3

  # Enable paging (enter compatibility mode)
  movl %cr0, %eax
  orl  $CR0_PG, %eax
  movl %eax, %cr0

  # Far jmp to the 64-bit entry
__ap_reloc_farjmp64:
  ljmpl $(TMP_CS64_INDEX << 3), $TO_RELOCATE

.align 32
.code64
__ap_entry64:
  movw $(TMP_DS64_INDEX << 3), %di
  movw %di, %ds
  movw %di, %es
  movw %di, %fs
  movw %di, %gs
  movw %di, %ss

__ap_reloc_zigentry:
  movabsq  $TO_RELOCATE, %rax
  pushq %rax
  retq

# Temporary IDTR
.align 16
.Lidtr:
  .word 0xFFFF        # Limit
  .long 0x00000000    # Base

# Temporary GDT
.align 16
__ap_gdt:
	.long	0x00000000, 0x00000000 # NULL descriptor
  .long	0x0000FFFF, 0x008F9200 # Data32
  .long	0x0000FFFF, 0x00CF9A00 # Code32
  .long	0x0000FFFF, 0x00CF9200 # Data64
  .long	0x0000FFFF, 0x00AF9A00 # Code64
.align 16
__ap_gdtr:
	.word	0xFFFF      # Limit
	.long	TO_RELOCATE # Base

__ap_trampoline_end:
