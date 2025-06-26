const std = @import("std");
const utils = @import("utils.zig");

pub const CommandOutput = struct {
    Command: Command,
    Output: Output,
};

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

pub const Output = struct {
    Stdout: std.fs.File,
    Stderr: std.fs.File,
};

// const OutputType = union(enum) {
//     std = std.io.getStdOut(),
//     file: std.fs.File,
// };

const CommandType = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
};

pub fn parseCommand(input: []const u8) !CommandOutput {
    const heap = std.heap.page_allocator;
    // const pattern = "\\s*(\'(?:[^\']*)\'|\"(?:[^\"\\]*(?:\\.[^\"\\]*)*)\"|(?:[^ \\t\\n\\r\\]*(?:\\.[^ \\t\\n\\r\\]*)*))\\s*";

    var commands = std.ArrayList([]const u8).init(heap);
    var arg = std.ArrayList(u8).init(heap);
    defer arg.deinit();

    var in_single_quote: bool = false;
    var in_double_quote: bool = false;
    var is_escaped: bool = false;

    for (input) |token| {
        switch (token) {
            ' ' => {
                if (in_single_quote) {
                    try arg.append(token);
                } else if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                } else if (in_double_quote) {
                    try arg.append(token);
                } else if (is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                } else if (arg.items.len != 0) {
                    try commands.append(try arg.toOwnedSlice());
                    arg.clearRetainingCapacity();
                }
                is_escaped = false;
            },
            '\'' => {
                if (in_double_quote) {
                    try arg.append(token);
                } else if (is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                } else {
                    in_single_quote = !in_single_quote;
                }
                is_escaped = false;
            },
            '"' => {
                // std.debug.print("in_double_quote: {}, is_escaped: {}, in_single_quote: {}\n", .{ in_double_quote, is_escaped, in_single_quote });
                if (in_single_quote) {
                    try arg.append(token);
                } else if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                } else if (!in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
                } else {
                    in_double_quote = !in_double_quote;
                }
                is_escaped = false;
            },
            '\\' => {
                if (in_single_quote) {
                    try arg.append(token);
                } else if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                    try arg.append(token);
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
                }
                try arg.append(token);
                is_escaped = false;
            },
            '`' => {
                if (in_double_quote and is_escaped) {
                    _ = arg.pop();
                }
                try arg.append(token);
                is_escaped = false;
            },
            else => {
                if (is_escaped and !in_double_quote) {
                    _ = arg.pop();
                }
                try arg.append(token);
                is_escaped = false;
            },
        }
    }

    if (arg.items.len != 0) {
        try commands.append(try arg.toOwnedSlice());
        arg.clearRetainingCapacity();
    }
    const output = try parseOutput(&commands);

    if (commands.items.len == 0) {
        return CommandOutput{ .Command = Command{ .unknown = .{ .commands = commands } }, .Output = output };
    }

    const lower_first_token = try std.ascii.allocLowerString(heap, commands.items[0]);
    defer heap.free(lower_first_token);
    if (std.meta.stringToEnum(CommandType, lower_first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => {
                if (commands.items.len < 2) {
                    return CommandOutput{ .Command = Command{ .unknown = .{ .commands = commands } }, .Output = output };
                }
                const code = try std.fmt.parseInt(u8, commands.items[1], 10);
                return CommandOutput{ .Command = Command{ .exit = .{ .code = code } }, .Output = output };
            },
            .echo => {
                return CommandOutput{ .Command = Command{ .echo = .{ .messages = commands } }, .Output = output };
            },
            .type => {
                if (commands.items.len < 2) {
                    return CommandOutput{ .Command = Command{ .unknown = .{ .commands = commands } }, .Output = output };
                }
                const raw_cmd = commands.items[1];
                const cleaned_cmd = std.mem.trim(u8, raw_cmd, &std.ascii.whitespace);
                const lower_cmd = try std.ascii.allocLowerString(heap, cleaned_cmd);

                return CommandOutput{ .Command = Command{ .type = .{ .allocator = heap, .cmd = lower_cmd } }, .Output = output };
            },
            .pwd => CommandOutput{ .Command = Command{ .pwd = void{} }, .Output = output },
            .cd => {
                if (commands.items.len < 2) {
                    return CommandOutput{ .Command = Command{ .unknown = .{ .commands = commands } }, .Output = output };
                }
                const path = commands.items[1];
                const cleaned_path = std.mem.trim(u8, path, &std.ascii.whitespace);
                const lower_path = try std.ascii.allocLowerString(heap, cleaned_path);
                return CommandOutput{ .Command = Command{ .cd = .{ .allocator = heap, .path = lower_path } }, .Output = output };
            },
        };
    }

    return CommandOutput{ .Command = Command{ .unknown = .{ .commands = commands } }, .Output = output };
}

pub fn parseOutput(commands: *std.ArrayList([]const u8)) !Output {
    const allocator = std.heap.page_allocator;
    var output = Output{
        .Stdout = std.io.getStdOut(),
        .Stderr = std.io.getStdErr(),
    };

    var to_remove = std.ArrayList(usize).init(allocator);
    defer to_remove.deinit();

    const l = commands.items.len;
    for (commands.items, 0..) |arg, i| {
        if (i + 1 >= l) {
            continue;
        }
        const handleFile = struct {
            fn create(path: []const u8, truncate: bool) !std.fs.File {
                if (std.fs.path.isAbsolute(path)) {
                    if (truncate) {
                        return std.fs.createFileAbsolute(path, .{}) catch |err| {
                            if (err == error.PathAlreadyExists) {
                                return std.fs.openFileAbsolute(path, .{ .mode = .read_write });
                            }
                            return err;
                        };
                    } else {
                        return std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                            if (err == error.FileNotFound) {
                                return std.fs.cwd().createFile(path, .{ .truncate = false });
                            }
                            return err;
                        };
                    }
                } else {
                    if (truncate) {
                        return std.fs.cwd().createFile(path, .{}) catch |err| {
                            if (err == error.PathAlreadyExists) {
                                return std.fs.cwd().openFile(path, .{ .mode = .read_write });
                            }
                            return err;
                        };
                    } else {
                        return std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| {
                            if (err == error.FileNotFound) {
                                return std.fs.cwd().createFile(path, .{ .truncate = false });
                            }
                            return err;
                        };
                    }
                }
            }
        };

        if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>")) {
            output.Stdout = try handleFile.create(commands.items[i + 1], true);
            try to_remove.append(i);
            try to_remove.append(i + 1);
        } else if (std.mem.eql(u8, arg, "2>")) {
            output.Stderr = try handleFile.create(commands.items[i + 1], true);
            try to_remove.append(i);
            try to_remove.append(i + 1);
        } else if (std.mem.eql(u8, arg, ">>") or std.mem.eql(u8, arg, "1>>")) {
            const file = try handleFile.create(commands.items[i + 1], false);
            try file.seekTo(try file.getEndPos());
            output.Stdout = file;
            try to_remove.append(i);
            try to_remove.append(i + 1);
        } else if (std.mem.eql(u8, arg, "2>>")) {
            const file = try handleFile.create(commands.items[i + 1], false);
            try file.seekTo(try file.getEndPos());
            output.Stderr = file;
            try to_remove.append(i);
            try to_remove.append(i + 1);
        }
    }

    std.sort.block(usize, to_remove.items, {}, comptime std.sort.desc(usize));
    for (to_remove.items) |i| {
        _ = commands.orderedRemove(i);
    }
    return output;
}

pub fn runEcho(output: Output, messages: std.ArrayList([]const u8)) !void {
    defer messages.deinit();

    for (1..messages.items.len) |i| {
        try output.Stdout.writer().print("{s} ", .{messages.items[i]});
    }
    try output.Stdout.writer().print("\n", .{});
}

pub fn runType(output: Output, cmd: []const u8, paths: std.StringHashMap([]const u8)) !void {
    // {
    //     var it = paths.iterator();
    //     while (it.next()) |entry| {
    //         std.debug.print("- {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    //     }
    // }
    const valid = std.meta.stringToEnum(CommandType, cmd) != null;

    if (valid) {
        try output.Stdout.writer().print("{s} is a shell builtin\n", .{cmd});
    } else {
        var it = paths.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, cmd)) {
                try output.Stdout.writer().print("{s} is {s}\n", .{ cmd, entry.value_ptr.* });
                return;
            }
        }
        try output.Stdout.writer().print("{s}: not found\n", .{cmd});
    }
}

pub fn runCd(output: Output, allocator: std.mem.Allocator, path: []const u8) !void {
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
                try output.Stdout.writer().print("cd: {s}: Not a directory\n", .{path});
                return;
            }
        } else |_| {}

        var dir = std.fs.openDirAbsolute(path, .{}) catch {
            try output.Stdout.writer().print("cd: {s}: No such file or directory\n", .{path});
            return;
        };
        defer dir.close();
        return try dir.setAsCwd();
    }

    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch {
        try output.Stdout.writer().print("cd: {s}: No such file or directory\n", .{path});
        return;
    };
    defer allocator.free(abs_path);

    if (std.fs.openFileAbsolute(abs_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.kind != .directory) {
            try output.Stdout.writer().print("cd: {s}: Not a directory\n", .{abs_path});
            return;
        }
    } else |_| {}

    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch {
        try output.Stdout.writer().print("cd: {s}: No such file or directory\n", .{abs_path});
        return;
    };
    defer dir.close();
    return try dir.setAsCwd();
}
