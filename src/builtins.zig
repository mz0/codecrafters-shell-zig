const std = @import("std");
const path = @import("path.zig");
const Allocator = std.mem.Allocator;

pub const Builtins = struct {
    path_resolver: *path.PathResolver,
    allocator: Allocator,

    const builtin_names = [_][]const u8{ "cd", "echo", "exit", "pwd", "type" };

    pub fn init(allocator: Allocator, path_resolver: *path.PathResolver) Builtins {
        return .{
            .path_resolver = path_resolver,
            .allocator = allocator,
        };
    }

    /// Returns exit code if command was a builtin, null if not a builtin.
    /// Returns error.Exit to signal shell should exit.
    pub fn run(self: *Builtins, argv: []const []const u8, stdout: anytype, stderr: anytype) !?u8 {
        if (argv.len == 0) return 0;

        const cmd = argv[0];
        if (std.mem.eql(u8, cmd, "exit")) {
            return self.builtin_exit(argv);
        } else if (std.mem.eql(u8, cmd, "echo")) {
            return self.builtin_echo(argv, stdout);
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            return self.builtin_pwd(stdout);
        } else if (std.mem.eql(u8, cmd, "cd")) {
            return self.builtin_cd(argv, stderr);
        } else if (std.mem.eql(u8, cmd, "type")) {
            return self.builtin_type(argv, stdout, stderr);
        }
        return null; // Not a builtin
    }

    pub fn isBuiltin(name: []const u8) bool {
        for (builtin_names) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn builtin_exit(_: *Builtins, argv: []const []const u8) error{Exit}!?u8 {
        if (argv.len > 1) {
            const code = std.fmt.parseInt(u8, argv[1], 10) catch 1;
            std.process.exit(code);
        }
        return error.Exit;
    }

    fn builtin_echo(_: *Builtins, argv: []const []const u8, stdout: anytype) u8 {
        const args = argv[1..];
        for (args, 0..) |arg, i| {
            if (i > 0) stdout.print(" ", .{}) catch {};
            stdout.print("{s}", .{arg}) catch {};
        }
        stdout.print("\n", .{}) catch {};
        return 0;
    }

    fn builtin_pwd(_: *Builtins, stdout: anytype) u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&buf) catch {
            return 1;
        };
        stdout.print("{s}\n", .{cwd}) catch {};
        return 0;
    }

    fn builtin_cd(_: *Builtins, argv: []const []const u8, stderr: anytype) u8 {
        const target = if (argv.len > 1) argv[1] else std.posix.getenv("HOME") orelse "/";

        // Handle ~ expansion
        const actual_target = if (target.len > 0 and target[0] == '~') blk: {
            const home = std.posix.getenv("HOME") orelse "/";
            if (target.len == 1) {
                break :blk home;
            }
            // ~/ case - would need allocation, skip for now
            break :blk target;
        } else target;

        std.posix.chdir(actual_target) catch |err| {
            const msg = switch (err) {
                error.FileNotFound => "No such file or directory",
                error.NotDir => "Not a directory",
                error.AccessDenied => "Permission denied",
                else => @errorName(err),
            };
            stderr.print("cd: {s}: {s}\n", .{ actual_target, msg }) catch {};
            return 1;
        };
        return 0;
    }

    fn builtin_type(self: *Builtins, argv: []const []const u8, stdout: anytype, stderr: anytype) u8 {
        if (argv.len < 2) {
            return 0;
        }

        const name = argv[1];

        // Check if builtin
        if (isBuiltin(name)) {
            stdout.print("{s} is a shell builtin\n", .{name}) catch {};
            return 0;
        }

        // Check PATH
        if (self.path_resolver.resolve(name)) |full_path| {
            defer self.allocator.free(full_path);
            stdout.print("{s} is {s}\n", .{ name, full_path }) catch {};
            return 0;
        }

        stderr.print("{s}: not found\n", .{name}) catch {};
        return 1;
    }
};
