const std = @import("std");

pub const Command = union(enum) {
    echo: struct {
        message: []const u8,
    },
    exit: struct {
        code: u8,
    },
    unknown: void,
};

const CommandType = enum {
    exit,
    echo,
};

pub fn parseCommand(input: []const u8) !Command {
    var command = std.mem.splitScalar(u8, input, ' ');
    const first_token_raw = command.next() orelse return Command{ .unknown = {} };

    var lower_buf: [1024]u8 = undefined;
    const first_token = std.ascii.lowerString(&lower_buf, first_token_raw);

    if (std.meta.stringToEnum(CommandType, first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => blk: {
                const code = try std.fmt.parseInt(u8, command.next() orelse "0", 10);
                break :blk Command{ .exit = .{ .code = code } };
            },
            .echo => Command{ .echo = .{ .message = command.rest() } },
        };
    }
    return Command{ .unknown = {} };
}

pub fn runEcho(stdout: anytype, message: []const u8) !void {
    try stdout.print("{s}\n", .{message});
}
