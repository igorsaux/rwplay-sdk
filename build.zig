// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ondatra = b.dependency("ondatra", .{
        .target = target,
        .optimize = optimize,
    });

    const sdk = b.addModule("rwplay_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ondatra", .module = ondatra.module("ondatra") },
        },
    });

    const imagemaker = b.addExecutable(.{
        .name = "imagemaker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/imagemaker.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sdk", .module = sdk },
            },
        }),
    });
    b.installArtifact(imagemaker);

    const imagemaker_run = b.addRunArtifact(imagemaker);

    if (b.args) |args| {
        imagemaker_run.addArgs(args);
    }

    const imagemaker_run_step = b.step("imagemaker", "");
    imagemaker_run_step.dependOn(&imagemaker_run.step);

    addGuestExecutable(b, sdk, imagemaker, "examples/empty", "empty");
    addGuestExecutable(b, sdk, imagemaker, "examples/fbtest", "fbtest");
    addGuestExecutable(b, sdk, imagemaker, "examples/intest", "intest");
    addGuestExecutable(b, sdk, imagemaker, "examples/rumble", "rumble");
    addGuestExecutable(b, sdk, imagemaker, "examples/snake", "snake");
}

const riscv32Query: std.Target.Query = .{
    .cpu_arch = .riscv32,
    .cpu_model = .{
        .explicit = std.Target.Cpu.Model.generic(.riscv32),
    },
    .cpu_features_add = std.Target.riscv.featureSet(&[_]std.Target.riscv.Feature{
        std.Target.riscv.Feature.@"32bit",
        std.Target.riscv.Feature.i,
        std.Target.riscv.Feature.m,
        std.Target.riscv.Feature.f,
        std.Target.riscv.Feature.d,
        std.Target.riscv.Feature.zicsr,
        std.Target.riscv.Feature.zicntr,
        std.Target.riscv.Feature.zifencei,
        std.Target.riscv.Feature.zba,
        std.Target.riscv.Feature.zbb,
    }),
    .os_tag = .freestanding,
};

fn addGuestExecutable(
    b: *std.Build,
    sdk: *std.Build.Module,
    imagemaker: *std.Build.Step.Compile,
    comptime base_folder: []const u8,
    comptime base_name: []const u8,
) void {
    const target = b.resolveTargetQuery(riscv32Query);

    const binary = b.addExecutable(.{
        .name = base_name ++ ".elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path(base_folder ++ "/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{
                .{ .name = "sdk", .module = sdk },
            },
        }),
    });
    binary.linker_script = b.path("examples/linker.ld");

    const imagemaker_step = b.addRunArtifact(imagemaker);

    imagemaker_step.step.dependOn(&b.addInstallArtifact(binary, .{}).step);
    imagemaker_step.addFileInput(binary.getEmittedBin());
    imagemaker_step.addFileArg(b.path(base_folder ++ "/manifest.json"));
    const output = imagemaker_step.addOutputFileArg(base_name ++ ".rwpi");

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .prefix, base_name ++ ".rwpi").step);
}
