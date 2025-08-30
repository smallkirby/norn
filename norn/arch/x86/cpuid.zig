/// CPUID Leaf.
/// SDM Vol2A Chapter 3.3 Table 3-8.
pub const Leaf = enum(u32) {
    /// Maximum input value for basic CPUID.
    maximum_input = 0x0,
    /// Version information.
    version_info = 0x1,
    /// Thermal and power management.
    thermal_power = 0x6,
    /// Structured extended feature enumeration.
    /// Output depends on the value of ECX.
    ext_feature = 0x7,
    /// Processor extended state enumeration.
    /// Output depends on the ECX input value.
    ext_enumeration = 0xD,
    /// Maximum input value for extended function CPUID information.
    ext_func = 0x80000000,
    /// EAX: Extended processor signature and feature bits.
    ext_proc_signature = 0x80000001,
    /// Unimplemented
    _,

    /// Convert u64 to Leaf.
    pub fn from(rax: u64) Leaf {
        return @enumFromInt(rax);
    }

    /// Issues CPUID instruction to query the leaf and sub-leaf.
    pub fn query(self: Leaf, subleaf: ?u32) CpuidRegisters {
        return cpuid(@intFromEnum(self), subleaf orelse 0);
    }
};

/// Return value of CPUID.
const CpuidRegisters = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Asm CPUID instruction.
fn cpuid(leaf: u32, subleaf: u32) CpuidRegisters {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\mov %[leaf], %%eax
        \\mov %[subleaf], %%ecx
        \\cpuid
        \\mov %%eax, %[eax]
        \\mov %%ebx, %[ebx]
        \\mov %%ecx, %[ecx]
        \\mov %%edx, %[edx]
        : [eax] "=r" (eax),
          [ebx] "=r" (ebx),
          [ecx] "=r" (ecx),
          [edx] "=r" (edx),
        : [leaf] "r" (leaf),
          [subleaf] "r" (subleaf),
        : .{ .eax = true, .ebx = true, .ecx = true, .edx = true }
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}
