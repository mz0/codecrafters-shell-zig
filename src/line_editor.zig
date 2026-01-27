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

    pub fn init(allocator: Allocator, term: *Terminal, path_resolver: *PathResolver) LineEditor {
        return .{
            .buffer = .empty,
            .cursor = 0,
            .term = term,
            .path_resolver = path_resolver,
            .allocator = allocator,
            .last_key_was_tab = false,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit(self.allocator);
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
            // Del, Arrows still just send BEL for now
            .delete, .arrow_up, .arrow_down, .arrow_left, .arrow_right, .home, .end => {
                if (self.term.is_tty) {
                    self.term.bell();
                }
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
            if (second_tab) {
                // Second TAB - complete to longest common prefix
                const lcp = longestCommonPrefix(completions.items);
                if (lcp.len > prefix.len) {
                    // There's more to complete
                    const suffix = lcp[prefix.len..];
                    for (suffix) |c| {
                        try self.insertChar(c);
                    }
                } else {
                    // No more common prefix, just bell
                    self.term.bell();
                }
            } else {
                // First TAB - just bell
                self.term.bell();
            }
        }
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
        try self.buffer.append(self.allocator, c);
        self.cursor += 1;
        if (self.term.is_tty) {
            try self.term.write(&[_]u8{c});
        }
    }

    fn deleteCharBefore(self: *LineEditor) void {
        if (self.cursor > 0 and self.buffer.items.len > 0) {
            _ = self.buffer.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
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
        self.last_key_was_tab = false;
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
