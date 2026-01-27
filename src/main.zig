const std = @import("std");
const path = @import("path.zig");
const builtins = @import("builtins.zig");
const executor = @import("executor.zig");
const tokenizer = @import("tokenizer.zig");
const terminal = @import("terminal.zig");
const line_editor = @import("line_editor.zig");

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

    // Initialize terminal (raw mode if tty, cooked mode otherwise)
    var term = terminal.Terminal.init();
    defer term.deinit();

    // Initialize line editor
    var editor = line_editor.LineEditor.init(allocator, &term);
    defer editor.deinit();

    // I/O setup for command output (not for line reading)
    // Using writerStreaming for automatic flush behavior
    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
    var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Main REPL loop
    while (true) {
        // Print prompt
        term.write("$ ") catch {};

        // Read line using line editor
        editor.clear();
        const line = readLine(&editor, &term) catch |err| {
            if (err == error.EOF) break;
            continue;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Tokenize input
        var t = tokenizer.Tokenizer.init(trimmed, allocator);
        defer t.deinit();

        const tokens = t.tokenize() catch |err| {
            const msg = switch (err) {
                error.UnterminatedSingleQuote => "syntax error: unterminated single quote",
                error.UnterminatedDoubleQuote => "syntax error: unterminated double quote",
                error.OutOfMemory => "error: out of memory",
            };
            stderr.print("{s}\n", .{msg}) catch {};
            stderr.flush() catch {};
            continue;
        };

        if (tokens.len == 0) continue;

        // Execute
        _ = exec.execute(tokens, stdout, stderr) catch |err| switch (err) {
            error.Exit => break,
            else => return err,
        };

    }
}

fn readLine(editor: *line_editor.LineEditor, term: *terminal.Terminal) ![]const u8 {
    while (true) {
        const key = try term.readKey();
        const action = try editor.handleKey(key);

        switch (action) {
            .continue_editing => continue,
            .submit => return editor.getLine(),
            .eof => return error.EOF,
        }
    }
}
