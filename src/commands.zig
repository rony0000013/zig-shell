const std = @import("std");
const mvzr = @import("mvzr");
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
    const pattern = "\\s*('[^']+'|\"[^\"]+\"|\\w+)\\s*";
    const re = mvzr.compile(pattern) orelse return error.RegexCompilationFailed;

    var command = std.mem.splitScalar(u8, input, ' ');
    const first_token_raw = command.next() orelse return Command{ .unknown = .{ .commands = std.ArrayList([]const u8).init(heap) } };

    var commands = std.ArrayList([]const u8).init(heap);
    try commands.append(first_token_raw);
    var it = re.iterator(command.rest());
    while (it.next()) |match| {
        const token = std.mem.trim(u8, match.slice, "'\" ");
        try commands.append(token);
    }

    const first_token = try std.ascii.allocLowerString(heap, first_token_raw);
    defer heap.free(first_token);

    if (std.meta.stringToEnum(CommandType, first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => {
                const code = try std.fmt.parseInt(u8, command.next() orelse "0", 10);
                return Command{ .exit = .{ .code = code } };
            },
            .echo => Command{ .echo = .{ .messages = commands } },
            .type => {
                const raw_cmd = command.next() orelse return Command{ .unknown = .{ .commands = commands } };
                const cleaned_cmd = std.mem.trim(u8, raw_cmd, &std.ascii.whitespace);
                const lower_cmd = try std.ascii.allocLowerString(heap, cleaned_cmd);

                return Command{ .type = .{ .allocator = heap, .cmd = lower_cmd } };
            },
            .pwd => Command{ .pwd = void{} },
            .cd => {
                const path = command.next() orelse return Command{ .unknown = .{ .commands = commands } };
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
