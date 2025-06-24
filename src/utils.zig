const std = @import("std");
const IS_WINDOWS = std.builtin.subsystem == .Windows;

/// Scans the system PATH for executable files.
/// Returns a map where keys are executable names (lowercase) and values are their full paths.
/// The caller owns the returned map and must call deinit() on it.
pub fn scanPath() !std.StringHashMap([]const u8) {
    const heap = std.heap.page_allocator;
    var map = std.StringHashMap([]const u8).init(heap);

    const path_variable = try std.process.getEnvVarOwned(heap, "PATH");
    defer heap.free(path_variable);

    // std.debug.print("PATH: {s}\n", .{path_variable});

    const separator = if (IS_WINDOWS) ';' else ':';
    var paths_iter = std.mem.tokenizeScalar(u8, path_variable, separator);

    while (paths_iter.next()) |path| {
        std.debug.print("Path: {s}\n", .{path});
        std.fs.accessAbsolute(path, .{}) catch |err| {
            std.debug.print("Warning: Directory not accessible: {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (true) {
            const entry = it.next() catch |err| {
                std.debug.print("Warning: Error reading directory '{s}': {s}\n", .{ path, @errorName(err) });
                continue;
            } orelse break;
            if (entry.kind == .file) {
                const full_path = try std.fs.path.join(heap, &[_][]const u8{ path, entry.name });
                defer heap.free(full_path);

                try addExecutableToMap(&map, entry.name, full_path);
            } else if (entry.kind == .sym_link) {
                const full_path = try std.fs.path.join(heap, &[_][]const u8{ path, entry.name });
                defer heap.free(full_path);

                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_path = std.fs.readLinkAbsolute(full_path, &buffer) catch |err| {
                    std.debug.print(" (failed to read symlink: {s})\n", .{@errorName(err)});
                    continue;
                };
                try addExecutableToMap(&map, entry.name, link_path);
            }
        }
    }

    return map;
}

pub fn addExecutableToMap(map: *std.StringHashMap([]const u8), file_name: []const u8, full_path: []const u8) !void {
    const is_executable = blk: {
        if (IS_WINDOWS) {
            const ext = std.fs.path.extension(file_name);
            break :blk std.ascii.eqlIgnoreCase(ext, ".exe") or
                std.ascii.eqlIgnoreCase(ext, ".bat") or
                std.ascii.eqlIgnoreCase(ext, ".cmd") or
                std.ascii.eqlIgnoreCase(ext, ".ps1");
        } else {
            const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch break :blk false;
            defer file.close();

            const stat = file.stat() catch break :blk false;
            break :blk (stat.mode & 0o111) != 0;
        }
    };

    if (is_executable) {
        var name_iter = std.mem.tokenizeScalar(u8, file_name, '.');
        if (name_iter.next()) |name| {
            const lower_name = try std.ascii.allocLowerString(map.allocator, name);
            errdefer map.allocator.free(lower_name);

            const e = map.getOrPut(lower_name) catch |err| {
                std.debug.print("Warning: Failed to add '{s}': {s}\n", .{ lower_name, @errorName(err) });
                map.allocator.free(lower_name);
                return;
            };
            if (!e.found_existing) {
                e.value_ptr.* = full_path;
            } else {
                map.allocator.free(lower_name);
                return;
            }
        }
    }
    return;
}

pub fn freeStringHashMap(map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        map.allocator.free(entry.key_ptr.*);
        map.allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
