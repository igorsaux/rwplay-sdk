// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;

pub fn main() noreturn {
    const frame_time: f32 = 1.0 / @as(f32, @floatFromInt(sdk.boot_info.fps));

    sdk.blitter.clear(.fb1, .{
        .color = .{ .a = 1, .r = std.math.maxInt(u5), .g = 0, .b = 0 },
    });
    sdk.blitter.rect(.fb1, .{
        .color = .{
            .a = 1,
            .r = std.math.maxInt(u5),
            .g = std.math.maxInt(u5),
            .b = std.math.maxInt(u5),
        },
        .pos = .{
            .x = sdk.fb1.width - 40,
            .y = 40,
        },
        .w = 300,
        .h = 10,
        .mode = .wrap,
    });

    sdk.blitter.clear(.fb2, .{
        .color = .{ .a = 1, .r = 0, .g = std.math.maxInt(u5), .b = 0 },
    });
    sdk.blitter.clear(.fb3, .{
        .color = .{ .a = 1, .r = 0, .g = 0, .b = std.math.maxInt(u5) },
    });
    sdk.blitter.rect(.fb3, .{
        .color = .{
            .a = 1,
            .r = std.math.maxInt(u5),
            .g = std.math.maxInt(u5),
            .b = std.math.maxInt(u5),
        },
        .pos = .{
            .x = sdk.fb3.width - 40,
            .y = 40,
        },
        .w = sdk.fb3.width,
        .h = 10,
        .mode = .crop,
    });

    sdk.fb1.set(0, 0, .{ .a = 0, .r = std.math.maxInt(u5), .g = std.math.maxInt(u5), .b = std.math.maxInt(u5) });
    sdk.fb2.set(0, 0, .{ .a = 0, .r = std.math.maxInt(u5), .g = std.math.maxInt(u5), .b = std.math.maxInt(u5) });
    sdk.fb3.set(0, 0, .{ .a = 0, .r = std.math.maxInt(u5), .g = std.math.maxInt(u5), .b = std.math.maxInt(u5) });
    sdk.gpu.switchFramebuffer(.fb1);

    sdk.arch.Mie.setMtie();

    while (true) {
        const controls = sdk.gamepad1.status().controls();
        sdk.gamepad1.clearSticky();

        if (controls.west.sticky) {
            sdk.gpu.switchFramebuffer(.fb3);
        } else if (controls.north.sticky) {
            sdk.gpu.switchFramebuffer(.fb2);
        } else if (controls.east.sticky) {
            sdk.gpu.switchFramebuffer(.fb1);
        }

        sdk.clint.interruptAfterNs(@intFromFloat(frame_time * std.time.ns_per_s));
        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
