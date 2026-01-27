const std = @import("std");
const terminal = @import("terminal.zig");
const Terminal = terminal.Terminal;
const Key = terminal.Key;
const Allocator = std.mem.Allocator;

pub const Action = enum {
    continue_editing,
    submit,
    eof,
};

pub const LineEditor = struct {
    buffer: std.ArrayListUnmanaged(u8),
    cursor: usize,
    term: *Terminal,
    allocator: Allocator,

    pub fn init(allocator: Allocator, term: *Terminal) LineEditor {
        return .{
            .buffer = .empty,
            .cursor = 0,
            .term = term,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn handleKey(self: *LineEditor, key: Key) !Action {
        switch (key) {
            .char => |c| {
                try self.insertChar(c);
            },
            .backspace => {
                self.deleteCharBefore();
            },
            .enter => {
                if (self.term.is_tty) {
                    try self.term.write("\n");
                }
                return .submit;
            },
            .ctrl_d => {
                if (self.buffer.items.len == 0) {
                    return .eof;
                }
                // On non-empty line, Ctrl+D does nothing (or could delete char)
                self.term.bell();
            },
            .ctrl_c => {
                // For now, just bell - Phase 9 will handle exit
                self.term.bell();
            },
            // Milestone 1: Tab, Del, Arrows just send BEL (only in raw mode)
            .tab, .delete, .arrow_up, .arrow_down, .arrow_left, .arrow_right, .home, .end => {
                if (self.term.is_tty) {
                    self.term.bell();
                }
            },
            .unknown => {},
        }
        return .continue_editing;
    }

    fn insertChar(self: *LineEditor, c: u8) !void {
        try self.buffer.append(self.allocator, c);
        self.cursor += 1;
        // Only echo in raw mode (tty handles echo in cooked mode)
        if (self.term.is_tty) {
            try self.term.write(&[_]u8{c});
        }
    }

    fn deleteCharBefore(self: *LineEditor) void {
        if (self.cursor > 0 and self.buffer.items.len > 0) {
            _ = self.buffer.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
            // Only handle visual backspace in raw mode
            if (self.term.is_tty) {
                _ = self.term.write("\x08 \x08") catch {};
            }
        }
    }

    pub fn getLine(self: *LineEditor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *LineEditor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn redraw(self: *LineEditor, prompt: []const u8) void {
        self.term.clearLine();
        self.term.write(prompt) catch {};
        self.term.write(self.buffer.items) catch {};
    }
};
