// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const ondatra = @import("ondatra");
pub const arch = ondatra.guest;

pub const utils = @import("utils.zig");

pub const ARGB1555 = packed struct(u16) {
    b: u5,
    g: u5,
    r: u5,
    a: u1,

    pub inline fn fromRGBA(r: u8, g: u8, b: u8, a: u8) ARGB1555 {
        return .{
            .b = @truncate(b >> 3),
            .g = @truncate(g >> 3),
            .r = @truncate(r >> 3),
            .a = @truncate(a >> 7),
        };
    }

    pub inline fn fromRGB(r: u8, g: u8, b: u8) ARGB1555 {
        return fromRGBA(r, g, b, 255);
    }
};

pub const Memory = struct {
    pub const BOOT_INFO = 0x0000_1000;

    pub const CLINT = 0x0200_0000;

    pub const PLIC = 0x0C00_0000;

    pub const GPU = 0x0C00_1000;
    comptime {
        std.debug.assert(GPU >= PLIC + @sizeOf(Plic));
    }

    pub const PRNG = 0x0C00_2000;
    comptime {
        std.debug.assert(PRNG >= GPU + @sizeOf(Gpu));
    }

    pub const UART = 0x1000_0000;

    pub const BLITTER = 0x3000_0000;
    comptime {
        std.debug.assert(BLITTER >= UART + @sizeOf(u8));
    }

    pub const GAMEPAD1 = 0x3000_1000;
    comptime {
        std.debug.assert(GAMEPAD1 >= BLITTER + @sizeOf(Blitter));
    }

    pub const GAMEPAD2 = 0x3000_1100;
    comptime {
        std.debug.assert(GAMEPAD2 >= GAMEPAD1 + @sizeOf(Gamepad));
    }

    pub const AUDIO = 0x3000_2000;
    comptime {
        std.debug.assert(AUDIO >= GAMEPAD2 + @sizeOf(Gamepad));
    }

    pub const DMA = 0x3000_3000;
    comptime {
        std.debug.assert(DMA >= AUDIO + @sizeOf(Audio));
    }

    pub const FRAMEBUFFER1 = 0x4000_0000;
    comptime {
        std.debug.assert(FRAMEBUFFER1 >= DMA + @sizeOf(Dma));
    }

    pub const FRAMEBUFFER2 = 0x400F_D200;
    comptime {
        std.debug.assert(FRAMEBUFFER2 >= FRAMEBUFFER1 + (fb1.width * fb1.height * @sizeOf(ARGB1555)));
    }

    pub const FRAMEBUFFER3 = 0x4016_DA00;
    comptime {
        std.debug.assert(FRAMEBUFFER3 >= FRAMEBUFFER2 + (fb2.width * fb2.height * @sizeOf(ARGB1555)));
    }

    pub const RAM_START: u32 = 0x8000_0000;
    comptime {
        std.debug.assert(RAM_START >= FRAMEBUFFER3 + (fb3.width * fb3.height * @sizeOf(ARGB1555)));
    }
};

pub const BootInfo = extern struct {
    cpu_frequency: u64,
    ram_size: u32,
    fps: u32,
    free_ram_start: u32,
    external_storage_size: u32,
    nvram_storage_size: u32,
};

pub const boot_info: *volatile BootInfo = @ptrFromInt(Memory.BOOT_INFO);

pub const Clint = extern struct {
    pub const Config = extern struct {
        mtime: u64,
        mtimecmp: u64,
    };

    _config: Config,

    pub inline fn config(this: *volatile Clint) *volatile Config {
        return &this._config;
    }

    pub inline fn readMtime(this: *volatile Clint) u64 {
        const bytes = std.mem.asBytes(&this.config().mtime);

        while (true) {
            const hi1 = std.mem.bytesToValue(u32, bytes[4..]);
            const lo = std.mem.bytesToValue(u32, bytes[0..]);
            const hi2 = std.mem.bytesToValue(u32, bytes[4..]);

            if (hi1 == hi2) {
                return @as(u64, hi1) << 32 | lo;
            }
        }
    }

    pub inline fn readMtimeNs(this: *volatile Clint) u64 {
        const ticks = this.readMtime();

        return utils.ticksToNs(ticks);
    }

    pub inline fn readMtimecmp(this: *volatile Clint) u64 {
        const bytes = std.mem.asBytes(&this.config().mtimecmp);

        while (true) {
            const hi1 = std.mem.bytesToValue(u32, bytes[4..]);
            const lo = std.mem.bytesToValue(u32, bytes[0..]);
            const hi2 = std.mem.bytesToValue(u32, bytes[4..]);

            if (hi1 == hi2) {
                return @as(u64, hi1) << 32 | lo;
            }
        }
    }

    pub inline fn readMtimecmpNs(this: *volatile Clint) u64 {
        const ticks = this.readMtimecmp();

        return utils.ticksToNs(ticks);
    }

    pub inline fn interruptAfter(this: *volatile Clint, ticks: u64) void {
        const mtime = this.readMtime();

        this.config().mtimecmp = mtime + ticks;
    }

    pub inline fn interruptAt(this: *volatile Clint, ticks: u64) void {
        this.config().mtimecmp = ticks;
    }

    pub inline fn interruptAfterNs(this: *volatile Clint, ns: u64) void {
        const ticks = utils.nsToTicks(ns);

        this.interruptAfter(ticks);
    }

    pub inline fn interruptAtNs(this: *volatile Clint, ns: u64) void {
        const ticks = utils.nsToTicks(ns);

        this.interruptAt(ticks);
    }
};

pub const clint: *volatile Clint = @ptrFromInt(Memory.CLINT);

pub const Plic = extern struct {
    pub const Device = enum(u8) {
        none = 0,
        gpu = 1,
        _,
    };

    claim: Device = .none,
};

pub const plic: *volatile Plic = @ptrFromInt(Memory.PLIC);

pub const FramebufferId = enum(u8) {
    off = 0,
    fb1 = 1,
    fb2 = 2,
    fb3 = 3,
};

pub const Gpu = extern struct {
    pub const Config = extern struct {
        vblank_interrupts: bool = false,
        active_framebuffer: FramebufferId = .off,
    };

    _config: Config = .{},

    pub inline fn config(this: *volatile Gpu) *volatile Config {
        return &this._config;
    }

    pub inline fn setVblankInterrupts(this: *volatile Gpu, enabled: bool) void {
        this.config().vblank_interrupts = enabled;
    }

    pub inline fn vblankInterrupts(this: *volatile Gpu) bool {
        return this.config().vblank_interrupts;
    }

    pub inline fn switchFramebuffer(this: *volatile Gpu, id: FramebufferId) void {
        this.config().active_framebuffer = id;
    }

    pub inline fn activeFramebuffer(this: *volatile Gpu) FramebufferId {
        return this.config().active_framebuffer;
    }
};

pub const gpu: *volatile Gpu = @ptrFromInt(Memory.GPU);

pub const Prng = extern struct {
    pub const Status = extern struct {
        /// Returns a random byte
        value: u8,
    };

    _status: Status,

    pub inline fn status(this: *volatile Prng) *volatile Status {
        return &this._status;
    }

    fn fill(ptr: *anyopaque, buf: []u8) void {
        _ = ptr;

        for (0..buf.len) |i| {
            buf[i] = prng.status().value;
        }
    }

    pub inline fn interface() std.Random {
        return .{
            .ptr = undefined,
            .fillFn = fill,
        };
    }
};

pub const prng: *volatile Prng = @ptrFromInt(Memory.PRNG);

pub const MMIOWriter = struct {
    dst: *volatile u8,
    writer: std.Io.Writer,

    pub fn init(dst: *volatile u8) MMIOWriter {
        return .{
            .dst = dst,
            .writer = .{
                .buffer = &.{},
                .end = 0,
                .vtable = &.{
                    .drain = drain,
                },
            },
        };
    }

    pub inline fn print(this: *MMIOWriter, comptime fmt: []const u8, args: anytype) void {
        this.writer.print(fmt, args) catch unreachable;
    }

    inline fn writeSlice(dst: *volatile u8, data: []const u8) void {
        for (data) |chr| {
            dst.* = chr;
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const this: *MMIOWriter = @fieldParentPtr("writer", w);

        std.debug.assert(data.len != 0);

        var consumed: usize = 0;
        const pattern = data[data.len - 1];
        const splat_len = pattern.len * splat;

        if (w.end != 0) {
            writeSlice(this.dst, w.buffered());
            w.end = 0;
        }

        for (data[0 .. data.len - 1]) |bytes| {
            writeSlice(this.dst, bytes);
            consumed += bytes.len;
        }

        switch (pattern.len) {
            0 => {},
            else => {
                for (0..splat) |_| {
                    writeSlice(this.dst, pattern);
                }
            },
        }
        consumed += splat_len;

        return consumed;
    }
};

pub var uart: MMIOWriter = .init(@ptrFromInt(Memory.UART));

pub const Blitter = extern struct {
    pub const Cmd = enum(u8) {
        none = 0,
        clear = 1,
        rect = 2,
        circle = 3,
        copy = 4,
        _,
    };

    pub const Args = extern union {
        pub const Mode = enum(u8) {
            crop,
            wrap,
        };

        pub const Origin = enum(u8) {
            top_left,
            top,
            top_right,
            right,
            bottom_right,
            bottom,
            bottom_left,
            left,
            center,
        };

        pub const Position = extern struct {
            x: u16 = 0,
            y: u16 = 0,
        };

        pub const Clear = extern struct {
            color: ARGB1555,
        };

        pub const Rect = extern struct {
            color: ARGB1555 = .{ .a = 1, .r = 0, .g = 0, .b = 0 },
            pos: Position = .{},
            w: u16 = 0,
            h: u16 = 0,
            origin: Origin = .top_left,
            mode: Mode = .crop,
        };

        pub const Circle = extern struct {
            color: ARGB1555 = .{ .a = 1, .r = 0, .g = 0, .b = 0 },
            pos: Position = .{},
            r: u16 = 0,
            origin: Origin = .top_left,
            mode: Mode = .crop,
        };

        pub const Copy = extern struct {
            pub const Alpha = enum(u8) {
                /// Ignore alpha channel, copy all pixels as-is (fastest)
                ignore,
                /// Use alpha as mask: skip pixels with a=0, copy pixels with a=1
                mask,
                _,
            };

            /// Address of the source pixels.
            src: u32,
            w: u16 = 0,
            h: u16 = 0,
            src_pos: Position = .{},
            dst_pos: Position = .{},
            alpha: Alpha = .ignore,
            mode: Mode = .crop,
        };

        clear: Clear,
        rect: Rect,
        circle: Circle,
        copy: Copy,
    };

    pub const Config = extern struct {
        target: FramebufferId,
        cmd: Cmd,
        args: Args,
    };

    pub const Action = extern struct {
        /// Write any data to execute the cmd
        execute: u8,
    };

    _action: Action,
    _config: Config,

    pub inline fn config(this: *volatile Blitter) *volatile Config {
        return &this._config;
    }

    pub inline fn action(this: *volatile Blitter) *volatile Action {
        return &this._action;
    }

    pub inline fn execute(this: *volatile Blitter) void {
        this.action().execute = 1;
    }

    pub inline fn clear(this: *volatile Blitter, target: FramebufferId, args: Args.Clear) void {
        this.config().* = .{
            .target = target,
            .cmd = .clear,
            .args = .{ .clear = args },
        };
        this.execute();
    }

    pub inline fn rect(this: *volatile Blitter, target: FramebufferId, args: Args.Rect) void {
        this.config().* = .{
            .target = target,
            .cmd = .rect,
            .args = .{ .rect = args },
        };
        this.execute();
    }

    pub inline fn circle(this: *volatile Blitter, target: FramebufferId, args: Args.Circle) void {
        this.config().* = .{
            .target = target,
            .cmd = .circle,
            .args = .{ .circle = args },
        };
        this.execute();
    }

    pub inline fn copy(this: *volatile Blitter, target: FramebufferId, args: Args.Copy) void {
        this.config().* = .{
            .target = target,
            .cmd = .copy,
            .args = .{ .copy = args },
        };
        this.execute();
    }
};

pub const blitter: *volatile Blitter = @ptrFromInt(Memory.BLITTER);

pub const Gamepad = extern struct {
    pub const Direction = enum {
        none,
        north,
        north_east,
        east,
        south_east,
        south,
        south_west,
        west,
        north_west,
    };

    pub const Cardinal = enum {
        none,
        north,
        east,
        south,
        west,
    };

    pub const ButtonState = extern struct {
        down: bool = false,
        sticky: bool = false,
    };

    pub const StickState = extern struct {
        x: i16 = 0,
        y: i16 = 0,

        pub inline fn withDeadzone(this: StickState, deadzone: i16) StickState {
            return .{
                .x = if (this.absX() < deadzone) 0 else this.x,
                .y = if (this.absY() < deadzone) 0 else this.y,
            };
        }

        pub inline fn isActive(this: StickState, deadzone: i16) bool {
            return this.absX() >= deadzone or this.absY() >= deadzone;
        }

        pub fn cardinal(this: StickState, deadzone: i16) Cardinal {
            if (!this.isActive(deadzone)) {
                return .none;
            }

            const abs_x = this.absX();
            const abs_y = this.absY();

            if (abs_x > abs_y) {
                return if (this.x > 0) .east else .west;
            } else {
                return if (this.y > 0) .south else .north;
            }
        }

        pub fn direction(this: StickState, deadzone: i16) Direction {
            if (!this.isActive(deadzone)) {
                return .none;
            }

            const abs_x = this.absX();
            const abs_y = this.absY();

            const min_val = @min(abs_x, abs_y);
            const max_val = @max(abs_x, abs_y);
            const is_diagonal = min_val >= max_val / 2 - max_val / 8;

            if (is_diagonal) {
                return if (this.y < 0)
                    (if (this.x > 0) .north_east else .north_west)
                else
                    (if (this.x > 0) .south_east else .south_west);
            } else if (abs_x > abs_y) {
                return if (this.x > 0) .east else .west;
            } else {
                return if (this.y > 0) .south else .north;
            }
        }

        pub inline fn isPointing(this: StickState, dir: Cardinal, deadzone: i16) bool {
            return this.cardinal(deadzone) == dir;
        }

        pub inline fn isPointingDir(this: StickState, dir: Direction, deadzone: i16) bool {
            return this.direction(deadzone) == dir;
        }

        pub inline fn absX(this: StickState) u16 {
            return @abs(this.x);
        }

        pub inline fn absY(this: StickState) u16 {
            return @abs(this.y);
        }

        pub inline fn magnitude(this: StickState) u16 {
            const abs_x = this.absX();
            const abs_y = this.absY();
            const max_val = @max(abs_x, abs_y);
            const min_val = @min(abs_x, abs_y);

            return max_val + min_val / 2;
        }

        pub inline fn magnitudeNorm(this: StickState) u8 {
            const mag = this.magnitude();

            return @intCast(@min(mag >> 7, 255));
        }
    };

    pub const TriggerState = u16;

    pub const Rumble = extern struct {
        /// Milliseconds. MAX_U32 = infinite.
        duration: u32 = 0,
        weak: u16 = 0,
        strong: u16 = 0,
    };

    pub const Controls = extern struct {
        left_stick: StickState = .{},
        right_stick: StickState = .{},
        left_trigger: TriggerState = 0,
        right_trigger: TriggerState = 0,
        up: ButtonState = .{},
        down: ButtonState = .{},
        left: ButtonState = .{},
        right: ButtonState = .{},
        north: ButtonState = .{},
        south: ButtonState = .{},
        east: ButtonState = .{},
        west: ButtonState = .{},
        left_bumper: ButtonState = .{},
        right_bumper: ButtonState = .{},
        select: ButtonState = .{},
        start: ButtonState = .{},
        left_stick_click: ButtonState = .{},
        right_stick_click: ButtonState = .{},
    };

    pub const Status = extern struct {
        _controls: Controls = .{},
        connected: bool = false,

        pub inline fn controls(this: *volatile Status) *volatile Controls {
            return &this._controls;
        }
    };

    pub const Config = extern struct {
        _rumble: Rumble = .{},

        pub inline fn rumble(this: *volatile Config) *volatile Rumble {
            return &this._rumble;
        }
    };

    pub const Action = extern struct {
        /// Write any data to clear all the sticky bytes from buttons.
        clear_sticky: u8 = 0,
        /// Write any data to trigger rumble update.
        update_rumble: u8 = 0,
    };

    _status: Status = .{},
    _config: Config = .{},
    _action: Action = .{},

    pub inline fn status(this: *volatile Gamepad) *volatile Status {
        return &this._status;
    }

    pub inline fn config(this: *volatile Gamepad) *volatile Config {
        return &this._config;
    }

    pub inline fn action(this: *volatile Gamepad) *volatile Action {
        return &this._action;
    }

    pub inline fn clearSticky(this: *volatile Gamepad) void {
        this.action().clear_sticky = 1;
    }

    pub inline fn updateRumble(this: *volatile Gamepad) void {
        this.action().update_rumble = 1;
    }

    pub inline fn rumble(this: *volatile Gamepad, weak: u16, strong: u16, duration: u32) void {
        this.config().rumble().* = .{
            .weak = weak,
            .strong = strong,
            .duration = duration,
        };
        this.updateRumble();
    }

    pub inline fn rumbleOff(this: *volatile Gamepad) void {
        this.rumble(0, 0, 0);
    }

    pub inline fn isConnected(this: *volatile Gamepad) bool {
        return this.status().connected;
    }
};

pub const gamepad1: *volatile Gamepad = @ptrFromInt(Memory.GAMEPAD1);
pub const gamepad2: *volatile Gamepad = @ptrFromInt(Memory.GAMEPAD2);

pub const Audio = extern struct {
    pub const SAMPLE_RATE = 22050;
    pub const VOICE_COUNT = 8;
    pub const MAX_BLOCK_ALIGN = 2048;
    pub const MAX_SAMPLES_PER_BLOCK = MAX_BLOCK_ALIGN * 2 - 7;

    comptime {
        std.debug.assert(MAX_SAMPLES_PER_BLOCK == 4089);
    }

    pub const Voice = extern struct {
        /// Relative to the RAM start.
        sample_addr: u32 = 0,
        sample_len: u32 = 0,
        // Used for compressed samples.
        block_align: u16 = 256,
        samples_per_block: u16 = 505,

        loop_start: u32 = 0,
        loop_end: u32 = 0,

        volume_l: f32 = 1.0,
        volume_r: f32 = 1.0,

        pitch: f32 = 1.0,
        position: f32 = 0,
        playing: bool = false,
        loop_enabled: bool = false,
        compressed: bool = false,

        pub inline fn play(this: *volatile Voice) void {
            this.playing = true;
        }

        pub inline fn pause(this: *volatile Voice) void {
            this.playing = false;
        }

        pub inline fn stop(this: *volatile Voice) void {
            this.playing = false;
            this.position = 0;
        }

        pub inline fn restart(this: *volatile Voice) void {
            this.position = 0;
            this.playing = true;
        }

        pub inline fn seek(this: *volatile Voice, pos: f32) void {
            this.position = pos;
        }

        pub inline fn setVolume(this: *volatile Voice, left: f32, right: f32) void {
            this.volume_l = left;
            this.volume_r = right;
        }

        /// -1.0 = left, 0.0 = center, 1.0 = right
        pub inline fn setPan(this: *volatile Voice, pan: f32) void {
            this.volume_l = 1.0 - @max(0.0, pan);
            this.volume_r = 1.0 + @min(0.0, pan);
        }
    };

    pub const Config = extern struct {
        enabled: bool = false,
        master_volume: f32 = 1.0,
        voices: [VOICE_COUNT]Voice = .{Voice{}} ** VOICE_COUNT,
    };

    _config: Config = .{},

    pub inline fn config(this: *volatile Audio) *volatile Config {
        return &this._config;
    }

    pub inline fn setEnabled(this: *volatile Audio, state: bool) void {
        this.config().enabled = state;
    }

    pub inline fn enabled(this: *volatile Audio) bool {
        return this.config().enabled;
    }

    pub inline fn setMasterVolume(this: *volatile Audio, value: f32) void {
        this.config().master_volume = value;
    }

    pub inline fn masterVolume(this: *volatile Audio) f32 {
        return this.config().master_volume;
    }

    pub inline fn voice(this: *volatile Audio, id: u4) *volatile Voice {
        return &this.config().voices[id];
    }
};

pub const audio: *volatile Audio = @ptrFromInt(Memory.AUDIO);

pub const Dma = extern struct {
    pub const Device = enum(u8) {
        none = 0,
        external_storage = 1,
        nvram_storage = 2,
        _,
    };

    pub const Mode = enum(u8) {
        /// Device -> RAM
        read = 0,
        /// RAM -> Device
        write = 1,
        /// Pattern -> Device (repeat)
        fill = 2,
        _,
    };

    pub const Config = extern struct {
        src_address: u32 = 0,
        dst_address: u32 = 0,
        len: u32 = 0,
        pattern_len: u32 = 0,
        device: Device = .none,
        mode: Mode = .read,
    };

    pub const Action = extern struct {
        execute: u8 = 0,
    };

    _config: Config = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Dma) *volatile Config {
        return &this._config;
    }

    pub inline fn action(this: *volatile Dma) *volatile Action {
        return &this._action;
    }

    pub inline fn read(this: *volatile Dma, device: Device, address: u32, dst: []u8) void {
        this.config().* = .{
            .src_address = address,
            .dst_address = @intFromPtr(dst.ptr) - Memory.RAM_START,
            .len = dst.len,
            .device = device,
            .mode = .read,
        };
        this.action().execute = 1;
    }

    pub inline fn write(this: *volatile Dma, device: Device, address: u32, src: []const u8) void {
        this.config().* = .{
            .src_address = @intFromPtr(src.ptr) - Memory.RAM_START,
            .dst_address = address,
            .len = src.len,
            .device = device,
            .mode = .write,
        };
        this.action().execute = 1;
    }

    pub inline fn fill(this: *volatile Dma, device: Device, address: u32, pattern: []const u8, total_len: u32) void {
        this.config().* = .{
            .src_address = @intFromPtr(pattern.ptr) - Memory.RAM_START,
            .dst_address = address,
            .len = total_len,
            .pattern_len = pattern.len,
            .device = device,
            .mode = .fill,
        };
        this.action().execute = 1;
    }

    pub inline fn memset(this: *volatile Dma, device: Device, address: u32, byte: u8, len: u32) void {
        const pattern: [1]u8 = .{byte};

        this.fill(device, address, &pattern, len);
    }
};

pub const dma: *volatile Dma = @ptrFromInt(Memory.DMA);

pub const Framebuffer = struct {
    width: u32,
    height: u32,
    id: FramebufferId,
    pixels: []volatile ARGB1555,

    pub fn new(comptime width: u32, comptime height: u32, id: FramebufferId, address: usize) Framebuffer {
        const len = width * height;

        return .{
            .width = width,
            .height = height,
            .id = id,
            .pixels = @as([*]volatile ARGB1555, @ptrFromInt(address))[0..len],
        };
    }

    pub inline fn ptr(this: Framebuffer, x: u16, y: u16) *volatile ARGB1555 {
        return &this.pixels[y * this.width + x];
    }

    pub inline fn get(this: Framebuffer, x: u16, y: u16) ARGB1555 {
        return this.ptr(x, y).*;
    }

    pub inline fn set(this: Framebuffer, x: u16, y: u16, color: ARGB1555) void {
        this.ptr(x, y).* = color;
    }

    pub inline fn pixelsAsBytes(this: Framebuffer) []volatile u8 {
        return std.mem.sliceAsBytes(this.pixels);
    }
};

pub const fb1: Framebuffer = .new(960, 540, .fb1, Memory.FRAMEBUFFER1);

pub const fb2: Framebuffer = .new(640, 360, .fb2, Memory.FRAMEBUFFER2);

pub const fb3: Framebuffer = .new(480, 270, .fb3, Memory.FRAMEBUFFER3);
