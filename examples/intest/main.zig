// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;
const fb = sdk.fb3;

const Colors = struct {
    const bg = sdk.ARGB1555{ .a = 1, .r = 4, .g = 4, .b = 6 };
    const inactive = sdk.ARGB1555{ .a = 1, .r = 8, .g = 8, .b = 10 };
    const pressed = sdk.ARGB1555{ .a = 1, .r = 0, .g = 31, .b = 0 };
    const disconnected = sdk.ARGB1555{ .a = 1, .r = 16, .g = 4, .b = 4 };
    const connected = sdk.ARGB1555{ .a = 1, .r = 0, .g = 20, .b = 0 };
    const text_white = sdk.ARGB1555{ .a = 1, .r = 31, .g = 31, .b = 31 };
    const text_dim = sdk.ARGB1555{ .a = 1, .r = 16, .g = 16, .b = 16 };
    const shadow = sdk.ARGB1555{ .a = 1, .r = 0, .g = 0, .b = 0 };
    const stick_bg = sdk.ARGB1555{ .a = 1, .r = 6, .g = 6, .b = 8 };
    const stick_pos = sdk.ARGB1555{ .a = 1, .r = 31, .g = 20, .b = 0 };
    const trigger_fill = sdk.ARGB1555{ .a = 1, .r = 20, .g = 10, .b = 31 };
    const dpad_color = sdk.ARGB1555{ .a = 1, .r = 12, .g = 12, .b = 14 };
    const south_btn = sdk.ARGB1555{ .a = 1, .r = 0, .g = 24, .b = 0 };
    const east_btn = sdk.ARGB1555{ .a = 1, .r = 28, .g = 8, .b = 8 };
    const west_btn = sdk.ARGB1555{ .a = 1, .r = 8, .g = 8, .b = 28 };
    const north_btn = sdk.ARGB1555{ .a = 1, .r = 28, .g = 28, .b = 0 };
};

const Layout = struct {
    const screen_w = fb.width;
    const screen_h = fb.height;
    const center_x = screen_w / 2;

    const base_y = 45;
    const left_x = 125;
    const right_x = 305;

    const left_stick_x = 155;
    const right_stick_x = 325;
    const stick_y = 165;

    const dpad_size = 18;
    const dpad_btn = 16;

    const btn_size = 18;
    const btn_spacing = 22;

    const stick_radius = 22;
    const stick_dot = 4;

    const trigger_w = 50;
    const trigger_h = 10;

    const bumper_w = 55;
    const bumper_h = 10;
};

inline fn fillRect(x: u16, y: u16, w: u16, h: u16, color: sdk.ARGB1555) void {
    sdk.blitter.rect(fb.id, .{
        .color = color,
        .pos = .{ .x = x, .y = y },
        .w = w,
        .h = h,
    });
}

inline fn fillRectCentered(cx: u16, y: u16, w: u16, h: u16, color: sdk.ARGB1555) void {
    sdk.blitter.rect(fb.id, .{
        .color = color,
        .pos = .{ .x = cx, .y = y },
        .w = w,
        .h = h,
        .origin = .top,
    });
}

inline fn fillCircle(cx: u16, cy: u16, r: u16, color: sdk.ARGB1555) void {
    sdk.blitter.circle(fb.id, .{
        .color = color,
        .pos = .{ .x = cx, .y = cy },
        .r = r,
        .origin = .center,
    });
}

fn drawDpad(x: u16, y: u16, controls: *volatile sdk.Gamepad.Controls) void {
    const size = Layout.dpad_size;
    const btn = Layout.dpad_btn;

    fillRect(x + size, y, btn, size * 3, Colors.dpad_color);
    fillRect(x, y + size, size * 3, btn, Colors.dpad_color);

    if (controls.up.down) {
        fillRect(x + size, y, btn, size, Colors.pressed);
    }

    if (controls.down.down) {
        fillRect(x + size, y + size * 2, btn, size, Colors.pressed);
    }

    if (controls.left.down) {
        fillRect(x, y + size, size, btn, Colors.pressed);
    }

    if (controls.right.down) {
        fillRect(x + size * 2, y + size, size, btn, Colors.pressed);
    }

    sdk.utils.Text.drawChar(fb, x + size + 4, y + 5, '^', Colors.text_dim);
    sdk.utils.Text.drawChar(fb, x + size + 4, y + size * 2 + 5, 'v', Colors.text_dim);
    sdk.utils.Text.drawChar(fb, x + 5, y + size + 4, '<', Colors.text_dim);
    sdk.utils.Text.drawChar(fb, x + size * 2 + 5, y + size + 4, '>', Colors.text_dim);
}

fn drawFaceButton(cx: u16, cy: u16, char: u8, pressed: bool, base_color: sdk.ARGB1555) void {
    const r = Layout.btn_size / 2;

    fillCircle(cx, cy, r, Colors.inactive);

    if (pressed) {
        fillCircle(cx, cy, r - 2, base_color);
    }

    sdk.utils.Text.drawChar(fb, cx - 3, cy - 3, char, if (pressed) Colors.text_white else Colors.text_dim);
}

fn drawFaceButtons(x: u16, y: u16, controls: *volatile sdk.Gamepad.Controls) void {
    const sp = Layout.btn_spacing;
    const r = Layout.btn_size / 2;

    drawFaceButton(x + sp + r, y + sp * 2 + r, 'A', controls.south.down, Colors.south_btn);
    drawFaceButton(x + sp * 2 + r, y + sp + r, 'B', controls.east.down, Colors.east_btn);
    drawFaceButton(x + r, y + sp + r, 'X', controls.west.down, Colors.west_btn);
    drawFaceButton(x + sp + r, y + r, 'Y', controls.north.down, Colors.north_btn);
}

fn drawStick(cx: u16, cy: u16, stick: sdk.Gamepad.StickState, clicked: bool) void {
    const r = Layout.stick_radius;
    const dot_r = Layout.stick_dot;

    fillCircle(cx, cy, r, Colors.stick_bg);

    fillRect(cx -| r, cy -| r, r * 2, 1, Colors.inactive);
    fillRect(cx -| r, cy + r - 1, r * 2, 1, Colors.inactive);
    fillRect(cx -| r, cy -| r, 1, r * 2, Colors.inactive);
    fillRect(cx + r - 1, cy -| r, 1, r * 2, Colors.inactive);

    fillRect(cx -| r + 4, cy, r * 2 - 8, 1, Colors.inactive);
    fillRect(cx, cy -| r + 4, 1, r * 2 - 8, Colors.inactive);

    const max_offset: i32 = r - dot_r - 3;
    const offset_x: i16 = @intCast(@divTrunc(@as(i32, stick.x) * max_offset, 32767));
    const offset_y: i16 = @intCast(@divTrunc(@as(i32, stick.y) * max_offset, 32767));

    const dot_cx: u16 = @intCast(@as(i32, cx) + offset_x);
    const dot_cy: u16 = @intCast(@as(i32, cy) + offset_y);

    fillCircle(dot_cx, dot_cy, dot_r, if (clicked) Colors.pressed else Colors.stick_pos);
}

fn drawTrigger(x: u16, y: u16, value: u16, label: []const u8) void {
    const w = Layout.trigger_w;
    const h = Layout.trigger_h;

    fillRect(x, y, w, h, Colors.inactive);
    fillRect(x + 1, y + 1, w - 2, h - 2, Colors.stick_bg);

    if (value > 0) {
        const fill_w: u16 = @intCast(@min(@as(u32, value) * (w - 2) / 32767, w - 2));

        fillRect(x + 1, y + 1, fill_w, h - 2, Colors.trigger_fill);
    }

    sdk.utils.Text.draw(fb, x + w + 4, y + 1, label, Colors.text_dim);
}

fn drawBumper(x: u16, y: u16, pressed: bool, label: []const u8) void {
    const w = Layout.bumper_w;
    const h = Layout.bumper_h;

    fillRect(x, y, w, h, if (pressed) Colors.pressed else Colors.inactive);
    sdk.utils.Text.draw(fb, x + (w - 16) / 2, y + 1, label, if (pressed) Colors.text_white else Colors.text_dim);
}

fn drawStartSelect(y: u16, controls: *volatile sdk.Gamepad.Controls) void {
    const btn_w: u16 = 28;
    const btn_h: u16 = 10;
    const gap: u16 = 24;

    fillRectCentered(Layout.center_x - gap, y, btn_w, btn_h, if (controls.select.down) Colors.pressed else Colors.inactive);
    sdk.utils.Text.drawCentered(fb, Layout.center_x - gap / 2 - btn_w / 2 + 2, y + 1, "SEL", if (controls.select.down) Colors.text_white else Colors.text_dim);

    fillRectCentered(Layout.center_x + gap, y, btn_w, btn_h, if (controls.start.down) Colors.pressed else Colors.inactive);
    sdk.utils.Text.drawCentered(fb, Layout.center_x + gap / 2 + btn_w / 2 - 2, y + 1, "STA", if (controls.start.down) Colors.text_white else Colors.text_dim);
}

fn render() void {
    const controls = sdk.gamepad1.status().controls();

    sdk.blitter.clear(fb.id, .{ .color = Colors.bg });

    sdk.utils.Text.drawCenteredWithShadow(fb, Layout.center_x, 8, "GAMEPAD TEST", Colors.text_white, Colors.shadow);

    const connected = sdk.gamepad1.status().connected;

    fillRectCentered(Layout.center_x, 22, 88, 12, if (connected) Colors.connected else Colors.disconnected);
    sdk.utils.Text.drawCentered(fb, Layout.center_x, 25, if (connected) "CONNECTED" else "DISCONNECT", Colors.text_white);

    if (!connected) {
        sdk.utils.Text.drawCentered(fb, Layout.center_x, 135, "Connect gamepad", Colors.text_dim);

        return;
    }

    drawBumper(Layout.left_x, Layout.base_y, controls.left_bumper.down, "LB");
    drawBumper(Layout.right_x, Layout.base_y, controls.right_bumper.down, "RB");

    drawTrigger(Layout.left_x, Layout.base_y + 14, controls.left_trigger, "LT");
    drawTrigger(Layout.right_x, Layout.base_y + 14, controls.right_trigger, "RT");

    drawDpad(Layout.left_x + 5, Layout.base_y + 35, controls);
    drawFaceButtons(Layout.right_x - 10, Layout.base_y + 30, controls);

    drawStartSelect(Layout.base_y + 55, controls);

    drawStick(Layout.left_stick_x, Layout.stick_y, controls.left_stick, controls.left_stick_click.down);
    drawStick(Layout.right_stick_x, Layout.stick_y, controls.right_stick, controls.right_stick_click.down);

    var buf: [24]u8 = undefined;

    const lx = std.fmt.bufPrint(&buf, "{d:>6},{d:>6}", .{ controls.left_stick.x, controls.left_stick.y }) catch "?";
    sdk.utils.Text.draw(fb, Layout.left_stick_x - 52, Layout.stick_y + 28, lx, Colors.text_dim);

    const rx = std.fmt.bufPrint(&buf, "{d:>6},{d:>6}", .{ controls.right_stick.x, controls.right_stick.y }) catch "?";
    sdk.utils.Text.draw(fb, Layout.right_stick_x - 52, Layout.stick_y + 28, rx, Colors.text_dim);
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
        sdk.gpu.switchFramebuffer(.off);
        render();
        sdk.gpu.switchFramebuffer(fb.id);

        waitForVBlank();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
