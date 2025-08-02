const std = @import("std");
const zon: ZonStruct = @import("build.zig.zon");

/// Type of build.zig.zon file.
const ZonStruct = struct {
    version: []const u8,
    name: @Type(.enum_literal),
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
};

/// Norn version string.
const norn_version = zon.version;

/// Get SHA-1 hash of the current Git commit.
fn getGitSha(b: *std.Build) ![]const u8 {
    return blk: {
        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{
                "git",
                "rev-parse",
                "HEAD",
            },
            .cwd = b.pathFromRoot("."),
        }) catch |err| {
            std.log.warn("Failed to get git SHA: {s}", .{@errorName(err)});
            break :blk "(unknown)";
        };
        return b.dupe(std.mem.trim(u8, result.stdout[0..7], "\n \t"));
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .ofmt = .elf,
    });
    const userland_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =============================================================
    // Options
    // =============================================================
    const s_log_level = b.option(
        []const u8,
        "log_level",
        "log_level",
    ) orelse "info";
    const log_level: std.log.Level = b: {
        const eql = std.mem.eql;
        break :b if (eql(u8, s_log_level, "debug"))
            .debug
        else if (eql(u8, s_log_level, "info"))
            .info
        else if (eql(u8, s_log_level, "warn"))
            .warn
        else if (eql(u8, s_log_level, "error"))
            .err
        else
            @panic("Invalid log level");
    };

    const is_runtime_test = b.option(
        bool,
        "runtime_test",
        "Specify if the build is for the runtime testing.",
    ) orelse false;

    const init_binary = b.option(
        []const u8,
        "init_binary",
        "ELF file to execute as init process.",
    ) orelse "/sbin/init";

    const wait_qemu = b.option(
        bool,
        "wait_qemu",
        "QEMU waits for GDB connection.",
    ) orelse false;
    const debug_intr = b.option(
        bool,
        "debug_intr",
        "Print interrupts for debugging.",
    ) orelse false;
    const debug_exit = b.option(
        bool,
        "debug_exit",
        "Add isa-debug-exit device.",
    ) orelse false;
    const debug_syscall = b.option(
        bool,
        "debug_syscall",
        "Print debug log for unhandled and ignored syscalls.",
    ) orelse false;
    const no_kvm = b.option(
        bool,
        "no_kvm",
        "Disable KVM.",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption(bool, "is_runtime_test", is_runtime_test);
    options.addOption([]const u8, "init_binary", init_binary);
    options.addOption([]const u8, "sha", try getGitSha(b));
    options.addOption([]const u8, "version", norn_version);
    options.addOption(bool, "debug_syscall", debug_syscall);

    // =============================================================
    // Modules
    // =============================================================
    const surtr_module = b.createModule(.{
        .root_source_file = b.path("surtr/surtr.zig"),
    });
    surtr_module.addOptions("option", options);

    const norn_module = b.createModule(.{
        .root_source_file = b.path("norn/norn.zig"),
    });
    norn_module.addImport("norn", norn_module);
    norn_module.addImport("surtr", surtr_module);
    norn_module.addOptions("option", options);

    // =============================================================
    // Surtr Executable
    // =============================================================
    const surtr = b.addExecutable(.{
        .name = "BOOTX64.EFI",
        .root_source_file = b.path("surtr/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
        }),
        .optimize = optimize,
        .linkage = .static,
    });
    surtr.root_module.addOptions("option", options);
    b.installArtifact(surtr);

    // =============================================================
    // Norn Executable
    // =============================================================
    const norn = b.addExecutable(.{
        .name = "norn.elf",
        .root_source_file = b.path("norn/main.zig"),
        .target = target, // Freestanding x64 ELF executable
        .optimize = optimize, // You can choose the optimization level.
        .linkage = .static,
        .code_model = .kernel,
    });
    norn.addAssemblyFile(b.path("norn/arch/x86/mp.S"));
    norn.entry = .{ .symbol_name = "kernelEntry" };
    norn.linker_script = b.path("norn/linker.ld");
    norn.root_module.addImport("surtr", surtr_module);
    norn.root_module.addImport("norn", norn_module);
    norn.root_module.addOptions("option", options);
    norn.want_lto = false; // NOTE: LTO dead-strips exported functions in Zig file. cf: https://github.com/ziglang/zig/issues/22234
    b.installArtifact(norn);

    // =============================================================
    // Init Executable
    // =============================================================
    const init = b.addExecutable(.{
        .name = "init",
        .root_source_file = b.path("apps/init/main.zig"),
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    b.installArtifact(init);

    // =============================================================
    // initramfs
    // =============================================================
    const make_initramfs = b.addSystemCommand(&[_][]const u8{
        "bash",
        "-c",
        "scripts/make_initramfs.bash",
    });
    make_initramfs.step.dependOn(&norn.step);
    b.getInstallStep().dependOn(&make_initramfs.step);

    const install_init = b.addInstallFile(
        init.getEmittedBin(),
        "rootfs/sbin/init",
    );
    make_initramfs.step.dependOn(&install_init.step);

    // =============================================================
    // EFI directory
    // =============================================================
    const out_dir_name = "img";
    const install_surtr = b.addInstallFile(
        surtr.getEmittedBin(),
        b.fmt("{s}/efi/boot/{s}", .{ out_dir_name, surtr.name }),
    );
    install_surtr.step.dependOn(&surtr.step);
    b.getInstallStep().dependOn(&install_surtr.step);

    const install_norn = b.addInstallFile(
        norn.getEmittedBin(),
        b.fmt("{s}/{s}", .{ out_dir_name, norn.name }),
    );
    install_norn.step.dependOn(&norn.step);
    b.getInstallStep().dependOn(&install_norn.step);

    // =============================================================
    // Boot parameters
    // =============================================================
    const path_bootparams = b.option(
        []const u8,
        "bootparams",
        "Path to Surtr boot parameters file.",
    ) orelse "assets/boot/bootprarams";
    const update_bootparams = b.addInstallFile(
        b.path(path_bootparams),
        b.fmt("{s}/efi/boot/bootparams", .{out_dir_name}),
    );
    const cmd_update_bootparams = b.step("update-bootparams", "Update boot parameters.");
    cmd_update_bootparams.dependOn(&update_bootparams.step);

    // =============================================================
    // QEMU
    // =============================================================
    var qemu_args = std.ArrayList([]const u8).init(b.allocator);
    defer qemu_args.deinit();
    try qemu_args.appendSlice(&.{
        "qemu-system-x86_64",
        "-m",
        "512M",
        "-bios",
        "/usr/share/ovmf/OVMF.fd", // TODO: Make this configurable
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-device",
        "nec-usb-xhci,id=xhci",
        "-device",
        "usb-kbd",
        "-nographic",
        "-serial",
        "mon:stdio",
        "-no-reboot",
        "-smp",
        "3",
        "-s",
        "-d",
        "guest_errors",
    });
    if (wait_qemu) try qemu_args.append("-S");
    if (debug_intr) {
        try qemu_args.appendSlice(&.{
            "-cpu",
            "qemu64,+fsgsbase,+invtsc",
            "-d",
            "int",
        });
    } else if (no_kvm) {
        try qemu_args.appendSlice(&.{
            "-cpu",
            "qemu64,+fsgsbase,+invtsc",
        });
    } else {
        try qemu_args.appendSlice(&.{
            "-cpu",
            "host,+invtsc",
            "-enable-kvm",
        });
    }
    if (debug_exit) try qemu_args.appendSlice(&.{
        "-device",
        "isa-debug-exit,iobase=0xF0,iosize=0x01",
    });
    const qemu_cmd = b.addSystemCommand(qemu_args.items);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_qemu_cmd = b.step("run", "Run QEMU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);

    // =============================================================
    // Unit Tests
    // =============================================================
    const norn_unit_test = b.addTest(.{
        .name = "Norn Unit Test",
        .root_source_file = b.path("norn/norn.zig"),
        .target = userland_target,
        .optimize = optimize,
        .link_libc = true,
    });
    norn_unit_test.addAssemblyFile(b.path("norn/tests/mock.S"));
    norn_unit_test.addAssemblyFile(b.path("norn/arch/x86/mp.S"));
    norn_unit_test.root_module.addImport("norn", norn_unit_test.root_module);
    norn_unit_test.root_module.addImport("surtr", surtr_module);
    norn_unit_test.root_module.addOptions("option", options);
    const run_norn_unit_tests = b.addRunArtifact(norn_unit_test);

    const surtr_unit_test = b.addTest(.{
        .name = "Surtr Unit Test",
        .root_source_file = b.path("surtr/surtr.zig"),
        .target = userland_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const run_surtr_unit_tests = b.addRunArtifact(surtr_unit_test);

    const unit_test_step = b.step("test", "Run unit tests");
    unit_test_step.dependOn(&run_norn_unit_tests.step);
    unit_test_step.dependOn(&run_surtr_unit_tests.step);
}
