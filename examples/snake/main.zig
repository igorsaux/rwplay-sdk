// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, rt: ?usize) noreturn {
    _ = rt;

    sdk.uart.print("Panic: {s}\n", .{msg});

    while (true) {}
}

const Config = struct {
    const fb = sdk.fb3;

    // World dimensions (in tiles)
    const world_width: u16 = 32;
    const world_height: u16 = 32;
    const tile_size: u16 = 8;

    // Calculated dimensions
    const world_pixel_width: u16 = world_width * tile_size;
    const world_pixel_height: u16 = world_height * tile_size;

    // World position on screen (centered vertically, with margins for UI)
    const world_x: u16 = (fb.width - world_pixel_width) / 2;
    const world_y: u16 = (fb.height - world_pixel_height) / 2;

    // UI positions
    const ui_left_x: u16 = 4;
    const ui_right_x: u16 = world_x + world_pixel_width + 8;
    const ui_top_y: u16 = 4;

    // Gameplay timing (milliseconds)
    const initial_speed: u64 = 800;
    const min_speed: u64 = 100;
    const turbo_divisor: u64 = 4;
    const turbo_min: u64 = 25;
    const speed_reduction_per_segment: u64 = 15;

    // Visual effects
    const blink_interval_ms: u64 = 300;
    const death_rumble_duration_ms: u32 = 1500;
    const eat_rumble_duration_ms: u32 = 200;
    const max_trail_points = 6;

    // Particles
    const max_particles: usize = 32;
    const particle_lifetime_ms: u64 = 500;
    const particles_per_eat: u8 = 8;

    // Screen shake
    const screen_shake_duration_ms: u64 = 400;
    const screen_shake_intensity: i16 = 4;

    // Input
    const stick_deadzone: i16 = 8000;

    // Audio
    const bgm_volume: f32 = 0.15;
    const sfx_volume: f32 = 0.5;

    const max_snake_length: u16 = world_width * world_height - 1;
};

const Colors = struct {
    const background: sdk.ARGB1555 = .fromRGB(52, 84, 58);
    const background_dark: sdk.ARGB1555 = .fromRGB(20, 30, 22);
    const collision_highlight: sdk.ARGB1555 = .fromRGB(255, 60, 60);

    const ui_text: sdk.ARGB1555 = .fromRGB(255, 255, 255);
    const ui_shadow: sdk.ARGB1555 = .fromRGB(20, 20, 20);
    const ui_score: sdk.ARGB1555 = .fromRGB(255, 220, 100);
    const ui_label: sdk.ARGB1555 = .fromRGB(180, 180, 180);
    const ui_highlight: sdk.ARGB1555 = .fromRGB(100, 255, 100);

    const game_over_text: sdk.ARGB1555 = .fromRGB(255, 80, 80);
    const new_high_score_text: sdk.ARGB1555 = .fromRGB(255, 213, 0);
    const paused_text: sdk.ARGB1555 = .fromRGB(100, 200, 255);

    const particle_colors = [_]sdk.ARGB1555{
        .fromRGB(255, 255, 100),
        .fromRGB(255, 220, 50),
        .fromRGB(255, 180, 30),
        .fromRGB(255, 140, 20),
        .fromRGB(255, 100, 10),
        .fromRGB(255, 60, 5),
    };

    const trail_colors = [_]sdk.ARGB1555{
        .fromRGB(80, 140, 80),
        .fromRGB(70, 120, 70),
        .fromRGB(60, 100, 60),
        .fromRGB(55, 90, 58),
    };
};

const Assets = struct {
    const SnakeHead = struct {
        var north: sdk.utils.Frame = .empty();
        var east: sdk.utils.Frame = .empty();
        var south: sdk.utils.Frame = .empty();
        var west: sdk.utils.Frame = .empty();

        inline fn forDirection(dir: Direction) sdk.utils.Frame {
            return switch (dir) {
                .north => north,
                .east => east,
                .south => south,
                .west => west,
            };
        }
    };

    var food: sdk.utils.Frame = .empty();
    var snake_body: sdk.utils.Frame = .empty();

    var grass = [_]?sdk.utils.Frame{
        null,
        .empty(),
        .empty(),
        .empty(),
    };

    var bgm: sdk.utils.Samples = .empty();
    var sfx_eat: sdk.utils.Samples = .empty();
    var sfx_game_over: sdk.utils.Samples = .empty();

    pub fn load(allocator: std.mem.Allocator) bool {
        var iter_buffer: [1024]u8 = undefined;
        var iter: sdk.utils.RomImageIterator = .dma(&iter_buffer);

        var file_buffer: [4096]u8 = undefined;

        while (iter.nextAlloc(allocator)) |it| {
            var freader: sdk.utils.DmaReader = .init(.external_storage, it.content_pos, &file_buffer);

            if (std.mem.eql(u8, it.name, "/bgm.wav")) {
                bgm = sdk.utils.Wav.fromReader(allocator, &freader.interface, .{ .loop_start = 0 }) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/eat.wav")) {
                sfx_eat = sdk.utils.Wav.fromReader(allocator, &freader.interface, .{}) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/game_over.wav")) {
                sfx_game_over = sdk.utils.Wav.fromReader(allocator, &freader.interface, .{}) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/food.tga")) {
                food = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/snake_body.tga")) {
                snake_body = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/snake_north.tga")) {
                SnakeHead.north = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/snake_east.tga")) {
                SnakeHead.east = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/snake_south.tga")) {
                SnakeHead.south = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/snake_west.tga")) {
                SnakeHead.west = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/grass_1.tga")) {
                grass[1] = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/grass_2.tga")) {
                grass[2] = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else if (std.mem.eql(u8, it.name, "/grass_3.tga")) {
                grass[3] = sdk.utils.Tga.fromReader(allocator, &freader.interface) catch |err| {
                    sdk.uart.print("failed to parse {s}: {t}\n", .{ it.name, err });

                    return false;
                };
            } else {
                continue;
            }
        }

        return true;
    }
};

const Direction = enum(u2) {
    north = 0,
    east = 1,
    south = 2,
    west = 3,

    pub inline fn opposite(this: Direction) Direction {
        return switch (this) {
            .north => .south,
            .south => .north,
            .east => .west,
            .west => .east,
        };
    }

    pub inline fn fromCardinal(cardinal: sdk.Gamepad.Cardinal) ?Direction {
        return switch (cardinal) {
            .north => .north,
            .south => .south,
            .east => .east,
            .west => .west,
            .none => null,
        };
    }

    pub inline fn delta(this: Direction) struct { dx: i16, dy: i16 } {
        return switch (this) {
            .north => .{ .dx = 0, .dy = -1 },
            .south => .{ .dx = 0, .dy = 1 },
            .east => .{ .dx = 1, .dy = 0 },
            .west => .{ .dx = -1, .dy = 0 },
        };
    }

    pub inline fn name(this: Direction) []const u8 {
        return switch (this) {
            .north => "UP",
            .south => "DOWN",
            .east => "RIGHT",
            .west => "LEFT",
        };
    }
};

const TilePos = struct {
    x: u16 = 0,
    y: u16 = 0,

    pub inline fn eql(this: TilePos, other: TilePos) bool {
        return this.x == other.x and this.y == other.y;
    }

    pub inline fn toScreenCenter(this: TilePos) struct { x: i16, y: i16 } {
        return .{
            .x = @as(i16, @intCast(Config.world_x + this.x * Config.tile_size)) + Config.tile_size / 2,
            .y = @as(i16, @intCast(Config.world_y + this.y * Config.tile_size)) + Config.tile_size / 2,
        };
    }

    pub inline fn toScreen(this: TilePos) struct { x: u16, y: u16 } {
        return .{
            .x = Config.world_x + this.x * Config.tile_size,
            .y = Config.world_y + this.y * Config.tile_size,
        };
    }

    pub inline fn moved(this: TilePos, dir: Direction) TilePos {
        const d = dir.delta();

        return wrap(
            @as(i16, @intCast(this.x)) + d.dx,
            @as(i16, @intCast(this.y)) + d.dy,
        );
    }

    inline fn wrap(x: i16, y: i16) TilePos {
        return .{
            .x = @intCast(@mod(x, Config.world_width)),
            .y = @intCast(@mod(y, Config.world_height)),
        };
    }
};

const GameState = enum {
    playing,
    paused,
    game_over,
};

const Particle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    vx: f32 = 0.0,
    vy: f32 = 0.0,
    life: f32 = 0.0,
    decay: f32 = 0.0,
    color_index: u8 = 0,
    size: u8 = 0,
    active: bool = false,
};

const ParticleSystem = struct {
    particles: [Config.max_particles]Particle = .{Particle{}} ** Config.max_particles,

    fn spawnEatBurst(this: *ParticleSystem, pos: TilePos) void {
        const rng = sdk.Prng.interface();
        const center = pos.toScreenCenter();

        for (0..Config.particles_per_eat) |_| {
            this.spawnParticle(.{
                .x = @floatFromInt(center.x),
                .y = @floatFromInt(center.y),
                .vx = (rng.float(f32) - 0.5) * 0.3,
                .vy = (rng.float(f32) - 0.5) * 0.3 - 0.1,
                .life = 1.0,
                .decay = 1.0 / @as(f32, @floatFromInt(Config.particle_lifetime_ms)),
                .color_index = rng.intRangeLessThan(u8, 0, Colors.particle_colors.len),
                .size = rng.intRangeAtMost(u8, 1, 3),
                .active = true,
            });
        }
    }

    fn spawnDeathExplosion(this: *ParticleSystem, pos: TilePos) void {
        const rng = sdk.Prng.interface();
        const center = pos.toScreenCenter();

        for (0..Config.max_particles) |_| {
            const angle = rng.float(f32) * std.math.pi * 2.0;
            const speed = rng.float(f32) * 0.4 + 0.1;

            this.spawnParticle(.{
                .x = @floatFromInt(center.x),
                .y = @floatFromInt(center.y),
                .vx = @cos(angle) * speed,
                .vy = @sin(angle) * speed,
                .life = 1.0,
                .decay = 1.0 / @as(f32, @floatFromInt(Config.particle_lifetime_ms * 2)),
                .color_index = rng.intRangeLessThan(u8, 3, Colors.particle_colors.len),
                .size = rng.intRangeAtMost(u8, 2, 4),
                .active = true,
            });
        }
    }

    inline fn spawnParticle(this: *ParticleSystem, particle: Particle) void {
        for (&this.particles) |*p| {
            if (!p.active) {
                p.* = particle;

                return;
            }
        }
    }

    fn update(this: *ParticleSystem, delta_ms: u64) void {
        const dt: f32 = @floatFromInt(delta_ms);

        for (&this.particles) |*p| {
            if (!p.active) {
                continue;
            }

            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.vy += 0.0005 * dt;
            p.life -= p.decay * dt;

            if (p.life <= 0) {
                p.active = false;
            }
        }
    }

    fn draw(this: *const ParticleSystem) void {
        for (&this.particles) |*p| {
            if (!p.active) {
                continue;
            }

            const color_idx: usize = @intFromFloat(
                @as(f32, @floatFromInt(p.color_index)) +
                    (1.0 - p.life) * @as(f32, @floatFromInt(Colors.particle_colors.len - 1 - p.color_index)),
            );
            const color = Colors.particle_colors[@min(color_idx, Colors.particle_colors.len - 1)];

            const x: i16 = @intFromFloat(p.x);
            const y: i16 = @intFromFloat(p.y);

            if (x < 0 or y < 0 or x >= Config.fb.width or y >= Config.fb.height) {
                continue;
            }

            sdk.blitter.rect(Config.fb.id, .{
                .color = color,
                .pos = .{ .x = @intCast(x), .y = @intCast(y) },
                .w = p.size,
                .h = p.size,
            });
        }
    }
};

const ScreenShake = struct {
    intensity: f32 = 0.0,
    duration_remaining_ms: u64 = 0,
    offset_x: i16 = 0,
    offset_y: i16 = 0,

    inline fn trigger(this: *ScreenShake, intensity: f32, duration_ms: u64) void {
        this.intensity = intensity;
        this.duration_remaining_ms = duration_ms;
    }

    fn update(this: *ScreenShake, delta_ms: u64) void {
        if (this.duration_remaining_ms == 0) {
            this.offset_x = 0;
            this.offset_y = 0;

            return;
        }

        if (delta_ms >= this.duration_remaining_ms) {
            this.duration_remaining_ms = 0;
            this.offset_x = 0;
            this.offset_y = 0;

            return;
        }

        this.duration_remaining_ms -= delta_ms;

        const progress = @as(f32, @floatFromInt(this.duration_remaining_ms)) /
            @as(f32, @floatFromInt(Config.screen_shake_duration_ms));
        const current_intensity = this.intensity * progress;
        const rng = sdk.Prng.interface();

        const range: i16 = @intFromFloat(current_intensity * Config.screen_shake_intensity);

        if (range > 0) {
            this.offset_x = rng.intRangeAtMost(i16, -range, range);
            this.offset_y = rng.intRangeAtMost(i16, -range, range);
        }
    }
};

const TrailEffect = struct {
    const TrailPoint = struct {
        pos: TilePos = .{},
        age: u8 = 0,
        active: bool = false,
    };

    points: [Config.max_trail_points]TrailPoint = .{TrailPoint{}} ** Config.max_trail_points,

    fn addPoint(this: *TrailEffect, pos: TilePos) void {
        for (&this.points) |*p| {
            if (!p.active) {
                continue;
            }

            p.age += 1;

            if (p.age >= Colors.trail_colors.len) {
                p.active = false;
            }
        }

        for (&this.points) |*p| {
            if (!p.active) {
                p.pos = pos;
                p.age = 0;
                p.active = true;

                return;
            }
        }
    }

    fn draw(this: *const TrailEffect, shake_x: i16, shake_y: i16) void {
        for (&this.points) |*p| {
            if (!p.active) {
                continue;
            }

            const screen = p.pos.toScreen();
            const color = Colors.trail_colors[@min(p.age, Colors.trail_colors.len - 1)];

            const x = @as(i16, @intCast(screen.x)) + shake_x + 2;
            const y = @as(i16, @intCast(screen.y)) + shake_y + 2;

            if (x < 0 or y < 0) {
                continue;
            }

            sdk.blitter.rect(Config.fb.id, .{
                .color = color,
                .pos = .{ .x = @intCast(x), .y = @intCast(y) },
                .w = Config.tile_size - 4,
                .h = Config.tile_size - 4,
            });
        }
    }
};

const AudioManager = struct {
    const Voice = struct {
        id: u4,

        pub inline fn get(this: Voice) *volatile sdk.Audio.Voice {
            return sdk.audio.voice(this.id);
        }

        pub inline fn play(this: Voice) void {
            this.get().restart();
        }

        pub inline fn pause(this: Voice) void {
            this.get().pause();
        }

        pub inline fn setVolume(this: Voice, volume: f32) void {
            this.get().setVolume(volume, volume);
        }
    };

    const bgm: Voice = .{ .id = 0 };
    const sfx_eat: Voice = .{ .id = 1 };
    const sfx_game_over: Voice = .{ .id = 2 };

    fn init() void {
        sdk.audio.setEnabled(true);

        Assets.bgm.apply(bgm.get());
        bgm.setVolume(Config.bgm_volume);

        Assets.sfx_eat.apply(sfx_eat.get());
        sfx_eat.setVolume(Config.sfx_volume);

        Assets.sfx_game_over.apply(sfx_game_over.get());
        sfx_game_over.setVolume(Config.sfx_volume);
    }

    inline fn startBgm() void {
        bgm.play();
    }

    inline fn stopBgm() void {
        bgm.pause();
    }

    inline fn playEat() void {
        sfx_eat.play();
    }

    inline fn playGameOver() void {
        sfx_game_over.play();
    }
};

const InputHandler = struct {
    buffered_direction: ?Direction = null,
    turbo_active: bool = false,
    input_consumed: bool = true,
    start_pressed: bool = false,
    select_pressed: bool = false,

    fn update(this: *InputHandler, current_snake_dir: Direction, snake_length: u16) void {
        const controls = sdk.gamepad1.status().controls();

        // Menu controls
        this.start_pressed = controls.start.sticky;
        this.select_pressed = controls.select.sticky;

        var new_dir: ?Direction = null;

        if (Direction.fromCardinal(controls.left_stick.cardinal(Config.stick_deadzone))) |dir| {
            new_dir = dir;
        }

        if (controls.up.sticky) {
            new_dir = .north;
        } else if (controls.down.sticky) {
            new_dir = .south;
        } else if (controls.left.sticky) {
            new_dir = .west;
        } else if (controls.right.sticky) {
            new_dir = .east;
        }

        // Only accept new input if previous was consumed AND direction is valid
        if (new_dir) |dir| {
            if (this.input_consumed) {
                if (snake_length == 0 or dir != current_snake_dir.opposite()) {
                    this.buffered_direction = dir;
                    this.input_consumed = false;
                }
            }
        }

        this.turbo_active = controls.south.down;

        sdk.gamepad1.clearSticky();
    }

    inline fn consumeDirection(this: *InputHandler) ?Direction {
        const dir = this.buffered_direction;

        this.buffered_direction = null;
        this.input_consumed = true;

        return dir;
    }

    inline fn reset(this: *InputHandler) void {
        this.buffered_direction = null;
        this.input_consumed = true;
        this.turbo_active = false;
        this.start_pressed = false;
        this.select_pressed = false;
    }
};

const Snake = struct {
    head: TilePos = .{
        .x = Config.world_width / 2,
        .y = Config.world_height / 2,
    },
    direction: Direction = .east,
    pending_direction: Direction = .east,
    segments: [Config.max_snake_length]TilePos = .{TilePos{}} ** Config.max_snake_length,
    length: u16 = 0,

    move_interval_ms: u64 = Config.initial_speed,
    next_move_time_ms: u64,

    // Store last tail position for trail effect
    last_tail_pos: ?TilePos = null,

    fn init(start_time_ms: u64) Snake {
        return .{
            .next_move_time_ms = start_time_ms + Config.initial_speed,
        };
    }

    fn queueDirection(this: *Snake, new_dir: Direction) void {
        this.pending_direction = new_dir;
    }

    fn updateSpeed(this: *Snake, turbo: bool) void {
        const length_penalty = @as(u64, this.length) * Config.speed_reduction_per_segment;
        const base_speed = if (Config.initial_speed > length_penalty + Config.min_speed)
            Config.initial_speed - length_penalty
        else
            Config.min_speed;

        this.move_interval_ms = if (turbo)
            @max(base_speed / Config.turbo_divisor, Config.turbo_min)
        else
            base_speed;
    }

    /// Move the snake forward. Returns true if moved.
    fn move(this: *Snake, current_time_ms: u64) bool {
        if (current_time_ms < this.next_move_time_ms) {
            return false;
        }

        if (this.length == 0 or this.pending_direction != this.direction.opposite()) {
            this.direction = this.pending_direction;
        }

        if (this.length > 0) {
            this.last_tail_pos = this.segments[this.length - 1];
        } else {
            this.last_tail_pos = null;
        }

        if (this.length > 0) {
            var i: u16 = this.length;

            while (i > 0) : (i -= 1) {
                this.segments[i] = this.segments[i - 1];
            }

            this.segments[0] = this.head;
        }

        this.head = this.head.moved(this.direction);
        this.next_move_time_ms = current_time_ms + this.move_interval_ms;

        return true;
    }

    inline fn grow(this: *Snake) void {
        if (this.length < Config.max_snake_length) {
            this.length += 1;
        }
    }

    inline fn checkSelfCollision(this: *const Snake) bool {
        for (this.segments[0..this.length]) |segment| {
            if (this.head.eql(segment)) {
                return true;
            }
        }

        return false;
    }

    inline fn occupies(this: *const Snake, pos: TilePos) bool {
        if (this.head.eql(pos)) {
            return true;
        }

        for (this.segments[0..this.length]) |segment| {
            if (segment.eql(pos)) {
                return true;
            }
        }

        return false;
    }

    inline fn score(this: *const Snake) u32 {
        return @as(u32, this.length);
    }
};

const FoodSpawner = struct {
    position: ?TilePos = null,

    fn spawnIfNeeded(this: *FoodSpawner, snake: *const Snake) void {
        if (this.position != null) {
            return;
        }

        var attempts: u32 = 0;
        const max_attempts = Config.world_width * Config.world_height;
        const rng = sdk.Prng.interface();

        while (attempts < max_attempts) : (attempts += 1) {
            const pos = TilePos{
                .x = rng.intRangeLessThan(u16, 0, Config.world_width),
                .y = rng.intRangeLessThan(u16, 0, Config.world_height),
            };

            if (!snake.occupies(pos)) {
                this.position = pos;

                return;
            }
        }

        this.position = null;
    }

    fn tryConsume(this: *FoodSpawner, head_pos: TilePos) bool {
        if (this.position) |food_pos| {
            if (food_pos.eql(head_pos)) {
                this.position = null;

                return true;
            }
        }

        return false;
    }
};

const EffectsManager = struct {
    blink_visible: bool = false,
    next_blink_time_ms: u64 = 0,
    world_seed: u32,
    particles: ParticleSystem = .{},
    shake: ScreenShake = .{},
    trail: TrailEffect = .{},

    fn init() EffectsManager {
        const rng = sdk.Prng.interface();

        return .{
            .world_seed = rng.int(u32),
        };
    }

    inline fn update(this: *EffectsManager, delta_ms: u64) void {
        this.particles.update(delta_ms);
        this.shake.update(delta_ms);
    }

    inline fn updateBlink(this: *EffectsManager, current_time_ms: u64) void {
        if (current_time_ms >= this.next_blink_time_ms) {
            this.blink_visible = !this.blink_visible;
            this.next_blink_time_ms = current_time_ms + Config.blink_interval_ms;
        }
    }

    inline fn onEatFood(this: *EffectsManager, pos: TilePos) void {
        this.particles.spawnEatBurst(pos);
    }

    inline fn onDeath(this: *EffectsManager, pos: TilePos) void {
        this.particles.spawnDeathExplosion(pos);
        this.shake.trigger(1.0, Config.screen_shake_duration_ms);
    }

    inline fn addTrailPoint(this: *EffectsManager, pos: TilePos) void {
        this.trail.addPoint(pos);
    }
};

const HapticFeedback = struct {
    inline fn onEatFood() void {
        sdk.gamepad1.rumble(0, std.math.maxInt(u16) / 2, Config.eat_rumble_duration_ms);
    }

    inline fn onDeath() void {
        sdk.gamepad1.rumble(std.math.maxInt(u16), std.math.maxInt(u16), Config.death_rumble_duration_ms);
    }
};

const Renderer = struct {
    inline fn beginFrame() void {
        sdk.gpu.switchFramebuffer(.off);
    }

    inline fn endFrame() void {
        sdk.gpu.switchFramebuffer(Config.fb.id);
    }

    inline fn clear(color: sdk.ARGB1555) void {
        sdk.blitter.clear(Config.fb.id, .{ .color = color });
    }

    fn drawBackground(effects: *const EffectsManager) void {
        const shake_x = effects.shake.offset_x;
        const shake_y = effects.shake.offset_y;

        sdk.blitter.rect(Config.fb.id, .{
            .color = Colors.background,
            .pos = .{
                .x = @intCast(@max(0, @as(i16, Config.world_x) + shake_x)),
                .y = @intCast(@max(0, @as(i16, Config.world_y) + shake_y)),
            },
            .w = Config.world_pixel_width,
            .h = Config.world_pixel_height,
        });

        var grass_rng = std.Random.DefaultPrng.init(effects.world_seed);
        const random = grass_rng.random();

        for (0..Config.world_height) |y| {
            for (0..Config.world_width) |x| {
                const grass_index = random.intRangeLessThan(u8, 0, Assets.grass.len);

                if (Assets.grass[grass_index]) |grass_sprite| {
                    const screen_pos = (TilePos{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    }).toScreen();

                    blitSpriteWithOffset(grass_sprite, screen_pos.x, screen_pos.y, shake_x, shake_y);
                }
            }
        }
    }

    inline fn drawTrail(effects: *const EffectsManager) void {
        effects.trail.draw(effects.shake.offset_x, effects.shake.offset_y);
    }

    fn drawSnake(snake: *const Snake, effects: *const EffectsManager) void {
        const shake_x = effects.shake.offset_x;
        const shake_y = effects.shake.offset_y;

        // Draw body (back to front)
        var i: u16 = snake.length;
        while (i > 0) {
            i -= 1;
            const segment = snake.segments[i];
            const screen = segment.toScreen();

            blitSpriteWithOffset(Assets.snake_body, screen.x, screen.y, shake_x, shake_y);
        }

        // Draw head
        const head_screen = snake.head.toScreen();
        const head_sprite = Assets.SnakeHead.forDirection(snake.direction);

        blitSpriteWithOffset(head_sprite, head_screen.x, head_screen.y, shake_x, shake_y);
    }

    fn drawFood(food_pos: ?TilePos, effects: *const EffectsManager) void {
        if (food_pos) |pos| {
            const screen = pos.toScreen();

            blitSpriteWithOffset(
                Assets.food,
                screen.x,
                screen.y,
                effects.shake.offset_x,
                effects.shake.offset_y,
            );
        }
    }

    inline fn drawParticles(effects: *const EffectsManager) void {
        effects.particles.draw();
    }

    fn drawDeathEffect(snake: *const Snake, effects: *const EffectsManager) void {
        if (!effects.blink_visible) {
            return;
        }

        const screen = snake.head.toScreen();
        const shake_x = effects.shake.offset_x;
        const shake_y = effects.shake.offset_y;

        const x = @as(i16, @intCast(screen.x)) + shake_x;
        const y = @as(i16, @intCast(screen.y)) + shake_y;

        if (x >= 0 and y >= 0) {
            sdk.blitter.rect(Config.fb.id, .{
                .color = Colors.collision_highlight,
                .pos = .{ .x = @intCast(x), .y = @intCast(y) },
                .w = Config.tile_size,
                .h = Config.tile_size,
            });
        }
    }

    fn drawUI(game: *const Game) void {
        const fb = Config.fb;

        // Left side
        sdk.utils.Text.drawWithShadow(fb, Config.ui_left_x, Config.ui_top_y, "SCORE", Colors.ui_label, Colors.ui_shadow);

        var score_buf: [3]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{}", .{game.snake.score()}) catch "999";

        sdk.utils.Text.drawWithShadow(fb, Config.ui_left_x, Config.ui_top_y + 12, score_str, Colors.ui_score, Colors.ui_shadow);

        // Right side
        const right_x = Config.ui_right_x;
        var y: u16 = Config.ui_top_y;

        sdk.utils.Text.drawWithShadow(fb, right_x, y, "CONTROLS", Colors.ui_label, Colors.ui_shadow);
        y += 14;

        sdk.utils.Text.draw(fb, right_x, y, "D-PAD Move", Colors.ui_text);
        y += 10;
        sdk.utils.Text.draw(fb, right_x, y, "STICK Move", Colors.ui_text);
        y += 10;
        sdk.utils.Text.draw(fb, right_x, y, "A     Turbo", Colors.ui_text);
        y += 10;
        sdk.utils.Text.draw(fb, right_x, y, "START Pause", Colors.ui_text);
        y += 10;

        if (game.state == .game_over) {
            sdk.utils.Text.draw(fb, right_x, y, "SEL   Restart", Colors.ui_highlight);
        }
    }

    fn drawGameOver(game: *const Game, effects: *const EffectsManager) void {
        if (effects.blink_visible) {
            const center_x = Config.fb.width / 2;
            const center_y = Config.fb.height / 2;

            var cursor_y: u16 = center_y;

            sdk.utils.Text.drawCenteredWithShadow(
                Config.fb,
                center_x,
                center_y - 4,
                "GAME OVER",
                Colors.game_over_text,
                Colors.ui_shadow,
            );

            if (game.is_new_high_score) {
                cursor_y += sdk.utils.Text.measure(" ").h;

                var str_buf: [20]u8 = undefined;
                const str = std.fmt.bufPrint(&str_buf, "NEW HIGH SCORE: {}", .{game.snake.score()}) catch {
                    return;
                };

                sdk.utils.Text.drawCenteredWithShadow(Config.fb, center_x, cursor_y, str, Colors.new_high_score_text, Colors.ui_shadow);
            }
        }
    }

    fn drawPaused(effects: *const EffectsManager) void {
        // Dim overlay
        sdk.blitter.rect(Config.fb.id, .{
            .color = .{ .a = 1, .r = 0, .g = 0, .b = 0 },
            .pos = .{
                .x = Config.world_x + 20,
                .y = Config.world_y + Config.world_pixel_height / 2 - 20,
            },
            .w = Config.world_pixel_width - 40,
            .h = 40,
        });

        if (effects.blink_visible) {
            const center_x = Config.fb.width / 2;
            const center_y = Config.fb.height / 2;

            sdk.utils.Text.drawCenteredWithShadow(
                Config.fb,
                center_x,
                center_y - 4,
                "PAUSED",
                Colors.paused_text,
                Colors.ui_shadow,
            );
        }
    }

    fn blitSpriteWithOffset(sprite: sdk.utils.Frame, x: u16, y: u16, ox: i16, oy: i16) void {
        const final_x = @as(i16, @intCast(x)) + ox;
        const final_y = @as(i16, @intCast(y)) + oy;

        if (final_x < 0 or final_y < 0) {
            return;
        }

        if (final_x >= Config.fb.width or final_y >= Config.fb.height) {
            return;
        }

        sdk.blitter.copy(Config.fb.id, .{
            .src = @intFromPtr(sprite.pixels.ptr) - sdk.Memory.RAM_START,
            .w = sprite.width,
            .h = sprite.height,
            .dst_pos = .{ .x = @intCast(final_x), .y = @intCast(final_y) },
            .alpha = .mask,
            .mode = .crop,
        });
    }
};

const SaveManager = struct {
    pub const SaveData = struct {
        high_score: u32 = 0,
    };

    save_data: SaveData,

    pub inline fn init(allocator: std.mem.Allocator) SaveManager {
        if (tryLoadSaves(allocator)) |data| {
            return .{ .save_data = data };
        }

        return .{ .save_data = .{} };
    }

    pub fn update(this: *SaveManager, new_data: SaveData) bool {
        this.save_data = new_data;

        var buffer: [512]u8 = undefined;
        var dma_writer: sdk.utils.DmaWriter = .init(.nvram_storage, 0, &buffer);

        std.json.Stringify.value(this.save_data, .{}, &dma_writer.interface) catch |err| {
            sdk.uart.print("failed to stringify the save data to the NVRAM: {t}\n", .{err});

            return false;
        };
        dma_writer.interface.flush() catch {};

        return true;
    }

    fn tryLoadSaves(allocator: std.mem.Allocator) ?SaveData {
        var raw_data: std.ArrayList(u8) = read: {
            var buffer: [512]u8 = std.mem.zeroes([512]u8);
            var dma_reader: sdk.utils.DmaReader = .init(.nvram_storage, 0, &buffer);
            var writer: std.Io.Writer.Allocating = .init(allocator);

            const bytes = dma_reader.interface.streamDelimiter(&writer.writer, '\x00') catch |err| {
                sdk.uart.print("failed to read the save data: {t}\n", .{err});
                sdk.dma.fill(.nvram_storage, 0, &.{0}, sdk.boot_info.nvram_storage_size);

                return null;
            };

            if (bytes == 0) {
                writer.deinit();

                return null;
            }

            break :read writer.toArrayList();
        };
        defer raw_data.deinit(allocator);

        var reader: std.Io.Reader = .fixed(raw_data.items);
        var json_reader: std.json.Reader = .init(allocator, &reader);
        defer json_reader.deinit();

        const parsed = std.json.parseFromTokenSource(SaveData, allocator, &json_reader, .{}) catch |err| {
            sdk.uart.print("failed to parse the save data: {t}\n", .{err});
            sdk.dma.fill(.nvram_storage, 0, &.{0}, sdk.boot_info.nvram_storage_size);

            return null;
        };
        parsed.deinit();

        return parsed.value;
    }
};

const Game = struct {
    state: GameState = .playing,
    snake: Snake,
    food: FoodSpawner = .{},
    input: InputHandler = .{},
    effects: EffectsManager,
    saves: SaveManager,
    last_update_time_ms: u64,
    is_new_high_score: bool = false,

    pub inline fn init(allocator: std.mem.Allocator) Game {
        const start_time = getCurrentTimeMs();

        return .{
            .snake = Snake.init(start_time),
            .effects = EffectsManager.init(),
            .saves = .init(allocator),
            .last_update_time_ms = start_time,
        };
    }

    pub inline fn update(this: *Game, current_time_ms: u64) void {
        const delta_ms = current_time_ms -| this.last_update_time_ms;
        this.last_update_time_ms = current_time_ms;

        this.input.update(this.snake.direction, this.snake.length);
        this.effects.update(delta_ms);

        switch (this.state) {
            .playing => this.updatePlaying(current_time_ms),
            .paused => this.updatePaused(current_time_ms),
            .game_over => this.updateGameOver(current_time_ms),
        }
    }

    pub inline fn draw(this: *Game) void {
        Renderer.beginFrame();
        Renderer.clear(Colors.background_dark);

        Renderer.drawBackground(&this.effects);
        Renderer.drawTrail(&this.effects);
        Renderer.drawSnake(&this.snake, &this.effects);
        Renderer.drawFood(this.food.position, &this.effects);
        Renderer.drawParticles(&this.effects);

        switch (this.state) {
            .game_over => {
                Renderer.drawDeathEffect(&this.snake, &this.effects);
                Renderer.drawGameOver(this, &this.effects);
            },
            .paused => {
                Renderer.drawPaused(&this.effects);
            },
            .playing => {},
        }

        Renderer.drawUI(this);

        Renderer.endFrame();
    }

    fn updatePlaying(this: *Game, current_time_ms: u64) void {
        if (this.input.start_pressed) {
            this.state = .paused;
            AudioManager.stopBgm();

            return;
        }

        if (this.input.consumeDirection()) |dir| {
            this.snake.queueDirection(dir);
        }

        this.snake.updateSpeed(this.input.turbo_active);

        if (this.snake.move(current_time_ms)) {
            if (this.snake.last_tail_pos) |tail_pos| {
                this.effects.addTrailPoint(tail_pos);
            }

            if (this.snake.checkSelfCollision()) {
                this.transitionToGameOver();

                return;
            }

            if (this.food.tryConsume(this.snake.head)) {
                this.snake.grow();
                this.effects.onEatFood(this.snake.head);

                AudioManager.playEat();
                HapticFeedback.onEatFood();
            }
        }

        this.food.spawnIfNeeded(&this.snake);
    }

    inline fn updatePaused(this: *Game, current_time_ms: u64) void {
        this.effects.updateBlink(current_time_ms);

        if (this.input.start_pressed) {
            this.state = .playing;
            AudioManager.startBgm();
        }
    }

    inline fn updateGameOver(this: *Game, current_time_ms: u64) void {
        this.effects.updateBlink(current_time_ms);

        if (this.input.select_pressed) {
            this.restart();
        }
    }

    inline fn transitionToGameOver(this: *Game) void {
        if (this.snake.score() > this.saves.save_data.high_score) {
            this.is_new_high_score = true;
            _ = this.saves.update(.{ .high_score = this.snake.score() });
        }

        this.state = .game_over;
        this.effects.onDeath(this.snake.head);

        AudioManager.stopBgm();
        AudioManager.playGameOver();
        HapticFeedback.onDeath();
    }

    inline fn restart(this: *Game) void {
        const start_time = getCurrentTimeMs();

        this.state = .playing;
        this.snake = Snake.init(start_time);
        this.food = .{};
        this.input.reset();
        this.effects = EffectsManager.init();
        this.last_update_time_ms = start_time;
        this.is_new_high_score = false;

        AudioManager.startBgm();
    }
};

inline fn getCurrentTimeMs() u64 {
    return sdk.clint.readMtimeNs() / std.time.ns_per_ms;
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

pub fn main() noreturn {
    sdk.gpu.setVblankInterrupts(true);
    sdk.arch.Mie.setMeie();

    const free_ram: [*]u8 = @ptrFromInt(sdk.boot_info.free_ram_start);
    var alloc: std.heap.FixedBufferAllocator = .init(free_ram[0..(sdk.boot_info.ram_size - sdk.boot_info.free_ram_start)]);
    defer alloc.reset();

    if (!Assets.load(alloc.allocator())) {
        sdk.uart.print("failed to load the assets\n", .{});

        while (true) {}
    }

    AudioManager.init();
    AudioManager.startBgm();

    var game = Game.init(alloc.allocator());

    while (true) {
        const current_time = getCurrentTimeMs();

        game.update(current_time);
        game.draw();

        waitForVBlank();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
