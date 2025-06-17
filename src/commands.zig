const std = @import("std");

pub const Command = union(enum) {
    type: struct {
        valid: bool,
        cmd: []const u8,
    },
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
    type,
};

pub fn parseCommand(input: []const u8) !Command {
    var command = std.mem.splitScalar(u8, input, ' ');
    const first_token_raw = command.next() orelse return Command{ .unknown = {} };

    var lower_buf: [1024]u8 = undefined;
    const first_token = std.ascii.lowerString(&lower_buf, first_token_raw);

    if (std.meta.stringToEnum(CommandType, first_token)) |cmd_type| {
        return switch (cmd_type) {
            .exit => {
                const code = try std.fmt.parseInt(u8, command.next() orelse "0", 10);
                return Command{ .exit = .{ .code = code } };
            },
            .echo => Command{ .echo = .{ .message = command.rest() } },
            .type => {
                const raw_cmd = command.next() orelse return Command{ .unknown = {} };
                lower_buf = undefined;
                const cleaned_cmd = std.mem.trim(u8, raw_cmd, &std.ascii.whitespace);
                const lower_cmd = std.ascii.lowerString(&lower_buf, cleaned_cmd);
                const valid = std.meta.stringToEnum(CommandType, lower_cmd) != null;
                return Command{ .type = .{ .valid = valid, .cmd = lower_cmd } };
            },
        };
    }
    return Command{ .unknown = {} };
}

pub fn runEcho(stdout: anytype, message: []const u8) !void {
    try stdout.print("{s}\n", .{message});
}

pub fn runType(stdout: anytype, valid: bool, cmd: []const u8) !void {
    if (valid) {
        try stdout.print("{s} is a shell builtin\n", .{cmd});
    } else {
        try stdout.print("{s}: not found\n", .{cmd});
    }
}
