const std = @import("std");
const posix = std.posix;
const path = @import("path.zig");
const builtins = @import("builtins.zig");
const tokenizer = @import("tokenizer.zig");
const terminal = @import("terminal.zig");
const Allocator = std.mem.Allocator;
const Token = tokenizer.Token;
const TokenKind = tokenizer.TokenKind;
const Terminal = terminal.Terminal;

pub const Command = struct {
    argv: []const []const u8,
    stdout_file: ?[]const u8 = null,
    stdout_append: bool = false,
    stderr_file: ?[]const u8 = null,
    stderr_append: bool = false,
    pipe_next: ?*Command = null,
};

pub const ParseError = error{
    MissingRedirectTarget,
    OutOfMemory,
};

pub const Executor = struct {
    builtins: *builtins.Builtins,
    path_resolver: *path.PathResolver,
    allocator: Allocator,
    term: ?*Terminal,

    pub fn init(allocator: Allocator, b: *builtins.Builtins, pr: *path.PathResolver) Executor {
        return .{
            .builtins = b,
            .path_resolver = pr,
            .allocator = allocator,
            .term = null,
        };
    }

    pub fn setTerminal(self: *Executor, term: *Terminal) void {
        self.term = term;
    }

    /// Parse tokens into a Command struct
    pub fn parseCommand(self: *Executor, tokens: []const Token) ParseError!Command {
        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv_list.deinit(self.allocator);

        var cmd = Command{ .argv = undefined };
        var i: usize = 0;

        while (i < tokens.len) {
            const token = tokens[i];
            switch (token.kind) {
                .word => {
                    try argv_list.append(self.allocator, token.value);
                    i += 1;
                },
                .redirect_out, .redirect_append => {
                    if (i + 1 >= tokens.len or tokens[i + 1].kind != .word) {
                        return error.MissingRedirectTarget;
                    }
                    cmd.stdout_file = tokens[i + 1].value;
                    cmd.stdout_append = (token.kind == .redirect_append);
                    i += 2;
                },
                .redirect_err, .redirect_err_append => {
                    if (i + 1 >= tokens.len or tokens[i + 1].kind != .word) {
                        return error.MissingRedirectTarget;
                    }
                    cmd.stderr_file = tokens[i + 1].value;
                    cmd.stderr_append = (token.kind == .redirect_err_append);
                    i += 2;
                },
                .pipe => {
                    cmd.argv = try argv_list.toOwnedSlice(self.allocator);
                    const remaining_tokens = tokens[i+1..];
                    if (remaining_tokens.len > 0) {
                        const next_cmd_ptr = try self.allocator.create(Command);
                        next_cmd_ptr.* = try self.parseCommand(remaining_tokens);
                        cmd.pipe_next = next_cmd_ptr;
                    }
                    // If no tokens after pipe, we still return the command,
                    // pipe_next will be null (initialized).
                    // We should return error. For now this is fine.
                    return cmd;
                },
            }
        }

        cmd.argv = try argv_list.toOwnedSlice(self.allocator);
        return cmd;
    }

    pub fn freeCommand(self: *Executor, cmd: *Command) void {
        self.allocator.free(cmd.argv);
        if (cmd.pipe_next) |next| {
            self.freeCommand(next);
            self.allocator.destroy(next);
        }
    }

    /// Execute a command. Returns exit code.
    /// Returns error.Exit if shell should exit.
    pub fn execute(self: *Executor, tokens: []const Token, stdout: anytype, stderr: anytype) !u8 {
        var cmd = self.parseCommand(tokens) catch |err| {
            const msg = switch (err) {
                error.MissingRedirectTarget => "syntax error: missing redirect target",
                error.OutOfMemory => "error: out of memory",
            };
            stderr.print("{s}\n", .{msg}) catch {};
            return 1;
        };
        defer self.freeCommand(&cmd);

        return self.executePipeline(&cmd, null, stdout, stderr);
    }

    fn executePipeline(self: *Executor, cmd: *Command, stdin_fd: ?posix.fd_t, stdout: anytype, stderr: anytype) !u8 {
        if (cmd.pipe_next) |next_cmd| {
             const p = try posix.pipe();
             const pid = posix.fork() catch |err| {
                 stderr.print("fork failed: {s}\n", .{@errorName(err)}) catch {};
                 return 1;
             };

             if (pid == 0) {
                 // Child
                 posix.close(p[0]); // Close read end

                 if (stdin_fd) |fd| {
                     posix.dup2(fd, posix.STDIN_FILENO) catch posix.exit(1);
                     posix.close(fd);
                 }

                 // If no explicit redirect, pipe to next command
                 if (cmd.stdout_file == null) {
                     posix.dup2(p[1], posix.STDOUT_FILENO) catch posix.exit(1);
                 }
                 posix.close(p[1]);

                 const code = self.executeSingle(cmd, null, stdout, stderr) catch 1;
                 posix.exit(code);
             }

             // Parent
             posix.close(p[1]); // Close write end
             if (stdin_fd) |fd| posix.close(fd);

             const last_exit = try self.executePipeline(next_cmd, p[0], stdout, stderr);
             _ = posix.waitpid(pid, 0);
             return last_exit;

        } else {
             defer if (stdin_fd) |fd| posix.close(fd);
             return self.executeSingle(cmd, stdin_fd, stdout, stderr);
        }
    }

    fn executeSingle(self: *Executor, cmd: *Command, stdin_fd: ?posix.fd_t, stdout: anytype, stderr: anytype) !u8 {
        if (cmd.argv.len == 0) return 0;

        // Try builtin first (builtins respect redirects too)
        if (cmd.stdout_file == null and cmd.stderr_file == null) {
            if (try self.builtins.run(cmd.argv, stdout, stderr)) |code| {
                return code;
            }
        } else {
            // Handle builtin with redirects
            if (try self.executeBuiltinWithRedirects(cmd, stdout, stderr)) |code| {
                return code;
            }
        }

        // External command
        return self.executeExternal(cmd, stdin_fd, stderr);
    }

    fn executeBuiltinWithRedirects(self: *Executor, cmd: *Command, fallback_stdout: anytype, fallback_stderr: anytype) !?u8 {
        // Check if it's a builtin
        if (!builtins.Builtins.isBuiltin(cmd.argv[0])) {
            return null;
        }

        // Open redirect files
        var stdout_file: ?std.fs.File = null;
        var stderr_file: ?std.fs.File = null;
        defer if (stdout_file) |f| f.close();
        defer if (stderr_file) |f| f.close();

        if (cmd.stdout_file) |filename| {
            stdout_file = openRedirectFile(filename, cmd.stdout_append) catch |err| {
                const msg = errorMessage(err);
                fallback_stderr.print("{s}: {s}\n", .{ filename, msg }) catch {};
                return 1;
            };
        }

        if (cmd.stderr_file) |filename| {
            stderr_file = openRedirectFile(filename, cmd.stderr_append) catch |err| {
                const msg = errorMessage(err);
                fallback_stderr.print("{s}: {s}\n", .{ filename, msg }) catch {};
                return 1;
            };
        }

        // Create writers for redirect targets
        var stdout_buf: [4096]u8 = undefined;
        var stderr_buf: [4096]u8 = undefined;

        if (stdout_file) |f| {
            var w = f.writer(&stdout_buf);
            const stdout_writer = &w.interface;
            if (stderr_file) |f2| {
                var w2 = f2.writer(&stderr_buf);
                const stderr_writer = &w2.interface;
                const result = try self.builtins.run(cmd.argv, stdout_writer, stderr_writer);
                stdout_writer.flush() catch {};
                stderr_writer.flush() catch {};
                return result;
            } else {
                const result = try self.builtins.run(cmd.argv, stdout_writer, fallback_stderr);
                stdout_writer.flush() catch {};
                return result;
            }
        } else if (stderr_file) |f2| {
            var w2 = f2.writer(&stderr_buf);
            const stderr_writer = &w2.interface;
            const result = try self.builtins.run(cmd.argv, fallback_stdout, stderr_writer);
            stderr_writer.flush() catch {};
            return result;
        }

        return null;
    }

    fn executeExternal(self: *Executor, cmd: *Command, stdin_fd: ?posix.fd_t, stderr: anytype) u8 {
        const argv = cmd.argv;
        const cmd_name = argv[0];

        // Resolve command path
        const exe_path = self.path_resolver.resolve(cmd_name) orelse {
            stderr.print("{s}: command not found\n", .{cmd_name}) catch {};
            return 127;
        };
        defer self.allocator.free(exe_path);

        // Open redirect files before fork
        var stdout_fd: ?posix.fd_t = null;
        var stderr_fd: ?posix.fd_t = null;
        defer if (stdout_fd) |fd| posix.close(fd);
        defer if (stderr_fd) |fd| posix.close(fd);

        if (cmd.stdout_file) |filename| {
            stdout_fd = openRedirectFd(filename, cmd.stdout_append) catch |err| {
                const msg = errorMessage(err);
                stderr.print("{s}: {s}\n", .{ filename, msg }) catch {};
                return 1;
            };
        }

        if (cmd.stderr_file) |filename| {
            stderr_fd = openRedirectFd(filename, cmd.stderr_append) catch |err| {
                const msg = errorMessage(err);
                stderr.print("{s}: {s}\n", .{ filename, msg }) catch {};
                return 1;
            };
        }

        // Build null-terminated argv for execve
        var argv_buf: [256:null]?[*:0]const u8 = undefined;
        var i: usize = 0;

        // First arg is the original command name
        const cmd_name_z = self.allocator.dupeZ(u8, cmd_name) catch return 1;
        defer self.allocator.free(cmd_name_z);
        argv_buf[i] = cmd_name_z;
        i += 1;

        // Rest of args
        var arg_copies: [256][:0]u8 = undefined;
        var arg_count: usize = 0;
        for (argv[1..]) |arg| {
            if (i >= argv_buf.len - 1) break;
            arg_copies[arg_count] = self.allocator.dupeZ(u8, arg) catch return 1;
            argv_buf[i] = arg_copies[arg_count];
            arg_count += 1;
            i += 1;
        }
        argv_buf[i] = null;
        defer for (arg_copies[0..arg_count]) |arg| self.allocator.free(arg);

        // Get exe path as null-terminated
        const exe_path_z = self.allocator.dupeZ(u8, exe_path) catch return 1;
        defer self.allocator.free(exe_path_z);

        // Restore cooked mode before fork so child gets proper terminal
        if (self.term) |t| t.restoreCooked();

        // Fork
        const pid = posix.fork() catch |err| {
            if (self.term) |t| t.enterRaw();
            stderr.print("{s}: fork failed: {s}\n", .{ cmd_name, @errorName(err) }) catch {};
            return 126;
        };

        if (pid == 0) {
            // Child process
            if (stdin_fd) |fd| {
                posix.dup2(fd, posix.STDIN_FILENO) catch posix.exit(126);
            }
            if (stdout_fd) |fd| {
                posix.dup2(fd, posix.STDOUT_FILENO) catch posix.exit(126);
            }
            if (stderr_fd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch posix.exit(126);
            }

            // Execute - use execvpe to let it handle PATH and env
            // execvpeZ only returns on error (success is noreturn)
            switch (posix.execvpeZ(exe_path_z, &argv_buf, @ptrCast(std.os.environ.ptr))) {
                else => posix.exit(126),
            }
        }

        // Parent: wait for child
        const result = posix.waitpid(pid, 0);

        // Re-enter raw mode after child exits
        if (self.term) |t| t.enterRaw();

        if (posix.W.IFEXITED(result.status)) {
            return posix.W.EXITSTATUS(result.status);
        } else if (posix.W.IFSIGNALED(result.status)) {
            return 128 + @as(u8, @intCast(posix.W.TERMSIG(result.status)));
        }
        return 1;
    }
};

fn openRedirectFile(filename: []const u8, append: bool) !std.fs.File {
    if (append) {
        // Open with O_APPEND for append mode
        const fd = posix.openat(
            posix.AT.FDCWD,
            filename,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        ) catch |err| return err;
        return std.fs.File{ .handle = fd };
    } else {
        return std.fs.cwd().createFile(filename, .{});
    }
}

fn openRedirectFd(filename: []const u8, append: bool) !posix.fd_t {
    const file = try openRedirectFile(filename, append);
    if (append) {
        file.seekFromEnd(0) catch {};
    }
    return file.handle;
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.AccessDenied => "Permission denied",
        error.NoSpaceLeft => "No space left on device",
        else => @errorName(err),
    };
}
