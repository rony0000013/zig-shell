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
    unknown: struct {
        commands: std.ArrayList([]const u8),
    },
};

const CommandType = enum {
    exit,
    echo,
    type,
    pwd,
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
