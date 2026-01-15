// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;

inline fn waitForVBlank() void {
    while (true) {
        const device = sdk.plic.claim;

        if (device == .none) {
            break;
        }

        sdk.plic.claim = device;
    }

    sdk.arch.wfi();
}

pub fn main() noreturn {
    sdk.gpu.setVblankInterrupts(true);
    sdk.arch.Mie.setMeie();

    while (true) {
        waitForVBlank();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
