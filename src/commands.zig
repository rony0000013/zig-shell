const std = @import("std");
const utils = @import("utils.zig");

pub const Command = union(enum) {
    type: struct {
        allocator: std.mem.Allocator,
        cmd: []const u8,
    },
    echo: struct {
        messages: std.ArrayList([]const u8),
    },
    exit: struct {
        code: u8,
    },
    pwd: void,
    cd: struct {
        allocator: std.mem.Allocator,
        path: []const u8,
    },
    unknown: struct {
        commands: std.ArrayList([]const u8),
    },
};

const CommandType = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
};

pub fn parseCommand(input: []const u8) !Command {
    const heap = std.heap.page_allocator;
    // const pattern = "\\s*(\'(?:[^\']*)\'|\"(?:[^\"\\]*(?:\\.[^\"\\]*)*)\"|(?:[^ \\t\\n\\r\\]*(?:\\.[^ \\t\\n\\r\\]*)*))\\s*";

    var commands = std.ArrayList([]const u8).init(heap);
    var arg = std.ArrayList(u8).init(heap);
    defer arg.deinit();

    var command_iter = std.mem.splitScalar(u8, input, ' ');
    const first_token_raw = command_iter.next() orelse return Command{ .unknown = .{ .commands = std.ArrayList([]const u8).init(heap) } };

    const first_token_dup = try heap.dupe(u8, first_token_raw);
    try commands.append(first_token_dup);

    var in_single_quote: bool = false;
    var in_double_quote: bool = false;
    var is_escaped: bool = false;

    for (command_iter.rest()) |token| {
        switch (token) {
            ' ' => {
                if (in_single_quote or in_double_quote or is_escaped) {
                    if (!in_double_quote and is_escaped) {
                        _ = arg.pop();
                    }
                    is_escaped = false;
                    try arg.append(token);
                } else if (arg.items.len != 0) {
                    try commands.append(try arg.toOwnedSlice());
                    arg.clearRetainingCapacity();
                }
            },
            '\'' => {
                if (!in_double_quote and is_escaped) {
                    _ = arg.pop();
                    is_escaped = false;
                } else {
                    in_single_quote = !in_single_quote;
                }
                try arg.append(token);
            },
            '"' => {
                if (in_single_quote) {
                    try arg.append(token);
                } else if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                    is_escaped = false;
                } else if (is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                    is_escaped = false;
                } else {
                    in_double_quote = !in_double_quote;
                }
            },
            '\\' => {
                if (in_single_quote) {
                    try arg.append(token);
                } else if (in_double_quote and is_escaped) {
                    is_escaped = false;
                } else {
                    try arg.append(token);
                    is_escaped = true;
                }
            },
            '\n' => {
                if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append('\n');
                    is_escaped = false;
                } else {
                    break;
                }
            },
            '$' => {
                if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append('$');
                    is_escaped = false;
                }
            },
            '`' => {
                if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append('`');
                    is_escaped = false;
                }
            },
            else => {
                if (in_double_quote and is_escaped) {
                    is_escaped = false;
                } else if (is_escaped) {
                    _ = arg.pop();
                    is_escaped = false;
                }
                try arg.append(token);
            },
        }
    }

    if (arg.items.len != 0) {
        try commands.append(try arg.toOwnedSlice());
        arg.clearRetainingCapacity();
    }

    const lower_first_token = try std.ascii.allocLowerString(heap, commands.items[0]);
    defer heap.free(lower_first_token);
    if (std.meta.stringToEnum(CommandType, lower_first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => {
                const code = try std.fmt.parseInt(u8, command_iter.next() orelse "0", 10);
                return Command{ .exit = .{ .code = code } };
            },
            .echo => {
                return Command{ .echo = .{ .messages = commands } };
            },
            .type => {
                const raw_cmd = command_iter.next() orelse return Command{ .unknown = .{ .commands = commands } };
                const cleaned_cmd = std.mem.trim(u8, raw_cmd, &std.ascii.whitespace);
                const lower_cmd = try std.ascii.allocLowerString(heap, cleaned_cmd);

                return Command{ .type = .{ .allocator = heap, .cmd = lower_cmd } };
            },
            .pwd => Command{ .pwd = void{} },
            .cd => {
                const path = command_iter.next() orelse return Command{ .unknown = .{ .commands = commands } };
                const cleaned_path = std.mem.trim(u8, path, &std.ascii.whitespace);
                const lower_path = try std.ascii.allocLowerString(heap, cleaned_path);
                return Command{ .cd = .{ .allocator = heap, .path = lower_path } };
            },
        };
    }

    return Command{ .unknown = .{ .commands = commands } };
}

pub fn runEcho(stdout: anytype, messages: std.ArrayList([]const u8)) !void {
    defer messages.deinit();

    for (1..messages.items.len) |i| {
        try stdout.print("{s} ", .{messages.items[i]});
    }
    try stdout.print("\n", .{});
}

pub fn runType(stdout: anytype, cmd: []const u8, paths: std.StringHashMap([]const u8)) !void {
    // {
    //     var it = paths.iterator();
    //     while (it.next()) |entry| {
    //         std.debug.print("- {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    //     }
    // }
    const valid = std.meta.stringToEnum(CommandType, cmd) != null;

    if (valid) {
        try stdout.print("{s} is a shell builtin\n", .{cmd});
    } else {
        var it = paths.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, cmd)) {
                try stdout.print("{s} is {s}\n", .{ cmd, entry.value_ptr.* });
                return;
            }
        }
        try stdout.print("{s}: not found\n", .{cmd});
    }
}

pub fn runCd(stdout: anytype, allocator: std.mem.Allocator, path: []const u8) !void {
    defer allocator.free(path);

    if (std.mem.eql(u8, path, "~")) {
        const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home_dir);
        var dir = try std.fs.openDirAbsolute(home_dir, .{});
        defer dir.close();
        return try dir.setAsCwd();
    }
    if (std.fs.path.isAbsolute(path)) {
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            const stat = try file.stat();
            if (stat.kind != .directory) {
                try stdout.print("cd: {s}: Not a directory\n", .{path});
                return;
            }
        } else |_| {}

        var dir = std.fs.openDirAbsolute(path, .{}) catch {
            try stdout.print("cd: {s}: No such file or directory\n", .{path});
            return;
        };
        defer dir.close();
        return try dir.setAsCwd();
    }

    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch {
        try stdout.print("cd: {s}: No such file or directory\n", .{path});
        return;
    };
    defer allocator.free(abs_path);

    if (std.fs.openFileAbsolute(abs_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.kind != .directory) {
            try stdout.print("cd: {s}: Not a directory\n", .{abs_path});
            return;
        }
    } else |_| {}

    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch {
        try stdout.print("cd: {s}: No such file or directory\n", .{abs_path});
        return;
    };
    defer dir.close();
    return try dir.setAsCwd();
}
