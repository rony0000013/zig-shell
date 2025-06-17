const std = @import("std");
const commands = @import("commands.zig");
const utils = @import("utils.zig");

pub fn main() !u8 {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    // var paths = try utils.scanPath();
    // defer utils.freeStringHashMap(&paths);
    // var it = paths.iterator();
    // while (it.next()) |entry| {
    //     std.debug.print("- {s}\n", .{entry.key_ptr.*});
    // }
    while (true) {
        try stdout.print("$ ", .{});
        var buffer: [4096]u8 = undefined;
        const user_input = (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) orelse {
            try stdout.print("\n", .{});
            break;
        };

        const raw_cmd = std.mem.trim(u8, user_input, &std.ascii.whitespace);

        const cmd = commands.parseCommand(raw_cmd) catch |err| {
            try stderr.print("Parse error: {s}\n", .{@errorName(err)});
            try stdout.print("{s}: command not found\n", .{raw_cmd});
            continue;
        };

        switch (cmd) {
            .type => |type_| {
                defer type_.allocator.free(type_.cmd);
                try commands.runType(stdout, type_.cmd);
            },
            .echo => |echo| try commands.runEcho(stdout, echo.message),
            .exit => |exit| return exit.code,
            .unknown => try stdout.print("{s}: command not found\n", .{raw_cmd}),
        }
    }
    return 0;
}
