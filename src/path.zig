const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PathResolver = struct {
    dirs: []const []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !PathResolver {
        const path_env = std.posix.getenv("PATH") orelse "";
        var dirs: std.ArrayListUnmanaged([]const u8) = .empty;

        var iter = std.mem.splitScalar(u8, path_env, ':');
        while (iter.next()) |dir| {
            if (dir.len > 0) {
                try dirs.append(allocator, dir);
            }
        }

        return .{
            .dirs = try dirs.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PathResolver) void {
        self.allocator.free(self.dirs);
    }

    /// Returns the full path to the executable if found, null otherwise.
    /// Caller must free the returned slice.
    pub fn resolve(self: *PathResolver, command: []const u8) ?[]const u8 {
        // If command contains '/', treat as path directly
        if (std.mem.indexOfScalar(u8, command, '/') != null) {
            if (self.isExecutable(command)) {
                return self.allocator.dupe(u8, command) catch null;
            }
            return null;
        }

        // Search PATH directories
        for (self.dirs) |dir| {
            const full_path = std.fs.path.join(self.allocator, &.{ dir, command }) catch continue;
            if (self.isExecutable(full_path)) {
                return full_path;
            }
            self.allocator.free(full_path);
        }
        return null;
    }

    fn isExecutable(self: *PathResolver, path: []const u8) bool {
        _ = self;
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        defer file.close();
        const stat = file.stat() catch return false;
        // Check if it's a regular file and has execute permission
        return stat.kind == .file and (stat.mode & std.posix.S.IXUSR != 0);
    }

    /// Get command completions for a prefix. Caller owns returned slice and its contents.
    pub fn getCompletions(self: *PathResolver, prefix: []const u8) ![][]const u8 {
        var results: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (results.items) |item| self.allocator.free(item);
            results.deinit(self.allocator);
        }

        // Track seen names to avoid duplicates
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Search PATH directories
        for (self.dirs) |dir| {
            var dir_handle = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch continue;
            defer dir_handle.close();

            var iter = dir_handle.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
                if (seen.contains(entry.name)) continue;

                // Check if executable
                const full_path = std.fs.path.join(self.allocator, &.{ dir, entry.name }) catch continue;
                defer self.allocator.free(full_path);

                if (!self.isExecutable(full_path)) continue;

                // Add to results
                const name_copy = try self.allocator.dupe(u8, entry.name);
                try results.append(self.allocator, name_copy);
                try seen.put(name_copy, {});
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn freeCompletions(self: *PathResolver, completions: [][]const u8) void {
        for (completions) |c| self.allocator.free(c);
        self.allocator.free(completions);
    }
};
