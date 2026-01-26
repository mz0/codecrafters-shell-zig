const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;
var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    while (true) {
        try stdout.print("$ ", .{});
        if (try stdin.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            try stdout.print("{s}: command not found\n", .{trimmed});
        } else {
            break; // ^D - EOF reached - Exit
        }
    }
}
