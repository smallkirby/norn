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
    ) orelse is_runtime_test;
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
    const graphics = b.option(
        bool,
        "graphics",
        "Enable QEMU graphics.",
    ) orelse false;
    const sched_freq = b.option(
        u64,
        "sched_freq",
        "Scheduler timer frequency in Hz.",
    ) orelse if (no_kvm) @as(u64, 100) else @as(u64, 250);

    const path_bootparams = b.option(
        []const u8,
        "bootparams",
        "Path to Surtr boot parameters file.",
    ) orelse "assets/boot/bootprarams";

    const rtt_hid_wait = b.option(
        u32,
        "rtt_hid_wait",
        "(Runtime Test) Seconds to wait for keyboard input after USB subsystem is initialized.",
    ) orelse 0;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption(bool, "is_runtime_test", is_runtime_test);
    options.addOption([]const u8, "sha", try getGitSha(b));
    options.addOption([]const u8, "version", norn_version);
    options.addOption(bool, "debug_syscall", debug_syscall);
    options.addOption(u32, "rtt_hid_wait", rtt_hid_wait);
    options.addOption(u64, "sched_freq", sched_freq);

    // =============================================================
    // Modules
    // =============================================================

    const surtr_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("surtr/surtr.zig"),
        });
        module.addOptions("option", options);

        break :blk module;
    };

    const norn_module = blk: {
        const module = b.createModule(.{
            .root_source_file = b.path("norn/norn.zig"),
        });
        module.addImport("norn", module);
        module.addImport("surtr", surtr_module);
        module.addOptions("option", options);

        break :blk module;
    };

    // =============================================================
    // Surtr Executable
    // =============================================================

    const surtr = blk: {
        const exe = b.addExecutable(.{
            .name = "BOOTX64.EFI",
            .root_module = b.createModule(.{
                .root_source_file = b.path("surtr/main.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .x86_64,
                    .os_tag = .uefi,
                }),
                .optimize = optimize,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.root_module.addOptions("option", options);

        break :blk exe;
    };

    // =============================================================
    // Norn Executable
    // =============================================================

    const norn = blk: {
        const exe = b.addExecutable(.{
            .name = "norn.elf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("norn/main.zig"),
                .target = target, // Freestanding x64 ELF executable
                .optimize = optimize, // You can choose the optimization level.
                .code_model = .kernel,
            }),
            .linkage = .static,
            .use_llvm = true,
        });
        exe.addAssemblyFile(b.path("norn/arch/x86/mp.S"));
        exe.entry = .{ .symbol_name = "kernelEntry" };
        exe.linker_script = b.path("norn/linker.ld");
        exe.root_module.addImport("surtr", surtr_module);
        exe.root_module.addImport("norn", norn_module);
        exe.root_module.addOptions("option", options);
        exe.want_lto = false; // NOTE: LTO dead-strips exported functions in Zig file. cf: https://github.com/ziglang/zig/issues/22234

        break :blk exe;
    };

    // =============================================================
    // Init Executable
    // =============================================================

    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/init/main.zig"),
            .target = userland_target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    // =============================================================
    // initramfs
    // =============================================================

    const initramfs = blk: {
        const make_initramfs = b.addSystemCommand(&[_][]const u8{
            "bash",
            "-c",
            "scripts/make_initramfs.bash",
        });

        const install_init = b.addInstallFile(
            init.getEmittedBin(),
            "rootfs/sbin/init",
        );
        make_initramfs.step.dependOn(&install_init.step);

        const install_busybox = b.addInstallFile(
            b.path("vendor/busybox/busybox"),
            "rootfs/bin/busybox",
        );
        make_initramfs.step.dependOn(&install_busybox.step);

        break :blk make_initramfs;
    };

    // =============================================================
    // FAT32 disk image
    // =============================================================

    const outdir_name = "img";
    const diskimg_name = "diskimg";

    const update_bootparams = blk: {
        const bp = b.addInstallFile(
            b.path(path_bootparams),
            b.fmt("{s}/efi/boot/bootparams", .{outdir_name}),
        );

        break :blk bp;
    };

    const install_surtr = blk: {
        const install = b.addInstallFile(
            surtr.getEmittedBin(),
            b.fmt(
                "{s}/efi/boot/{s}",
                .{ outdir_name, surtr.name },
            ),
        );
        install.step.dependOn(&surtr.step);

        break :blk install;
    };

    const install_norn = blk: {
        const install = b.addInstallFile(
            norn.getEmittedBin(),
            b.fmt(
                "{s}/efi/boot/{s}",
                .{ outdir_name, norn.name },
            ),
        );
        install.step.dependOn(&norn.step);

        break :blk install;
    };

    const start_mib = 1;
    const size_mib = 64;
    const create_disk = blk: {
        const command = b.addSystemCommand(&[_][]const u8{
            "scripts/create_disk.bash",
            b.fmt("{s}/{s}", .{ b.install_path, outdir_name }), // copy source
            b.fmt("{s}/{s}", .{ b.install_prefix, diskimg_name }), // output image
            b.fmt("{d}", .{start_mib}), // start MiB
            b.fmt("{d}", .{size_mib}), // size MiB
        });
        command.step.dependOn(&update_bootparams.step);
        command.step.dependOn(&initramfs.step);
        command.step.dependOn(&install_surtr.step);
        command.step.dependOn(&install_norn.step);

        break :blk command;
    };

    {
        // Copy bootparams into the disk image.
        const command1 = b.addSystemCommand(&[_][]const u8{
            "mcopy",
            "-i",
            b.fmt("{s}/{s}@@{d}", .{ b.install_prefix, diskimg_name, start_mib * 1024 * 1024 }),
            "-o",
            "-s",
            path_bootparams,
            "::efi/boot/bootparams",
        });
        // Copy bootparams into the disk image directory, so that next creation of the image uses the updated bootparams.
        const command2 = b.addInstallFile(
            b.path(path_bootparams),
            b.fmt("{s}/efi/boot/bootparams", .{outdir_name}),
        );

        const cmd_update_bootparams = b.step(
            "update-bootparams",
            "Update boot parameters.",
        );
        cmd_update_bootparams.dependOn(&command1.step);
        cmd_update_bootparams.dependOn(&command2.step);
    }

    // =============================================================
    // Install
    // =============================================================

    b.installArtifact(norn);
    b.installArtifact(surtr);
    b.installArtifact(init);
    b.getInstallStep().dependOn(&create_disk.step);

    // =============================================================
    // QEMU
    // =============================================================

    {
        const qemu_cpu_feats = "+fsgsbase,+invtsc,+avx,+avx2,+xsave,+xsaveopt,+bmi1";

        var qemu_args = std.array_list.Aligned([]const u8, null).empty;
        defer qemu_args.deinit(b.allocator);
        try qemu_args.appendSlice(b.allocator, &.{
            "qemu-system-x86_64",
            "-m",
            "512M",
            "-bios",
            "/usr/share/ovmf/OVMF.fd", // TODO: Make this configurable
            "-drive",
            b.fmt("file={s}/{s},format=raw,if=virtio,media=disk", .{ b.install_path, diskimg_name }),
            "-device",
            "nec-usb-xhci,id=xhci",
            "-device",
            "usb-kbd",
            "-serial",
            "mon:stdio",
            "-no-reboot",
            "-no-shutdown",
            "-smp",
            "3",
            "-s",
            "-d",
            "guest_errors",
        });

        if (wait_qemu) {
            try qemu_args.append(b.allocator, "-S");
        }

        if (debug_intr) {
            try qemu_args.appendSlice(b.allocator, &.{
                "-cpu",
                "qemu64," ++ qemu_cpu_feats,
                "-d",
                "int,cpu_reset",
            });
        } else if (no_kvm) {
            try qemu_args.appendSlice(b.allocator, &.{
                "-cpu",
                "qemu64," ++ qemu_cpu_feats,
            });
        } else {
            try qemu_args.appendSlice(b.allocator, &.{
                "-cpu",
                "host,+invtsc",
                "-enable-kvm",
            });
        }

        if (debug_exit) try qemu_args.appendSlice(b.allocator, &.{
            "-device",
            "isa-debug-exit,iobase=0xF0,iosize=0x01",
        });

        if (!graphics) try qemu_args.appendSlice(b.allocator, &.{
            "-nographic",
        });

        const qemu_cmd = b.addSystemCommand(qemu_args.items);
        qemu_cmd.step.dependOn(b.getInstallStep());

        const run_qemu_cmd = b.step("run", "Run QEMU");
        run_qemu_cmd.dependOn(&qemu_cmd.step);
    }

    // =============================================================
    // Unit Tests
    // =============================================================

    {
        const norn_unit_test = b.addTest(.{
            .name = "Norn Unit Test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("norn/norn.zig"),
                .target = userland_target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = true,
        });
        norn_unit_test.addAssemblyFile(b.path("norn/tests/mock.S"));
        norn_unit_test.addAssemblyFile(b.path("norn/arch/x86/mp.S"));
        norn_unit_test.root_module.addImport("norn", norn_unit_test.root_module);
        norn_unit_test.root_module.addImport("surtr", surtr_module);
        norn_unit_test.root_module.addOptions("option", options);
        const run_norn_unit_tests = b.addRunArtifact(norn_unit_test);

        const surtr_unit_test = b.addTest(.{
            .name = "Surtr Unit Test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("surtr/surtr.zig"),
                .target = userland_target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_surtr_unit_tests = b.addRunArtifact(surtr_unit_test);

        const unit_test_step = b.step("test", "Run unit tests");
        unit_test_step.dependOn(&run_norn_unit_tests.step);
        unit_test_step.dependOn(&run_surtr_unit_tests.step);
    }
}
