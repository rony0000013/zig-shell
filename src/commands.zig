const std = @import("std");

pub const Command = union(enum) { exit: struct {
    code: i32,
}, unknown: void };

pub fn parseCommand(input: []const u8) !Command {
    var command = std.mem.splitScalar(u8, input, ' ');
    const first_token = command.next() orelse {
        return Command{ .unknown = {} };
    };

    var lower_buf: [1024]u8 = undefined;
    const lower_first_token = std.ascii.lowerString(&lower_buf, first_token);
    if (std.mem.eql(u8, lower_first_token, "exit")) {
        const code = try std.fmt.parseInt(i32, command.next() orelse "", 10);
        return Command{ .exit = .{ .code = code } };
    }
    return Command{ .unknown = {} };
}
