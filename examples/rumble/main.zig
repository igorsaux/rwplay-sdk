// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;
const fb = sdk.fb3;

const Colors = struct {
    const bg: sdk.ARGB1555 = .fromRGB(12, 12, 18);
    const panel: sdk.ARGB1555 = .fromRGB(20, 20, 28);
    const panel_border: sdk.ARGB1555 = .fromRGB(40, 40, 50);

    const text_white: sdk.ARGB1555 = .fromRGB(255, 255, 255);
    const text_dim: sdk.ARGB1555 = .fromRGB(120, 120, 140);
    const text_hint: sdk.ARGB1555 = .fromRGB(80, 80, 100);
    const shadow: sdk.ARGB1555 = .fromRGB(0, 0, 0);

    const btn_a: sdk.ARGB1555 = .fromRGB(80, 200, 80);
    const btn_b: sdk.ARGB1555 = .fromRGB(200, 80, 80);
    const btn_x: sdk.ARGB1555 = .fromRGB(80, 80, 200);
    const btn_y: sdk.ARGB1555 = .fromRGB(200, 200, 80);

    const motor_weak: sdk.ARGB1555 = .fromRGB(100, 180, 255);
    const motor_strong: sdk.ARGB1555 = .fromRGB(255, 100, 100);
    const motor_off: sdk.ARGB1555 = .fromRGB(40, 40, 50);
    const motor_glow: sdk.ARGB1555 = .fromRGB(255, 200, 100);

    const connected: sdk.ARGB1555 = .fromRGB(60, 180, 60);
    const disconnected: sdk.ARGB1555 = .fromRGB(180, 60, 60);

    const progress_bg: sdk.ARGB1555 = .fromRGB(30, 30, 40);
    const progress_fill: sdk.ARGB1555 = .fromRGB(100, 200, 255);
};

const Layout = struct {
    const center_x = fb.width / 2;
    const center_y = fb.height / 2;
};

inline fn getCurrentTimeMs() u64 {
    return sdk.clint.readMtimeNs() / std.time.ns_per_ms;
}

const RumbleState = struct {
    weak_intensity: u16 = 0,
    strong_intensity: u16 = 0,
    duration_ms: u32 = 0,
    start_time_ms: u64 = 0,
    active: bool = false,
    infinite: bool = false,
};

var rumble_state = RumbleState{};

inline fn fillRect(x: u16, y: u16, w: u16, h: u16, color: sdk.ARGB1555) void {
    sdk.blitter.rect(fb.id, .{ .pos = .{ .x = x, .y = y }, .w = w, .h = h, .color = color });
}

inline fn fillRectCentered(cx: u16, cy: u16, w: u16, h: u16, color: sdk.ARGB1555) void {
    sdk.blitter.rect(fb.id, .{ .pos = .{ .x = cx, .y = cy }, .w = w, .h = h, .color = color, .origin = .center });
}

inline fn fillCircle(cx: u16, cy: u16, r: u16, color: sdk.ARGB1555) void {
    sdk.blitter.circle(fb.id, .{ .pos = .{ .x = cx, .y = cy }, .r = r, .color = color, .origin = .center });
}

fn drawPanel(x: u16, y: u16, w: u16, h: u16) void {
    fillRect(x, y, w, h, Colors.panel_border);
    fillRect(x + 1, y + 1, w - 2, h - 2, Colors.panel);
}

fn drawHeader(connected: bool) void {
    sdk.utils.Text.drawCenteredWithShadow(fb, Layout.center_x, 8, "RUMBLE TEST", Colors.text_white, Colors.shadow);

    const status_color = if (connected) Colors.connected else Colors.disconnected;
    const status_text = if (connected) "GAMEPAD CONNECTED" else "NO GAMEPAD";

    fillRectCentered(Layout.center_x, 28, 140, 14, status_color);
    sdk.utils.Text.drawCentered(fb, Layout.center_x, 25, status_text, Colors.text_white);
}

fn drawButtonHint(x: u16, y: u16, char: u8, color: sdk.ARGB1555, label: []const u8, pressed: bool) void {
    fillCircle(x, y, 11, Colors.panel_border);

    if (pressed) {
        fillCircle(x, y, 10, color);
        sdk.utils.Text.drawChar(fb, x - 3, y - 3, char, Colors.text_white);
    } else {
        fillCircle(x, y, 10, Colors.panel);
        sdk.utils.Text.drawChar(fb, x - 3, y - 3, char, color);
    }

    sdk.utils.Text.draw(fb, x + 16, y - 4, label, Colors.text_dim);
}

fn drawButtonPanel(controls: sdk.Gamepad.Controls) void {
    const panel_x: u16 = 30;
    const panel_y: u16 = 50;
    const panel_w: u16 = 180;
    const panel_h: u16 = 120;

    drawPanel(panel_x, panel_y, panel_w, panel_h);
    sdk.utils.Text.draw(fb, panel_x + 8, panel_y + 8, "CONTROLS", Colors.text_hint);

    const btn_x: u16 = panel_x + 22;
    const start_y: u16 = panel_y + 30;
    const spacing: u16 = 24;

    drawButtonHint(btn_x, start_y, 'A', Colors.btn_a, "Weak 1s", controls.south.down);
    drawButtonHint(btn_x, start_y + spacing, 'B', Colors.btn_b, "Strong 1s", controls.east.down);
    drawButtonHint(btn_x, start_y + spacing * 2, 'X', Colors.btn_x, "Both infinite", controls.west.down);
    drawButtonHint(btn_x, start_y + spacing * 3, 'Y', Colors.btn_y, "Stop", controls.north.down);
}

fn drawMotorIndicator(cx: u16, cy: u16, label: []const u8, intensity: u16, base_color: sdk.ARGB1555, time_ms: u64) void {
    const max_radius: u16 = 30;
    const min_radius: u16 = 18;

    fillCircle(cx, cy, max_radius + 2, Colors.panel_border);
    fillCircle(cx, cy, max_radius, Colors.motor_off);

    if (intensity > 0) {
        const norm: u32 = @as(u32, intensity) * 100 / 65535;

        const pulse_phase: u32 = @intCast((time_ms % 100) * 255 / 100);
        const pulse_offset: u16 = @intCast(pulse_phase * 3 / 255);
        const intensity_radius: u16 = @intCast(min_radius + (max_radius - min_radius) * norm / 100);
        const display_radius = @min(intensity_radius + pulse_offset, max_radius);

        fillCircle(cx, cy, display_radius, base_color);

        var buf: [8]u8 = undefined;
        const pct = std.fmt.bufPrint(&buf, "{d}%", .{norm}) catch "?";

        sdk.utils.Text.drawCentered(fb, cx, cy - 4, pct, Colors.text_white);
    } else {
        sdk.utils.Text.drawCentered(fb, cx, cy - 4, "OFF", Colors.text_dim);
    }

    sdk.utils.Text.drawCentered(fb, cx, cy + max_radius + 10, label, Colors.text_hint);
}

fn drawMotorPanel(time_ms: u64) void {
    const panel_x: u16 = 230;
    const panel_y: u16 = 50;
    const panel_w: u16 = 190;
    const panel_h: u16 = 120;

    drawPanel(panel_x, panel_y, panel_w, panel_h);
    sdk.utils.Text.draw(fb, panel_x + 8, panel_y + 8, "MOTORS", Colors.text_hint);

    const motor_y: u16 = panel_y + 60;

    drawMotorIndicator(panel_x + 50, motor_y, "WEAK", rumble_state.weak_intensity, Colors.motor_weak, time_ms);
    drawMotorIndicator(panel_x + 140, motor_y, "STRONG", rumble_state.strong_intensity, Colors.motor_strong, time_ms);
}

fn drawProgressBar(x: u16, y: u16, w: u16, h: u16, progress: f32) void {
    fillRect(x, y, w, h, Colors.progress_bg);

    if (progress > 0) {
        const fill_w: u16 = @intFromFloat(@as(f32, @floatFromInt(w - 2)) * @min(progress, 1.0));

        if (fill_w > 0) {
            fillRect(x + 1, y + 1, fill_w, h - 2, Colors.progress_fill);
        }
    }
}

fn drawStatusPanel(time_ms: u64) void {
    const panel_x: u16 = 30;
    const panel_y: u16 = 175;
    const panel_w: u16 = 390;
    const panel_h: u16 = 50;

    drawPanel(panel_x, panel_y, panel_w, panel_h);

    if (rumble_state.active) {
        if (rumble_state.infinite) {
            const dot_count: usize = @intCast((time_ms / 500) % 4);
            const dots = [_][]const u8{ "INFINITE RUMBLE", "INFINITE RUMBLE.", "INFINITE RUMBLE..", "INFINITE RUMBLE..." };

            sdk.utils.Text.draw(fb, panel_x + 12, panel_y + 12, dots[dot_count], Colors.motor_glow);
            sdk.utils.Text.draw(fb, panel_x + 12, panel_y + 30, "Press Y to stop", Colors.text_hint);
        } else {
            const elapsed_ms = time_ms -| rumble_state.start_time_ms;
            const remaining_ms = if (elapsed_ms < rumble_state.duration_ms)
                rumble_state.duration_ms - @as(u32, @intCast(elapsed_ms))
            else
                0;

            var buf: [32]u8 = undefined;
            const time_str = std.fmt.bufPrint(&buf, "Time remaining: {d}ms", .{remaining_ms}) catch "?";
            sdk.utils.Text.draw(fb, panel_x + 12, panel_y + 12, time_str, Colors.text_white);

            const progress: f32 = @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(rumble_state.duration_ms));
            drawProgressBar(panel_x + 12, panel_y + 30, panel_w - 24, 10, 1.0 - progress);

            if (remaining_ms == 0) {
                rumble_state.active = false;
                rumble_state.weak_intensity = 0;
                rumble_state.strong_intensity = 0;
            }
        }
    } else {
        sdk.utils.Text.draw(fb, panel_x + 12, panel_y + 12, "STATUS: IDLE", Colors.text_dim);
        sdk.utils.Text.draw(fb, panel_x + 12, panel_y + 30, "Press A/B/X to start rumble", Colors.text_hint);
    }
}

fn drawWaveform(time_ms: u64) void {
    if (!rumble_state.active) return;

    const base_y: u16 = 240;
    const wave_w: u16 = 390;
    const start_x: u16 = 30;

    const combined = (@as(u32, rumble_state.weak_intensity) + @as(u32, rumble_state.strong_intensity)) / 2;
    const amplitude: i32 = @intCast(combined * 15 / 65535);

    const time_offset: i32 = @intCast((time_ms / 10) % 1000);

    var x: u16 = start_x;

    while (x < start_x + wave_w) : (x += 3) {
        const phase: i32 = @as(i32, x) + time_offset * 2;
        const sin_val: i32 = @rem(@mod(phase, 40) - 20, 20);
        const wave_y: i32 = @divTrunc(sin_val * amplitude, 20);

        const y: u16 = @intCast(@as(i32, base_y) + wave_y);

        fillRect(x, y, 2, 2, Colors.motor_glow);
    }
}

fn startRumble(weak: u16, strong: u16, duration_ms: u32) void {
    rumble_state = .{
        .weak_intensity = weak,
        .strong_intensity = strong,
        .duration_ms = duration_ms,
        .start_time_ms = getCurrentTimeMs(),
        .active = true,
        .infinite = duration_ms == std.math.maxInt(u32),
    };
    sdk.gamepad1.rumble(weak, strong, duration_ms);
}

fn stopRumble() void {
    rumble_state = .{};
    sdk.gamepad1.rumbleOff();
}

fn handleInput(controls: sdk.Gamepad.Controls) void {
    if (controls.south.sticky) {
        startRumble(std.math.maxInt(u16), 0, 1000);
    }

    if (controls.east.sticky) {
        startRumble(0, std.math.maxInt(u16), 1000);
    }

    if (controls.west.sticky) {
        startRumble(std.math.maxInt(u16), std.math.maxInt(u16), std.math.maxInt(u32));
    }

    if (controls.north.sticky) {
        stopRumble();
    }
}

fn render(controls: sdk.Gamepad.Controls, connected: bool, time_ms: u64) void {
    sdk.blitter.clear(fb.id, .{ .color = Colors.bg });

    drawHeader(connected);
    drawButtonPanel(controls);
    drawMotorPanel(time_ms);
    drawStatusPanel(time_ms);
    drawWaveform(time_ms);
}

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

pub fn main() void {
    sdk.arch.Mie.setMeie();
    sdk.gpu.setVblankInterrupts(true);

    while (true) {
        const status = sdk.gamepad1.status();
        const controls = status.controls().*;
        const connected = status.connected;
        sdk.gamepad1.clearSticky();

        const time_ms = getCurrentTimeMs();

        handleInput(controls);

        sdk.gpu.switchFramebuffer(.off);
        render(controls, connected, time_ms);
        sdk.gpu.switchFramebuffer(fb.id);

        waitForVBlank();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
