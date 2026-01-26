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
};
