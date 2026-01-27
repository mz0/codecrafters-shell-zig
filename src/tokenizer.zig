const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    word,
    pipe, // |
    redirect_out, // > or 1>
    redirect_append, // >> or 1>>
    redirect_err, // 2>
    redirect_err_append, // 2>>
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const TokenizeError = error{
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    OutOfMemory,
};

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,
    tokens: std.ArrayListUnmanaged(Token),
    current_word: std.ArrayListUnmanaged(u8),

    pub fn init(input: []const u8, allocator: Allocator) Tokenizer {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .tokens = .empty,
            .current_word = .empty,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        for (self.tokens.items) |token| {
            if (token.kind == .word) {
                self.allocator.free(token.value);
            }
        }
        self.tokens.deinit(self.allocator);
        self.current_word.deinit(self.allocator);
    }

    pub fn tokenize(self: *Tokenizer) TokenizeError![]Token {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == ' ' or c == '\t') {
                try self.finishWord();
                self.pos += 1;
            } else if (c == '\'') {
                try self.parseSingleQuote();
            } else if (c == '"') {
                try self.parseDoubleQuote();
            } else if (c == '\\') {
                try self.parseEscape();
            } else if (c == '|') {
                try self.finishWord();
                try self.tokens.append(self.allocator, .{ .kind = .pipe, .value = "|" });
                self.pos += 1;
            } else if (c == '>') {
                try self.finishWord();
                try self.parseRedirect(.redirect_out, .redirect_append);
            } else if (c == '2' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                try self.finishWord();
                self.pos += 1; // skip '2'
                try self.parseRedirect(.redirect_err, .redirect_err_append);
            } else if (c == '1' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                try self.finishWord();
                self.pos += 1; // skip '1'
                try self.parseRedirect(.redirect_out, .redirect_append);
            } else {
                try self.current_word.append(self.allocator, c);
                self.pos += 1;
            }
        }

        try self.finishWord();
        return self.tokens.items;
    }

    fn finishWord(self: *Tokenizer) !void {
        if (self.current_word.items.len > 0) {
            const word = try self.allocator.dupe(u8, self.current_word.items);
            try self.tokens.append(self.allocator, .{ .kind = .word, .value = word });
            self.current_word.clearRetainingCapacity();
        }
    }

    fn parseSingleQuote(self: *Tokenizer) !void {
        self.pos += 1; // skip opening quote
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\'') {
                self.pos += 1; // skip closing quote
                return;
            }
            try self.current_word.append(self.allocator, c);
            self.pos += 1;
        }
        return error.UnterminatedSingleQuote;
    }

    fn parseDoubleQuote(self: *Tokenizer) !void {
        self.pos += 1; // skip opening quote
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1; // skip closing quote
                return;
            }
            if (c == '\\' and self.pos + 1 < self.input.len) {
                const next = self.input[self.pos + 1];
                // In double quotes, only these are escaped: $ ` " \ newline
                if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                    if (next != '\n') { // \newline is line continuation, produces nothing
                        try self.current_word.append(self.allocator, next);
                    }
                    self.pos += 2;
                    continue;
                }
            }
            try self.current_word.append(self.allocator, c);
            self.pos += 1;
        }
        return error.UnterminatedDoubleQuote;
    }

    fn parseEscape(self: *Tokenizer) !void {
        self.pos += 1; // skip backslash
        if (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c != '\n') { // \newline is line continuation
                try self.current_word.append(self.allocator, c);
            }
            self.pos += 1;
        }
    }

    fn parseRedirect(self: *Tokenizer, single: TokenKind, double: TokenKind) !void {
        self.pos += 1; // skip first '>'
        if (self.pos < self.input.len and self.input[self.pos] == '>') {
            try self.tokens.append(self.allocator, .{ .kind = double, .value = ">>" });
            self.pos += 1;
        } else {
            try self.tokens.append(self.allocator, .{ .kind = single, .value = ">" });
        }
    }
};

test "simple words" {
    var t = Tokenizer.init("echo hello world", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(3, tokens.len);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
    try std.testing.expectEqualStrings("world", tokens[2].value);
}

test "single quotes" {
    var t = Tokenizer.init("echo 'hello world'", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(2, tokens.len);
    try std.testing.expectEqualStrings("hello world", tokens[1].value);
}

test "double quotes with escape" {
    var t = Tokenizer.init("echo \"hello\\\"world\"", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(2, tokens.len);
    try std.testing.expectEqualStrings("hello\"world", tokens[1].value);
}

test "pipe" {
    var t = Tokenizer.init("ls | grep foo", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(4, tokens.len);
    try std.testing.expectEqual(TokenKind.word, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.pipe, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.word, tokens[2].kind);
}

test "redirect" {
    var t = Tokenizer.init("ls > out.txt", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(3, tokens.len);
    try std.testing.expectEqual(TokenKind.redirect_out, tokens[1].kind);
}

test "no space around operators" {
    var t = Tokenizer.init("pwd|grep home", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(4, tokens.len);
    try std.testing.expectEqualStrings("pwd", tokens[0].value);
    try std.testing.expectEqual(TokenKind.pipe, tokens[1].kind);
    try std.testing.expectEqualStrings("grep", tokens[2].value);
}

test "redirect without spaces" {
    var t = Tokenizer.init("echo test>out.txt", std.testing.allocator);
    defer t.deinit();
    const tokens = try t.tokenize();
    try std.testing.expectEqual(4, tokens.len);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqualStrings("test", tokens[1].value);
    try std.testing.expectEqual(TokenKind.redirect_out, tokens[2].kind);
    try std.testing.expectEqualStrings("out.txt", tokens[3].value);
}
