// Export arch-specific implementation.
pub const impl = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("arch/x86/arch.zig"),
    else => @compileError("Unsupported architecture."),
};

const builtin = @import("builtin");
