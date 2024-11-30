const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .ofmt = .elf,
    });
    const userland_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Options
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

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption(bool, "is_runtime_test", is_runtime_test);

    // Modules
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

    // Executables
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

    const norn = b.addExecutable(.{
        .name = "norn.elf",
        .root_source_file = b.path("norn/main.zig"),
        .target = target, // Freestanding x64 ELF executable
        .optimize = optimize, // You can choose the optimization level.
        .linkage = .static,
        .code_model = .kernel,
    });
    norn.entry = .{ .symbol_name = "kernelEntry" };
    norn.linker_script = b.path("norn/linker.ld");
    norn.root_module.addImport("surtr", surtr_module);
    norn.root_module.addImport("norn", norn_module);
    norn.root_module.addOptions("option", options);
    b.installArtifact(norn);

    // EFI directory
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

    // Run QEMU
    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-m",
        "512M",
        "-bios",
        "/usr/share/ovmf/OVMF.fd", // TODO: Make this configurable
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-nographic",
        "-serial",
        "mon:stdio",
        "-no-reboot",
        "-enable-kvm",
        "-cpu",
        "host",
        "-smp",
        "1",
        "-s",
    };
    const qemu_cmd = b.addSystemCommand(&qemu_args);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_qemu_cmd = b.step("run", "Run QEMU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);

    // Unit tests
    const unit_test = b.addTest(.{
        .name = "Unit Test",
        .root_source_file = b.path("norn/norn.zig"),
        .target = userland_target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_test.root_module.addImport("norn", &unit_test.root_module);
    unit_test.root_module.addImport("surtr", surtr_module);
    unit_test.root_module.addOptions("option", options);
    const run_unit_tests = b.addRunArtifact(unit_test);
    const unit_test_step = b.step("test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
}
