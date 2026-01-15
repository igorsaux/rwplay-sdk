// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const sdk = @import("sdk").gen1;

pub const MAX_VERSION: usize = 1;
pub const MIN_VERSION: usize = 1;
/// 1 MB
pub const MAX_MANIFEST_SIZE = std.math.pow(usize, 2, 20);
pub const VERSION = 1;
pub const HASH_SEED: u64 = 0x52575049;

pub const PackManifestV1 = struct {
    pub const Complex = struct {
        args: std.ArrayList([]u8) = .empty,
        from_stdio: bool = true,
        from_file: []u8 = &.{},

        pub fn deinit(this: *Complex, allocator: std.mem.Allocator) void {
            for (this.args.items) |arg| {
                allocator.free(arg);
            }

            this.args.deinit(allocator);
            allocator.free(this.from_file);
        }
    };

    pub const FileSource = union(enum) {
        simple: []u8,
        extended: Complex,

        pub fn deinit(this: *FileSource, allocator: std.mem.Allocator) void {
            switch (this.*) {
                .simple => allocator.free(this.simple),
                .extended => this.extended.deinit(allocator),
            }
        }
    };

    pub const File = struct {
        name: []u8,
        source: FileSource,

        pub fn deinit(this: *File, allocator: std.mem.Allocator) void {
            allocator.free(this.name);
            this.source.deinit(allocator);
        }
    };

    version: u32 = 0,
    game: []u8 = &.{},
    developer: []u8 = &.{},
    files: std.ArrayList(File) = .empty,

    pub const Error = error{BadManifest};

    pub fn fromJson(allocator: std.mem.Allocator, root: std.json.Value) !PackManifestV1 {
        if (root != .object) {
            std.debug.print("a manifest should be an object\n", .{});

            return PackManifestV1.Error.BadManifest;
        }

        var manifest: PackManifestV1 = .{};

        try manifest.readVersionField(root);
        try manifest.readGameField(allocator, root);
        errdefer allocator.free(manifest.game);

        try manifest.readDeveloperField(allocator, root);
        errdefer allocator.free(manifest.developer);

        try manifest.readFilesField(allocator, root);

        return manifest;
    }

    fn readVersionField(this: *PackManifestV1, root: std.json.Value) !void {
        const version_value = root.object.get("version") orelse {
            std.debug.print("the field \"version\" is missing\n", .{});

            return PackManifestV1.Error.BadManifest;
        };

        if (version_value != .integer) {
            std.debug.print("the field \"version\" should be an integer\n", .{});

            return PackManifestV1.Error.BadManifest;
        }

        if (version_value.integer < 0 or version_value.integer > std.math.maxInt(u32)) {
            std.debug.print("the field \"version\" should be in range between 0 and {d}\n", .{std.math.maxInt(u32)});

            return PackManifestV1.Error.BadManifest;
        }

        this.version = @intCast(version_value.integer);
    }

    fn readGameField(this: *PackManifestV1, allocator: std.mem.Allocator, root: std.json.Value) !void {
        const game_value = root.object.get("game") orelse {
            std.debug.print("the field \"game\" is missing\n", .{});

            return PackManifestV1.Error.BadManifest;
        };

        if (game_value != .string) {
            std.debug.print("the field \"game\" should be a string\n", .{});

            return PackManifestV1.Error.BadManifest;
        }

        this.game = try allocator.dupe(u8, game_value.string);
    }

    fn readDeveloperField(this: *PackManifestV1, allocator: std.mem.Allocator, root: std.json.Value) !void {
        const developer_value = root.object.get("developer") orelse {
            std.debug.print("the field \"developer\" is missing\n", .{});

            return PackManifestV1.Error.BadManifest;
        };

        if (developer_value != .string) {
            std.debug.print("the field \"developer\" should be a string\n", .{});

            return PackManifestV1.Error.BadManifest;
        }

        this.developer = try allocator.dupe(u8, developer_value.string);
    }

    fn readFilesField(this: *PackManifestV1, allocator: std.mem.Allocator, root: std.json.Value) !void {
        const file_value = root.object.get("files") orelse {
            std.debug.print("the field \"files\" is missing\n", .{});

            return PackManifestV1.Error.BadManifest;
        };

        if (file_value != .object) {
            std.debug.print("the field \"files\" should be an object\n", .{});

            return PackManifestV1.Error.BadManifest;
        }

        try this.files.ensureTotalCapacity(allocator, @intCast(file_value.object.count()));
        errdefer this.deinitFiles(allocator);

        var file_iter = file_value.object.iterator();
        var file_idx: usize = 0;

        while (file_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr;

            switch (value.*) {
                .string => {
                    this.files.append(allocator, .{
                        .name = try allocator.dupe(u8, key),
                        .source = .{
                            .simple = try allocator.dupe(u8, value.string),
                        },
                    }) catch unreachable;
                },
                .object => {
                    var cmd: Complex = .{};
                    errdefer cmd.deinit(allocator);

                    // args field

                    if (value.object.get("args")) |args| {
                        if (args != .array) {
                            std.debug.print("the type of field \"files[{}].args\" must be an array\n", .{file_idx});

                            return PackManifestV1.Error.BadManifest;
                        }

                        try cmd.args.ensureTotalCapacity(allocator, args.array.items.len);

                        for (args.array.items, 0..) |arg, arg_idx| {
                            if (arg != .string) {
                                std.debug.print("the type of the value \"files[{}].args[{}]\" must be a string\n", .{ file_idx, arg_idx });

                                return PackManifestV1.Error.BadManifest;
                            }

                            const dupe = try allocator.dupe(u8, arg.string);
                            cmd.args.append(allocator, dupe) catch unreachable;
                        }
                    }

                    // from_stdio field

                    var from_stdio_was_set = false;

                    if (value.object.get("from_stdio")) |from_stdio_value| {
                        from_stdio_was_set = true;

                        if (from_stdio_value != .bool) {
                            std.debug.print("the type of field \"files[{}].from_stdio\" must be a bool\n", .{file_idx});

                            return PackManifestV1.Error.BadManifest;
                        }

                        cmd.from_stdio = from_stdio_value.bool;
                    }

                    // from_file field

                    if (value.object.get("from_file")) |from_file_value| {
                        if (from_file_value != .string) {
                            std.debug.print("the type of field \"files[{}].from_file\" must be a string\n", .{file_idx});

                            return PackManifestV1.Error.BadManifest;
                        }

                        cmd.from_file = try allocator.dupe(u8, from_file_value.string);

                        if (!from_stdio_was_set) {
                            cmd.from_stdio = false;
                        }
                    }

                    this.files.append(allocator, .{
                        .name = try allocator.dupe(u8, key),
                        .source = .{
                            .extended = cmd,
                        },
                    }) catch unreachable;
                },
                else => {
                    std.debug.print("the value of \"files[{}]\" must be a string or an object\n", .{file_idx});

                    return PackManifestV1.Error.BadManifest;
                },
            }

            file_idx += 1;
        }
    }

    fn deinitFiles(this: *PackManifestV1, allocator: std.mem.Allocator) void {
        for (this.files.items) |*file| {
            file.deinit(allocator);
        }

        this.files.deinit(allocator);
    }

    pub fn deinit(this: *PackManifestV1, allocator: std.mem.Allocator) void {
        allocator.free(this.game);
        allocator.free(this.developer);
        this.deinitFiles(allocator);
    }
};

fn printHelp() void {
    std.debug.print(
        \\Usage: imagemaker <path> <out>
    ++ "\n", .{});
}

const PackError = error{ BadManifest, IoError, OutOfMemory };

fn serializeRomImage(allocator: std.mem.Allocator, manifest: *const PackManifestV1, writer: *std.Io.Writer) PackError!void {
    var pos: usize = 0;

    const header: sdk.utils.RomImageHeader = .{
        .magic = sdk.utils.RomImageHeader.MAGIC,
        .version = manifest.version,
        .game_id = std.hash.XxHash64.hash(HASH_SEED, manifest.game),
        .developer_id = std.hash.XxHash64.hash(HASH_SEED, manifest.developer),
        .entries_count = @intCast(manifest.files.items.len),
        .entries_start = @intCast(std.mem.Alignment.forward(.of(sdk.utils.RomImageEntry), @sizeOf(sdk.utils.RomImageHeader))),
    };

    writer.writeAll(std.mem.asBytes(&header)) catch |err| {
        std.debug.print("failed to write the header bytes: {t}\n", .{err});

        return PackError.IoError;
    };
    pos += @sizeOf(sdk.utils.RomImageHeader);

    for (pos..header.entries_start) |_| {
        writer.writeByte(0) catch |err| {
            std.debug.print("failed to write the table padding: {t}\n", .{err});

            return PackError.IoError;
        };

        pos += 1;
    }

    for (manifest.files.items) |file| {
        const content: []u8 = content: switch (file.source) {
            .simple => |path| {
                const content = std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(u32)) catch |err| {
                    std.debug.print("failed to read the file \"{s}\": {t}\n", .{ path, err });

                    return PackError.IoError;
                };

                break :content content;
            },
            .extended => |*extented| {
                if (extented.from_file.len != 0 and extented.from_stdio) {
                    std.debug.print("the \"from_file\" and \"from_stdio\" fields should not be set at the same time.\n", .{});

                    return PackError.BadManifest;
                }

                if (extented.args.items.len == 0) {
                    if (extented.from_stdio) {
                        std.debug.print("the commands for file \"{s}\" are missing\n", .{file.name});

                        return PackError.BadManifest;
                    }

                    const content = std.fs.cwd().readFileAlloc(allocator, extented.from_file, std.math.maxInt(u32)) catch |err| {
                        std.debug.print("failed to read the file \"{s}\": {t}\n", .{ extented.from_file, err });

                        return PackError.IoError;
                    };

                    break :content content;
                }

                var child = std.process.Child.init(extented.args.items, allocator);
                child.stderr_behavior = .Pipe;
                child.stdout_behavior = .Pipe;

                child.waitForSpawn() catch |err| {
                    std.debug.print("failed to spawn subprocess \"{any}\": {t}\n", .{ extented.args.items, err });

                    return PackError.BadManifest;
                };

                var stdout: std.ArrayList(u8) = .empty;
                var stderr: std.ArrayList(u8) = .empty;

                child.collectOutput(allocator, &stdout, &stderr, std.math.maxInt(u32)) catch |err| {
                    std.debug.print("failed to collect outputs of subprocess \"{any}\": {t}\n", .{ extented.args.items, err });

                    return PackError.IoError;
                };

                defer stdout.deinit(allocator);
                defer stderr.deinit(allocator);

                const term = child.wait() catch |err| {
                    std.debug.print("failed to wait for subprocess \"{any}\": {t}\n", .{ extented.args.items, err });

                    return PackError.IoError;
                };

                var lines = std.mem.splitScalar(u8, stderr.items, '\n');

                while (lines.next()) |line| {
                    std.debug.print("[{s}] {s}\n", .{ extented.args.items[0], line });
                }

                switch (term) {
                    .Exited => |code| {
                        if (code != 0) {
                            std.debug.print("subprocess \"{any}\" exited with code {}\n", .{ extented.args.items, code });

                            return PackError.IoError;
                        }
                    },
                    else => {
                        std.debug.print("subprocess \"{any}\" terminated unexpectedly: {any}\n", .{ extented.args.items, term });

                        return PackError.IoError;
                    },
                }

                if (extented.from_stdio) {
                    break :content try stdout.toOwnedSlice(allocator);
                } else {
                    const content = std.fs.cwd().readFileAlloc(allocator, extented.from_file, std.math.maxInt(u32)) catch |err| {
                        std.debug.print("failed to read the file \"{s}\": {t}\n", .{ extented.from_file, err });

                        return PackError.IoError;
                    };

                    break :content content;
                }
            },
        };
        defer allocator.free(content);

        const entry: sdk.utils.RomImageEntry = .{
            .checksum = std.hash.Crc32.hash(content),
            .content_size = @intCast(content.len),
            .name_len = @intCast(file.name.len),
        };

        writer.writeAll(std.mem.asBytes(&entry)) catch |err| {
            std.debug.print("failed to write the entry bytes: {t}\n", .{err});

            return PackError.IoError;
        };
        pos += @sizeOf(sdk.utils.RomImageEntry);

        writer.writeAll(file.name) catch |err| {
            std.debug.print("failed to write the file name: {t}\n", .{err});

            return PackError.IoError;
        };
        pos += file.name.len;

        writer.writeAll(content) catch |err| {
            std.debug.print("failed to write the file content: {t}\n", .{err});

            return PackError.IoError;
        };
        pos += content.len;
    }

    writer.flush() catch |err| {
        std.debug.print("failed to flush the image bytes: {t}\n", .{err});

        return PackError.IoError;
    };
}

fn packCmd(allocator: std.mem.Allocator, path: []const u8, out: []const u8) PackError!void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, MAX_MANIFEST_SIZE) catch |err| {
        std.debug.print("failed to open the file '{s}': {t}\n", .{ path, err });

        return PackError.BadManifest;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_if_needed,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| {
        std.debug.print("failed to parse the file '{s}': {t}\n", .{ path, err });

        return PackError.BadManifest;
    };
    defer parsed.deinit();

    var manifest: PackManifestV1 = try .fromJson(allocator, parsed.value);
    defer manifest.deinit(allocator);

    if (manifest.version > MAX_VERSION or manifest.version < MIN_VERSION) {
        std.debug.print("manifest version {} is not supported, supported versions range: {} - {}\n", .{ manifest.version, MIN_VERSION, MAX_VERSION });

        return PackError.BadManifest;
    }

    var buffer: [std.math.pow(usize, 2, 12)]u8 = undefined;

    if (std.mem.eql(u8, out, "-")) {
        var writer = std.fs.File.stdout().writer(&buffer);

        try serializeRomImage(allocator, &manifest, &writer.interface);
    } else {
        var out_file = std.fs.cwd().createFile(out, .{}) catch |err| {
            std.debug.print("failed to create a file \"{s}\": {t}\n", .{ out, err });

            return PackError.IoError;
        };
        errdefer std.fs.cwd().deleteFile(out) catch {};
        defer out_file.close();

        var writer = out_file.writer(&buffer);

        try serializeRomImage(allocator, &manifest, &writer.interface);
    }
}

const Error = error{ InvalidArgs, CommandFailed };

pub fn main() !void {
    var alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = alloc.deinit();

    const args = try std.process.argsAlloc(alloc.allocator());
    defer std.process.argsFree(alloc.allocator(), args);

    if (args.len != 3) {
        printHelp();

        return Error.InvalidArgs;
    }

    packCmd(alloc.allocator(), args[1], args[2]) catch |err| {
        std.debug.print("failed to execute \"pack\" command: {t}\n", .{err});

        return Error.CommandFailed;
    };
}
