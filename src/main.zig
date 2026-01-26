const std = @import("std");
const path = @import("path.zig");
const builtins = @import("builtins.zig");
const executor = @import("executor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize PATH resolver
    var path_resolver = try path.PathResolver.init(allocator);
    defer path_resolver.deinit();

    // Initialize builtins
    var b = builtins.Builtins.init(allocator, &path_resolver);

    // Initialize executor
    var exec = executor.Executor.init(allocator, &b, &path_resolver);

    // I/O setup
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdin_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    const stdin = &stdin_reader.interface;

    // Main REPL loop
    while (true) {
        try stdout.print("$ ", .{});
        try stdout.flush();

        // Read line
        const line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stderr.print("error: line too long\n", .{});
                try stderr.flush();
                continue;
            },
            else => return err,
        } orelse break; // EOF

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Parse into argv (simple whitespace split for now)
        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        var iter = std.mem.splitAny(u8, trimmed, " \t");
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try argv_list.append(allocator, arg);
            }
        }

        if (argv_list.items.len == 0) continue;

        // Execute
        _ = exec.execute(argv_list.items, stdout, stderr) catch |err| switch (err) {
            error.Exit => break,
            else => return err,
        };

        try stdout.flush();
        try stderr.flush();
    }
}
