const std = @import("std");
const terminal = @import("terminal.zig");
const path_mod = @import("path.zig");
const builtins_mod = @import("builtins.zig");
const Terminal = terminal.Terminal;
const Key = terminal.Key;
const PathResolver = path_mod.PathResolver;
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
    path_resolver: *PathResolver,
    allocator: Allocator,
    last_key_was_tab: bool,
    // History support
    history: std.ArrayListUnmanaged([]const u8),
    history_index: ?usize, // null = editing new line, 0 = most recent, etc.
    saved_line: std.ArrayListUnmanaged(u8), // saves current input when navigating history

    pub fn init(allocator: Allocator, term: *Terminal, path_resolver: *PathResolver) LineEditor {
        return .{
            .buffer = .empty,
            .cursor = 0,
            .term = term,
            .path_resolver = path_resolver,
            .allocator = allocator,
            .last_key_was_tab = false,
            .history = .empty,
            .history_index = null,
            .saved_line = .empty,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |line| {
            self.allocator.free(line);
        }
        self.history.deinit(self.allocator);
        self.saved_line.deinit(self.allocator);
    }

    pub fn handleKey(self: *LineEditor, key: Key) !Action {
        const is_tab = (key == .tab);
        defer self.last_key_was_tab = is_tab;

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
                self.term.bell();
            },
            .ctrl_c => {
                self.term.bell();
            },
            .tab => {
                if (self.term.is_tty) {
                    try self.handleTab(self.last_key_was_tab);
                }
            },
            .arrow_up => {
                if (self.term.is_tty) {
                    self.historyUp();
                }
            },
            .arrow_down => {
                if (self.term.is_tty) {
                    self.historyDown();
                }
            },
            .arrow_left => {
                if (self.term.is_tty) {
                    self.moveCursorLeft();
                }
            },
            .arrow_right => {
                if (self.term.is_tty) {
                    self.moveCursorRight();
                }
            },
            .home => {
                if (self.term.is_tty) {
                    self.moveCursorToStart();
                }
            },
            .end => {
                if (self.term.is_tty) {
                    self.moveCursorToEnd();
                }
            },
            .delete => {
                self.deleteCharAt();
            },
            .unknown => {},
        }
        return .continue_editing;
    }

    fn handleTab(self: *LineEditor, second_tab: bool) !void {
        // Only complete if we're at the first word (command position)
        const line = self.buffer.items;

        // Find the word being completed (from start to cursor)
        const prefix = self.getWordAtCursor();
        if (prefix.len == 0) {
            self.term.bell();
            return;
        }

        // Check if we're completing the first word (command)
        // For now, only complete commands (first word)
        const space_before = std.mem.lastIndexOfScalar(u8, line[0..self.cursor], ' ');
        if (space_before != null) {
            // Not at command position, bell for now
            self.term.bell();
            return;
        }

        // Get completions
        var completions: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (completions.items) |c| self.allocator.free(c);
            completions.deinit(self.allocator);
        }

        // Add matching builtins
        for (builtins_mod.Builtins.builtin_names) |name| {
            if (std.mem.startsWith(u8, name, prefix)) {
                const copy = try self.allocator.dupe(u8, name);
                try completions.append(self.allocator, copy);
            }
        }

        // Add matching executables from PATH
        const path_completions = try self.path_resolver.getCompletions(prefix);
        defer self.path_resolver.freeCompletions(path_completions);

        for (path_completions) |name| {
            // Check if already in completions (builtin with same name)
            var found = false;
            for (completions.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const copy = try self.allocator.dupe(u8, name);
                try completions.append(self.allocator, copy);
            }
        }

        if (completions.items.len == 0) {
            self.term.bell();
            return;
        }

        if (completions.items.len == 1) {
            // Single match - complete it
            const match = completions.items[0];
            try self.completeWith(match, prefix.len);
        } else {
            // Multiple matches
            const lcp = longestCommonPrefix(completions.items);
            if (lcp.len > prefix.len) {
                const suffix = lcp[prefix.len..];
                for (suffix) |c| {
                    try self.insertChar(c);
                }
            }
            if (second_tab) {
                // Second TAB - display all candidates and complete to longest common prefix
                try self.displayCandidates(completions.items);

                // Also complete to longest common prefix if possible
            } else {
                // First TAB - just bell
                self.term.bell();
            }
        }
    }

    fn displayCandidates(self: *LineEditor, candidates: []const []const u8) !void {
        // Copy to mutable slice for sorting
        const sorted = try self.allocator.alloc([]const u8, candidates.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, candidates);

        // Sort alphabetically
        std.sort.insertion([]const u8, sorted, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Print newline, then candidates, then redraw prompt+buffer
        try self.term.write("\n");

        for (sorted) |c| {
            try self.term.write(c);
            try self.term.write("  ");
        }
        try self.term.write("\n");

        // Redraw prompt and current buffer
        try self.term.write("$ ");
        try self.term.write(self.buffer.items);
    }

    fn completeWith(self: *LineEditor, match: []const u8, prefix_len: usize) !void {
        const suffix = match[prefix_len..];
        for (suffix) |c| {
            try self.insertChar(c);
        }
        // Add trailing space
        try self.insertChar(' ');
    }

    fn getWordAtCursor(self: *LineEditor) []const u8 {
        if (self.cursor == 0) return "";

        // Find start of current word
        var start: usize = self.cursor;
        while (start > 0 and self.buffer.items[start - 1] != ' ') {
            start -= 1;
        }

        return self.buffer.items[start..self.cursor];
    }

    fn insertChar(self: *LineEditor, c: u8) !void {
        if (self.cursor == self.buffer.items.len) {
            // Append at end (common case)
            try self.buffer.append(self.allocator, c);
            self.cursor += 1;
            if (self.term.is_tty) {
                try self.term.write(&[_]u8{c});
            }
        } else {
            // Insert in middle
            try self.buffer.insert(self.allocator, self.cursor, c);
            self.cursor += 1;
            if (self.term.is_tty) {
                // Write char and rest of line
                try self.term.write(self.buffer.items[self.cursor - 1 ..]);
                // Move cursor back to correct position
                const chars_after = self.buffer.items.len - self.cursor;
                if (chars_after > 0) {
                    self.term.moveCursorLeft(chars_after);
                }
            }
        }
    }

    fn deleteCharBefore(self: *LineEditor) void {
        if (self.cursor > 0 and self.buffer.items.len > 0) {
            _ = self.buffer.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
            if (self.term.is_tty) {
                // Move cursor back, redraw rest of line, clear trailing char
                self.term.write("\x08") catch {};
                self.term.write(self.buffer.items[self.cursor..]) catch {};
                self.term.write(" \x08") catch {};
                // Move cursor back to correct position
                const chars_after = self.buffer.items.len - self.cursor;
                if (chars_after > 0) {
                    self.term.moveCursorLeft(chars_after);
                }
            }
        }
    }

    fn deleteCharAt(self: *LineEditor) void {
        if (self.cursor < self.buffer.items.len) {
            _ = self.buffer.orderedRemove(self.cursor);
            if (self.term.is_tty) {
                // Redraw rest of line and clear trailing char
                self.term.write(self.buffer.items[self.cursor..]) catch {};
                self.term.write(" \x08") catch {};
                const chars_after = self.buffer.items.len - self.cursor;
                if (chars_after > 0) {
                    self.term.moveCursorLeft(chars_after);
                }
            }
        }
    }

    fn moveCursorLeft(self: *LineEditor) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            self.term.moveCursorLeft(1);
        }
    }

    fn moveCursorRight(self: *LineEditor) void {
        if (self.cursor < self.buffer.items.len) {
            self.cursor += 1;
            self.term.moveCursorRight(1);
        }
    }

    fn moveCursorToStart(self: *LineEditor) void {
        if (self.cursor > 0) {
            self.term.moveCursorLeft(self.cursor);
            self.cursor = 0;
        }
    }

    fn moveCursorToEnd(self: *LineEditor) void {
        if (self.cursor < self.buffer.items.len) {
            self.term.moveCursorRight(self.buffer.items.len - self.cursor);
            self.cursor = self.buffer.items.len;
        }
    }

    fn historyUp(self: *LineEditor) void {
        if (self.history.items.len == 0) {
            self.term.bell();
            return;
        }

        if (self.history_index == null) {
            // Save current line before navigating
            self.saved_line.clearRetainingCapacity();
            self.saved_line.appendSlice(self.allocator, self.buffer.items) catch return;
            self.history_index = 0;
        } else if (self.history_index.? + 1 < self.history.items.len) {
            self.history_index = self.history_index.? + 1;
        } else {
            self.term.bell();
            return;
        }

        self.replaceLineWith(self.history.items[self.history.items.len - 1 - self.history_index.?]);
    }

    fn historyDown(self: *LineEditor) void {
        if (self.history_index == null) {
            self.term.bell();
            return;
        }

        if (self.history_index.? > 0) {
            self.history_index = self.history_index.? - 1;
            self.replaceLineWith(self.history.items[self.history.items.len - 1 - self.history_index.?]);
        } else {
            // Back to the saved line
            self.history_index = null;
            self.replaceLineWith(self.saved_line.items);
        }
    }

    fn replaceLineWith(self: *LineEditor, new_line: []const u8) void {
        // Clear current line display
        if (self.cursor > 0) {
            self.term.moveCursorLeft(self.cursor);
        }
        // Clear from cursor to end
        self.term.write("\x1b[K") catch {};

        // Replace buffer
        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.allocator, new_line) catch return;
        self.cursor = self.buffer.items.len;

        // Display new line
        self.term.write(self.buffer.items) catch {};
    }

    pub fn getLine(self: *LineEditor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *LineEditor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.last_key_was_tab = false;
        self.history_index = null;
        self.saved_line.clearRetainingCapacity();
    }

    /// Add a command to history (call after successful command execution)
    pub fn addToHistory(self: *LineEditor, line: []const u8) !void {
        // Don't add empty lines or duplicates of last entry
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) return;
        }

        const copy = try self.allocator.dupe(u8, trimmed);
        try self.history.append(self.allocator, copy);
    }

    pub fn getHistory(self: *LineEditor) []const []const u8 {
        return self.history.items;
    }

    /// Load history from file (typically HISTFILE)
    pub fn loadHistoryFile(self: *LineEditor, filepath: []const u8) !void {
        const file = std.fs.openFileAbsolute(filepath, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // No history file yet, that's OK
            else => return err,
        };
        defer file.close();

        // Read file content
        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        // Split by lines
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) {
                const copy = try self.allocator.dupe(u8, line);
                try self.history.append(self.allocator, copy);
            }
        }
    }

    /// Save history to file (typically HISTFILE)
    pub fn saveHistoryFile(self: *LineEditor, filepath: []const u8) !void {
        const file = try std.fs.createFileAbsolute(filepath, .{});
        defer file.close();

        for (self.history.items) |line| {
            _ = try file.write(line);
            _ = try file.write("\n");
        }
    }

    /// Append a single line to history file (for -a flag)
    pub fn appendToHistoryFile(_: *LineEditor, filepath: []const u8, line: []const u8) !void {
        const file = std.fs.openFileAbsolute(filepath, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(filepath, .{}),
            else => return err,
        };
        defer file.close();

        try file.seekFromEnd(0);
        _ = try file.write(line);
        _ = try file.write("\n");
    }

    pub fn redraw(self: *LineEditor, prompt: []const u8) void {
        self.term.clearLine();
        self.term.write(prompt) catch {};
        self.term.write(self.buffer.items) catch {};
    }
};

fn longestCommonPrefix(strings: []const []const u8) []const u8 {
    if (strings.len == 0) return "";
    if (strings.len == 1) return strings[0];

    const first = strings[0];
    var prefix_len: usize = first.len;

    for (strings[1..]) |s| {
        var i: usize = 0;
        while (i < prefix_len and i < s.len and first[i] == s[i]) {
            i += 1;
        }
        prefix_len = i;
        if (prefix_len == 0) break;
    }

    return first[0..prefix_len];
}
