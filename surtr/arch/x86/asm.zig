pub inline fn loadCr3(cr3: u64) void {
    asm volatile (
        \\mov %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
    );
}

pub inline fn readCr3() u64 {
    var cr3: u64 = undefined;
    asm volatile (
        \\mov %%cr3, %[cr3]
        : [cr3] "=r" (cr3),
    );
    return cr3;
}

pub inline fn flushTlbSingle(virt: u64) void {
    asm volatile (
        \\invlpg (%[virt])
        :
        : [virt] "r" (virt),
        : .{ .memory = true });
}

pub fn rdmsr(T: type, comptime msr: u64) T {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\rdmsr
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (msr),
        : .{ .eax = true, .edx = true, .ecx = true });

    const value = (@as(u64, edx) << 32) | eax;
    return switch (@typeInfo(T)) {
        .int, .comptime_int => value,
        .@"struct" => @bitCast(value),
        else => @compileError("rdmsr: invalid type"),
    };
}

pub fn wrmsr(comptime msr: u64, value: anytype) void {
    const val: u64 = switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => value,
        .@"struct" => @bitCast(value),
        else => @compileError("wrmsr: invalid type"),
    };
    const eax: u32 = @truncate(val);
    const edx: u32 = @truncate(val >> 32);
    asm volatile (
        \\wrmsr
        :
        : [msr] "{ecx}" (msr),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
        : .{ .eax = true, .edx = true, .ecx = true });
}
