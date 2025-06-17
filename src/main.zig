const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    while (true) {
        try stdout.print("$ ", .{});
        const stdin = std.io.getStdIn().reader();
        var buffer: [4096]u8 = undefined;
        const user_input = (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) orelse {
            try stdout.print("\n", .{});
            break;
        };

        const cmd = std.mem.trim(u8, user_input, &std.ascii.whitespace);
        if (cmd.len == 0) continue;
        try stdout.print("{s}: command not found\n", .{cmd});
    }
}
