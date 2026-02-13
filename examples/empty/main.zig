// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;

pub fn main() void {}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
