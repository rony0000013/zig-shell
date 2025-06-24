const std = @import("std");
const utils = @import("utils.zig");

pub const Command = union(enum) {
    type: struct {
        allocator: std.mem.Allocator,
        cmd: []const u8,
    },
    echo: struct {
        message: []const u8,
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
    var command = std.mem.splitScalar(u8, input, ' ');
    const first_token_raw = command.next() orelse return Command{ .unknown = .{ .commands = std.ArrayList([]const u8).init(heap) } };

    var commands = std.ArrayList([]const u8).init(heap);
    try commands.append(first_token_raw);

    const first_token = try std.ascii.allocLowerString(heap, first_token_raw);
    defer heap.free(first_token);

    if (std.meta.stringToEnum(CommandType, first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => {
                const code = try std.fmt.parseInt(u8, command.next() orelse "0", 10);
                return Command{ .exit = .{ .code = code } };
            },
            .echo => Command{ .echo = .{ .message = command.rest() } },
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

    while (command.next()) |token| {
        try commands.append(token);
    }
    return Command{ .unknown = .{ .commands = commands } };
}

pub fn runEcho(stdout: anytype, message: []const u8) !void {
    try stdout.print("{s}\n", .{message});
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
        try dir.setAsCwd();
    } else if (std.mem.eql(u8, path, ".")) {
        try std.fs.cwd().setAsCwd();
    } else if (std.mem.eql(u8, path, "..")) {
        const parent_cwd = try std.fs.cwd().realpathAlloc(allocator, "..");
        defer allocator.free(parent_cwd);
        var parent_dir = try std.fs.openDirAbsolute(parent_cwd, .{});
        defer parent_dir.close();
        try parent_dir.setAsCwd();
    } else {
        const resolved_path = std.fs.path.resolve(allocator, &[1][]const u8{path}) catch {
            try stdout.print("{s}: No such file or directory\n", .{path});
            return;
        };
        defer allocator.free(resolved_path);

        if (std.fs.path.isAbsolute(resolved_path)) {
            if (std.fs.openFileAbsolute(resolved_path, .{})) |file| {
                defer file.close();
                try stdout.print("{s}: Not a directory\n", .{path});
                return;
            } else |_| {}

            var dir = try std.fs.openDirAbsolute(resolved_path, .{});
            defer dir.close();
            try dir.setAsCwd();
        } else {
            const abs_path = try std.fs.cwd().realpathAlloc(allocator, resolved_path);
            defer allocator.free(abs_path);

            if (std.fs.openFileAbsolute(abs_path, .{})) |file| {
                defer file.close();
                try stdout.print("{s}: Not a directory\n", .{path});
                return;
            } else |_| {}

            var dir = try std.fs.openDirAbsolute(abs_path, .{});
            defer dir.close();
            try dir.setAsCwd();
        }
    }
}
