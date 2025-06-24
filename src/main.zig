const std = @import("std");
const commands = @import("commands.zig");
const utils = @import("utils.zig");

pub fn main() !u8 {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    var paths = try utils.scanPath();
    defer utils.freeStringHashMap(&paths);
    // {
    //     var it = paths.iterator();
    //     while (it.next()) |entry| {
    //         std.debug.print("- {s}\n", .{entry.key_ptr.*});
    //     }
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
                try commands.runType(stdout, type_.cmd, paths);
            },
            .echo => |echo| try commands.runEcho(stdout, echo.message),
            .exit => |exit| return exit.code,
            .unknown => |unknown| {
                // defer utils.freeArrayList(&unknown.commands);
                defer unknown.commands.deinit();

                if (unknown.commands.items.len == 0) {
                    try stdout.print("{s}: command not found\n", .{raw_cmd});
                    continue;
                }
                const first_cmd = unknown.commands.items[0];
                if (paths.get(first_cmd)) |_| {
                    const result = try std.process.Child.run(.{
                        .allocator = unknown.commands.allocator,
                        .argv = unknown.commands.items,
                        .max_output_bytes = 10 * 1024 * 1024, // 10MB max output
                    });
                    try stdout.print("{s}", .{result.stdout});
                    try stderr.print("{s}", .{result.stderr});
                } else {
                    try stdout.print("{s}: command not found\n", .{first_cmd});
                }
            },
        }
    }
    return 0;
}
