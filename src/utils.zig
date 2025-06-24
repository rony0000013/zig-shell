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
        std.fs.accessAbsolute(path, .{}) catch {
            // std.debug.print("Warning: Directory not accessible: {s}: {s}\n", .{ path, @errorName(err) });
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

                if (isExecutable(full_path)) {
                    var name_iter = std.mem.tokenizeScalar(u8, entry.name, '.');
                    if (name_iter.next()) |name| {
                        const lower_name = try std.ascii.allocLowerString(heap, name);

                        const e = map.getOrPut(lower_name) catch {
                            heap.free(lower_name);
                            continue;
                        };
                        if (!e.found_existing) {
                            const full_path_dup = try heap.dupe(u8, full_path);
                            e.value_ptr.* = full_path_dup;
                        } else {
                            heap.free(lower_name);
                        }
                    }
                }
            } else if (entry.kind == .sym_link) {
                const full_path = try std.fs.path.join(heap, &[_][]const u8{ path, entry.name });
                defer heap.free(full_path);

                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_path = std.fs.readLinkAbsolute(full_path, &buffer) catch {
                    // Skip if we can't read the symlink
                    continue;
                };

                if (isExecutable(link_path)) {
                    var name_iter = std.mem.tokenizeScalar(u8, entry.name, '.');
                    if (name_iter.next()) |name| {
                        const lower_name = try std.ascii.allocLowerString(heap, name);
                        const e = map.getOrPut(lower_name) catch {
                            heap.free(lower_name);
                            continue;
                        };

                        if (!e.found_existing) {
                            const full_path_dup = try heap.dupe(u8, full_path);
                            e.value_ptr.* = full_path_dup;
                        } else {
                            heap.free(lower_name);
                        }
                    }
                }
            }
        }
    }

    return map;
}

pub fn isExecutable(path: []const u8) bool {
    if (IS_WINDOWS) {
        const ext = std.fs.path.extension(path);
        return std.ascii.eqlIgnoreCase(ext, ".exe") or
            std.ascii.eqlIgnoreCase(ext, ".bat") or
            std.ascii.eqlIgnoreCase(ext, ".cmd") or
            std.ascii.eqlIgnoreCase(ext, ".ps1");
    } else {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
            std.debug.print("Warning: Error opening file '{s}': {s}\n", .{ path, @errorName(err) });
            return false;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            std.debug.print("Warning: Error getting file stats '{s}': {s}\n", .{ path, @errorName(err) });
            return false;
        };
        return (stat.mode & 0o111) != 0;
    }
}

pub fn freeStringHashMap(map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        map.allocator.free(entry.key_ptr.*);
        map.allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
