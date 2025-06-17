const std = @import("std");

/// Scans the system PATH for executable files.
/// Returns a map where keys are executable names (lowercase) and values are their full paths.
/// The caller owns the returned map and must call deinit() on it.
pub fn scanPath() !std.StringHashMap([]const u8) {
    const heap = std.heap.page_allocator;
    var map = std.StringHashMap([]const u8).init(heap);

    const path_variable = try std.process.getEnvVarOwned(heap, "PATH");
    defer heap.free(path_variable);

    const is_windows = std.builtin.subsystem == .Windows;
    const separator = if (is_windows) ';' else ':';
    var paths_iter = std.mem.tokenizeScalar(u8, path_variable, separator);

    while (paths_iter.next()) |path| {
        std.fs.accessAbsolute(path, .{}) catch {
            // std.debug.print("Warning: Directory not accessible: {s}: {s}\n", .{ p, @errorName(err) });
            continue;
        };

        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (true) {
            const entry = it.next() catch {
                // std.debug.print("Warning: Error reading directory '{s}': {s}\n", .{ p, @errorName(err) });
                continue;
            } orelse break;
            if (entry.kind == .file) {
                const is_executable = blk: {
                    if (is_windows) {
                        const ext = std.fs.path.extension(entry.name);
                        break :blk std.ascii.eqlIgnoreCase(ext, ".exe") or
                            std.ascii.eqlIgnoreCase(ext, ".bat") or
                            std.ascii.eqlIgnoreCase(ext, ".cmd") or
                            std.ascii.eqlIgnoreCase(ext, ".ps1");
                    } else {
                        const full_path = try std.fs.path.join(heap, &[_][]const u8{ path, entry.name });
                        defer heap.free(full_path);

                        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch break :blk false;
                        defer file.close();

                        const stat = file.stat() catch break :blk false;
                        break :blk (stat.mode & 0o111) != 0;
                    }
                };

                if (is_executable) {
                    var name_iter = std.mem.tokenizeScalar(u8, entry.name, '.');
                    if (name_iter.next()) |name| {
                        const full_path = try std.fs.path.join(heap, &[_][]const u8{ path, entry.name });
                        errdefer heap.free(full_path);

                        const lower_name = try std.ascii.allocLowerString(heap, name);
                        errdefer heap.free(lower_name);

                        map.putNoClobber(lower_name, full_path) catch {};
                    }
                }
            }
        }
    }

    return map;
}

pub fn freeStringHashMap(map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        map.allocator.free(entry.key_ptr.*);
        map.allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
