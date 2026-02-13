// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const sdk = @import("root.zig").gen1;

pub inline fn EntryPoint(comptime config: struct {
    stack_size: u32 = if (builtin.mode == .Debug) std.math.pow(u32, 2, 16) else std.math.pow(u32, 2, 15),
    enable_fpu: bool = true,
}) type {
    return struct {
        const root = @import("root");

        var stack: [config.stack_size]u8 align(16) linksection(".bss") = undefined;

        export fn _start() callconv(.naked) noreturn {
            asm volatile (
                \\ .option push
                \\ .option norelax
                \\
                \\ la sp, %[stack_top]
                \\
                \\ j %[init]
                \\
                \\ .option pop
                :
                : [stack_top] "i" (&@as([*]align(16) u8, @ptrCast(&stack))[stack.len]),
                  [init] "i" (&init),
            );
        }

        fn init() callconv(.c) noreturn {
            if (comptime config.enable_fpu) {
                sdk.arch.Mstatus.enableFpu();
            }

            const ReturnType = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;

            switch (ReturnType) {
                void, noreturn => {
                    @call(.never_inline, root.main, .{});
                },
                else => {
                    if (@typeInfo(ReturnType) != .error_union) {
                        @compileError("expected return type of main to be 'void', '!void' or 'noreturn'");
                    }

                    _ = @call(.never_inline, root.main, .{}) catch |err| {
                        sdk.uart.print("{s}", .{@errorName(err)});
                    };
                },
            }

            sdk.gpu.setVblankInterrupts(true);
            sdk.arch.Mie.setMeie();

            while (true) {
                while (true) {
                    const device = sdk.plic.claim;

                    if (device == .none) {
                        break;
                    }

                    sdk.plic.claim = device;
                }

                sdk.arch.wfi();
            }
        }
    };
}

pub const Frame = struct {
    width: u16,
    height: u16,
    pixels: []const sdk.ARGB1555,

    pub fn deinit(this: *Frame, allocator: std.mem.Allocator) void {
        if (this.allocated_size > 0) {
            allocator.free(this.pixels);
            this.pixels = &.{};
        }
    }

    pub fn slice(this: Frame) []const sdk.ARGB1555 {
        return this.pixels[0 .. @as(usize, this.width) * this.height];
    }

    pub fn empty() Frame {
        return .{
            .width = 0,
            .height = 0,
            .pixels = undefined,
        };
    }
};

pub const Tga = struct {
    pub const ImageType = enum(u8) {
        empty = 0,
        palette = 1,
        true_color = 2,
        grayscale = 3,
        palette_rle = 9,
        true_color_rle = 10,
        grayscale_rle = 11,
    };

    pub const ColorMapType = enum(u8) {
        none = 0,
        present = 1,
    };

    const Descriptor = packed struct(u8) {
        alpha_depth: u4,
        x_order: Order,
        y_order: Order,
        _pad: u2 = 0,

        const Order = enum(u1) { normal = 0, reversed = 1 };
    };

    const RawHeader = extern struct {
        id_len: u8,
        colormap_type: u8,
        image_type: u8,
        // Color map spec
        colormap_first: u16 align(1),
        colormap_len: u16 align(1),
        colormap_bpp: u8,
        // Image spec
        x_origin: u16 align(1),
        y_origin: u16 align(1),
        width: u16 align(1),
        height: u16 align(1),
        bpp: u8,
        descriptor: u8,
    };

    pub const ParseError = error{
        FileTooSmall,
        InvalidColorMapType,
        InvalidImageType,
        UnsupportedPalette,
        UnsupportedBpp,
        UnsupportedAlphaDepth,
        InvalidDimensions,
        TruncatedData,
    };

    pub const ReadError = ParseError || std.mem.Allocator.Error || error{
        ReadFailed,
        EndOfStream,
    };

    const FormatInfo = struct {
        image_type: ImageType,
        width: u16,
        height: u16,
        bpp: u8,
        alpha_depth: u4,
        x_reversed: bool,
        y_bottom_to_top: bool,
        id_len: u8,
        colormap_size: u32,
        is_rle: bool,
    };

    inline fn parseHeader(header: RawHeader) ParseError!FormatInfo {
        const colormap_type = std.meta.intToEnum(ColorMapType, header.colormap_type) catch {
            return error.InvalidColorMapType;
        };

        const image_type = std.meta.intToEnum(ImageType, header.image_type) catch {
            return error.InvalidImageType;
        };

        if (colormap_type == .present or
            image_type == .palette or
            image_type == .palette_rle)
        {
            return error.UnsupportedPalette;
        }

        if (image_type == .empty or header.width == 0 or header.height == 0) {
            return .{
                .image_type = .empty,
                .width = 0,
                .height = 0,
                .bpp = 0,
                .alpha_depth = 0,
                .x_reversed = false,
                .y_bottom_to_top = false,
                .id_len = header.id_len,
                .colormap_size = 0,
                .is_rle = false,
            };
        }

        const is_grayscale = image_type == .grayscale or image_type == .grayscale_rle;
        const is_rle = image_type == .true_color_rle or image_type == .grayscale_rle;

        const valid_bpp = if (is_grayscale)
            header.bpp == 8
        else
            header.bpp == 16 or header.bpp == 24 or header.bpp == 32;

        if (!valid_bpp) {
            return error.UnsupportedBpp;
        }

        const desc: Descriptor = @bitCast(header.descriptor);

        const expected_alpha: u4 = switch (header.bpp) {
            8, 24 => 0,
            16 => 1,
            32 => 8,
            else => 0,
        };

        if (header.bpp == 32 and desc.alpha_depth != 8 and desc.alpha_depth != 0) {
            return error.UnsupportedAlphaDepth;
        }

        _ = expected_alpha;

        return .{
            .image_type = image_type,
            .width = header.width,
            .height = header.height,
            .bpp = header.bpp,
            .alpha_depth = desc.alpha_depth,
            .x_reversed = desc.x_order == .reversed,
            .y_bottom_to_top = desc.y_order == .normal,
            .id_len = header.id_len,
            .colormap_size = @as(u32, header.colormap_len) * ((header.colormap_bpp + 7) / 8),
            .is_rle = is_rle,
        };
    }

    inline fn convertPixel(src: []const u8, bpp: u8, is_grayscale: bool) sdk.ARGB1555 {
        if (is_grayscale) {
            const gray: u16 = src[0];
            const v5: u5 = @truncate(gray >> 3);

            return .{ .r = v5, .g = v5, .b = v5, .a = 1 };
        }

        return switch (bpp) {
            16 => blk: {
                const raw = std.mem.readInt(u16, src[0..2], .little);

                break :blk @bitCast(raw);
            },
            24 => blk: {
                const b = src[0];
                const g = src[1];
                const r = src[2];

                break :blk .fromRGBA(r, g, b, 255);
            },
            32 => blk: {
                const b = src[0];
                const g = src[1];
                const r = src[2];
                const a = src[3];

                break :blk .fromRGBA(r, g, b, a);
            },
            else => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        };
    }

    inline fn calcDstIndex(
        src_idx: usize,
        width: u16,
        height: u16,
        x_reversed: bool,
        y_bottom_to_top: bool,
    ) usize {
        const w: usize = width;
        const h: usize = height;
        const src_row = src_idx / w;
        const src_col = src_idx % w;

        const dst_row = if (y_bottom_to_top) h - 1 - src_row else src_row;
        const dst_col = if (x_reversed) w - 1 - src_col else src_col;

        return dst_row * w + dst_col;
    }

    pub inline fn frame(comptime data: []const u8) Frame {
        if (data.len < @sizeOf(RawHeader)) {
            @compileError("TGA file too small");
        }

        const header: *const RawHeader = @ptrCast(@alignCast(data.ptr));
        const info = parseHeader(header.*) catch |err| {
            @compileError("TGA parse error: " ++ @errorName(err));
        };

        if (info.image_type == .empty) {
            return Frame.empty();
        }

        const pixel_count = @as(usize, info.width) * info.height;
        const bytes_per_pixel = info.bpp / 8;
        const pixel_data_offset = @sizeOf(RawHeader) + info.id_len + info.colormap_size;
        const is_grayscale = info.image_type == .grayscale or info.image_type == .grayscale_rle;

        var out: [pixel_count]sdk.ARGB1555 = undefined;

        if (info.is_rle) {
            var src_pos: usize = pixel_data_offset;
            var pixel_idx: usize = 0;

            while (pixel_idx < pixel_count) {
                if (src_pos >= data.len) {
                    @compileError("TGA: truncated RLE data");
                }

                const packet_header = data[src_pos];
                src_pos += 1;

                const count: usize = (packet_header & 0x7F) + 1;
                const is_rle_packet = (packet_header & 0x80) != 0;

                if (is_rle_packet) {
                    const pixel = convertPixel(
                        data[src_pos..][0..bytes_per_pixel],
                        info.bpp,
                        is_grayscale,
                    );
                    src_pos += bytes_per_pixel;

                    for (0..count) |_| {
                        const dst_idx = calcDstIndex(
                            pixel_idx,
                            info.width,
                            info.height,
                            info.x_reversed,
                            info.y_bottom_to_top,
                        );

                        out[dst_idx] = pixel;
                        pixel_idx += 1;
                    }
                } else {
                    for (0..count) |_| {
                        const pixel = convertPixel(
                            data[src_pos..][0..bytes_per_pixel],
                            info.bpp,
                            is_grayscale,
                        );
                        src_pos += bytes_per_pixel;

                        const dst_idx = calcDstIndex(
                            pixel_idx,
                            info.width,
                            info.height,
                            info.x_reversed,
                            info.y_bottom_to_top,
                        );
                        out[dst_idx] = pixel;
                        pixel_idx += 1;
                    }
                }
            }
        } else {
            const required_size = pixel_data_offset + pixel_count * bytes_per_pixel;

            if (data.len < required_size) {
                @compileError("TGA: truncated pixel data");
            }

            for (0..pixel_count) |src_idx| {
                const src_offset = pixel_data_offset + src_idx * bytes_per_pixel;
                const pixel = convertPixel(
                    data[src_offset..][0..bytes_per_pixel],
                    info.bpp,
                    is_grayscale,
                );

                const dst_idx = calcDstIndex(
                    src_idx,
                    info.width,
                    info.height,
                    info.x_reversed,
                    info.y_bottom_to_top,
                );
                out[dst_idx] = pixel;
            }
        }

        const final = out[0..out.len].*;

        return .{
            .width = info.width,
            .height = info.height,
            .pixels = &final,
        };
    }

    pub fn fromReader(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) ReadError!Frame {
        const header = try reader.takeStruct(RawHeader, .little);
        const info = try parseHeader(header);

        if (info.image_type == .empty) {
            return Frame.empty();
        }

        try reader.discardAll(info.id_len);
        try reader.discardAll(@intCast(info.colormap_size));

        const pixel_count: usize = @as(usize, info.width) * info.height;
        const bytes_per_pixel: usize = info.bpp / 8;
        const is_grayscale = info.image_type == .grayscale or info.image_type == .grayscale_rle;

        const out = try allocator.alloc(sdk.ARGB1555, pixel_count);
        errdefer allocator.free(out);

        if (info.is_rle) {
            try decodeRleRuntime(reader, out, info, bytes_per_pixel, is_grayscale);
        } else {
            try decodeRawRuntime(reader, out, info, bytes_per_pixel, is_grayscale);
        }

        return .{
            .width = info.width,
            .height = info.height,
            .pixels = out,
        };
    }

    fn decodeRawRuntime(
        reader: *std.Io.Reader,
        out: []sdk.ARGB1555,
        info: FormatInfo,
        bytes_per_pixel: usize,
        is_grayscale: bool,
    ) ReadError!void {
        var pixel_buf: [4]u8 = undefined;
        const buf = pixel_buf[0..bytes_per_pixel];

        for (0..out.len) |src_idx| {
            try reader.readSliceAll(buf);

            const pixel = convertPixel(buf, info.bpp, is_grayscale);
            const dst_idx = calcDstIndex(
                src_idx,
                info.width,
                info.height,
                info.x_reversed,
                info.y_bottom_to_top,
            );

            out[dst_idx] = pixel;
        }
    }

    fn decodeRleRuntime(
        reader: *std.Io.Reader,
        out: []sdk.ARGB1555,
        info: FormatInfo,
        bytes_per_pixel: usize,
        is_grayscale: bool,
    ) ReadError!void {
        var pixel_buf: [4]u8 = undefined;
        const buf = pixel_buf[0..bytes_per_pixel];
        var pixel_idx: usize = 0;

        while (pixel_idx < out.len) {
            const packet_header = try reader.takeByte();
            const count: usize = (packet_header & 0x7F) + 1;
            const is_rle_packet = (packet_header & 0x80) != 0;

            if (is_rle_packet) {
                try reader.readSliceAll(buf);
                const pixel = convertPixel(buf, info.bpp, is_grayscale);

                for (0..count) |_| {
                    if (pixel_idx >= out.len) {
                        break;
                    }

                    const dst_idx = calcDstIndex(
                        pixel_idx,
                        info.width,
                        info.height,
                        info.x_reversed,
                        info.y_bottom_to_top,
                    );

                    out[dst_idx] = pixel;
                    pixel_idx += 1;
                }
            } else {
                for (0..count) |_| {
                    if (pixel_idx >= out.len) {
                        break;
                    }

                    try reader.readSliceAll(buf);
                    const pixel = convertPixel(buf, info.bpp, is_grayscale);

                    const dst_idx = calcDstIndex(
                        pixel_idx,
                        info.width,
                        info.height,
                        info.x_reversed,
                        info.y_bottom_to_top,
                    );

                    out[dst_idx] = pixel;
                    pixel_idx += 1;
                }
            }
        }
    }
};

pub const Samples = struct {
    data: [*]const u8,
    len: u32,
    block_align: u16,
    samples_per_block: u16,
    loop_start: ?u32 = null,
    loop_end: ?u32 = null,
    compressed: bool,
    allocated_size: u32 = 0,

    pub inline fn apply(this: Samples, v: *volatile sdk.Audio.Voice) void {
        v.sample_addr = @intFromPtr(this.data) - sdk.Memory.RAM_START;
        v.sample_len = this.len;
        v.block_align = this.block_align;
        v.samples_per_block = this.samples_per_block;
        v.compressed = this.compressed;

        if (this.loop_start) |ls| {
            v.loop_start = ls;
            v.loop_end = this.loop_end orelse this.len;
            v.loop_enabled = true;
        } else {
            v.loop_start = 0;
            v.loop_end = 0;
            v.loop_enabled = false;
        }
    }

    pub inline fn empty() Samples {
        return .{
            .data = undefined,
            .len = 0,
            .block_align = 0,
            .samples_per_block = 0,
            .compressed = false,
        };
    }

    pub inline fn deinit(this: *Samples, allocator: std.mem.Allocator) void {
        if (this.allocated_size > 0) {
            allocator.free(this.data[0..this.allocated_size]);
            this.allocated_size = 0;
        }
    }
};

pub const Wav = struct {
    pub const PCM_FORMAT: u16 = 0x0001;
    pub const IMA_ADPCM_FORMAT: u16 = 0x0011;

    pub const RawHeader = extern struct {
        riff_signature: [4]u8,
        file_size: u32,
        wave_signature: [4]u8,
    };

    pub const RawChunk = extern struct {
        id: [4]u8,
        size: u32,
    };

    pub const RawFormatChunk = extern struct {
        tag: u16,
        channels: u16,
        sample_rate: u32,
        avg_bytes_per_sec: u32,
        block_align: u16,
        bits_per_sample: u16,
    };

    pub const RawFormatChunkExt = extern struct {
        cb_size: u16,
        samples_per_block: u16,
    };

    pub const Options = struct {
        loop_start: ?u32 = null,
        loop_end: ?u32 = null,
    };

    pub const ParseError = error{
        InvalidRiffSignature,
        InvalidWaveSignature,
        UnsupportedFormat,
        UnsupportedChannels,
        UnsupportedSampleRate,
        BlockAlignTooLarge,
        DataBeforeFmt,
        NoDataChunk,
    };

    pub const ReadError = ParseError || std.mem.Allocator.Error || error{
        ReadFailed,
        EndOfStream,
    };

    const FormatInfo = struct {
        compressed: bool,
        block_align: u16,
        samples_per_block: u16,
    };

    inline fn calcSamplesPerBlock(block_align: u16, compressed: bool, ext_value: ?u16) u16 {
        if (!compressed) {
            return 1;
        }

        return ext_value orelse ((block_align - 4) * 2 + 1);
    }

    inline fn calcTotalSamples(
        data_size: u32,
        block_align: u16,
        samples_per_block: u16,
        fact_samples: ?u32,
        compressed: bool,
    ) u32 {
        if (fact_samples) |fs| {
            return fs;
        }

        if (compressed) {
            const num_full_blocks = data_size / block_align;
            const remainder = data_size % block_align;
            var total: u32 = num_full_blocks * samples_per_block;

            if (remainder > 4) {
                total += 1 + (remainder - 4) * 2;
            }

            return total;
        } else {
            return data_size / block_align;
        }
    }

    inline fn makeSamples(
        data_ptr: [*]const u8,
        data_size: u32,
        info: FormatInfo,
        fact_samples: ?u32,
        options: Options,
        allocated: bool,
    ) Samples {
        return .{
            .data = data_ptr,
            .len = calcTotalSamples(data_size, info.block_align, info.samples_per_block, fact_samples, info.compressed),
            .block_align = info.block_align,
            .samples_per_block = info.samples_per_block,
            .loop_start = options.loop_start,
            .loop_end = options.loop_end,
            .compressed = info.compressed,
            .allocated_size = if (allocated) data_size else 0,
        };
    }

    pub inline fn samples(comptime data: []const u8, options: Options) Samples {
        if (data.len < @sizeOf(RawHeader)) {
            @compileError("WAV file too small");
        }

        const header: *const RawHeader = @ptrCast(@alignCast(data.ptr));

        if (!std.mem.eql(u8, &header.riff_signature, "RIFF")) {
            @compileError("Invalid RIFF signature");
        }

        if (!std.mem.eql(u8, &header.wave_signature, "WAVE")) {
            @compileError("Invalid WAVE signature");
        }

        var fmt: ?*const RawFormatChunk = null;
        var fmt_ext: ?*const RawFormatChunkExt = null;
        var fact_samples: ?u32 = null;
        var pos: usize = @sizeOf(RawHeader);

        while (pos + @sizeOf(RawChunk) <= data.len) {
            const chunk: *const RawChunk = @ptrCast(@alignCast(data.ptr + pos));
            const chunk_data_pos = pos + @sizeOf(RawChunk);

            if (std.mem.eql(u8, &chunk.id, "fmt ")) {
                if (chunk_data_pos + @sizeOf(RawFormatChunk) > data.len) {
                    @compileError("Truncated fmt chunk");
                }

                fmt = @ptrCast(@alignCast(data.ptr + chunk_data_pos));

                validateFormatComptime(fmt.?);

                if (fmt.?.tag == IMA_ADPCM_FORMAT) {
                    const ext_pos = chunk_data_pos + @sizeOf(RawFormatChunk);

                    if (ext_pos + @sizeOf(RawFormatChunkExt) <= chunk_data_pos + chunk.size) {
                        fmt_ext = @ptrCast(@alignCast(data.ptr + ext_pos));
                    }
                }
            } else if (std.mem.eql(u8, &chunk.id, "fact")) {
                if (chunk_data_pos + 4 <= data.len) {
                    fact_samples = std.mem.readInt(u32, (data.ptr + chunk_data_pos)[0..4], .little);
                }
            } else if (std.mem.eql(u8, &chunk.id, "data")) {
                if (fmt == null) {
                    @compileError("data chunk before fmt chunk");
                }

                const f = fmt.?;
                const compressed = f.tag == IMA_ADPCM_FORMAT;
                const ext_spb: ?u16 = if (fmt_ext) |e| e.samples_per_block else null;

                const info = FormatInfo{
                    .compressed = compressed,
                    .block_align = f.block_align,
                    .samples_per_block = calcSamplesPerBlock(f.block_align, compressed, ext_spb),
                };

                return makeSamples(
                    data.ptr + chunk_data_pos,
                    chunk.size,
                    info,
                    fact_samples,
                    options,
                    false,
                );
            }

            pos = chunk_data_pos + ((chunk.size + 1) & ~@as(u32, 1));
        }

        @compileError("No data chunk found in WAV file");
    }

    inline fn validateFormatComptime(f: *const RawFormatChunk) void {
        if (f.tag != PCM_FORMAT and f.tag != IMA_ADPCM_FORMAT) {
            @compileError("Only PCM (0x0001) and IMA ADPCM (0x0011) formats are supported");
        }

        if (f.channels != 1) {
            @compileError("Only mono audio is supported");
        }

        if (f.sample_rate != sdk.Audio.SAMPLE_RATE) {
            @compileError("Sample rate must match SDK (22050 Hz)");
        }

        if (f.block_align > sdk.Audio.MAX_BLOCK_ALIGN) {
            @compileError("Block align exceeds maximum");
        }
    }

    pub fn fromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, options: Options) ReadError!Samples {
        const header = try reader.takeStruct(RawHeader, .little);

        if (!std.mem.eql(u8, &header.riff_signature, "RIFF")) {
            return error.InvalidRiffSignature;
        }

        if (!std.mem.eql(u8, &header.wave_signature, "WAVE")) {
            return error.InvalidWaveSignature;
        }

        var fmt: ?RawFormatChunk = null;
        var fmt_ext: ?RawFormatChunkExt = null;
        var fact_samples: ?u32 = null;

        while (true) {
            const chunk = reader.takeStruct(RawChunk, .little) catch |err| switch (err) {
                error.EndOfStream => return error.NoDataChunk,
                else => |e| return e,
            };

            if (std.mem.eql(u8, &chunk.id, "fmt ")) {
                fmt = try reader.takeStruct(RawFormatChunk, .little);

                try validateFormatRuntime(fmt.?);

                try readFormatExtension(reader, &fmt_ext, fmt.?, chunk.size);
            } else if (std.mem.eql(u8, &chunk.id, "fact")) {
                if (chunk.size >= 4) {
                    fact_samples = try reader.takeInt(u32, .little);
                    if (chunk.size > 4) {
                        try reader.discardAll(chunk.size - 4);
                    }
                } else {
                    try reader.discardAll(chunk.size);
                }
            } else if (std.mem.eql(u8, &chunk.id, "data")) {
                const f = fmt orelse return error.DataBeforeFmt;

                const compressed = f.tag == IMA_ADPCM_FORMAT;
                const ext_spb: ?u16 = if (fmt_ext) |e| e.samples_per_block else null;

                const info = FormatInfo{
                    .compressed = compressed,
                    .block_align = f.block_align,
                    .samples_per_block = calcSamplesPerBlock(f.block_align, compressed, ext_spb),
                };

                const data = try allocator.alloc(u8, chunk.size);
                errdefer allocator.free(data);

                try reader.readSliceAll(data);

                return makeSamples(
                    data.ptr,
                    chunk.size,
                    info,
                    fact_samples,
                    options,
                    true,
                );
            } else {
                try reader.discardAll(chunk.size);
            }

            if (chunk.size % 2 != 0) {
                reader.discardAll(1) catch {};
            }
        }
    }

    inline fn validateFormatRuntime(f: RawFormatChunk) ParseError!void {
        if (f.tag != PCM_FORMAT and f.tag != IMA_ADPCM_FORMAT) {
            return error.UnsupportedFormat;
        }

        if (f.channels != 1) {
            return error.UnsupportedChannels;
        }

        if (f.sample_rate != sdk.Audio.SAMPLE_RATE) {
            return error.UnsupportedSampleRate;
        }

        if (f.block_align > sdk.Audio.MAX_BLOCK_ALIGN) {
            return error.BlockAlignTooLarge;
        }
    }

    inline fn readFormatExtension(
        reader: *std.Io.Reader,
        fmt_ext: *?RawFormatChunkExt,
        f: RawFormatChunk,
        chunk_size: u32,
    ) !void {
        const fmt_size: u32 = @sizeOf(RawFormatChunk);
        const ext_size: u32 = @sizeOf(RawFormatChunkExt);

        if (chunk_size <= fmt_size) {
            return;
        }

        const remaining = chunk_size - fmt_size;

        if (f.tag == IMA_ADPCM_FORMAT and remaining >= ext_size) {
            fmt_ext.* = try reader.takeStruct(RawFormatChunkExt, .little);

            if (remaining > ext_size) {
                try reader.discardAll(remaining - ext_size);
            }
        } else {
            try reader.discardAll(remaining);
        }
    }
};

pub const Text = struct {
    pub const CHAR_WIDTH: u16 = 8;
    pub const CHAR_HEIGHT: u16 = 8;
    pub const FIRST_CHAR: u8 = 32;
    pub const LAST_CHAR: u8 = 126;

    /// 8x8 bitmap font data (CP437-style)
    /// Each byte represents one row, MSB is leftmost pixel
    const font_data: [95][8]u8 = .{
        // 32: Space
        .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        // 33: !
        .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 },
        // 34: "
        .{ 0x6C, 0x6C, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00 },
        // 35: #
        .{ 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00 },
        // 36: $
        .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 },
        // 37: %
        .{ 0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00 },
        // 38: &
        .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00 },
        // 39: '
        .{ 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00 },
        // 40: (
        .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 },
        // 41: )
        .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 },
        // 42: *
        .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 },
        // 43: +
        .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 },
        // 44: ,
        .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 },
        // 45: -
        .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
        // 46: .
        .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 },
        // 47: /
        .{ 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00 },
        // 48: 0
        .{ 0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00 },
        // 49: 1
        .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
        // 50: 2
        .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 },
        // 51: 3
        .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 },
        // 52: 4
        .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 },
        // 53: 5
        .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 },
        // 54: 6
        .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 },
        // 55: 7
        .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 },
        // 56: 8
        .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 },
        // 57: 9
        .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 },
        // 58: :
        .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 },
        // 59: ;
        .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 },
        // 60: <
        .{ 0x0C, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0C, 0x00 },
        // 61: =
        .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 },
        // 62: >
        .{ 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x00 },
        // 63: ?
        .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 },
        // 64: @
        .{ 0x3C, 0x66, 0x6E, 0x6A, 0x6E, 0x60, 0x3C, 0x00 },
        // 65: A
        .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 },
        // 66: B
        .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 },
        // 67: C
        .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 },
        // 68: D
        .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 },
        // 69: E
        .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 },
        // 70: F
        .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 },
        // 71: G
        .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 },
        // 72: H
        .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 },
        // 73: I
        .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
        // 74: J
        .{ 0x3E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 },
        // 75: K
        .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 },
        // 76: L
        .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 },
        // 77: M
        .{ 0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00 },
        // 78: N
        .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 },
        // 79: O
        .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        // 80: P
        .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 },
        // 81: Q
        .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 },
        // 82: R
        .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 },
        // 83: S
        .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 },
        // 84: T
        .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
        // 85: U
        .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        // 86: V
        .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
        // 87: W
        .{ 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 },
        // 88: X
        .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 },
        // 89: Y
        .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 },
        // 90: Z
        .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 },
        // 91: [
        .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 },
        // 92: backslash
        .{ 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 },
        // 93: ]
        .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 },
        // 94: ^
        .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 },
        // 95: _
        .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF },
        // 96: `
        .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 },
        // 97: a
        .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 },
        // 98: b
        .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 },
        // 99: c
        .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 },
        // 100: d
        .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        // 101: e
        .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 },
        // 102: f
        .{ 0x1C, 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x00 },
        // 103: g
        .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C },
        // 104: h
        .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        // 105: i
        .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        // 106: j
        .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 },
        // 107: k
        .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 },
        // 108: l
        .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        // 109: m
        .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 },
        // 110: n
        .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        // 111: o
        .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        // 112: p
        .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 },
        // 113: q
        .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 },
        // 114: r
        .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 },
        // 115: s
        .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 },
        // 116: t
        .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 },
        // 117: u
        .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        // 118: v
        .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
        // 119: w
        .{ 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00 },
        // 120: x
        .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 },
        // 121: y
        .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C },
        // 122: z
        .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 },
        // 123: {
        .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 },
        // 124: |
        .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
        // 125: }
        .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 },
        // 126: ~
        .{ 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };

    pub fn drawChar(fb: sdk.Framebuffer, x: u16, y: u16, char: u8, color: sdk.ARGB1555) void {
        if (char < FIRST_CHAR or char > LAST_CHAR) {
            return;
        }

        const glyph = font_data[char - FIRST_CHAR];

        inline for (0..8) |row| {
            const py = y + @as(u16, @intCast(row));

            if (py < fb.height) {
                const row_bits = glyph[row];

                inline for (0..8) |col| {
                    const px = x + @as(u16, @intCast(col));

                    if (px < fb.width) {
                        if (row_bits & (@as(u8, 0x80) >> @intCast(col)) != 0) {
                            fb.set(px, py, color);
                        }
                    }
                }
            }
        }
    }

    pub fn draw(fb: sdk.Framebuffer, x: u16, y: u16, text: []const u8, color: sdk.ARGB1555) void {
        var cursor_x = x;
        var cursor_y = y;

        for (text) |char| {
            if (char == '\n') {
                cursor_y += measure(&.{'\n'}).h;

                continue;
            }

            drawChar(fb, cursor_x, y, char, color);

            cursor_x += CHAR_WIDTH;
        }
    }

    pub inline fn drawWithShadow(
        fb: sdk.Framebuffer,
        x: u16,
        y: u16,
        text: []const u8,
        color: sdk.ARGB1555,
        shadow_color: sdk.ARGB1555,
    ) void {
        draw(fb, x + 1, y + 1, text, shadow_color);
        draw(fb, x, y, text, color);
    }

    pub inline fn drawCentered(
        fb: sdk.Framebuffer,
        center_x: u16,
        y: u16,
        text: []const u8,
        color: sdk.ARGB1555,
    ) void {
        const width = measure(text).w;
        const x = center_x -| (width / 2);

        draw(fb, x, y, text, color);
    }

    pub inline fn drawCenteredWithShadow(
        fb: sdk.Framebuffer,
        center_x: u16,
        y: u16,
        text: []const u8,
        color: sdk.ARGB1555,
        shadow_color: sdk.ARGB1555,
    ) void {
        const width = measure(text).w;
        const x = center_x -| (width / 2);

        drawWithShadow(fb, x, y, text, color, shadow_color);
    }

    pub inline fn measure(text: []const u8) struct { w: u16, h: u16 } {
        return .{
            .w = @intCast(text.len * CHAR_WIDTH),
            .h = CHAR_HEIGHT,
        };
    }
};

pub inline fn nsToTicks(ns: u64) u64 {
    return @truncate(@as(u128, ns) * sdk.boot_info.cpu_frequency / std.time.ns_per_s);
}

pub inline fn ticksToNs(ticks: u64) u64 {
    return @truncate(@as(u128, ticks) * std.time.ns_per_s / sdk.boot_info.cpu_frequency);
}

pub const DmaReader = struct {
    interface: std.Io.Reader,
    device: sdk.Dma.Device,
    pos: u32,
    end: u32,

    pub inline fn init(device: sdk.Dma.Device, address: u32, buffer: []u8) DmaReader {
        return .{
            .interface = .{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = stream,
                },
            },
            .device = device,
            .pos = address,
            .end = switch (device) {
                .external_storage => sdk.boot_info.external_storage_size,
                .nvram_storage => sdk.boot_info.nvram_storage_size,
                else => 0,
            },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const this: *DmaReader = @fieldParentPtr("interface", reader);

        if (this.pos >= this.end) {
            return error.EndOfStream;
        }

        const available = writer.buffer.len - writer.end;
        const limited = if (limit.toInt()) |l|
            @min(available, l)
        else
            available;

        if (limited == 0) {
            return 0;
        }

        const to_read: u32 = @intCast(@min(limited, this.end - this.pos));
        const dest = writer.buffer[writer.end..][0..to_read];

        sdk.dma.read(this.device, this.pos, dest);

        this.pos += to_read;
        writer.end += to_read;

        return to_read;
    }

    pub fn seekTo(this: *DmaReader, new_pos: u32) void {
        const logical_pos = this.getPos();

        if (new_pos >= logical_pos and new_pos < this.pos) {
            this.interface.seek += new_pos - logical_pos;

            return;
        }

        this.pos = new_pos;
        this.interface.seek = 0;
        this.interface.end = 0;
    }

    pub fn seekBy(this: *DmaReader, offset: i32) void {
        const current = this.getPos();
        const new_pos: u32 = if (offset >= 0)
            current +| @as(u32, @intCast(offset))
        else
            current -| @as(u32, @intCast(-offset));

        this.seekTo(new_pos);
    }

    pub fn seekFromEnd(this: *DmaReader, offset: u32) void {
        this.seekTo(this.end -| offset);
    }

    pub fn getPos(this: *const DmaReader) u32 {
        const buffered: u32 = @intCast(this.interface.end - this.interface.seek);

        return this.pos - buffered;
    }
};

pub const DmaWriter = struct {
    interface: std.Io.Writer,
    device: sdk.Dma.Device,
    pos: u32,
    end: u32,

    pub inline fn init(device: sdk.Dma.Device, address: u32, buffer: []u8) DmaWriter {
        return .{
            .interface = .{
                .buffer = buffer,
                .end = 0,
                .vtable = &.{
                    .drain = drain,
                },
            },
            .device = device,
            .pos = address,
            .end = switch (device) {
                .external_storage => sdk.boot_info.external_storage_size,
                .nvram_storage => sdk.boot_info.nvram_storage_size,
                else => 0,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const this: *DmaWriter = @fieldParentPtr("interface", w);

        if (w.end > 0) {
            try this.dmaWrite(w.buffer[0..w.end]);
            w.end = 0;
        }

        var written: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len > 0) {
                try this.dmaWrite(bytes);
            }

            written += bytes.len;
        }

        const pattern = data[data.len - 1];

        for (0..splat) |_| {
            if (pattern.len > 0) {
                try this.dmaWrite(pattern);
            }

            written += pattern.len;
        }

        return written;
    }

    fn dmaWrite(this: *DmaWriter, bytes: []const u8) std.Io.Writer.Error!void {
        const len: u32 = std.math.cast(u32, bytes.len) orelse return error.WriteFailed;

        if (this.end - this.pos < len) {
            return error.WriteFailed;
        }

        sdk.dma.write(this.device, this.pos, bytes);
        this.pos += len;
    }

    pub fn seekTo(this: *DmaWriter, new_pos: u32) std.Io.Writer.Error!void {
        try this.interface.flush();
        this.pos = new_pos;
    }

    pub fn seekBy(this: *DmaWriter, offset: i32) std.Io.Writer.Error!void {
        try this.interface.flush();

        if (offset >= 0) {
            this.pos +|= @as(u32, @intCast(offset));
        } else {
            this.pos -|= @as(u32, @intCast(-offset));
        }
    }

    pub fn seekFromEnd(this: *DmaWriter, offset: u32) std.Io.Writer.Error!void {
        try this.seekTo(this.end -| offset);
    }

    pub fn getPos(this: *const DmaWriter) u32 {
        return this.pos + @as(u32, @intCast(this.interface.end));
    }

    pub fn fillBytes(this: *DmaWriter, byte: u8, count: u32) !void {
        try this.interface.flush();

        if (this.end - this.pos < count) {
            return error.WriteFailed;
        }

        const pattern: [1]u8 = .{byte};
        sdk.dma.fill(this.device, this.pos, &pattern, count);
        this.pos += count;
    }

    pub fn fillPattern(this: *DmaWriter, pattern: []const u8, total_len: u32) !void {
        try this.interface.flush();

        if (this.end - this.pos < total_len) {
            return error.WriteFailed;
        }

        sdk.dma.fill(this.device, this.pos, pattern, total_len);
        this.pos += total_len;
    }
};

pub const RomImageHeader = extern struct {
    pub const MAGIC = [4]u8{ 'R', 'W', 'P', 'I' };

    magic: [4]u8,
    version: u32,
    game_id: u64,
    developer_id: u64,
    entries_count: u32,
    entries_start: u32,
};

pub const RomImageEntry = extern struct {
    checksum: u32,
    content_size: u32,
    name_len: u16,
    _padding: [2]u8 = std.mem.zeroes([2]u8),
    // name: []u8,
};

pub const RomImageIterator = union(enum) {
    pub const Entry = struct {
        entry: RomImageEntry,
        name: []u8,
        content_pos: u32,

        pub inline fn deinit(this: *const Entry, allocator: std.mem.Allocator) void {
            allocator.free(this.name);
        }
    };

    const DmaIterator = struct {
        reader: DmaReader,
        header: ?RomImageHeader = null,
        current_entry: ?u32 = null,

        pub inline fn init(buffer: []u8) DmaIterator {
            return .{
                .reader = .init(.external_storage, 0, buffer),
            };
        }

        inline fn next(this: *DmaIterator, allocator: ?std.mem.Allocator) ?Entry {
            if (this.header == null) {
                const header = this.reader.interface.takeStruct(RomImageHeader, .little) catch {
                    return null;
                };

                this.header = header;
            }

            const header: *const RomImageHeader = &this.header.?;

            if (this.current_entry == null) {
                this.reader.seekTo(header.entries_start);
                this.current_entry = 0;
            }

            if (this.current_entry.? >= header.entries_count) {
                return null;
            }

            const entry = this.reader.interface.takeStruct(RomImageEntry, .little) catch {
                return null;
            };

            var name: []u8 = &.{};

            if (allocator != null) {
                name = this.reader.interface.readAlloc(allocator.?, entry.name_len) catch &.{};
            } else {
                this.reader.seekBy(entry.name_len);
            }

            const content_pos = this.reader.getPos();

            this.reader.seekBy(@intCast(entry.content_size));
            this.current_entry.? += 1;

            return .{
                .entry = entry,
                .name = name,
                .content_pos = content_pos,
            };
        }
    };

    from_dma: DmaIterator,

    pub inline fn dma(buffer: []u8) RomImageIterator {
        return .{
            .from_dma = .init(buffer),
        };
    }

    pub inline fn next(this: *RomImageIterator) ?Entry {
        switch (this.*) {
            .from_dma => return this.from_dma.next(null),
        }
    }

    pub inline fn nextAlloc(this: *RomImageIterator, allocator: std.mem.Allocator) ?Entry {
        switch (this.*) {
            .from_dma => return this.from_dma.next(allocator),
        }
    }
};
