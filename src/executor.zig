const std = @import("std");
const path = @import("path.zig");
const builtins = @import("builtins.zig");
const Allocator = std.mem.Allocator;

pub const Executor = struct {
    builtins: *builtins.Builtins,
    path_resolver: *path.PathResolver,
    allocator: Allocator,

    pub fn init(allocator: Allocator, b: *builtins.Builtins, pr: *path.PathResolver) Executor {
        return .{
            .builtins = b,
            .path_resolver = pr,
            .allocator = allocator,
        };
    }

    /// Execute a command. Returns exit code.
    /// Returns error.Exit if shell should exit.
    pub fn execute(self: *Executor, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
        if (argv.len == 0) return 0;

        // Try builtin first
        if (try self.builtins.run(argv, stdout, stderr)) |code| {
            return code;
        }

        // External command
        return self.executeExternal(argv, stderr);
    }

    fn executeExternal(self: *Executor, argv: []const []const u8, stderr: anytype) u8 {
        const cmd = argv[0];

        // Resolve command path
        const exe_path = self.path_resolver.resolve(cmd) orelse {
            stderr.print("{s}: command not found\n", .{cmd}) catch {};
            return 127;
        };
        defer self.allocator.free(exe_path);

        // Build argv with original command name (not resolved path)
        var child_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer child_argv.deinit(self.allocator);
        child_argv.append(self.allocator, cmd) catch return 1;
        for (argv[1..]) |arg| {
            child_argv.append(self.allocator, arg) catch return 1;
        }

        // Spawn child process
        var child = std.process.Child.init(child_argv.items, self.allocator);
        child.spawn() catch |err| {
            stderr.print("{s}: {s}\n", .{ cmd, @errorName(err) }) catch {};
            return 126;
        };

        // Wait for completion
        const term = child.wait() catch |err| {
            stderr.print("{s}: wait failed: {s}\n", .{ cmd, @errorName(err) }) catch {};
            return 1;
        };

        return switch (term) {
            .Exited => |code| code,
            .Signal => |sig| 128 + @as(u8, @intCast(sig)),
            .Stopped => |_| 1,
            .Unknown => |_| 1,
        };
    }
};
